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
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw IntegrationError.authFailed }
            if http.statusCode >= 500 { throw IntegrationError.unexpectedFormat }
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    func baseURL(_ service: Service) -> String {
        "\(service.scheme.rawValue)://\(service.host):\(service.port)"
    }
}
