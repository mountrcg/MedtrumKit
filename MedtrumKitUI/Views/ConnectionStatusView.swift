import CoreBluetooth
import LoopKit
import SwiftUI
import UIKit

/// Where the link to the pump base stands, as a screen needs to show it.
enum MedtrumConnectionStatus: Equatable {
    case connected
    case connecting
    case disconnected
    /// CoreBluetooth itself is unusable, so no connect can succeed until the user acts.
    case bluetoothUnavailable(CBManagerState)

    init(_ state: MedtrumPumpState) {
        // `.unknown` only means CoreBluetooth has not reported yet, so it is not worth alarming over.
        if state.bluetoothState != .poweredOn, state.bluetoothState != .unknown {
            self = .bluetoothUnavailable(state.bluetoothState)
        } else if state.isConnected {
            self = .connected
        } else if state.isConnecting || state.isSearchingForBase {
            self = .connecting
        } else {
            self = .disconnected
        }
    }

    /// CoreBluetooth is stuck where only a relaunch helps - `.unsupported` never reports again.
    var needsAppRestart: Bool {
        guard case let .bluetoothUnavailable(state) = self else {
            return false
        }

        return state != .poweredOff && state != .unauthorized
    }
}

/// Tracks the link to the pump base for any screen that wants to show it.
final class ConnectionStatusViewModel: ObservableObject, PumpManagerStatusObserver {
    private let processQueue = DispatchQueue(label: "com.nightscout.medtrumkit.connectionStatusViewModel")

    @Published var status: MedtrumConnectionStatus = .disconnected

    private weak var pumpManager: MedtrumPumpManager?

    init(_ pumpManager: MedtrumPumpManager?) {
        self.pumpManager = pumpManager

        guard let pumpManager = pumpManager else {
            return
        }

        updateState(pumpManager)
        pumpManager.addStatusObserver(self, queue: processQueue)
    }

    deinit {
        pumpManager?.removeStatusObserver(self)
    }

    func pumpManager(
        _ pumpManager: any LoopKit.PumpManager,
        didUpdate _: LoopKit.PumpManagerStatus,
        oldStatus _: LoopKit.PumpManagerStatus
    ) {
        guard let pumpManager = pumpManager as? MedtrumPumpManager else {
            return
        }

        DispatchQueue.main.async {
            self.updateState(pumpManager)
        }
    }

    private func updateState(_ pumpManager: MedtrumPumpManager) {
        status = MedtrumConnectionStatus(pumpManager.state)
    }
}

/// The antenna that carries the status on its own, where there is no room for a label.
struct ConnectionStatusIcon: View {
    let status: MedtrumConnectionStatus

    var size: CGFloat = 17

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .connectionStatusBreathe(isActive: status.needsAppRestart)
    }

    /// The circle closes only once the patch is reachable, so the shape carries the state too.
    private var symbolName: String {
        switch status {
        case .connected:
            return "antenna.radiowaves.left.and.right.circle"
        case .connecting:
            return "antenna.radiowaves.left.and.right"
        case .bluetoothUnavailable,
             .disconnected:
            return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var gradient: [Color] {
        switch status {
        case .connected:
            return [.statusGreen, .statusDeepGreen]
        case .connecting:
            // The tab bar's own colour, so reaching reads as routine rather than as a warning.
            return [.statusTint, .statusTeal]
        case .disconnected:
            return [.statusRed, Color.statusRed.opacity(0.6)]
        case .bluetoothUnavailable:
            // Amber, not red: nothing is wrong with the patch, the phone is what needs attention.
            return [.statusOrange, .statusWarning]
        }
    }
}

/// The label says what to do, not just what happened - a stuck Bluetooth stack is the user's to fix.
enum MedtrumConnectionStatusLabel {
    static func text(for status: MedtrumConnectionStatus) -> Text {
        switch status {
        case .connected:
            return Text("Connected", comment: "label for connected")
        case .connecting:
            return Text("Connecting...", comment: "label for connecting")
        case .disconnected:
            return Text("Disconnected", comment: "label for disconnected")
        case let .bluetoothUnavailable(state):
            switch state {
            case .poweredOff:
                return Text("Bluetooth off", comment: "label for bluetooth powered off")
            case .unauthorized:
                return Text("Allow Bluetooth", comment: "label for bluetooth unauthorized")
            default:
                // .unsupported is terminal: CoreBluetooth never reports again on this manager.
                return Text("Restart app", comment: "label for bluetooth unusable")
            }
        }
    }
}

/// The antenna-and-label pill that goes in the middle of the navigation bar.
struct ConnectionStatusView: View {
    @ObservedObject var viewModel: ConnectionStatusViewModel

    var body: some View {
        HStack(spacing: 5) {
            ConnectionStatusIcon(status: viewModel.status)

            label
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var label: Text {
        MedtrumConnectionStatusLabel.text(for: viewModel.status)
    }
}

private extension View {
    /// Breathes only where the user has to act. Breathe needs iOS 18, pulse 17.
    @ViewBuilder func connectionStatusBreathe(isActive: Bool) -> some View {
        if #available(iOS 18.0, *) {
            symbolEffect(.breathe.wholeSymbol, options: .speed(1.2).repeating, isActive: isActive)
                .animation(.smooth(duration: 0.50), value: isActive)
        } else if #available(iOS 17.0, *) {
            symbolEffect(.pulse, options: .speed(1.2).repeating, isActive: isActive)
        } else {
            self
        }
    }
}

/// The host app's palette by hand: this framework cannot reach its asset catalogue. Mirrors its
/// tab bar, teal, green and red colours, dark variants included.
private extension Color {
    static let statusTint = statusAdaptive(light: 0x7D8C_F2, dark: .systemTeal)
    static let statusTeal = statusAdaptive(light: 0x00A3_B9, dark: UIColor(statusHex: 0x29BB_D0))
    static let statusGreen = Color(statusHex: 0x6FCF_97)
    static let statusDeepGreen = statusAdaptive(light: 0x2A9F_47, dark: UIColor(statusHex: 0x26A7_46))
    static let statusRed = Color(statusHex: 0xEB57_57)
    static let statusWarning = Color(statusHex: 0xEAC3_45)
    static let statusOrange = statusAdaptive(light: 0xFF8C_42, dark: UIColor(statusHex: 0xFF9B_56))

    /// Not `adaptive`, which collides with a member of `Color` in the iOS 26 SDK.
    static func statusAdaptive(light: UInt32, dark: UIColor) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : UIColor(statusHex: light)
        })
    }

    init(statusHex: UInt32) {
        self.init(UIColor(statusHex: statusHex))
    }
}

private extension UIColor {
    /// Hex, to stay readable next to the asset catalogue it mirrors. There is no such init here.
    convenience init(statusHex: UInt32) {
        self.init(
            red: CGFloat((statusHex >> 16) & 0xFF) / 255,
            green: CGFloat((statusHex >> 8) & 0xFF) / 255,
            blue: CGFloat(statusHex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct ConnectionStatusBarModifier: ViewModifier {
    @ObservedObject var viewModel: ConnectionStatusViewModel

    /// Decided once at build time: the principal item owns the title view, so toggling it live
    /// would take the screen title with it and rebuild the tree underneath.
    let isEnabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isEnabled {
            content
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ConnectionStatusView(viewModel: viewModel)
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    /// Puts the connection status in the middle of the navigation bar, once a serial number exists.
    func connectionStatusBar(_ viewModel: ConnectionStatusViewModel, isEnabled: Bool) -> some View {
        modifier(ConnectionStatusBarModifier(viewModel: viewModel, isEnabled: isEnabled))
    }
}
