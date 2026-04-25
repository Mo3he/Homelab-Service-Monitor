import SwiftUI

struct HomeAssistantIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)
        guard let token = service.apiKey, !token.isEmpty else {
            return [ServiceMetric(label: "API token required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }

        let headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]

        guard let configURL = URL(string: "\(base)/api/config"),
              let statesURL = URL(string: "\(base)/api/states") else {
            throw IntegrationError.badURL
        }
        // Fetch config (version) and states in parallel
        async let configResult  = fetchJSON(url: configURL, headers: headers)
        async let statesResult  = fetchJSON(url: statesURL, headers: headers)

        var metrics: [ServiceMetric] = []

        if let config = try? await configResult as? [String: Any] {
            if let version = config["version"] as? String {
                metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
            }
            if let location = config["location_name"] as? String {
                metrics.append(ServiceMetric(label: "Location", value: location, icon: "location.fill", color: .blue))
            }
        }

        if let states = try? await statesResult as? [[String: Any]] {
            let domains = Dictionary(grouping: states) { entity -> String in
                let id = entity["entity_id"] as? String ?? ""
                return String(id.prefix(while: { $0 != "." }))
            }

            let entityCount = states.count
            metrics.append(ServiceMetric(
                label: "Entities",
                value: "\(entityCount)",
                icon: "square.grid.2x2.fill",
                color: .primary
            ))

            // Show on/off counts for lights and switches
            for domain in ["light", "switch", "binary_sensor"] {
                guard let entities = domains[domain] else { continue }
                let on = entities.filter { ($0["state"] as? String) == "on" }.count
                let label = domain.capitalized + "s"
                metrics.append(ServiceMetric(
                    label: label,
                    value: "\(on) on / \(entities.count) total",
                    icon: domain == "light" ? "lightbulb.fill" : domain == "switch" ? "togglepower" : "sensor.fill",
                    color: on > 0 ? .yellow : .secondary
                ))
            }

            // Unavailable entities as an alert
            let unavailable = states.filter { ($0["state"] as? String) == "unavailable" }.count
            if unavailable > 0 {
                metrics.append(ServiceMetric(
                    label: "Unavailable",
                    value: "\(unavailable) entities",
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    isAlert: true
                ))
            }

            // Available updates: filter update.* domain entities where state == "on"
            let pendingUpdates = states.filter { entity in
                let id = entity["entity_id"] as? String ?? ""
                return id.hasPrefix("update.") && (entity["state"] as? String) == "on"
            }
            metrics.append(ServiceMetric(
                label: "Updates available",
                value: pendingUpdates.isEmpty ? "Up to date" : "\(pendingUpdates.count)",
                icon: "arrow.down.circle.fill",
                color: pendingUpdates.isEmpty ? .secondary : .orange,
                isAlert: !pendingUpdates.isEmpty
            ))
        }

        return metrics
    }
}
