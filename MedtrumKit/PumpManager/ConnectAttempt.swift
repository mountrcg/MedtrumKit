import Foundation

/// Bridges a callback-owned connection attempt into a task. Cancellation only releases this
/// waiter; it never completes or cancels the shared BLE attempt other commands may be using.
final class ConnectionWait {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MedtrumConnectError?, Never>?
    private var isFinished = false
    private var result: MedtrumConnectError?

    func wait() async -> MedtrumConnectError? {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isFinished {
                    let result = result
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }, onCancel: {
            finish(nil)
        })
    }

    func finish(_ result: MedtrumConnectError?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

/// One connect attempt: the callers waiting on it, and the deadline that guarantees they hear
/// back. Connect, disconnect, timeout and the auth flow all race to report a result, so the
/// attempt owns which of them wins rather than each site checking for itself.
///
/// An attempt can carry more than one caller. A connect takes seconds to complete - auth,
/// synchronize and subscribe all have to run - and anything the loop or the user asks for in that
/// window joins the attempt in flight rather than being turned away.
///
/// NOT thread safe, `BluetoothManager` MUST access its attempt from `managerQueue`.
final class ConnectAttempt {
    private(set) var completions: [(MedtrumConnectError?) -> Void]
    var timeout: Task<Void, Never>?
    var timeoutGeneration = 0
    private var reported = false

    /// When the deadline currently in flight was armed. `Task.sleep` does not advance while iOS has
    /// the app suspended, so a timeout that wakes far past its budget never actually spent it
    /// waiting - see `BluetoothManager.startTimeout`.
    var armedAt: Date = .now

    static let maxExtensions = 2

    /// How many times a deadline may still be re-armed after waking up suspended. Bounded so the
    /// attempt always terminates, even if the app keeps getting suspended.
    var remainingExtensions = ConnectAttempt.maxExtensions

    init(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        completions = [completion]
    }

    /// Adds a caller to an attempt that is still in flight, so it gets the same result as everyone
    /// else on it. Only valid before the attempt is reported: `BluetoothManager.finish` claims and
    /// clears the attempt in one step on `managerQueue`, so a non-nil `attempt` there has not been
    /// reported yet.
    func addCompletion(_ completion: @escaping (MedtrumConnectError?) -> Void) {
        completions.append(completion)
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
