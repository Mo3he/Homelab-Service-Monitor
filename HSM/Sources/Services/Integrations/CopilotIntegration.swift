import SwiftUI

struct CopilotIntegration: ServiceIntegration {
    private let apiBase = "https://api.github.com"

    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let token = service.apiKey, !token.isEmpty else {
            return [ServiceMetric(
                label: "Status",
                value: "No token",
                icon: "key.slash",
                color: .orange
            )]
        }

        let headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]

        var metrics: [ServiceMetric] = []

        // Authenticated user - confirms token is valid
        if let url = URL(string: "\(apiBase)/user"),
           let json = try? await fetchJSON(url: url, headers: headers) as? [String: Any] {
            if let login = json["login"] as? String {
                metrics.append(ServiceMetric(
                    label: "Account",
                    value: "@\(login)",
                    icon: "person.fill",
                    color: .primary
                ))
            }
        }

        // Copilot subscription - plan_type is a top-level field, not nested
        if let url = URL(string: "\(apiBase)/user/copilot_subscription"),
           let json = try? await fetchJSON(url: url, headers: headers) as? [String: Any] {
            if let planType = json["plan_type"] as? String {
                metrics.append(ServiceMetric(
                    label: "Plan",
                    value: planType.replacingOccurrences(of: "_", with: " ").capitalized,
                    icon: "star.fill",
                    color: .accentColor
                ))
            }
            if let seatType = json["seat_type"] as? String {
                metrics.append(ServiceMetric(
                    label: "Seat type",
                    value: seatType.replacingOccurrences(of: "_", with: " ").capitalized,
                    icon: "person.badge.key.fill",
                    color: .secondary
                ))
            }
        }

        // API rate limit - always works with any valid token
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

        // If we have nothing at all, the token is likely invalid - throw so status shows degraded
        if metrics.isEmpty {
            throw IntegrationError.authFailed
        }

        return metrics
    }
}
