import CoreBluetooth
import UIKit

class BluetoothManager: NSObject, CBCentralManagerDelegate {
    public var pumpManager: MedtrumPumpManager?

    let logger = MedtrumLogger(category: "BluetoothManager")

    var manager: CBCentralManager!
    let managerQueue = DispatchQueue(label: "com.nightscout.MedtrumKit.bluetoothManagerQueue", qos: .unspecified)

    private var peripheral: CBPeripheral?
    private var peripheralManager: PeripheralManager?
    private var forcedDisconnect: Bool = false

    private var scanCompletion: ((MedtrumScanResult) -> Void)?

    private var attempt: ConnectAttempt?

    // MARK: - Pump-provided heartbeat (delayed-connect probe)

    /// Buffer (seconds) added after the next expected CGM reading, so the reading has landed before the
    /// wake drives a loop cycle.
    private static var heartbeatBufferSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "MedtrumKit.heartbeatBufferSeconds") as? Double) ?? 20
    }

    /// Floor (seconds) for the computed StartDelay. An overdue target must not collapse to a near-zero
    /// delay: that produces a tight wake loop which burns the background budget and gets the app
    /// suspended for long stretches.
    private static var heartbeatMinDelaySeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "MedtrumKit.heartbeatMinDelaySeconds") as? Double) ?? 60
    }

    /// Backoff (seconds) before re-arming after a connect failure, so a failing probe doesn't spin.
    private static var heartbeatFailureBackoffSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "MedtrumKit.heartbeatFailureBackoffSeconds") as? Double) ?? 30
    }

    /// Off by default, and measured to be the right default: the probe can only arm while the link is
    /// down, and the link goes down about six times a day — under 5% of loop cycles. Covering the rest
    /// needs a deliberate idle-disconnect, which MedtrumKit has no session concept to hang one on. The
    /// silent-tones keep-alive already removes the throttling outright (20 ms vs 142 ms per cycle,
    /// measured three hours apart on 2026-08-16), so this stays available to experiment with rather than
    /// carrying its risk for a few percent. Off means the previous behaviour exactly: reconnect
    /// immediately on every drop, never issue a StartDelay connect.
    static var delayedConnectProbeEnabled: Bool {
        (UserDefaults.standard.object(forKey: "MedtrumKit.delayedConnectProbeEnabled") as? Bool) ?? false
    }

    /// Drop the link a few seconds after the last command, so the probe has something to arm against.
    /// Off by default; the probe alone only covers the involuntary drops, which is under 5% of cycles.
    ///
    /// Ported from OmnipodKit, where the pair has been in production against the same host and the same
    /// iOS behaviour. Kept deliberately close to it — names, defaults and structure — so the two can be
    /// reviewed against each other.
    static var connectOnDemandEnabled: Bool {
        (UserDefaults.standard.object(forKey: "MedtrumKit.connectOnDemandEnabled") as? Bool) ?? false
    }

    /// Idle-disconnect delay (seconds) after the last command. Kept SHORT so a background wake cycle
    /// disconnects promptly — before iOS suspends the app — which lets the StartDelay probe re-arm (it
    /// needs a DISCONNECTED patch). OmnipodKit measured the failure mode of a long delay: the app
    /// suspended with the link still up and the timer frozen, so the probe never re-armed and a loop was
    /// missed for ~12 min. A command burst still shares one connection: each command resets `idleStart`,
    /// so the disconnect lands this many seconds after the LAST one.
    static var idleDisconnectSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "MedtrumKit.idleDisconnectSeconds") as? Double) ?? 4
    }

    /// True while the app is in the foreground. Set from the lifecycle notifications, read from
    /// `managerQueue` and cross-queue by PeripheralManager — a benign bool race, as in OmnipodKit.
    private var isAppForeground = true

    /// Hold the link rather than dropping it to idle. Foreground only: the UI wants the patch connected,
    /// and `CBConnectPeripheralOptionStartDelayKey` is a background-only mechanism — iOS ignores the delay
    /// while the app is foreground, so a foreground probe connects at once, is taken for a wake,
    /// disconnects, re-arms and churns.
    var shouldHoldConnection: Bool {
        isAppForeground
    }

    /// Set from `setBLEHeartbeatRequest`: the host wants the pump to provide the BLE heartbeat.
    private var heartbeatEnabled = false
    /// When the next wake should land — (lastCGMReading + expectedInterval + buffer).
    private var heartbeatTargetDate: Date?
    /// Reading interval last supplied, used to advance a chronically stale target.
    private var heartbeatInterval: TimeInterval?
    /// When the target was last refreshed, to tell a briefly-late reading from a target nobody updates.
    private var heartbeatTargetSetAt: Date?
    /// True while a StartDelay connect is in flight, so we don't stack probes.
    private var delayedProbeInFlight = false
    /// Set when a scheduled wake connected: the link is dropped again straight away and the heartbeat is
    /// fired from the disconnect handler, so the loop cycle runs with the radio idle and the next wake
    /// already armed. Its commands then connect on demand instead of fighting the probe's link.
    private var pendingHeartbeatFire = false

    /// The probe needs a DISCONNECTED peripheral: CoreBluetooth only honours the start delay on a fresh
    /// connect. While the link is up the app has no scheduled wake at all — it runs only when the patch
    /// happens to send something, which is what leaves every loop cycle to start in a freshly resumed,
    /// background-throttled process.
    private var delayedProbeUsable: Bool {
        BluetoothManager.delayedConnectProbeEnabled && heartbeatEnabled && attempt == nil
            && !shouldHoldConnection
    }

    // MUST NOT be called from within managerQueue - deadlock
    public var isConnected: Bool {
        managerQueue.sync { isConnectedOnQueue }
    }

    private var isConnectedOnQueue: Bool {
        if let peripheral = peripheral, peripheral.state == .connected {
            return true
        }

        return false
    }

    override init() {
        super.init()

        managerQueue.sync {
            self.manager = CBCentralManager(
                delegate: self,
                queue: managerQueue,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "com.nightscout.MedtrumKit.bluetoothManager"]
            )
        }

        for (name, foreground) in [
            (UIApplication.didBecomeActiveNotification, true),
            (UIApplication.didEnterBackgroundNotification, false)
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.managerQueue.async { self?.isAppForeground = foreground }
            }
        }
    }

    /// Drop the link between commands, leaving the patch "normally disconnected" so the StartDelay probe
    /// can arm against it.
    ///
    /// Routed through `managerQueue` on purpose: OmnipodKit found that cancelling from the
    /// PeripheralManager queue raced CoreBluetooth's teardown and wedged the next connect. `force` stays
    /// false so `didDisconnect` runs its arming path rather than returning early on `forcedDisconnect`.
    func disconnectOnDemand() {
        disconnect(force: false)
    }

    private func startScan(_ completion: @escaping (_ result: MedtrumScanResult) -> Void) {
        if let pumpManager = self.pumpManager, pumpManager.state.pumpSN.isEmpty {
            completion(.failure(error: .noSerialNumberAvailable))
            return
        }
        guard manager.state == .poweredOn else {
            completion(.failure(error: .invalidBluetoothState(state: manager.state)))
            return
        }

        if manager.isScanning {
            manager.stopScan()
        }

        scanCompletion = completion
        manager.scanForPeripherals(withServices: [])

        logger.info("Started scanning")
        // TODO: Add scan timeout - 15s?
    }

    private func connect(peripheral: CBPeripheral) {
        if manager.isScanning {
            manager.stopScan()
            scanCompletion = nil
        }

        logger.info("Connecting to \(peripheral)")

        self.peripheral = peripheral
        manager.connect(peripheral)
    }

    /// Hands a result to a caller. Never on the current thread: completions issue blocking BLE
    /// writes: from the main thread that freezes the UI for up to 30s per packet (syncPumpTime
    /// sends three), and from managerQueue - which every caller of this is now on - it would
    /// deadlock outright, since that is the queue the response has to be delivered on.
    private func report(_ error: MedtrumConnectError?, to completion: @escaping (MedtrumConnectError?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(error)
        }
    }

    /// Reports `attempt` to everyone waiting on it, if nobody has yet. Must be called on
    /// `managerQueue`.
    private func finish(_ attempt: ConnectAttempt, _ error: MedtrumConnectError?) {
        guard attempt.claim() else {
            return
        }

        if self.attempt === attempt {
            self.attempt = nil
        }

        for completion in attempt.completions {
            report(error, to: completion)
        }
    }

    /// Enable and schedule the pump-provided heartbeat. Driven by `PumpManager.setBLEHeartbeatRequest`,
    /// i.e. refreshed after every CGM reading, so the wake cadence tracks the actual reading schedule.
    /// `expectedCGMReadingInterval == nil` disables it and restores plain connect-on-demand.
    ///
    /// Refreshing the target while a probe is in flight does not churn it — the in-flight probe completes
    /// and the next one picks up the new target.
    func setHeartbeatRequest(lastCGMReadingDate: Date?, expectedCGMReadingInterval: TimeInterval?) {
        managerQueue.async {
            if let interval = expectedCGMReadingInterval {
                let base = lastCGMReadingDate ?? Date()
                self.heartbeatTargetDate = base
                    .addingTimeInterval(interval + BluetoothManager.heartbeatBufferSeconds)
                self.heartbeatInterval = interval
                self.heartbeatTargetSetAt = Date()
                self.heartbeatEnabled = true
            } else {
                self.heartbeatTargetDate = nil
                self.heartbeatInterval = nil
                self.heartbeatTargetSetAt = nil
                self.heartbeatEnabled = false
            }

            let targetDesc = self.heartbeatTargetDate.map { String(format: "%.0fs", $0.timeIntervalSinceNow) } ?? "-"
            self.logger.info("[heartbeat] enabled=\(self.heartbeatEnabled) targetIn=\(targetDesc)")

            if self.heartbeatEnabled {
                self.issueDelayedConnectProbe()
            }
        }
    }

    /// Issue a connect carrying `CBConnectPeripheralOptionStartDelayKey`, so iOS itself wakes the app when
    /// the delay elapses. This is the only scheduled wake the driver has: it holds no timers, and a timer
    /// would not survive suspension anyway. Background-only — iOS ignores the delay in the foreground, where
    /// the app is not being throttled and does not need it.
    ///
    /// Returns whether a probe was actually issued, so a caller that skipped the immediate reconnect can
    /// fall back to it rather than leave the link down with nothing scheduled.
    ///
    /// Must be called on `managerQueue`.
    @discardableResult
    private func issueDelayedConnectProbe() -> Bool {
        guard delayedProbeUsable, !delayedProbeInFlight else { return false }
        guard let peripheral = peripheral ?? knownPeripheralOnQueue() else { return false }
        guard peripheral.state == .disconnected else { return false }

        // A target nobody refreshes goes chronically overdue and every probe then collapses onto the floor,
        // which is exactly the tight wake loop the floor exists to prevent. Advance it by whole reading
        // intervals instead. A host that refreshes every reading never reaches this.
        if let interval = heartbeatInterval, interval > 0,
           let setAt = heartbeatTargetSetAt, Date().timeIntervalSince(setAt) > interval * 1.5,
           var advanced = heartbeatTargetDate, advanced <= Date()
        {
            let now = Date()
            while advanced <= now { advanced.addTimeInterval(interval) }
            heartbeatTargetDate = advanced
        }

        let target = heartbeatTargetDate ?? Date().addingTimeInterval(BluetoothManager.heartbeatMinDelaySeconds)
        // The option takes an INTEGER number of seconds; a fractional NSNumber is rejected outright with
        // CBErrorDomain Code=1, which together with the failure re-arm would spin.
        let delaySeconds = max(
            Int(BluetoothManager.heartbeatMinDelaySeconds),
            Int(target.timeIntervalSinceNow.rounded())
        )

        if manager.isScanning {
            manager.stopScan()
            scanCompletion = nil
        }

        self.peripheral = peripheral
        delayedProbeInFlight = true
        logger.info("[heartbeat] issuing connect with StartDelay=\(delaySeconds)s")
        manager.connect(peripheral, options: [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: delaySeconds)])
        return true
    }

    /// The peripheral we are paired with, without scanning. Mirrors the retrieve path in
    /// `ensureConnectedOnQueue` — a scan only ever discovers anything in the foreground.
    private func knownPeripheralOnQueue() -> CBPeripheral? {
        guard manager?.state == .poweredOn,
              let identifier = pumpManager?.state.peripheralIdentifier
        else {
            return nil
        }

        return manager.retrievePeripherals(withIdentifiers: [identifier]).first
    }

    func ensureConnected(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        managerQueue.async {
            self.ensureConnectedOnQueue(completion)
        }
    }

    private func ensureConnectedOnQueue(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        // Wait on the connect already in flight instead of failing. A connect owns the link for as
        // long as auth, synchronize and subscribe take, and anything the loop or the user asks for
        // in that window used to be turned away outright - a bolus issued in the same second as a
        // reconnect would fail while the link it needed came up moments later.
        if let inFlight = attempt {
            logger.debug("EnsureConnected is already running, waiting on it")
            inFlight.addCompletion(completion)
            return
        }

        let attempt = ConnectAttempt(completion)
        self.attempt = attempt
        // A real command supersedes any pending scheduled wake: its connect carries no start delay, and
        // leaving the flag set would block every later probe.
        delayedProbeInFlight = false

        if let peripheral = peripheral, peripheral.state == .connected {
            logger.debug("Already connect!")
            finish(attempt, nil)
            return
        }

        if let peripheral = peripheral {
            // We've the peripheral reference to a previous connection
            // Just try to reconnect
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        // We lost the reference but know which device we are paired with. Ask CoreBluetooth for it
        // back rather than scanning: a connect to a known peripheral is honoured in the background
        // (and stays pending until the pump is in range again), while a scan only ever discovers
        // anything while the app is in the foreground.
        if manager.state == .poweredOn,
           let identifier = pumpManager?.state.peripheralIdentifier,
           let peripheral = manager.retrievePeripherals(withIdentifiers: [identifier]).first
        {
            logger.info("Retrieved known peripheral \(identifier), reconnecting")
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        let connectedDevices = manager.retrieveConnectedPeripherals(withServices: [CBUUID.SERVICE_UUID])
        if let peripheral = connectedDevices.first(where: { $0.name == "MT" }) {
            // Phone is already connected, but the app is not
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        guard var pumpSNState = pumpManager?.state.pumpSN else {
            logger.error("No pump serial number found")
            finish(attempt, .failedToFindDevice)
            return
        }

        pumpSNState = Data(pumpSNState.reversed())

        // We are disconnected and have no reference to the previous connection
        // Start to scan for patch and reconnect the long way
        startTimeout(attempt, seconds: .seconds(15))
        startScan { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .failure(error):
                self.logger.error("Error during scanning: \(error.localizedDescription)")
                self.manager.stopScan()
                self.finish(attempt, .failedToFindDevice)

            case let .success(peripheral, pumpSN, _, _):
                guard pumpSN == pumpSNState else {
                    // Other patch pump found. IGNORE
                    return
                }

                self.connect(peripheral: peripheral)
            }
        }
    }

    /// Arms the deadline for `attempt`, replacing any deadline already on it. Called at each point
    /// the connect flow makes progress, so the allowance for waking up suspended starts over.
    private func startTimeout(_ attempt: ConnectAttempt, seconds: TimeInterval) {
        attempt.remainingExtensions = ConnectAttempt.maxExtensions
        armTimeout(attempt, seconds: seconds)
    }

    private func armTimeout(_ attempt: ConnectAttempt, seconds: TimeInterval) {
        attempt.timeout?.cancel()
        attempt.armedAt = .now

        attempt.timeout = Task { [weak self, weak attempt] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            } catch {
                // Cancelled, because the attempt was reported before we woke
                return
            }

            guard let self else {
                return
            }

            managerQueue.async { [weak self, weak attempt] in
                // is this still the attempt in flight? Covers being superseded by a re-arm, and waking a moment before cancellation landed.
                guard let self, let attempt, self.attempt === attempt else {
                    return
                }

                // `Task.sleep` is frozen while iOS has the app suspended, so waking far past the budget
                // means we were asleep for most of it rather than waiting on a pump that never answered
                // - and we typically wake because the connection we were waiting for just arrived. Give
                // the attempt the budget it never got instead of failing a connect that may be landing
                // in this very instant. Bounded, so a phone that keeps suspending still terminates.
                let elapsed = Date.now.timeIntervalSince(attempt.armedAt)
                if elapsed > seconds * 2, attempt.remainingExtensions > 0 {
                    attempt.remainingExtensions -= 1
                    self.logger
                        .warning(
                            "Timeout woke after \(Int(elapsed))s of a \(Int(seconds))s budget - app was suspended, re-arming"
                        )
                    self.armTimeout(attempt, seconds: seconds)
                    return
                }

                // Don't skip this just because the peripheral is connected by now: the link coming up
                // is not the same as being ready, since auth, synchronize and subscribe still follow.
                // Skipping would leave the attempt in flight with nothing to clear it, wedging every
                // later ensureConnected. didConnect re-arms us on a longer budget.
                self.logger.error("Failed to connect: Timeout reached...")

                if self.manager.isScanning {
                    self.manager.stopScan()
                    self.scanCompletion = nil
                }

                self.finish(attempt, .failedToConnectToDevice)
            }
        }
    }

    func write(_ packet: any MedtrumBasePacketProtocol) -> MedtrumWriteResult<Any> {
        // Only the lookup is serialised. writePacket blocks for up to 30s waiting for a response
        // that is delivered on managerQueue, so it must not be holding the queue while it waits.
        guard let peripheralManager = managerQueue.sync(execute: { self.peripheralManager }) else {
            return .failure(error: .noManager)
        }

        return peripheralManager.writePacket(packet)
    }

    func disconnect(force: Bool = false) {
        managerQueue.async {
            self.disconnectOnQueue(force: force)
        }
    }

    private func disconnectOnQueue(force: Bool) {
        forcedDisconnect = force

        if let peripheral, peripheral.state == .connected {
            manager.cancelPeripheralConnection(peripheral)
        }

        if force {
            clearPeripheralOnQueue()
        }
    }

    /// Forgets the device entirely - used when the patch is deactivated and when the pump base is
    /// swapped for another one. It also drops the stored identifier, so the next connect has to
    /// find the base by scanning, which is fine: both of those are foreground activities.
    func clearPeripheral() {
        managerQueue.async {
            self.clearPeripheralOnQueue()
        }
    }

    private func clearPeripheralOnQueue() {
        peripheral = nil
        peripheralManager = nil

        if pumpManager?.state.peripheralIdentifier != nil {
            pumpManager?.state.peripheralIdentifier = nil
            pumpManager?.notifyStateDidChange()
        }
    }
}

extension BluetoothManager {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("\(String(describing: central.state.rawValue))")

        guard central.state == .poweredOn else {
            return
        }

        guard attempt == nil else {
            // Somebody is already connecting and owns the attempt. Installing ours over it would
            // strand that caller - they would never be called back at all.
            logger.info("Powered on while a connect attempt is in flight, leaving it be")
            return
        }

        if let peripheral = self.peripheral {
            logger.info("Reconnecting to restored state...")

            let attempt = ConnectAttempt { [weak self] (error: MedtrumConnectError?) in
                if let error = error {
                    self?.logger.error("Failed to restore state: \(error)")
                } else {
                    self?.logger.info("Restored state!")
                }
            }
            self.attempt = attempt

            // Without this the restore path has no deadline at all: a connect that never completes
            // leaves the attempt in flight for good, and every later ensureConnected fails.
            startTimeout(attempt, seconds: .seconds(15))
            connect(peripheral: peripheral)
            return
        }

        if !isConnectedOnQueue, pumpManager?.state.pumpState == .active {
            ensureConnectedOnQueue { error in
                if let error = error {
                    self.logger.error("Failed to auto reconnect on boot: \(error)")
                }
            }
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !name.isEmpty, name == "MT" else {
            return
        }

        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey]
        guard let manufacturerData = manufacturerData as? Data, manufacturerData.count >= 7 else {
            // Simulator bypass -> 200u
            scanCompletion?(
                .success(
                    peripheral: peripheral,
                    pumpSN: Data([0x28, 0xD8, 0x12, 0x4A]),
                    deviceType: 1,
                    version: 1
                )
            )
            // Simulator bypass -> 300u
            scanCompletion?(
                .success(
                    peripheral: peripheral,
                    pumpSN: Data([0x14, 0x16, 0xDF, 0x52]),
                    deviceType: 1,
                    version: 1
                )
            )
            return
        }

        // Index:
        // 0 & 1 -> Manufacturer ID
        // 2-5 -> PumpSN
        // 6 -> Device type
        // 7 -> Version
        scanCompletion?(
            .success(
                peripheral: peripheral,
                pumpSN: manufacturerData[2 ..< 6],
                deviceType: manufacturerData[6],
                version: manufacturerData[7]
            )
        )
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to pump: \(peripheral.name ?? "<NO_NAME>")!")

        // This guard drops the link rather than just returning. `peripheral` is already set at this
        // point, so bailing out would leave a live peripheral with no PeripheralManager behind it:
        // the next ensureConnected reports "Already connect!" while every write fails with
        // .noManager, and nothing clears that until the link happens to drop on its own.
        guard let pumpManager = pumpManager else {
            logger.warning("No pumpManager...")
            disconnectOnQueue(force: true)
            return
        }

        // A scheduled wake, with nobody waiting on the link. Its only job is to get the app running for a
        // loop cycle, so drop it again immediately rather than authorising and subscribing: the disconnect
        // handler fires the heartbeat and re-arms the next wake, and the loop's own commands take the link
        // through ensureConnected. Holding this link instead would put us right back where we started —
        // connected, idle, and never scheduled.
        if delayedProbeInFlight, attempt == nil {
            logger.info("[heartbeat] scheduled wake connected - dropping link, firing heartbeat")
            delayedProbeInFlight = false
            pendingHeartbeatFire = true
            self.peripheral = peripheral
            manager.cancelPeripheralConnection(peripheral)
            return
        }

        // The attempt this belongs to already gave up - typically its deadline fired while the app
        // was suspended, in the same instant the link finally came up. Do not throw the connection
        // away: reconnecting to a known peripheral is the only thing that works while backgrounded,
        // and dropping it here strands us on the scan path, which does not. Nobody is waiting on
        // the result any more, so adopt it under an attempt of our own and finish the flow.
        let attempt: ConnectAttempt
        if let inFlight = self.attempt {
            attempt = inFlight
        } else {
            logger.info("No connectCompletion, adopting the connection anyway")

            attempt = ConnectAttempt { [weak self] (error: MedtrumConnectError?) in
                if let error = error {
                    self?.logger.error("Failed to complete adopted connection: \(error)")
                } else {
                    self?.logger.info("Adopted connection is ready")
                }
            }
            self.attempt = attempt
        }

        forcedDisconnect = false
        // Whatever brought the link up, the scheduled wake has been consumed. The next one is armed on
        // disconnect, once this connection's work is done.
        delayedProbeInFlight = false

        self.peripheral = peripheral
        // Remember what to reconnect to. Only identifiers that actually produced a connection get
        // stored, and it survives an app restart, so the scan path is only ever needed for pairing.
        if pumpManager.state.peripheralIdentifier != peripheral.identifier {
            pumpManager.state.peripheralIdentifier = peripheral.identifier
            pumpManager.notifyStateDidChange()
        }

        peripheralManager = PeripheralManager(peripheral, self, pumpManager) { [weak self] error in
            // Called from two queues: the CBPeripheralDelegate callbacks report discovery failures
            // on managerQueue, while the auth flow runs on a global worker and reports from there.
            // Land both on managerQueue, since that is where finish reads and clears the attempt.
            self?.managerQueue.async {
                self?.finish(attempt, error)
            }
        }

        // The link is up but the flow is not done - auth, synchronize and subscribe still have to
        // run, and each of those is a writePacket with its own 30s timeout. Re-arm on a budget that
        // covers all of them, so a stalled flow still reports back instead of hanging the caller.
        startTimeout(attempt, seconds: .seconds(150))

        peripheral.discoverServices([CBUUID.SERVICE_UUID])
    }

    func centralManager(_ centralManager: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let peripheral = peripherals.first else {
            logger.warning("No restored peripherals!")
            return
        }

        if peripheral.services?.first(where: { $0.uuid == CBUUID.SERVICE_UUID }) == nil {
            logger.warning("Couldnt restore state, since no service is available...")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        self.peripheral = peripheral
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger
            .info(
                "Device disconnected, name: \(peripheral.name ?? "<NO_NAME>"), error: \(error?.localizedDescription ?? "No error")"
            )

        if forcedDisconnect {
            forcedDisconnect = false
            return
        }

        // Clear before anything can arm a new probe: a flag left over from a connect that never landed
        // would silently block the re-arm, and the guard inside issueDelayedConnectProbe gives no signal.
        delayedProbeInFlight = false

        if let pumpManager = self.pumpManager {
            pumpManager.state.isConnected = false
            pumpManager.notifyStateDidChange()
        }

        if let peripheralManager = peripheralManager {
            peripheralManager.cleanup()
            self.peripheralManager = nil
        }

        if let attempt = attempt {
            finish(attempt, .failedToConnectToDevice)
        } else if !(delayedProbeUsable && issueDelayedConnectProbe()) {
            // Nobody is waiting on the link and no wake could be armed. Reconnecting right back is what
            // leaves the app holding a live but idle connection — iOS then has no reason to schedule it,
            // so the next loop cycle starts in a freshly resumed, throttled process. But an unarmed link
            // that nobody reconnects is worse: it stays down until some command happens to need it.
            ensureConnectedOnQueue { error in
                if let error = error {
                    self.logger.warning("Failed to auto-reconnect: \(error)")
                }
            }
        }

        // A scheduled wake ends here, not at didConnect: the link is down again and the next wake is
        // already armed, so the loop cycle runs with the radio idle and its commands connect on demand.
        if pendingHeartbeatFire {
            pendingHeartbeatFire = false
            pumpManager?.issueHeartbeatNow()
        }
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger
            .info(
                "Device connect error, name: \(peripheral.name ?? "<NO_NAME>"), error: \(error?.localizedDescription ?? "No error")"
            )

        if let pumpManager = self.pumpManager {
            pumpManager.state.isConnected = false
            pumpManager.notifyStateDidChange()
        }

        // The attempt is over, so report it now. Leaving it to the timeout means the caller waits
        // out the full budget for a failure we already know about.
        if let attempt = attempt {
            finish(attempt, .failedToConnectToDevice)
        }

        // Re-arm the scheduled wake, but not immediately: a probe that fails and re-arms at once spins.
        if delayedProbeInFlight {
            delayedProbeInFlight = false
            let backoff = BluetoothManager.heartbeatFailureBackoffSeconds
            managerQueue.asyncAfter(deadline: .now() + backoff) { [weak self] in
                self?.issueDelayedConnectProbe()
            }
        }
    }
}
