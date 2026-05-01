import SwiftUI

struct QBittorrentIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)

        // Attempt login if credentials are provided; fail fast with a clear message if they're wrong.
        var cookie: String? = nil
        if let user = service.username, !user.isEmpty {
            do {
                cookie = try await login(base: base, username: user, password: service.password ?? "")
            } catch is IntegrationError {
                // Genuine auth failure (server responded but rejected credentials).
                return [ServiceMetric(
                    label: "Auth failed",
                    value: "Check username & password",
                    icon: "lock.slash.fill",
                    color: .red,
                    isAlert: true
                )]
            }
            // Network errors propagate so the caller preserves previous metrics.
        }

        // Build headers as a `let` so the `async let` fetches don't capture a `var`
        // (which Swift 6 mode rejects as a data race).
        let headers: [String: String] = cookie.map { ["Cookie": "SID=\($0)"] } ?? [:]

        guard let transferURL = URL(string: "\(base)/api/v2/transfer/info"),
              let torrentsURL = URL(string: "\(base)/api/v2/torrents/info"),
              let freeSpaceURL = URL(string: "\(base)/api/v2/sync/maindata") else {
            throw IntegrationError.badURL
        }

        async let transferResult  = fetchJSON(url: transferURL,  headers: headers)
        async let torrentsResult  = fetchJSON(url: torrentsURL,  headers: headers)
        async let mainDataResult  = fetchJSON(url: freeSpaceURL, headers: headers)

        let t        = try? await transferResult as? [String: Any]
        let torrents = try? await torrentsResult as? [[String: Any]]
        let mainData = try? await mainDataResult as? [String: Any]

        // If both fail with no cookie, auth is probably required but not configured.
        if t == nil, torrents == nil, cookie == nil {
            return [ServiceMetric(
                label: "Auth may be required",
                value: "Swipe → Edit to add credentials",
                icon: "key.fill",
                color: .orange
            )]
        }

        var metrics: [ServiceMetric] = []

        if let t {
            let dlSpeed = (t["dl_info_speed"] as? Int) ?? 0
            let ulSpeed = (t["up_info_speed"] as? Int) ?? 0
            metrics.append(ServiceMetric(
                label: "Download",
                value: formatSpeed(dlSpeed),
                icon: "arrow.down.circle.fill",
                color: dlSpeed > 0 ? .green : .secondary
            ))
            metrics.append(ServiceMetric(
                label: "Upload",
                value: formatSpeed(ulSpeed),
                icon: "arrow.up.circle.fill",
                color: ulSpeed > 0 ? .blue : .secondary
            ))
        }

        if let torrents {
            let downloading = torrents.filter { ($0["state"] as? String)?.contains("downloading") == true }.count
            let seeding     = torrents.filter { ($0["state"] as? String)?.contains("seeding") == true }.count
            metrics.append(ServiceMetric(
                label: "Torrents",
                value: "\(torrents.count) total · \(downloading) DL · \(seeding) seed",
                icon: "arrow.down.circle",
                color: .primary
            ))
        }

        if let md = mainData,
           let serverState = md["server_state"] as? [String: Any],
           let freeSpace = serverState["free_space_on_disk"] as? Int {
            let gb = Double(freeSpace) / 1_073_741_824
            metrics.append(ServiceMetric(label: "Free space", value: String(format: "%.0f GB", gb), icon: "internaldrive", color: gb < 10 ? .orange : .primary, isAlert: gb < 10))
        }

        return metrics
    }

    private func login(base: String, username: String, password: String) async throws -> String {
        guard let url = URL(string: "\(base)/api/v2/auth/login") else { throw IntegrationError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let pass = password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        request.httpBody = "username=\(user)&password=\(pass)".data(using: .utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let setCookie = http.value(forHTTPHeaderField: "Set-Cookie") else {
            throw IntegrationError.authFailed
        }
        // Parse SID from Set-Cookie header directly — avoids shared cookie storage races
        for part in setCookie.components(separatedBy: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("SID=") {
                return String(kv.dropFirst(4))
            }
        }
        throw IntegrationError.authFailed
    }

    private func formatSpeed(_ bps: Int) -> String {
        let kb = Double(bps) / 1024
        let mb = kb / 1024
        if mb >= 1  { return String(format: "%.1f MB/s", mb) }
        if kb >= 1  { return String(format: "%.0f KB/s", kb) }
        return "0 KB/s"
    }
}