import SwiftUI

// Shared rate-limit cache so all service instances using the same token
// report the same value within a refresh cycle.
private actor GitHubRateLimitCache {
    struct Entry { let remaining: Int; let limit: Int; let date: Date }
    private var store: [String: Entry] = [:]
    private let ttl: TimeInterval = 60

    static let shared = GitHubRateLimitCache()

    func get(token: String) -> Entry? {
        guard let e = store[token], Date().timeIntervalSince(e.date) < ttl else { return nil }
        return e
    }

    func set(token: String, remaining: Int, limit: Int) {
        store[token] = Entry(remaining: remaining, limit: limit, date: Date())
    }
}

struct GitHubIntegration: ServiceIntegration {
    private let apiBase = "https://api.github.com"

    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        var headers: [String: String] = [
            "Accept": "application/vnd.github.v3+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
        if let token = service.apiKey, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }

        var metrics: [ServiceMetric] = []

        // Repo-specific metrics when a repository path (owner/repo) is configured
        let repoPath = service.username?.trimmingCharacters(in: .whitespaces) ?? ""
        if !repoPath.isEmpty && repoPath.contains("/") {
            metrics += await repoInfo(path: repoPath, headers: headers)
            metrics += await actionsRuns(path: repoPath, headers: headers)
        }

        // Rate limit — shared cache per token so all repos with the same key
        // report the same value within a 60-second window.
        let cacheKey = service.apiKey ?? ""
        var rlEntry = await GitHubRateLimitCache.shared.get(token: cacheKey)
        if rlEntry == nil,
           let url = URL(string: "\(apiBase)/rate_limit"),
           let json = try? await fetchJSON(url: url, headers: headers) as? [String: Any] {
            let rate = (json["resources"] as? [String: Any]).flatMap { $0["core"] as? [String: Any] }
                    ?? json["rate"] as? [String: Any]
            if let r = rate?["remaining"] as? Int, let l = rate?["limit"] as? Int {
                await GitHubRateLimitCache.shared.set(token: cacheKey, remaining: r, limit: l)
                rlEntry = .init(remaining: r, limit: l, date: .now)
            }
        }
        if let entry = rlEntry {
            let pct = entry.limit > 0 ? Double(entry.remaining) / Double(entry.limit) * 100 : 100
            metrics.append(ServiceMetric(
                label: "API rate limit",
                value: "\(entry.remaining) / \(entry.limit)",
                icon: "gauge.medium",
                color: pct < 20 ? .red : pct < 50 ? .orange : .green,
                isAlert: entry.remaining < 10
            ))
        }

        // Authenticated user
        if let token = service.apiKey, !token.isEmpty,
           let url = URL(string: "\(apiBase)/user"),
           let user = try? await fetchJSON(url: url, headers: headers) as? [String: Any],
           let login = user["login"] as? String {
            metrics.append(ServiceMetric(
                label: "Signed in as",
                value: "@\(login)",
                icon: "person.fill",
                color: .primary
            ))
        }

        return metrics
    }

    // MARK: - Helpers

    private func repoInfo(path: String, headers: [String: String]) async -> [ServiceMetric] {
        guard let url = URL(string: "\(apiBase)/repos/\(path)"),
              let repo = try? await fetchJSON(url: url, headers: headers) as? [String: Any]
        else { return [] }

        var metrics: [ServiceMetric] = []
        if let stars = repo["stargazers_count"] as? Int {
            metrics.append(ServiceMetric(
                label: "Stars",
                value: formatCount(stars),
                icon: "star.fill",
                color: .yellow
            ))
        }
        if let forks = repo["forks_count"] as? Int {
            metrics.append(ServiceMetric(
                label: "Forks",
                value: formatCount(forks),
                icon: "tuningfork",
                color: .secondary
            ))
        }
        if let issues = repo["open_issues_count"] as? Int {
            metrics.append(ServiceMetric(
                label: "Open issues",
                value: "\(issues)",
                icon: "exclamationmark.circle",
                color: issues > 50 ? .red : issues > 0 ? .orange : .green,
                isAlert: issues > 50
            ))
        }
        if let watchers = repo["subscribers_count"] as? Int {
            metrics.append(ServiceMetric(
                label: "Watchers",
                value: formatCount(watchers),
                icon: "eye.fill",
                color: .secondary
            ))
        }
        return metrics
    }

    private func actionsRuns(path: String, headers: [String: String]) async -> [ServiceMetric] {
        guard let url = URL(string: "\(apiBase)/repos/\(path)/actions/runs?per_page=10"),
              let json = try? await fetchJSON(url: url, headers: headers) as? [String: Any],
              let runs = json["workflow_runs"] as? [[String: Any]], !runs.isEmpty
        else { return [] }

        var metrics: [ServiceMetric] = []
        var seen = Set<String>()
        for run in runs {
            guard let name = run["name"] as? String, !seen.contains(name) else { continue }
            seen.insert(name)
            let conclusion = run["conclusion"] as? String
            let status = run["status"] as? String
            let (icon, color, label) = actionsDisplay(status: status, conclusion: conclusion)
            metrics.append(ServiceMetric(
                label: "CI: \(name)",
                value: label,
                icon: icon,
                color: color,
                isAlert: conclusion == "failure"
            ))
        }
        return metrics
    }

    private func formatCount(_ n: Int) -> String {
        n >= 1_000 ? String(format: "%.1fk", Double(n) / 1_000.0) : "\(n)"
    }

    private func actionsDisplay(status: String?, conclusion: String?) -> (String, Color, String) {
        switch conclusion {
        case "success":   return ("checkmark.circle.fill", .green,    "Passing")
        case "failure":   return ("xmark.circle.fill",    .red,       "Failed")
        case "cancelled": return ("slash.circle.fill",    .secondary, "Cancelled")
        case "skipped":   return ("forward.circle.fill",  .secondary, "Skipped")
        default:
            switch status {
            case "in_progress": return ("arrow.clockwise.circle.fill", .orange,    "Running")
            case "queued":      return ("clock.fill",                  .secondary, "Queued")
            default:            return ("circle.fill",                 .secondary, "Unknown")
            }
        }
    }
}
