import SwiftUI

struct PiholeIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)
        // Pi-hole v5 API (no auth needed for summary, token for more)
        let tokenParam = service.apiKey.map { "?auth=\($0)" } ?? ""
        guard let url = URL(string: "\(base)/admin/api.php\(tokenParam)&summaryRaw") else { throw IntegrationError.badURL }

        let json = try await fetchJSON(url: url, headers: [:])
        guard let data = json as? [String: Any] else { throw IntegrationError.unexpectedFormat }

        var metrics: [ServiceMetric] = []

        if let blocked = data["ads_blocked_today"] as? Int {
            metrics.append(ServiceMetric(label: "Blocked today", value: "\(blocked)", icon: "shield.fill", color: .green))
        }
        if let pct = data["ads_percentage_today"] as? Double {
            metrics.append(ServiceMetric(label: "Block rate", value: String(format: "%.1f%%", pct), icon: "percent", color: .primary))
        }
        if let queries = data["dns_queries_today"] as? Int {
            metrics.append(ServiceMetric(label: "Queries today", value: "\(queries)", icon: "arrow.left.arrow.right", color: .secondary))
        }
        if let uptime = data["gravity_last_updated"] as? [String: Any],
           let absolute = uptime["absolute"] as? TimeInterval {
            let ts = Date(timeIntervalSince1970: absolute)
            let days = Int(Date().timeIntervalSince(ts) / 86400)
            metrics.append(ServiceMetric(label: "Gravity updated",
                                         value: days == 0 ? "Today" : "\(days)d ago",
                                         icon: "list.bullet.clipboard",
                                         color: days > 7 ? .orange : .secondary))
        }
        if let domains = data["domains_being_blocked"] as? Int {
            let formatted = domains > 1000 ? String(format: "%.0fk", Double(domains) / 1000) : "\(domains)"
            metrics.append(ServiceMetric(label: "Blocklist", value: formatted, icon: "list.bullet.clipboard", color: .secondary))
        }
        if let clients = data["unique_clients"] as? Int {
            metrics.append(ServiceMetric(label: "Clients", value: "\(clients)", icon: "iphone.and.arrow.forward", color: .secondary))
        }
        if let status = data["status"] as? String {
            let enabled = status == "enabled"
            metrics.append(ServiceMetric(label: "Status", value: enabled ? "Enabled" : "Disabled", icon: enabled ? "checkmark.shield.fill" : "xmark.shield.fill", color: enabled ? .green : .red, isAlert: !enabled))
        }

        return metrics
    }
}
