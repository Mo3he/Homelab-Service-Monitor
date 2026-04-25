import Foundation

protocol ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric]
}

// Factory
enum IntegrationProvider {
    static func integration(for service: Service) -> ServiceIntegration {
        switch service.serviceType {
        case .glances:       return GlancesIntegration()
        case .adGuard:       return AdGuardIntegration()
        case .homeAssistant: return HomeAssistantIntegration()
        case .qBittorrent:   return QBittorrentIntegration()
        case .portainer:     return PortainerIntegration()
        case .jellyfin:      return JellyfinIntegration()
        case .github:        return GitHubIntegration()
        case .grafana:       return GrafanaIntegration()
        case .nginxProxyMgr: return NginxProxyManagerIntegration()
        case .openWrt:       return OpenWrtIntegration()
        case .plex:          return PlexIntegration()
        case .sonarr, .radarr: return ArrIntegration()
        case .prowlarr:      return ProwlarrIntegration()
        case .overseerr:     return OverseerrIntegration()
        case .proxmox:       return ProxmoxIntegration()
        case .truenas:       return TrueNASIntegration()
        case .traefik:       return TraefikIntegration()
        case .unifi:         return UnifiIntegration()
        case .pihole:        return PiholeIntegration()
        case .nextcloud:     return NextcloudIntegration()
        case .vaultwarden:   return VaultwardenIntegration()
        case .immich:        return ImmichIntegration()
        case .paperless:     return PaperlessIntegration()
        case .frigate:       return FrigateIntegration()
        case .ntfy:          return NtfyIntegration()
        case .claude:        return ClaudeIntegration()
        case .copilot:       return CopilotIntegration()
        default:             return GenericIntegration()
        }
    }
}

// Shared JSON fetch helper
extension ServiceIntegration {
    func fetchJSON(url: URL, headers: [String: String] = [:]) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await IntegrationHTTP.session.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 401, 403:
                throw IntegrationError.authFailed
            case 429, 502, 503, 504:
                throw IntegrationError.transient(retryAfter: parseRetryAfter(http))
            case 500...:
                throw IntegrationError.serviceError(statusCode: http.statusCode)
            default:
                break
            }
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw IntegrationError.unexpectedFormat
        }
    }

    func baseURL(_ service: Service) -> String {
        "\(service.scheme.rawValue)://\(service.host):\(service.port)"
    }

    /// Reads a Retry-After header. RFC 7231 allows either delta-seconds or HTTP-date.
    private func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let secs = TimeInterval(raw) { return secs }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}

/// Single ephemeral URLSession shared by all integrations. Mirrors the configuration
/// PingService uses so transport behavior (timeouts, redirects, no caching) is consistent.
enum IntegrationHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config,
                          delegate: InsecureTrustRegistry.shared,
                          delegateQueue: nil)
    }()
}
