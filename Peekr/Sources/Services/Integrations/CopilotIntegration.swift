import SwiftUI

struct CopilotIntegration: ServiceIntegration {
    private let apiBase = "https://api.github.com"

    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let token = service.apiKey, !token.isEmpty else {
            return [ServiceMetric(
                label: "Status",
                value: "No token",
                icon: "key.slash",
                color: .secondary
            )]
        }

        let headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]

        var metrics: [ServiceMetric] = []

        // Copilot subscription for the authenticated user
        if let url = URL(string: "\(apiBase)/user/copilot_subscription"),
           let json = try? await fetchJSON(url: url, headers: headers) as? [String: Any] {
            if let plan = (json["plan"] as? [String: Any])?["name"] as? String {
                metrics.append(ServiceMetric(
                    label: "Plan",
                    value: plan,
                    icon: "star.fill",
                    color: .accentColor
                ))
            }
            if let seat = json["assignee"] as? [String: Any],
               let login = seat["login"] as? String {
                metrics.append(ServiceMetric(
                    label: "Seat",
                    value: "@\(login)",
                    icon: "person.fill",
                    color: .primary
                ))
            }
        }

        // Business usage (org-level) - available if the token has org read scope
        if let url = URL(string: "\(apiBase)/copilot/usage"),
           let json = try? await fetchJSON(url: url, headers: headers) as? [String: Any] {
            if let total = json["total_suggestions_count"] as? Int {
                metrics.append(ServiceMetric(
                    label: "Suggestions (30d)",
                    value: formatCount(total),
                    icon: "sparkles",
                    color: .secondary
                ))
            }
            if let accepted = json["total_acceptances_count"] as? Int,
               let total = json["total_suggestions_count"] as? Int, total > 0 {
                let rate = Int(Double(accepted) / Double(total) * 100)
                metrics.append(ServiceMetric(
                    label: "Acceptance rate",
                    value: "\(rate)%",
                    icon: "checkmark.seal.fill",
                    color: rate >= 30 ? .green : rate >= 15 ? .orange : .red
                ))
            }
        }

        // Fallback: rate limit shows the token is valid
        if let url = URL(string: "\(apiBase)/rate_limit"),
           let json = try? await fetchJSON(url: url, headers: headers) as? [String: Any],
           let resources = json["resources"] as? [String: Any],
           let core = resources["core"] as? [String: Any],
           let remaining = core["remaining"] as? Int,
           let limit = core["limit"] as? Int {
            let pct = limit > 0 ? Double(remaining) / Double(limit) * 100 : 100
            metrics.append(ServiceMetric(
                label: "API rate limit",
                value: "\(remaining) / \(limit)",
                icon: "gauge.medium",
                color: pct < 20 ? .red : pct < 50 ? .orange : .green,
                isAlert: remaining < 10
            ))
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

    private func formatCount(_ n: Int) -> String {
        n >= 1_000 ? String(format: "%.1fk", Double(n) / 1_000.0) : "\(n)"
    }
}
