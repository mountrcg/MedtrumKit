import CoreBluetooth
@testable import MedtrumKit
import XCTest

final class ConnectionStatusMappingTests: XCTestCase {
    private let unavailableStates: [CBManagerState] = [.poweredOff, .unauthorized, .unsupported, .resetting]

    // MARK: - Initializer

    func testPoweredOnConnectedIsConnected() {
        let status = MedtrumConnectionStatus(isConnected: true, isReconnecting: false, bluetoothState: .poweredOn)
        XCTAssertEqual(status, .connected)
    }

    func testPoweredOnConnectedWinsOverReconnecting() {
        let status = MedtrumConnectionStatus(isConnected: true, isReconnecting: true, bluetoothState: .poweredOn)
        XCTAssertEqual(status, .connected)
    }

    func testPoweredOnReconnectingIsConnecting() {
        let status = MedtrumConnectionStatus(isConnected: false, isReconnecting: true, bluetoothState: .poweredOn)
        XCTAssertEqual(status, .connecting)
    }

    func testPoweredOnIdleIsDisconnected() {
        let status = MedtrumConnectionStatus(isConnected: false, isReconnecting: false, bluetoothState: .poweredOn)
        XCTAssertEqual(status, .disconnected)
    }

    func testUnusableStatesAreBluetoothUnavailable() {
        for state in unavailableStates {
            for isConnected in [true, false] {
                for isReconnecting in [true, false] {
                    let status = MedtrumConnectionStatus(
                        isConnected: isConnected,
                        isReconnecting: isReconnecting,
                        bluetoothState: state
                    )
                    XCTAssertEqual(status, .bluetoothUnavailable(state), "state \(state.rawValue)")
                }
            }
        }
    }

    func testUnknownStateIsNotTreatedAsUnavailable() {
        XCTAssertEqual(
            MedtrumConnectionStatus(isConnected: true, isReconnecting: false, bluetoothState: .unknown),
            .connected
        )
        XCTAssertEqual(
            MedtrumConnectionStatus(isConnected: false, isReconnecting: true, bluetoothState: .unknown),
            .connecting
        )
        XCTAssertEqual(
            MedtrumConnectionStatus(isConnected: false, isReconnecting: false, bluetoothState: .unknown),
            .disconnected
        )
    }

    // MARK: - needsAppRestart

    func testOnlyUnsupportedNeedsAppRestart() {
        XCTAssertFalse(MedtrumConnectionStatus.bluetoothUnavailable(.poweredOff).needsAppRestart)
        XCTAssertFalse(MedtrumConnectionStatus.bluetoothUnavailable(.unauthorized).needsAppRestart)
        XCTAssertTrue(MedtrumConnectionStatus.bluetoothUnavailable(.unsupported).needsAppRestart)
        XCTAssertFalse(MedtrumConnectionStatus.bluetoothUnavailable(.resetting).needsAppRestart)
    }

    func testUnknownAndFutureStatesNeverNeedAppRestart() {
        XCTAssertFalse(MedtrumConnectionStatus.bluetoothUnavailable(.unknown).needsAppRestart)
        if let future = CBManagerState(rawValue: 99) {
            XCTAssertFalse(MedtrumConnectionStatus.bluetoothUnavailable(future).needsAppRestart)
        }
    }

    func testLinkStatesNeverNeedAppRestart() {
        XCTAssertFalse(MedtrumConnectionStatus.connected.needsAppRestart)
        XCTAssertFalse(MedtrumConnectionStatus.connecting.needsAppRestart)
        XCTAssertFalse(MedtrumConnectionStatus.disconnected.needsAppRestart)
    }

    // MARK: - Label kind

    func testLabelKindForUnavailableStates() {
        XCTAssertEqual(MedtrumBluetoothUnavailableKind.kind(for: .poweredOff), .bluetoothOff)
        XCTAssertEqual(MedtrumBluetoothUnavailableKind.kind(for: .unauthorized), .allowBluetooth)
        XCTAssertEqual(MedtrumBluetoothUnavailableKind.kind(for: .unsupported), .restartApp)
        XCTAssertEqual(MedtrumBluetoothUnavailableKind.kind(for: .resetting), .unavailable)
    }

    func testLabelKindForUnknownAndFutureStates() {
        XCTAssertEqual(MedtrumBluetoothUnavailableKind.kind(for: .unknown), .unavailable)
        // CBManagerState is an ObjC enum, so an unlisted raw value models a future SDK case.
        if let future = CBManagerState(rawValue: 99) {
            XCTAssertEqual(MedtrumBluetoothUnavailableKind.kind(for: future), .unavailable)
        }
    }
}
