import SwiftUI

struct PlexIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let token = service.apiKey, !token.isEmpty else {
            return [ServiceMetric(label: "Token required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let headers = ["X-Plex-Token": token, "Accept": "application/json"]

        async let serverResult   = fetchJSON(url: URL(string: "\(base)/")!, headers: headers)
        async let sessionsResult = fetchJSON(url: URL(string: "\(base)/status/sessions")!, headers: headers)
        async let libraryResult  = fetchJSON(url: URL(string: "\(base)/library/sections")!, headers: headers)

        var metrics: [ServiceMetric] = []

        if let root = try? await serverResult as? [String: Any],
           let ms = root["MediaContainer"] as? [String: Any] {
            if let version = ms["version"] as? String {
                metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
            }
        }

        if let root = try? await sessionsResult as? [String: Any],
           let ms = root["MediaContainer"] as? [String: Any] {
            let size = ms["size"] as? Int ?? 0
            let transcodes = (ms["Metadata"] as? [[String: Any]])?.filter {
                ($0["TranscodeSession"] as? [String: Any]) != nil
            }.count ?? 0
            metrics.append(ServiceMetric(
                label: "Active streams",
                value: "\(size)",
                icon: "play.fill",
                color: size == 0 ? .secondary : .green
            ))
            if transcodes > 0 {
                metrics.append(ServiceMetric(label: "Transcoding", value: "\(transcodes)", icon: "arrow.triangle.2.circlepath", color: .orange))
            }
        }

        if let root = try? await libraryResult as? [String: Any],
           let ms = root["MediaContainer"] as? [String: Any],
           let sections = ms["Directory"] as? [[String: Any]] {
            let movies  = sections.filter { ($0["type"] as? String) == "movie" }.count
            let shows   = sections.filter { ($0["type"] as? String) == "show" }.count
            let music   = sections.filter { ($0["type"] as? String) == "artist" }.count
            if movies > 0 { metrics.append(ServiceMetric(label: "Movie libraries", value: "\(movies)", icon: "film.fill", color: .secondary)) }
            if shows  > 0 { metrics.append(ServiceMetric(label: "TV libraries",    value: "\(shows)",  icon: "tv.fill",   color: .secondary)) }
            if music  > 0 { metrics.append(ServiceMetric(label: "Music libraries", value: "\(music)",  icon: "music.note",color: .secondary)) }
        }

        return metrics
    }
}
