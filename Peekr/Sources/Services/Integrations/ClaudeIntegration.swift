import SwiftUI

struct ClaudeIntegration: ServiceIntegration {
    private let apiBase = "https://api.anthropic.com"

    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let token = service.apiKey, !token.isEmpty else {
            return [ServiceMetric(
                label: "Status",
                value: "No API key",
                icon: "key.slash",
                color: .secondary
            )]
        }

        let headers: [String: String] = [
            "x-api-key": token,
            "anthropic-version": "2023-06-01"
        ]

        var metrics: [ServiceMetric] = []

        // Fetch available models - also validates the API key
        if let url = URL(string: "\(apiBase)/v1/models"),
           let json = try? await fetchJSON(url: url, headers: headers) as? [String: Any],
           let data = json["data"] as? [[String: Any]] {
            let names = data.compactMap { $0["id"] as? String }
            let haiku = names.contains(where: { $0.contains("haiku") })
            let sonnet = names.contains(where: { $0.contains("sonnet") })
            let opus = names.contains(where: { $0.contains("opus") })
            var available: [String] = []
            if opus   { available.append("Opus") }
            if sonnet { available.append("Sonnet") }
            if haiku  { available.append("Haiku") }
            metrics.append(ServiceMetric(
                label: "Available models",
                value: available.isEmpty ? "\(data.count)" : available.joined(separator: ", "),
                icon: "cpu",
                color: .primary
            ))
        }

        // Rate limit info comes back in response headers. We do a lightweight models
        // list call above. The headers from the LAST request carry the limits.
        // For a reliable rate-limit read, make a minimal messages call.
        // Instead, surface the org usage endpoint if available.
        if let url = URL(string: "\(apiBase)/v1/organizations/usage") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let (_, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse {
                // Extract rate-limit headers returned on any 200/429 response
                let remaining = http.value(forHTTPHeaderField: "anthropic-ratelimit-requests-remaining")
                let limit = http.value(forHTTPHeaderField: "anthropic-ratelimit-requests-limit")
                if let r = remaining.flatMap({ Int($0) }), let l = limit.flatMap({ Int($0) }) {
                    let pct = l > 0 ? Double(r) / Double(l) * 100 : 100
                    metrics.append(ServiceMetric(
                        label: "Request quota",
                        value: "\(r) / \(l)",
                        icon: "gauge.medium",
                        color: pct < 20 ? .red : pct < 50 ? .orange : .green,
                        isAlert: pct < 10
                    ))
                }
            }
        }

        if metrics.isEmpty {
            metrics.append(ServiceMetric(
                label: "API",
                value: "Connected",
                icon: "checkmark.circle.fill",
                color: .green
            ))
        }

        return metrics
    }
}
