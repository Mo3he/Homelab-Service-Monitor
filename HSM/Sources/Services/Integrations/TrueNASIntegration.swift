import SwiftUI

struct TrueNASIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let key = service.apiKey, !key.isEmpty else {
            return [ServiceMetric(label: "API key required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let headers = ["Authorization": "Bearer \(key)"]

        async let sysResult    = fetchJSON(url: URL(string: "\(base)/api/v2.0/system/info")!, headers: headers)
        async let poolResult   = fetchJSON(url: URL(string: "\(base)/api/v2.0/pool")!, headers: headers)
        async let alertResult  = fetchJSON(url: URL(string: "\(base)/api/v2.0/alert/list")!, headers: headers)
        async let updateResult = fetchJSON(url: URL(string: "\(base)/api/v2.0/update/check_available")!, headers: headers)

        var metrics: [ServiceMetric] = []

        if let sys = try? await sysResult as? [String: Any] {
            if let version = sys["version"] as? String {
                metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
            }
            if let uptime = sys["uptimeSeconds"] as? Double {
                let days = Int(uptime / 86400)
                metrics.append(ServiceMetric(label: "Uptime", value: "\(days)d", icon: "clock.fill", color: .secondary))
            }
        }

        if let pools = try? await poolResult as? [[String: Any]] {
            let healthy = pools.filter { ($0["healthy"] as? Bool) == true }
            let status = "\(healthy.count)/\(pools.count)"
            metrics.append(ServiceMetric(
                label: "Pools healthy",
                value: status,
                icon: "externaldrive.fill",
                color: healthy.count == pools.count ? .green : .red,
                isAlert: healthy.count < pools.count
            ))
        }

        if let alerts = try? await alertResult as? [[String: Any]] {
            let critical = alerts.filter { ($0["level"] as? String) == "CRITICAL" }
            if !critical.isEmpty {
                metrics.append(ServiceMetric(label: "Critical alerts", value: "\(critical.count)", icon: "exclamationmark.triangle.fill", color: .red, isAlert: true))
            }
        }

        if let update = try? await updateResult as? [String: Any],
           let status = update["status"] as? String, status == "AVAILABLE" {
            let version = update["version"] as? String ?? "Available"
            metrics.append(ServiceMetric(label: "Update available", value: version, icon: "arrow.down.circle.fill", color: .orange, isAlert: true))
        }

        return metrics
    }
}
