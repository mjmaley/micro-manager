import Foundation

extension WLDevice {
    /// Async request bookkeeping lives on main alongside input callbacks;
    /// actual report writes run on the device's serial background write queue.
    /// Slow lighting writes therefore cannot block handling a button or dial.
    public func callAsync(_ method: String, params: Any? = nil) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let finish: (Result<Any?, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            DispatchQueue.main.async {
                let sent = self.callQueued(method, params: params) { result, error in
                    if let error {
                        finish(.failure(WLDevice.Failure.rpc(method, error)))
                    } else {
                        finish(.success(result))
                    }
                }
                if sent == nil {
                    // A request can be refused before queueing; the completion
                    // already carried the
                    // reason, so this only covers the silent case.
                    finish(.failure(WLDevice.Failure.notConnected))
                }
            }
        }
    }
}
