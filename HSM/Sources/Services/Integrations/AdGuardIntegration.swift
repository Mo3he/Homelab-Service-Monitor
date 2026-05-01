import SwiftUI

struct AdGuardIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)
        var headers: [String: String] = [:]
        if let user = service.username, !user.isEmpty {
            let pass = service.password ?? ""
            if let data = "\(user):\(pass)".data(using: .utf8) {
                headers["Authorization"] = "Basic \(data.base64EncodedString())"
            }
        }

        guard let url = URL(string: "\(base)/control/stats") else { throw IntegrationError.badURL }

        let json: Any
        do {
            json = try await fetchJSON(url: url, headers: headers)
        } catch IntegrationError.authFailed {
            return [ServiceMetric(
                label: "Auth failed",
                value: "Check username & password",
                icon: "lock.slash.fill",
                color: .red,
                isAlert: true
            )]
        }

        guard let d = json as? [String: Any] else { throw IntegrationError.unexpectedFormat }

        var metrics: [ServiceMetric] = []

        if let total = d["num_dns_queries"] as? Int {
            metrics.append(ServiceMetric(
                label: "Queries today",
                value: formatCount(total),
                icon: "globe",
                color: .blue
            ))
        }

        if let blocked = d["num_blocked_filtering"] as? Int,
           let total   = d["num_dns_queries"] as? Int, total > 0 {
            let pct = Double(blocked) / Double(total) * 100
            metrics.append(ServiceMetric(
                label: "Blocked",
                value: "\(formatCount(blocked)) (\(String(format: "%.1f", pct))%)",
                icon: "shield.fill",
                color: .green
            ))
        }

        // avg_processing_time may come back as Double or as a JSON number type
        let avgSec = (d["avg_processing_time"] as? Double)
                  ?? (d["avg_processing_time"] as? NSNumber).map { $0.doubleValue }
        if let avgSec {
            metrics.append(ServiceMetric(
                label: "Avg response",
                value: String(format: "%.1f ms", avgSec * 1000),
                icon: "timer",
                color: .secondary
            ))
        }

        return metrics
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
