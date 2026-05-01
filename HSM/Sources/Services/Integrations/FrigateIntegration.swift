import SwiftUI

struct FrigateIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)

        async let statsResult  = fetchJSON(url: URL(string: "\(base)/api/stats")!,  headers: [:])
        async let configResult = fetchJSON(url: URL(string: "\(base)/api/config")!, headers: [:])
        async let eventsResult = fetchJSON(url: URL(string: "\(base)/api/events?limit=1")!, headers: [:])

        var metrics: [ServiceMetric] = []

        if let stats = try? await statsResult as? [String: Any] {
            if let cameras = stats["cameras"] as? [String: Any] {
                let total = cameras.count
                let online = cameras.values.compactMap { $0 as? [String: Any] }
                    .filter { ($0["camera_fps"] as? Double ?? 0) > 0 }
                metrics.append(ServiceMetric(label: "Cameras", value: "\(online.count)/\(total)", icon: "video.fill", color: online.count == total ? .green : .orange))
            }

            if let detection = stats["detection_fps"] as? Double {
                metrics.append(ServiceMetric(label: "Detection FPS", value: String(format: "%.1f", detection), icon: "eye.fill", color: .primary))
            }

            if let processes = stats["processes"] as? [String: Any],
               let detect = processes["detect"] as? [String: Any],
               let cpuPct = detect["cpu_average"] as? Double {
                metrics.append(ServiceMetric(label: "CPU (detect)", value: String(format: "%.1f%%", cpuPct), icon: "cpu", color: cpuPct > 80 ? .red : .secondary, isAlert: cpuPct > 80))
            }
        }

        if let config = try? await configResult as? [String: Any],
           let cameras = config["cameras"] as? [String: Any] {
            if metrics.isEmpty {
                metrics.append(ServiceMetric(label: "Configured cameras", value: "\(cameras.count)", icon: "video.fill", color: .primary))
            }
        }

        // Events today: Frigate doesn't expose a direct count, but /api/events returns a list we can count
        if (try? await eventsResult as? [[String: Any]]) != nil {
            let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            async let allEventsResult = fetchJSON(url: URL(string: "\(base)/api/events?after=\(Int(todayStart))")!, headers: [:])
            if let allEvents = try? await allEventsResult as? [[String: Any]] {
                metrics.append(ServiceMetric(label: "Events today", value: "\(allEvents.count)", icon: "calendar.badge.clock", color: .secondary))
            }
        }

        return metrics
    }
}
