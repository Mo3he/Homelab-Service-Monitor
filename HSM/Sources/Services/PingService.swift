import Foundation
import Network
import os

struct CheckResult {
    let latencyMs: Double
    let httpStatusCode: Int?
    var usedFailover: Bool = false
}

actor PingService {
    static let shared = PingService()
    private init() {}

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config,
                          delegate: InsecureTrustRegistry.shared,
                          delegateQueue: nil)
    }()

    // Separate session for failover attempts so timed-out primary connections
    // cannot contaminate the failover's connection pool.
    private let failoverSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config,
                          delegate: InsecureTrustRegistry.shared,
                          delegateQueue: nil)
    }()

    func check(_ service: Service, timeout: Double = 5) async throws -> CheckResult {
        AppLogger.ping.debug("Checking \(service.name, privacy: .public) (\(service.host, privacy: .public))")
        do {
            let result = try await doCheck(service, using: session, timeout: timeout)
            AppLogger.ping.info("\(service.name, privacy: .public) OK — \(Int(result.latencyMs))ms HTTP \(result.httpStatusCode.map(String.init) ?? "n/a", privacy: .public)")
            return result
        } catch {
            guard let failover = service.failoverHost, !failover.trimmingCharacters(in: .whitespaces).isEmpty else {
                AppLogger.ping.error("\(service.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            AppLogger.ping.info("\(service.name, privacy: .public) primary failed, trying failover host")
            var alt = service
            alt.host = failover.trimmingCharacters(in: .whitespaces)
            var result = try await doCheck(alt, using: failoverSession, timeout: timeout)
            result.usedFailover = true
            AppLogger.ping.info("\(service.name, privacy: .public) OK via failover — \(Int(result.latencyMs))ms HTTP \(result.httpStatusCode.map(String.init) ?? "n/a", privacy: .public)")
            return result
        }
    }

    private func doCheck(_ service: Service, using session: URLSession, timeout: Double) async throws -> CheckResult {
        if service.serviceType.prefersTCPPing || !service.scheme.isHTTP {
            AppLogger.ping.debug("\(service.name, privacy: .public) using TCP check")
            let ms = try await tcpCheck(host: service.host, port: service.port, timeout: timeout)
            return CheckResult(latencyMs: ms, httpStatusCode: nil)
        }
        AppLogger.ping.debug("\(service.name, privacy: .public) using HTTP check")
        return try await httpCheck(service, using: session, timeout: timeout)
    }

    // MARK: - HTTP

    private func httpCheck(_ service: Service, using session: URLSession, timeout: Double) async throws -> CheckResult {
        guard let url = service.pingURL else { throw CheckError.invalidURL }
        let totalBudget: TimeInterval = timeout
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
            let once = OnceFlag()

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(throwing: CheckError.timeout)
            }
            timer.resume()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    timer.cancel()
                    connection.cancel()
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    guard once.claim() else { return }
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

/// Thread-safe one-shot flag used to ensure a CheckedContinuation is resumed exactly once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    /// Returns `true` the first time it is called; `false` on every subsequent call.
    func claim() -> Bool {
        lock.withLock {
            guard !settled else { return false }
            settled = true
            return true
        }
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
