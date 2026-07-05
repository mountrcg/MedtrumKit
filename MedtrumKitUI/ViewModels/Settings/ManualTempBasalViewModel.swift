import LoopKit

class ManualTempBasalViewModel: ObservableObject {
    @Published var selectedRate = 0.05
    @Published var selectedDuration = TimeInterval.minutes(30)
    @Published var enacting: Bool = false
    @Published var error: String? = nil

    public let allowedRates: [Double] = MedtrumPumpManager.onboardingSupportedBasalRates.filter { $0 > 0 && $0 < 10 }
    public let allowedDurations: [Double] = (1 ... 24).map { Double($0) * TimeInterval.minutes(30) }

    func rateFormatter(for basal: Double) -> String {
        let stepped = (basal / 0.05).rounded() * 0.05
        return String(format: "%.2f", stepped) + " " + String(localized: "U/hr", comment: "Units for showing temp basal rate")
    }

    func durationFormatter(for duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return "\(hours)h \(minutes)min"
    }

    private let pumpManager: MedtrumPumpManager?
    private let goBack: () -> Void
    init(pumpManager: MedtrumPumpManager?, goBack: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.goBack = goBack

        if let pumpManager {
            selectedRate = pumpManager.state.currentBaseBasalRate
        }
    }

    func enact() {
        guard let pumpManager else {
            return
        }

        enacting = true
        pumpManager.enactTempBasal(
            unitsPerHour: selectedRate,
            duration: selectedDuration,
            automatic: false
        ) { error in
            DispatchQueue.main.async {
                self.enacting = false

                if let error {
                    self.error = error.localizedDescription
                } else {
                    self.goBack()
                }
            }
        }
    }
}
