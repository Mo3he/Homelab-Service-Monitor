import Foundation
import Network

struct CheckResult {
    let latencyMs: Double
    let httpStatusCode: Int?
}

actor PingService {
    static let shared = PingService()
    private init() {}

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        // Follow redirects so e.g. http→https services report correctly.
        // Delegate only trusts hosts the user has opted into for self-signed certs.
        return URLSession(configuration: config,
                          delegate: InsecureTrustRegistry.shared,
                          delegateQueue: nil)
    }()

    func check(_ service: Service) async throws -> CheckResult {
        if service.serviceType.prefersTCPPing || !service.scheme.isHTTP {
            let ms = try await tcpCheck(host: service.host, port: service.port)
            return CheckResult(latencyMs: ms, httpStatusCode: nil)
        }
        return try await httpCheck(service)
    }

    // MARK: - HTTP

    private func httpCheck(_ service: Service) async throws -> CheckResult {
        guard let url = service.pingURL else { throw CheckError.invalidURL }
        let totalBudget: TimeInterval = 5
        let start = Date()

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = totalBudget

        let (_, headResponse) = try await session.data(for: request)
        let headCode = (headResponse as? HTTPURLResponse)?.statusCode

        // Some servers (e.g. Home Assistant) reject HEAD with 405 — retry with GET, but
        // cap the total wall-clock budget for the whole HEAD+GET pair at `totalBudget`.
        if headCode == 405 {
            let elapsed = Date().timeIntervalSince(start)
            let remaining = totalBudget - elapsed
            guard remaining > 0.1 else {
                // No time left for a GET — return the HEAD result rather than waste another timeout cycle.
                return CheckResult(latencyMs: elapsed * 1000, httpStatusCode: headCode)
            }
            var getReq = URLRequest(url: url)
            getReq.httpMethod = "GET"
            getReq.timeoutInterval = remaining
            let (_, getResponse) = try await session.data(for: getReq)
            let ms = Date().timeIntervalSince(start) * 1000
            let code = (getResponse as? HTTPURLResponse)?.statusCode
            return CheckResult(latencyMs: ms, httpStatusCode: code)
        }

        let ms = Date().timeIntervalSince(start) * 1000
        return CheckResult(latencyMs: ms, httpStatusCode: headCode)
    }

    // MARK: - TCP

    private func tcpCheck(host: String, port: Int, timeout: Double = 5) async throws -> Double {
        let start = Date()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
            let connection = NWConnection(to: endpoint, using: .tcp)
            var settled = false

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard !settled else { return }
                settled = true
                connection.cancel()
                continuation.resume(throwing: CheckError.timeout)
            }
            timer.resume()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !settled else { return }
                    settled = true
                    timer.cancel()
                    connection.cancel()
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    guard !settled else { return }
                    settled = true
                    timer.cancel()
                    continuation.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: .global())
        }

        return Date().timeIntervalSince(start) * 1000
    }
}

enum CheckError: LocalizedError {
    case timeout, invalidURL

    var errorDescription: String? {
        switch self {
        case .timeout:    return "Connection timed out"
        case .invalidURL: return "Invalid URL"
        }
    }
}
