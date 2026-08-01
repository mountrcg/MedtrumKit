/// One connect attempt: the caller waiting on it, and the deadline that guarantees they hear
/// back. Connect, disconnect, timeout and the auth flow all race to report a result, so the
/// attempt owns which of them wins rather than each site checking for itself.
final class ConnectAttempt {
    let completion: (MedtrumConnectError?) -> Void
    var timeout: Task<Void, Never>?
    private var reported = false

    init(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        self.completion = completion
    }

    /// True for the first caller only - whoever gets it owns reporting the result.
    func claim() -> Bool {
        guard !reported else {
            return false
        }

        reported = true
        timeout?.cancel()
        timeout = nil

        return true
    }
}
