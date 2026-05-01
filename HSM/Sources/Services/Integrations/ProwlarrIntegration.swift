import SwiftUI

struct ProwlarrIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let key = service.apiKey, !key.isEmpty else {
            return [ServiceMetric(label: "API key required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let headers = ["X-Api-Key": key]

        async let statusResult   = fetchJSON(url: URL(string: "\(base)/api/v1/system/status")!, headers: headers)
        async let indexersResult = fetchJSON(url: URL(string: "\(base)/api/v1/indexer")!, headers: headers)

        var metrics: [ServiceMetric] = []

        if let status = try? await statusResult as? [String: Any],
           let version = status["version"] as? String {
            metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
        }

        if let indexers = try? await indexersResult as? [[String: Any]] {
            let enabled = indexers.filter { ($0["enableRss"] as? Bool) == true || ($0["enableSearch"] as? Bool) == true }
            metrics.append(ServiceMetric(label: "Indexers", value: "\(indexers.count)", icon: "list.bullet.circle.fill", color: .primary))
            metrics.append(ServiceMetric(label: "Enabled", value: "\(enabled.count)", icon: "checkmark.circle.fill", color: .green))
        }

        return metrics
    }
}
