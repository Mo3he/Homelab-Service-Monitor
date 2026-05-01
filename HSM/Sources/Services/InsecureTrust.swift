import Foundation

/// Tracks which hostnames the user has opted into trusting with invalid/self-signed TLS
/// certificates. Pure opt-in: services default to strict TLS validation.
///
/// Thread-safe — used from URLSession delegate callbacks (background queue) and from
/// the main actor (when ServiceStore mutates).
final class InsecureTrustRegistry: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = InsecureTrustRegistry()

    private let lock = NSLock()
    private var trustedHosts: Set<String> = []

    private override init() { super.init() }

    func reload(from services: [Service]) {
        let hosts = Set(services.filter(\.allowSelfSignedCert).map { $0.host.lowercased() })
        lock.lock(); defer { lock.unlock() }
        trustedHosts = hosts
    }

    func isTrusted(host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return trustedHosts.contains(host.lowercased())
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              isTrusted(host: challenge.protectionSpace.host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
