import SwiftUI

struct TraefikIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)
        // Traefik dashboard API - no auth by default
        async let overviewResult  = fetchJSON(url: URL(string: "\(base)/api/overview")!, headers: [:])
        async let routersResult   = fetchJSON(url: URL(string: "\(base)/api/http/routers")!, headers: [:])
        async let servicesResult  = fetchJSON(url: URL(string: "\(base)/api/http/services")!, headers: [:])
        async let middlewareResult = fetchJSON(url: URL(string: "\(base)/api/http/middlewares")!, headers: [:])

        var metrics: [ServiceMetric] = []

        if let overview = try? await overviewResult as? [String: Any] {
            if let version = overview["version"] as? String {
                metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
            }
            if let routers = overview["http"] as? [String: Any],
               let total = (routers["routers"] as? [String: Any])?["total"] as? Int {
                metrics.append(ServiceMetric(label: "HTTP Routers", value: "\(total)", icon: "arrow.triangle.swap", color: .primary))
            }
        }

        if let routers = try? await routersResult as? [[String: Any]] {
            let errored = routers.filter { ($0["status"] as? String) != "enabled" }
            if !errored.isEmpty {
                metrics.append(ServiceMetric(label: "Errored routes", value: "\(errored.count)", icon: "exclamationmark.circle.fill", color: .red, isAlert: true))
            }
        }

        if let svcs = try? await servicesResult as? [[String: Any]] {
            metrics.append(ServiceMetric(label: "Services", value: "\(svcs.count)", icon: "arrow.right.circle.fill", color: .secondary))
        }

        if let mws = try? await middlewareResult as? [[String: Any]] {
            metrics.append(ServiceMetric(label: "Middlewares", value: "\(mws.count)", icon: "slider.horizontal.3", color: .secondary))
        }

        return metrics
    }
}
