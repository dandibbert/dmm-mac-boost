import WebKit

extension WKWebView {
    /// The SDK's isolated-world overload returns through a Result callback rather than
    /// importing an async result. Keep that result instead of accidentally awaiting Void.
    @MainActor
    func evaluateJavaScript(_ source: String, in frame: WKFrameInfo?, in world: WKContentWorld) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(source, in: frame, in: world, completionHandler: { result in
                continuation.resume(with: result)
            })
        }
    }
}
