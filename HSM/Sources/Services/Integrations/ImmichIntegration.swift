import SwiftUI

struct ImmichIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let key = service.apiKey, !key.isEmpty else {
            return [ServiceMetric(label: "API key required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let headers = ["x-api-key": key]

        async let serverResult = fetchJSON(url: URL(string: "\(base)/api/server/about")!,      headers: headers)
        async let statsResult  = fetchJSON(url: URL(string: "\(base)/api/server/statistics")!, headers: headers)
        async let albumsResult = fetchJSON(url: URL(string: "\(base)/api/albums?shared=false")!, headers: headers)

        var metrics: [ServiceMetric] = []

        if let server = try? await serverResult as? [String: Any] {
            if let version = server["version"] as? String {
                metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
            }
        }

        if let stats = try? await statsResult as? [String: Any] {
            if let photos = stats["photos"] as? Int {
                metrics.append(ServiceMetric(label: "Photos", value: "\(photos)", icon: "photo.fill", color: .primary))
            }
            if let videos = stats["videos"] as? Int {
                metrics.append(ServiceMetric(label: "Videos", value: "\(videos)", icon: "video.fill", color: .primary))
            }
            if let usage = stats["usage"] as? Int {
                let gb = Double(usage) / 1_073_741_824
                metrics.append(ServiceMetric(label: "Storage used", value: String(format: "%.1f GB", gb), icon: "internaldrive", color: .secondary))
            }
        }

        if let albums = try? await albumsResult as? [[String: Any]] {
            metrics.append(ServiceMetric(label: "Albums", value: "\(albums.count)", icon: "rectangle.stack.fill", color: .secondary))
        }

        return metrics
    }
}
