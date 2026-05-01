import SwiftUI

struct JellyfinIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let token = service.apiKey, !token.isEmpty else {
            return [ServiceMetric(label: "API key required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let headers = ["X-MediaBrowser-Token": token]

        async let infoResult     = fetchJSON(url: URL(string: "\(base)/System/Info")!,           headers: headers)
        async let sessionsResult = fetchJSON(url: URL(string: "\(base)/Sessions?activeWithinSeconds=960")!, headers: headers)
        async let countsResult   = fetchJSON(url: URL(string: "\(base)/Items/Counts")!,          headers: headers)

        var metrics: [ServiceMetric] = []

        if let info = try? await infoResult as? [String: Any] {
            if let version = info["Version"] as? String {
                metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
            }
        }

        if let sessions = try? await sessionsResult as? [[String: Any]] {
            let active = sessions.filter { $0["NowPlayingItem"] != nil }
            let transcoding = active.filter { ($0["TranscodingInfo"] as? [String: Any]) != nil }.count
            metrics.append(ServiceMetric(
                label: "Active streams",
                value: "\(active.count)",
                icon: "play.fill",
                color: active.isEmpty ? .secondary : .green
            ))
            if transcoding > 0 {
                metrics.append(ServiceMetric(label: "Transcoding", value: "\(transcoding)", icon: "arrow.triangle.2.circlepath", color: .orange))
            }
            metrics.append(ServiceMetric(
                label: "Connected clients",
                value: "\(sessions.count)",
                icon: "person.2.fill",
                color: .primary
            ))
        }

        if let counts = try? await countsResult as? [String: Any] {
            if let movies = counts["MovieCount"] as? Int {
                metrics.append(ServiceMetric(label: "Movies", value: "\(movies)", icon: "film.fill", color: .primary))
            }
            if let series = counts["SeriesCount"] as? Int {
                metrics.append(ServiceMetric(label: "TV Shows", value: "\(series)", icon: "tv.fill", color: .primary))
            }
            if let episodes = counts["EpisodeCount"] as? Int {
                metrics.append(ServiceMetric(label: "Episodes", value: "\(episodes)", icon: "play.square.stack.fill", color: .secondary))
            }
            if let music = counts["SongCount"] as? Int, music > 0 {
                metrics.append(ServiceMetric(label: "Songs", value: "\(music)", icon: "music.note", color: .secondary))
            }
        }

        return metrics
    }
}
