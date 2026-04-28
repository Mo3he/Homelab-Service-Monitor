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
        // Fetch config (version), states, and repairs in parallel
        async let configResult  = fetchJSON(url: configURL, headers: headers)
        async let statesResult  = fetchJSON(url: statesURL, headers: headers)
        async let repairsCount  = fetchRepairsCount(base: base, token: token)

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
            metrics.append(ServiceMetric(
                label: "Unavailable",
                value: "\(unavailable) entities",
                icon: "exclamationmark.triangle.fill",
                color: unavailable > 0 ? .red : .secondary,
                isAlert: unavailable > 0
            ))

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

        // Repairs: active issues via WebSocket API
        if let count = await repairsCount {
            metrics.append(ServiceMetric(
                label: "Repairs",
                value: "\(count)",
                icon: "wrench.and.screwdriver.fill",
                color: count == 0 ? .secondary : .orange,
                isAlert: count > 0
            ))
        }

        return metrics
    }

    /// Fetches active repair issues via the Home Assistant WebSocket API.
    /// Opens a one-shot connection, authenticates, sends `repairs/list_issues`, and disconnects.
    private func fetchRepairsCount(base: String, token: String) async -> Int? {
        let wsScheme = base.hasPrefix("https") ? "wss" : "ws"
        let stripped = base
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        guard let url = URL(string: "\(wsScheme)://\(stripped)/api/websocket") else { return nil }

        let ws = IntegrationHTTP.session.webSocketTask(with: url)
        ws.resume()

        do {
            // 1. Receive auth_required
            let first = try await ws.receive()
            guard case .string(let text) = first,
                  text.contains("auth_required") else {
                ws.cancel(with: .normalClosure, reason: nil)
                return nil
            }

            // 2. Send auth
            let authMsg = #"{"type":"auth","access_token":"\#(token)"}"#
            try await ws.send(.string(authMsg))

            // 3. Receive auth_ok
            let second = try await ws.receive()
            guard case .string(let authResp) = second,
                  authResp.contains("auth_ok") else {
                ws.cancel(with: .normalClosure, reason: nil)
                return nil
            }

            // 4. Request repairs list
            try await ws.send(.string(#"{"id":1,"type":"repairs/list_issues"}"#))

            // 5. Receive result
            let third = try await ws.receive()
            ws.cancel(with: .normalClosure, reason: nil)

            guard case .string(let resultText) = third,
                  let data = resultText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["success"] as? Bool == true,
                  let result = json["result"] as? [String: Any],
                  let issues = result["issues"] as? [[String: Any]] else {
                return nil
            }

            return issues.filter { ($0["dismissed_version"] as? String) == nil }.count
        } catch {
            ws.cancel(with: .normalClosure, reason: nil)
            return nil
        }
    }
}
