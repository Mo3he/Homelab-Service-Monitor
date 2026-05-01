import SwiftUI

struct ClaudeIntegration: ServiceIntegration {
    private let apiBase = "https://api.anthropic.com"

    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let token = service.apiKey, !token.isEmpty else {
            return [ServiceMetric(
                label: "Status",
                value: "No API key",
                icon: "key.slash",
                color: .orange
            )]
        }

        let headers: [String: String] = [
            "x-api-key": token,
            "anthropic-version": "2023-06-01"
        ]

        // List models - validates the API key and shows what's available.
        // Throws authFailed on 401/403, which the refresh path surfaces as an error.
        guard let url = URL(string: "\(apiBase)/v1/models") else {
            throw IntegrationError.badURL
        }
        let json = try await fetchJSON(url: url, headers: headers)
        guard let dict = json as? [String: Any],
              let data = dict["data"] as? [[String: Any]] else {
            throw IntegrationError.unexpectedFormat
        }

        var metrics: [ServiceMetric] = []

        // Categorise models by family
        let ids = data.compactMap { $0["id"] as? String }
        let families = ["opus", "sonnet", "haiku"].compactMap { family -> String? in
            let count = ids.filter { $0.contains(family) }.count
            guard count > 0 else { return nil }
            return "\(count) \(family.capitalized)"
        }
        metrics.append(ServiceMetric(
            label: "Available models",
            value: families.isEmpty ? "\(data.count) models" : families.joined(separator: ", "),
            icon: "cpu",
            color: .primary
        ))

        // Newest model name
        if let newest = ids.first {
            metrics.append(ServiceMetric(
                label: "Latest",
                value: newest,
                icon: "sparkle",
                color: .secondary
            ))
        }

        return metrics
    }
}
