import SwiftUI

struct PortainerIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let token = service.apiKey, !token.isEmpty else {
            return [ServiceMetric(label: "API key required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let headers = ["X-API-Key": token]

        guard let endpointsURL = URL(string: "\(base)/api/endpoints") else { throw IntegrationError.badURL }
        let json = try await fetchJSON(url: endpointsURL, headers: headers)
        guard let endpoints = json as? [[String: Any]] else { throw IntegrationError.unexpectedFormat }

        var metrics: [ServiceMetric] = []
        metrics.append(ServiceMetric(label: "Environments", value: "\(endpoints.count)", icon: "server.rack", color: .primary))

        // Fetch containers for each endpoint
        var running = 0, unhealthy = 0, stopped = 0
        var images: Int? = nil
        var volumes: Int? = nil
        for ep in endpoints {
            guard let epID = ep["Id"] as? Int else { continue }
            async let containersResult = fetchJSON(url: URL(string: "\(base)/api/endpoints/\(epID)/docker/containers/json?all=true")!, headers: headers)
            async let imagesResult    = fetchJSON(url: URL(string: "\(base)/api/endpoints/\(epID)/docker/images/json")!, headers: headers)
            async let volumesResult   = fetchJSON(url: URL(string: "\(base)/api/endpoints/\(epID)/docker/volumes")!, headers: headers)
            if let containers = try? await containersResult as? [[String: Any]] {
                for c in containers {
                    let state = c["State"] as? String ?? ""
                    let status = c["Status"] as? String ?? ""
                    if state == "running" {
                        if status.contains("unhealthy") { unhealthy += 1 } else { running += 1 }
                    } else {
                        stopped += 1
                    }
                }
            }
            if let imgs = try? await imagesResult as? [[String: Any]] { images = (images ?? 0) + imgs.count }
            if let vols = try? await volumesResult as? [String: Any],
               let list = vols["Volumes"] as? [[String: Any]] { volumes = (volumes ?? 0) + list.count }
        }
        if running + unhealthy + stopped > 0 {
            metrics.append(ServiceMetric(label: "Running", value: "\(running)", icon: "play.circle.fill", color: .green))
            metrics.append(ServiceMetric(label: "Unhealthy", value: "\(unhealthy)", icon: "exclamationmark.circle.fill", color: unhealthy > 0 ? .orange : .secondary, isAlert: unhealthy > 0))
            metrics.append(ServiceMetric(label: "Stopped", value: "\(stopped)", icon: "stop.circle.fill", color: .secondary))
        }
        if let images { metrics.append(ServiceMetric(label: "Images", value: "\(images)", icon: "photo.stack.fill", color: .secondary)) }
        if let volumes { metrics.append(ServiceMetric(label: "Volumes", value: "\(volumes)", icon: "externaldrive.fill", color: .secondary)) }

        return metrics
    }
}
