import SwiftUI

struct GrafanaIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)
        var headers: [String: String] = [:]
        if let token = service.apiKey, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }

        var metrics: [ServiceMetric] = []

        // Health endpoint needs no auth
        if let url = URL(string: "\(base)/api/health"),
           let health = try? await fetchJSON(url: url, headers: headers) as? [String: Any] {
            if let version = health["version"] as? String {
                metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
            }
            if let db = health["database"] as? String {
                let ok = db.lowercased() == "ok"
                metrics.append(ServiceMetric(
                    label: "Database",
                    value: db,
                    icon: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    color: ok ? .green : .red,
                    isAlert: !ok
                ))
            }
        }

        guard let token = service.apiKey, !token.isEmpty else { return metrics }
        // Snapshot headers as `let` so the `async let` fetches don't capture a `var`
        // (which Swift 6 mode rejects).
        let authHeaders = headers.merging(["Authorization": "Bearer \(token)"]) { _, new in new }

        // Datasources + dashboards in parallel (both need auth)
        async let dsResult      = fetchJSON(url: URL(string: "\(base)/api/datasources")!, headers: authHeaders)
        async let dashResult    = fetchJSON(url: URL(string: "\(base)/api/search?type=dash-db&limit=1000")!, headers: authHeaders)
        async let alertsResult  = fetchJSON(url: URL(string: "\(base)/api/prometheus/grafana/api/v1/alerts")!, headers: authHeaders)

        if let ds = try? await dsResult as? [[String: Any]] {
            metrics.append(ServiceMetric(label: "Datasources", value: "\(ds.count)", icon: "cylinder.fill", color: .primary))
        }
        if let dash = try? await dashResult as? [[String: Any]] {
            metrics.append(ServiceMetric(label: "Dashboards", value: "\(dash.count)", icon: "chart.bar.fill", color: .blue))
        }
        if let alertsJSON = try? await alertsResult as? [String: Any],
           let data = alertsJSON["data"] as? [String: Any],
           let alerts = data["alerts"] as? [[String: Any]] {
            let firing = alerts.filter { ($0["state"] as? String) == "firing" }.count
            metrics.append(ServiceMetric(
                label: "Alerts firing", value: "\(firing)",
                icon: "bell.badge.fill", color: firing > 0 ? .red : .secondary, isAlert: firing > 0
            ))
        }

        return metrics
    }
}
