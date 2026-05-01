import SwiftUI

/// Handles both Sonarr and Radarr - they share the same v3 API shape.
struct ArrIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let key = service.apiKey, !key.isEmpty else {
            return [ServiceMetric(label: "API key required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let headers = ["X-Api-Key": key]
        let isSonarr = service.serviceType == .sonarr

        async let statusResult  = fetchJSON(url: URL(string: "\(base)/api/v3/system/status")!, headers: headers)
        async let queueResult   = fetchJSON(url: URL(string: "\(base)/api/v3/queue?pageSize=1")!, headers: headers)
        async let itemsResult   = fetchJSON(
            url: URL(string: isSonarr ? "\(base)/api/v3/series" : "\(base)/api/v3/movie")!,
            headers: headers
        )
        async let diskResult    = fetchJSON(url: URL(string: "\(base)/api/v3/diskspace")!, headers: headers)

        var metrics: [ServiceMetric] = []

        if let status = try? await statusResult as? [String: Any] {
            if let version = status["version"] as? String {
                metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
            }
        }

        if let items = try? await itemsResult as? [[String: Any]] {
            let label = isSonarr ? "Series" : "Movies"
            let icon  = isSonarr ? "tv.fill" : "film.fill"
            metrics.append(ServiceMetric(label: label, value: "\(items.count)", icon: icon, color: .primary))

            if isSonarr {
                let monitored = items.filter { ($0["monitored"] as? Bool) == true }
                metrics.append(ServiceMetric(label: "Monitored", value: "\(monitored.count)", icon: "eye.fill", color: .secondary))
            } else {
                let missing = items.filter { ($0["monitored"] as? Bool) == true && ($0["hasFile"] as? Bool) == false }
                if !missing.isEmpty {
                    metrics.append(ServiceMetric(label: "Missing", value: "\(missing.count)", icon: "exclamationmark.triangle.fill", color: .orange, isAlert: true))
                }
            }
        }

        if let queue = try? await queueResult as? [String: Any] {
            let total = queue["totalRecords"] as? Int ?? 0
            if total > 0 {
                metrics.append(ServiceMetric(label: "Queue", value: "\(total)", icon: "arrow.down.circle.fill", color: .blue))
            }
        }

        if let disks = try? await diskResult as? [[String: Any]] {
            let totalFree = disks.compactMap { ($0["freeSpace"] as? NSNumber)?.int64Value }.reduce(0, +)
            let gb = Double(totalFree) / 1_073_741_824
            let color: Color = gb < 10 ? .red : gb < 50 ? .orange : .primary
            metrics.append(ServiceMetric(label: "Free space", value: String(format: "%.0f GB", gb), icon: "internaldrive", color: color, isAlert: gb < 10))
        }

        return metrics
    }
}
