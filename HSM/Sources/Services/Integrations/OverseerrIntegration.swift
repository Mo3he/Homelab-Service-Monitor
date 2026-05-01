import SwiftUI

struct OverseerrIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let key = service.apiKey, !key.isEmpty else {
            return [ServiceMetric(label: "API key required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let headers = ["X-Api-Key": key]

        async let statusResult   = fetchJSON(url: URL(string: "\(base)/api/v1/status")!, headers: headers)
        async let requestsResult = fetchJSON(url: URL(string: "\(base)/api/v1/request?take=1&filter=pending")!, headers: headers)
        async let usersResult    = fetchJSON(url: URL(string: "\(base)/api/v1/user?take=1")!, headers: headers)

        var metrics: [ServiceMetric] = []

        if let status = try? await statusResult as? [String: Any] {
            if let version = status["version"] as? String {
                metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
            }
        }

        if let req = try? await requestsResult as? [String: Any] {
            let pending = req["pageInfo"] as? [String: Any]
            let total   = (pending?["results"] as? Int) ?? 0
            metrics.append(ServiceMetric(
                label: "Pending requests",
                value: "\(total)",
                icon: "person.crop.circle.badge.clock",
                color: total > 0 ? .orange : .secondary,
                isAlert: total > 0
            ))
        }

        if let usersRes = try? await usersResult as? [String: Any],
           let pageInfo = usersRes["pageInfo"] as? [String: Any],
           let userCount = pageInfo["results"] as? Int {
            metrics.append(ServiceMetric(label: "Total users", value: "\(userCount)", icon: "person.2.fill", color: .secondary))
        }

        return metrics
    }
}
