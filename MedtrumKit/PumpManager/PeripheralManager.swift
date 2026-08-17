import CoreBluetooth

class PeripheralManager: NSObject {
    private let log = MedtrumLogger(category: "PeripheralManager")

    private let peripheral: CBPeripheral
    private let bluetoothManager: BluetoothManager
    private let pumpManager: MedtrumPumpManager
    private var completion: ((MedtrumConnectError?) -> Void)?

    private var readCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?

    // access is serialized by the semaphore inside writePacket
    private var writeSequence: UInt8 = 0

    /// Guards the four fields below. writePacket runs on the caller's thread while the response
    /// arrives on the central manager's queue, so every access to them is cross-thread. Never
    /// held across `writeQ.wait()`, `peripheral.writeValue` or `leave()`.
    private let stateLock = NSLock()

    /* access must be serialized with stateLock */
    private var currentPacket: (any MedtrumBasePacketProtocol)?
    private var currentSequence: UInt8 = 0
    private var writeQueue: MedtrumKitDispatchGroup?
    private var writeResponse: MedtrumWriteResult<Any>?
    /* end */

    private let semaphore = DispatchSemaphore(value: 1)

    /// Where the idle-disconnect timer runs. OmnipodKit hangs idle detection on its session queue;
    /// MedtrumKit has no session concept, so the equivalent is the `writePacket` semaphore plus the
    /// counter below — `activeCommands == 0` is this driver's `sessionQueue.operationCount == 0`.
    private let queue = DispatchQueue(label: "com.nightscout.MedtrumKit.peripheralManagerQueue", qos: .utility)

    /* access must be serialized with idleLock */
    private let idleLock = NSLock()
    /// Callers currently inside `writePacket`, whether waiting on the link or holding it.
    private var activeCommands = 0
    /// When the last command finished with nothing behind it. Reset by the next command, so a burst
    /// disconnects only after its last member.
    private var idleStart: Date?
    /* end */

    /// How long a caller waits for the link before giving up. Deliberately longer than the
    /// exchange timeout in `writePacket`, so one stuck command is waited out and the caller
    /// behind it is not.
    private static let linkWaitTimeoutSeconds = 40

    public init(
        _ peripheral: CBPeripheral,
        _ bluetoothManager: BluetoothManager,
        _ pumpManager: MedtrumPumpManager,
        _ completion: @escaping (MedtrumConnectError?) -> Void
    ) {
        self.peripheral = peripheral
        self.bluetoothManager = bluetoothManager
        self.pumpManager = pumpManager
        self.completion = completion

        super.init()

        peripheral.delegate = self
    }

    func cleanup() {
        stateLock.lock()
        let queue = writeQueue
        writeQueue = nil
        currentPacket = nil
        stateLock.unlock()

        // outside the lock: leave() takes a lock of its own, and it wakes writePacket, which
        // immediately wants ours.
        queue?.leave()
    }

    /// Sends one packet and blocks the caller until its response arrives, or fails.
    ///
    /// Two waits, and both have to be bounded. The inner one covers the exchange itself; the
    /// outer one is the queue for the link, which carries a single command at a time because
    /// the protocol keys responses to one `currentSequence`.
    ///
    /// Bounding the outer wait is what keeps a bad link from going *quiet*. Every caller here
    /// sits on the loop's path — `ensureCurrentPumpData` and every dosing command — and
    /// `trio.aps.loop.notActive` is raised from inside the loop cycle, so a cycle parked here
    /// suppresses the alert that exists to report the stall. On 2026-08-14 five cycles queued
    /// behind one dead patch and drained together after 898 s; Trio raised nothing for the 18
    /// minutes in between. Failing the caller instead lets its cycle finish and alert.
    func writePacket(_ packet: any MedtrumBasePacketProtocol) -> MedtrumWriteResult<Any> {
        guard let characteristic = writeCharacteristic else {
            log.error("No write characteristic found... Device might be disconnected...")
            return .failure(error: .noWriteCharacteristic)
        }

        // Counted before the link wait, so a caller queued behind a running command still keeps the
        // connection off the idle path — the burst shares one connection, as in OmnipodKit.
        idleLock.lock()
        activeCommands += 1
        idleLock.unlock()
        defer { commandDidFinish() }

        // returning before the `defer` below is what keeps this correct: a caller that never
        // took the token must not signal one
        guard semaphore.wait(timeout: .now() + .seconds(Self.linkWaitTimeoutSeconds)) == .success else {
            log.warning("Link still busy after \(Self.linkWaitTimeoutSeconds)s, giving up on this command")
            return .failure(error: .alreadyRunning)
        }
        defer {
            semaphore.signal()
        }

        let writeQ = MedtrumKitDispatchGroup()
        writeQ.enter()

        stateLock.lock()
        writeQueue = writeQ
        currentPacket = packet
        currentSequence = writeSequence
        stateLock.unlock()

        let packages = packet.encode(sequenceNumber: writeSequence)
        writeSequence = UInt8(writeSequence + 1)
        if writeSequence >= 254 {
            writeSequence = 0
        }

        for package in packages {
            log.debug("Writing data: \(package.hexEncodedString())")
            peripheral.writeValue(package, for: characteristic, type: .withResponse)
        }

        // Wait for response or timeout timer...
        _ = writeQ.wait(timeout: .now() + .seconds(30))

        // Tear down as one step: on timeout the delegate may still be mid-flight, and this is
        // what tells it the command is no longer current.
        stateLock.lock()
        let response = writeResponse
        writeQueue = nil
        currentPacket = nil
        writeResponse = nil
        stateLock.unlock()

        guard let response = response else {
            log.warning("Timeout has been reached...")
            return .failure(error: .timeout)
        }

        return response
    }
}

extension PeripheralManager {
    // Connect step 1
    private func doAuthorize(useBackupToken: Bool = false) {
        let token = !useBackupToken ? pumpManager.state.sessionToken : pumpManager.state.backupSessionToken
        let authData = writePacket(
            AuthorizePacket(pumpSN: pumpManager.state.pumpSN, sessionToken: token)
        )

        switch authData {
        case let .failure(error):
            if !useBackupToken {
                log.warning("Failed to complete authorization flow, falling back to backup token")
                doAuthorize(useBackupToken: true)
                return
            }

            log.error("Failed to complete authorization flow: \(error.localizedDescription)")
            bluetoothManager.disconnect()
            completion?(.failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription))

        case let .success(data):
            guard let authResponse = data as? AuthorizeResponse else {
                log.error("Failed to complete authorization flow: invalid response")
                completion?(.failedToCompleteAuthorizationFlow(localizedError: "invalid response"))
                return
            }

            pumpManager.state.deviceType = authResponse.deviceType
            pumpManager.state.swVersion = authResponse.swVersion

            synchronize()
        }
    }

    // Connect step 2
    private func synchronize() {
        let syncData = writePacket(SynchronizePacket())

        switch syncData {
        case let .failure(error):
            log.error("Failed to synchronize: \(error.localizedDescription)")
            bluetoothManager.disconnect()
            completion?(.failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription))

        case let .success(data):
            guard let syncResponse = data as? SynchronizePacketResponse else {
                log.error("Failed to Synchronize packet: invalid response")
                completion?(.failedToCompleteAuthorizationFlow(localizedError: "invalid response"))
                return
            }

            parseStateUpdate(syncResponse, duringReconnect: true, fullSync: true)
            subscribe()
        }
    }

    // Connect step 4 (last)
    private func subscribe() {
        let subscribeData = writePacket(SubscribePacket())

        switch subscribeData {
        case let .failure(error):
            log.error("Failed to subscribe: \(error.localizedDescription)")
            bluetoothManager.disconnect()
            completion?(.failedToCompleteAuthorizationFlow(localizedError: error.localizedDescription))

        case .success:
            log.info("Connected to pump!")

            pumpManager.state.isConnected = true
            pumpManager.notifyStateDidChange()
            completion?(nil)
        }
    }

    private func parseStateUpdate(_ syncResponse: SynchronizePacketResponse, duringReconnect: Bool, fullSync: Bool) {
        // TEMP
        do {
            log.info("State update: \(String(data: try JSONEncoder().encode(syncResponse), encoding: .utf8) ?? "")")
        } catch {
            log.warning("State update: Failed to encode JSON - \(error)")
        }

        StateSyncer.sync(
            syncResponse: syncResponse,
            state: pumpManager.state,
            pumpManager: pumpManager,
            duringReconnect: duringReconnect,
            fullSync: fullSync
        )

        pumpManager.issueHeartbeatIfNeeded()
    }
}

extension PeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log.error("\(error.localizedDescription)")
            completion?(.failedToDiscoverServices(localizedError: error.localizedDescription))
            return
        }

        let service = peripheral.services?.first(where: { $0.uuid == CBUUID.SERVICE_UUID })
        guard let service = service else {
            let localizedError = "No Medtrum service found - " +
                (peripheral.services?.map(\.uuid.uuidString).joined(separator: ", ") ?? "No services discovered")
            log.error(localizedError)
            completion?(.failedToDiscoverServices(localizedError: localizedError))
            return
        }

        peripheral.discoverCharacteristics([CBUUID.READ_UUID, CBUUID.WRITE_UUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log.error("\(error.localizedDescription)")
            completion?(.failedToDiscoverCharacteristics(localizedError: error.localizedDescription))
            return
        }

        readCharacteristic = service.characteristics?.first(where: { $0.uuid == CBUUID.READ_UUID })
        writeCharacteristic = service.characteristics?.first(where: { $0.uuid == CBUUID.WRITE_UUID })

        guard readCharacteristic != nil, writeCharacteristic != nil else {
            let localizedError = "Failed to discover read, write or config characteristic - " +
                (service.characteristics?.map(\.uuid.uuidString).joined(separator: ", ") ?? "No characteristics discovered")

            log.error(localizedError)
            completion?(.failedToDiscoverCharacteristics(localizedError: localizedError))
            return
        }

        // Subscribe on all characteristics with notifying abilities
        service.characteristics?.forEach { characteristic in
            guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                return
            }

            self.log.debug("Enable notify for: \(characteristic.uuid.uuidString)")
            peripheral.setNotifyValue(true, for: characteristic)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }

            self.log.debug("Notify enabled and ready to start auth flow!")
            doAuthorize()
        }
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("Got error from didUpdateValueFor: \(error.localizedDescription)")
            if let connectCompletion = completion {
                connectCompletion(.failedToEnableNotify(localizedError: error.localizedDescription))
            }
            return
        }

        guard let data = characteristic.value else {
            log.warning("No data in didUpdateValueFor - characteristic: \(characteristic.uuid.uuidString)")
            return
        }

        if characteristic.uuid == CBUUID.READ_UUID {
            guard data[1] != 0x00 else {
                pumpManager.issueHeartbeatIfNeeded()
                return
            }

            handleHeartbeat(data: data)
            return
        }

        // Processing data
        log.debug("Got data: \(data.hexEncodedString())")

        stateLock.lock()
        let sequence = currentSequence
        let pending = currentPacket
        stateLock.unlock()

        guard var packet = pending else {
            log.warning("No packet available...")
            return
        }

        // Byte 2 echoes the sequence number of the command this is a response to, on every
        // fragment. It has to be checked on all of them, not just the first: decode() validates
        // a continuation fragment for ordering and CRC only, so a late fragment of an abandoned
        // command would otherwise be appended to whatever packet is now in flight - with a valid
        // CRC and a matching fragment index, so nothing downstream would notice.
        if data.count > 2, data[2] != sequence {
            log.warning("Ignoring response for sequence \(data[2]), waiting on \(sequence)")
            return
        }

        packet.decode(data)

        stateLock.lock()
        guard currentSequence == sequence, writeQueue != nil else {
            // writePacket timed out while we were decoding, and may already have started
            // another command. This response is no longer anybody's.
            stateLock.unlock()
            log.warning("Discarding response for sequence \(sequence), no longer the current command")
            return
        }
        currentPacket = packet
        stateLock.unlock()

        guard packet.isComplete else {
            log.debug("Waiting for more data...")
            return
        }

        if packet.responseCode == 16384 {
            // Need to skip to packet
            log.debug("Skipping this message - data: \(packet.totalData.hexEncodedString())")
            return
        }

        let response: MedtrumWriteResult<Any>
        if packet.responseCode != 0 {
            // Examples for invalid codes:
            // 7 -> Invalid authorization: propably wrong session token used
            // 8 -> Invalid state: The patch is not in state 32 (active), which is required for that command
            log.error("Invalid responseCode: \(packet.responseCode)")
            response = .failure(error: .invalidResponse(code: packet.responseCode))
        } else if packet.failed {
            log.error("Failed to parse message, either wrong command type or CRC check failed...")
            response = .failure(error: .invalidData)
        } else if !packet.hasEnoughData {
            let message =
                "Packet has too little data - expected: \(packet.mimimumDataSize), data: \(packet.totalData.hexEncodedString())"
            log.error(message)

            response = .failure(error: .invalidData)
        } else {
            response = .success(data: packet.parseResponse())
        }

        stateLock.lock()
        guard currentSequence == sequence, let writeCallback = writeQueue else {
            // Timed out between decoding and parsing; writePacket has already given up
            stateLock.unlock()
            return
        }
        writeResponse = response
        writeQueue = nil
        currentPacket = nil
        stateLock.unlock()

        // Outside the lock, and last: this hands writePacket the fields we just finished with.
        writeCallback.leave()
    }

    /// Marks a command done and, if it was the last one, starts the idle countdown.
    private func commandDidFinish() {
        idleLock.lock()
        activeCommands -= 1
        let idle = activeCommands == 0
        if idle {
            idleStart = Date()
        }
        idleLock.unlock()

        if idle {
            scheduleIdleDisconnectIfNeeded()
        }
    }

    /// Connect-on-demand: once the commands stop, drop the link so the patch is left "normally
    /// disconnected" between cycles and the StartDelay probe has something to arm against.
    ///
    /// The delay is kept SHORT (see `BluetoothManager.idleDisconnectSeconds`) so a background wake cycle
    /// disconnects before iOS suspends the app — a suspended app freezes this timer, and OmnipodKit
    /// measured a ~12 min missed loop when the link was still up at that point. A command burst shares one
    /// connection: each command resets `idleStart`, so this only lands after the last of them.
    private func scheduleIdleDisconnectIfNeeded() {
        guard BluetoothManager.connectOnDemandEnabled else { return }
        let idleDelay = BluetoothManager.idleDisconnectSeconds
        idleLock.lock()
        let idleAt = idleStart
        idleLock.unlock()

        queue.asyncAfter(deadline: .now() + idleDelay) { [weak self] in
            guard let self = self, BluetoothManager.connectOnDemandEnabled else { return }

            // Foreground holds the link: the UI wants it, and iOS ignores the start delay there anyway.
            if self.bluetoothManager.shouldHoldConnection {
                self.log.debug("[connectOnDemand] holding connection (foreground) - skip idle-disconnect")
                return
            }

            // Only disconnect if we are still idle (no newer command) and nothing is queued or running.
            self.idleLock.lock()
            let stillIdle = self.idleStart == idleAt && self.activeCommands == 0
            self.idleLock.unlock()
            guard stillIdle, self.peripheral.state == .connected else { return }

            self.log.info("[connectOnDemand] idle ~\(Int(idleDelay))s, no queued command -> disconnecting")
            self.bluetoothManager.disconnectOnDemand()
        }
    }

    private func handleHeartbeat(data: Data) {
        var data = data

        log.debug("READ -> Got data: \(data.hexEncodedString())")
        data.append(0x00) // Little CRC hack. The notification lacks the CRC value, thus add an empty value there

        var packet = NotificationPacket()
        packet.decode(data)

        // Same tolerance as `ensureCurrentPumpData`, for the same reason: it has to span one loop period,
        // otherwise an ordinary cycle finds the data stale and pays for a sync it does not need. At 2.5
        // minutes this gate opened on nearly every heartbeat once a loop period had passed, so the full
        // sync the loop-facing check was widened to avoid came back in through the notification path.
        guard Date.now.timeIntervalSince(pumpManager.state.lastSync) > .minutes(6) else {
            parseStateUpdate(packet.parseResponse(), duringReconnect: false, fullSync: false)
            return
        }

        guard pumpManager.state.bolusState == .noBolus else {
            parseStateUpdate(packet.parseResponse(), duringReconnect: false, fullSync: false)
            log.warning("Skipping sync, pump is currently bolusing")
            return
        }

        // Do full sync (only every 3min)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }

            let response = self.writePacket(SynchronizePacket())
            switch response {
            case let .failure(error):
                self.log.error("Failed to get synchronize: \(error.localizedDescription)")
                return

            case let .success(data):
                guard let syncResponse = data as? SynchronizePacketResponse else {
                    self.log.error("Failed to Synchronize packet: invalid response")
                    return
                }

                self.parseStateUpdate(syncResponse, duringReconnect: false, fullSync: true)
                StateSyncer.fetchPatchTime(pumpManager: self.pumpManager)
            }
        }
    }
}
