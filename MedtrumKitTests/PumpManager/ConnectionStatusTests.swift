import CoreBluetooth
import LoopKit
@testable import MedtrumKit
import XCTest

/// Regression coverage for the synchronized connection-status read model: the status precedence
/// derived from a snapshot, and the connect-wait cancellation contract that late completions must
/// respect. Both exercise real production types with no mock or standalone harness.
final class ConnectionStatusTests: XCTestCase {
    // MARK: - Snapshot -> status precedence

    /// Builds a snapshot straight from a real `MedtrumPumpState`, mutating only the four
    /// connection-relevant fields the snapshot reads.
    private func snapshot(
        connected: Bool = false,
        connecting: Bool = false,
        searchingForBase: Bool = false,
        bluetooth: CBManagerState = .poweredOn
    ) -> MedtrumConnectionStatusSnapshot {
        let state = MedtrumPumpState(rawValue: [:])
        state.isConnected = connected
        state.isConnecting = connecting
        state.isSearchingForBase = searchingForBase
        state.bluetoothState = bluetooth
        return MedtrumConnectionStatusSnapshot(state)
    }

    func testUnusableBluetoothOutranksEverythingElse() {
        // Even a fully connected patch reads as unavailable when the radio is unusable, because
        // nothing can be trusted once CoreBluetooth is down.
        let status = MedtrumConnectionStatus(snapshot(connected: true, connecting: true, bluetooth: .poweredOff))
        XCTAssertEqual(status, .bluetoothUnavailable(.poweredOff))
    }

    func testPoweredOnAndUnknownAreTreatedAsUsableRadio() {
        // `.unknown` only means CoreBluetooth has not reported yet, so it must not alarm.
        XCTAssertEqual(MedtrumConnectionStatus(snapshot(connected: true, bluetooth: .unknown)), .connected)
        XCTAssertEqual(MedtrumConnectionStatus(snapshot(connected: true, bluetooth: .poweredOn)), .connected)
    }

    func testConnectedOutranksConnecting() {
        let status = MedtrumConnectionStatus(snapshot(connected: true, connecting: true, searchingForBase: true))
        XCTAssertEqual(status, .connected)
    }

    func testConnectingCoversBothInFlightFlags() {
        XCTAssertEqual(MedtrumConnectionStatus(snapshot(connecting: true)), .connecting)
        XCTAssertEqual(MedtrumConnectionStatus(snapshot(searchingForBase: true)), .connecting)
    }

    func testDisconnectedWhenIdleOnUsableRadio() {
        XCTAssertEqual(MedtrumConnectionStatus(snapshot()), .disconnected)
    }

    func testClearPeripheralPublishesDisconnectedSnapshot() {
        let manager = MedtrumPumpManager(state: MedtrumPumpState(rawValue: [:]))
        manager.updateConnectionStatus { $0.isConnected = true }
        XCTAssertTrue(manager.connectionStatusSnapshot.isConnected)

        let snapshotDidDisconnect = expectation(description: "clear publishes disconnected snapshot")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(0.9)
            while Date() < deadline {
                if !manager.connectionStatusSnapshot.isConnected {
                    snapshotDidDisconnect.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        manager.bluetooth.clearPeripheral()
        wait(for: [snapshotDidDisconnect], timeout: 1)
        XCTAssertFalse(manager.connectionStatusSnapshot.isConnected)
    }

    /// Clearing from a connected state while a `peripheralIdentifier` is stored used to publish two
    /// state notifications: one for the `isConnected` flip and a second for dropping the identifier.
    /// The clear must coalesce both into a single notification that already reflects the final,
    /// disconnected, identifier-less state.
    func testClearFromConnectedWithStoredIdentifierPublishesSingleFinalNotification() {
        let manager = MedtrumPumpManager(state: MedtrumPumpState(rawValue: [:]))
        manager.state.peripheralIdentifier = UUID()
        manager.updateConnectionStatus { $0.isConnected = true }
        XCTAssertTrue(manager.connectionStatusSnapshot.isConnected)
        XCTAssertNotNil(manager.state.peripheralIdentifier)

        let observer = NotificationCountingObserver()
        manager.addStatusObserver(observer, queue: .main)

        manager.bluetooth.clearPeripheral()

        // Let the async clear run and every main-queue notification it enqueues settle, then drain
        // the main queue once more so a stray second notification would have been counted by now.
        let settled = expectation(description: "clear and its notifications settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(observer.updateCount, 1, "clear must publish exactly one state notification")
        XCTAssertFalse(manager.connectionStatusSnapshot.isConnected)
        XCTAssertNil(manager.state.peripheralIdentifier)
        // The lone notification observed the already-consolidated final state.
        XCTAssertEqual(observer.isConnectedAtNotification, [false])
        XCTAssertEqual(observer.identifierPresentAtNotification, [false])
    }

    // MARK: - ConnectionWait cancellation contract

    func testNormalFinishDeliversResult() async {
        let wait = ConnectionWait()
        let waiter = Task { await wait.wait() }
        wait.finish(.failedToConnectToDevice)

        let result = await waiter.value
        guard case .failedToConnectToDevice = result else {
            return XCTFail("Expected the finished error to be delivered, got \(String(describing: result))")
        }
    }

    func testFinishBeforeWaitReturnsStoredResult() async {
        let wait = ConnectionWait()
        wait.finish(.failedToFindDevice)

        let result = await wait.wait()
        guard case .failedToFindDevice = result else {
            return XCTFail("Expected the pre-stored error to be returned, got \(String(describing: result))")
        }
    }

    func testCancellationResumesWaiterAndLateCompletionIsIgnored() async {
        let wait = ConnectionWait()
        let waiter = Task { await wait.wait() }

        // Cancelling only releases this waiter; it resumes with nil regardless of ordering with the
        // continuation install, because `withTaskCancellationHandler` runs `onCancel` either way.
        waiter.cancel()
        let result = await waiter.value
        XCTAssertNil(result, "Cancellation must resume the waiter with no error")

        // A completion that lands after cancellation must be dropped, never re-resuming the already
        // finished continuation.
        wait.finish(.failedToConnectToDevice)
    }
}

/// Records every `didUpdate` callback so a test can assert the exact number of published state
/// notifications and the connection state visible at each one.
private final class NotificationCountingObserver: PumpManagerStatusObserver {
    private(set) var updateCount = 0
    private(set) var isConnectedAtNotification: [Bool] = []
    private(set) var identifierPresentAtNotification: [Bool] = []

    func pumpManager(_ pumpManager: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        updateCount += 1
        guard let manager = pumpManager as? MedtrumPumpManager else { return }
        isConnectedAtNotification.append(manager.connectionStatusSnapshot.isConnected)
        identifierPresentAtNotification.append(manager.state.peripheralIdentifier != nil)
    }
}
