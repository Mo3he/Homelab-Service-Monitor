import SwiftUI

struct NtfyIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)

        // ntfy health endpoint - publicly accessible
        guard let url = URL(string: "\(base)/v1/health") else { throw IntegrationError.badURL }
        let json = try await fetchJSON(url: url, headers: [:])
        guard let data = json as? [String: Any] else { throw IntegrationError.unexpectedFormat }

        let healthy = (data["healthy"] as? Bool) ?? false
        var metrics: [ServiceMetric] = [
            ServiceMetric(label: "Status", value: healthy ? "Healthy" : "Unhealthy", icon: healthy ? "checkmark.circle.fill" : "xmark.circle.fill", color: healthy ? .green : .red, isAlert: !healthy)
        ]

        // Stats endpoint (may not exist on all versions)
        if let statsURL = URL(string: "\(base)/v1/stats"),
           let stats = try? await fetchJSON(url: statsURL, headers: [:]) as? [String: Any] {
            if let messages = stats["messages"] as? Int {
                metrics.append(ServiceMetric(label: "Messages sent", value: "\(messages)", icon: "bell.fill", color: .secondary))
            }
        }

        return metrics
    }
}
