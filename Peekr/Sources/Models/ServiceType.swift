import Foundation

enum ServiceType: String, Codable, CaseIterable {
    case homeAssistant   = "home_assistant"
    case adGuard         = "adguard"
    case grafana         = "grafana"
    case github          = "github"
    case portainer       = "portainer"
    case nginxProxyMgr   = "nginx_proxy_manager"
    case glances         = "glances"
    case jellyfin        = "jellyfin"
    case qBittorrent     = "qbittorrent"
    case openWrt         = "openwrt"
    // New
    case plex            = "plex"
    case sonarr          = "sonarr"
    case radarr          = "radarr"
    case prowlarr        = "prowlarr"
    case overseerr       = "overseerr"
    case proxmox         = "proxmox"
    case truenas         = "truenas"
    case traefik         = "traefik"
    case unifi           = "unifi"
    case pihole          = "pihole"
    case nextcloud       = "nextcloud"
    case vaultwarden     = "vaultwarden"
    case immich          = "immich"
    case paperless       = "paperless"
    case frigate         = "frigate"
    case ntfy            = "ntfy"
    case generic         = "generic"

    var displayName: String {
        switch self {
        case .homeAssistant:  return "Home Assistant"
        case .adGuard:        return "AdGuard Home"
        case .grafana:        return "Grafana"
        case .github:         return "GitHub"
        case .portainer:      return "Portainer"
        case .nginxProxyMgr:  return "Nginx Proxy Manager"
        case .glances:        return "Glances"
        case .jellyfin:       return "Jellyfin"
        case .qBittorrent:    return "qBittorrent"
        case .openWrt:        return "OpenWrt"
        case .plex:           return "Plex"
        case .sonarr:         return "Sonarr"
        case .radarr:         return "Radarr"
        case .prowlarr:       return "Prowlarr"
        case .overseerr:      return "Overseerr"
        case .proxmox:        return "Proxmox"
        case .truenas:        return "TrueNAS"
        case .traefik:        return "Traefik"
        case .unifi:          return "Unifi Controller"
        case .pihole:         return "Pi-hole"
        case .nextcloud:      return "Nextcloud"
        case .vaultwarden:    return "Vaultwarden"
        case .immich:         return "Immich"
        case .paperless:      return "Paperless-ngx"
        case .frigate:        return "Frigate"
        case .ntfy:           return "ntfy"
        case .generic:        return "Generic"
        }
    }

    enum AuthMode { case none, token, credentials, tokenWithRepo }

    var authMode: AuthMode {
        switch self {
        case .homeAssistant, .portainer, .jellyfin: return .token
        case .github:                               return .tokenWithRepo
        case .grafana:                              return .token
        case .adGuard, .qBittorrent, .nginxProxyMgr, .openWrt: return .credentials
        case .plex:        return .token
        case .sonarr, .radarr, .prowlarr, .overseerr: return .token
        case .proxmox:     return .credentials
        case .truenas:     return .token
        case .traefik:     return .none
        case .unifi:       return .credentials
        case .pihole:      return .token
        case .nextcloud:   return .credentials
        case .vaultwarden: return .token
        case .immich:      return .token
        case .paperless:   return .token
        case .frigate:     return .none
        case .ntfy:        return .none
        default:           return .none
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .homeAssistant: return "Long-Lived Access Token"
        case .github:        return "Personal Access Token"
        case .portainer:     return "API Key"
        case .jellyfin:      return "API Key"
        case .grafana:       return "Service Account Token (optional)"
        case .plex:          return "X-Plex-Token"
        case .sonarr, .radarr, .prowlarr, .overseerr: return "API Key"
        case .truenas:       return "API Key"
        case .pihole:        return "API Token"
        case .vaultwarden:   return "Admin Token"
        case .immich:        return "API Key"
        case .paperless:     return "API Token"
        default:             return "API Key"
        }
    }

    var usernameLabel: String {
        switch self {
        case .github:        return "Repository (owner/repo)"
        case .nginxProxyMgr: return "Email"
        case .unifi:         return "Username"
        default:             return "Username"
        }
    }

    var apiKeyHint: String? {
        switch self {
        case .homeAssistant: return "Settings → Profile → Long-Lived Access Tokens"
        case .github:        return "Token: GitHub → Settings → Developer settings → Personal access tokens. Needed for private repos and Actions status. Without a token, only rate limit is shown."
        case .portainer:     return "Portainer → My Account → API Keys"
        case .jellyfin:      return "Dashboard → API Keys → +"
        case .grafana:       return "Administration → Service accounts → Add service account → Add token. Without a token, only version and DB health are shown."
        case .plex:          return "Find your token at plex.tv/claim or in the Plex Web app URL when signed in."
        case .sonarr:        return "Settings → General → API Key"
        case .radarr:        return "Settings → General → API Key"
        case .prowlarr:      return "Settings → General → API Key"
        case .overseerr:     return "Settings → General → API Key"
        case .truenas:       return "Credentials → API Keys → Add"
        case .pihole:        return "Settings → API → Show API token"
        case .vaultwarden:   return "Admin panel token set during server setup."
        case .immich:        return "User Settings → API Keys → New API Key"
        case .paperless:     return "Settings → API → Generate Token"
        default:             return nil
        }
    }

    var credentialsHint: String? {
        switch self {
        case .adGuard:       return "Leave blank if AdGuard authentication is disabled."
        case .qBittorrent:   return "Leave blank if qBittorrent authentication is disabled."
        case .openWrt:       return "Default username is root."
        case .nginxProxyMgr: return "Use your Nginx Proxy Manager login email and password."
        case .proxmox:       return "Use your Proxmox username (e.g. root@pam) and password."
        case .unifi:         return "Use your Unifi Controller login credentials."
        case .nextcloud:     return "Use your Nextcloud username and an app password (Settings → Security → Devices & sessions)."
        default:             return nil
        }
    }

    var icon: String {
        switch self {
        case .homeAssistant: return "house.fill"
        case .adGuard:       return "shield.fill"
        case .grafana:       return "chart.line.uptrend.xyaxis"
        case .github:        return "chevron.left.forwardslash.chevron.right"
        case .portainer:     return "shippingbox.fill"
        case .nginxProxyMgr: return "arrow.triangle.branch"
        case .glances:       return "gauge.with.dots.needle.33percent"
        case .jellyfin:      return "play.tv.fill"
        case .qBittorrent:   return "arrow.down.circle.fill"
        case .openWrt:       return "wifi.router.fill"
        case .plex:          return "play.rectangle.fill"
        case .sonarr:        return "tv.and.mediabox"
        case .radarr:        return "film.stack.fill"
        case .prowlarr:      return "magnifyingglass.circle.fill"
        case .overseerr:     return "person.crop.circle.badge.plus"
        case .proxmox:       return "server.rack"
        case .truenas:       return "externaldrive.fill"
        case .traefik:       return "arrow.triangle.swap"
        case .unifi:         return "wifi.circle.fill"
        case .pihole:        return "shield.lefthalf.filled"
        case .nextcloud:     return "cloud.fill"
        case .vaultwarden:   return "lock.fill"
        case .immich:        return "photo.stack.fill"
        case .paperless:     return "doc.text.fill"
        case .frigate:       return "video.fill"
        case .ntfy:          return "bell.fill"
        case .generic:       return "server.rack"
        }
    }

    var defaultPort: Int {
        switch self {
        case .homeAssistant: return 8123
        case .adGuard:       return 80
        case .grafana:       return 3000
        case .github:        return 443
        case .portainer:     return 9000
        case .nginxProxyMgr: return 81
        case .glances:       return 61208
        case .jellyfin:      return 8096
        case .qBittorrent:   return 8080
        case .openWrt:       return 80
        case .plex:          return 32400
        case .sonarr:        return 8989
        case .radarr:        return 7878
        case .prowlarr:      return 9696
        case .overseerr:     return 5055
        case .proxmox:       return 8006
        case .truenas:       return 80
        case .traefik:       return 8080
        case .unifi:         return 8443
        case .pihole:        return 80
        case .nextcloud:     return 443
        case .vaultwarden:   return 8000
        case .immich:        return 2283
        case .paperless:     return 8000
        case .frigate:       return 5000
        case .ntfy:          return 80
        case .generic:       return 80
        }
    }

    var defaultScheme: ServiceScheme {
        switch self {
        case .github, .nextcloud: return .https
        case .proxmox, .unifi:    return .https
        default:                  return .http
        }
    }

    // Auto-detect from service name
    static func detect(from name: String) -> ServiceType {
        let n = name.lowercased()
        if n.contains("home assistant") || n.contains("homeassistant") { return .homeAssistant }
        if n.contains("adguard")        { return .adGuard }
        if n.contains("grafana")        { return .grafana }
        if n.contains("github")         { return .github }
        if n.contains("portainer")      { return .portainer }
        if n.contains("nginx")          { return .nginxProxyMgr }
        if n.contains("glances")        { return .glances }
        if n.contains("jellyfin")       { return .jellyfin }
        if n.contains("qbittorrent") || n.contains("torrent") { return .qBittorrent }
        if n.contains("openwrt")        { return .openWrt }
        if n.contains("plex")           { return .plex }
        if n.contains("sonarr")         { return .sonarr }
        if n.contains("radarr")         { return .radarr }
        if n.contains("prowlarr")       { return .prowlarr }
        if n.contains("overseerr") || n.contains("jellyseerr") { return .overseerr }
        if n.contains("proxmox")        { return .proxmox }
        if n.contains("truenas") || n.contains("freenas") { return .truenas }
        if n.contains("traefik")        { return .traefik }
        if n.contains("unifi")          { return .unifi }
        if n.contains("pihole") || n.contains("pi-hole") { return .pihole }
        if n.contains("nextcloud")      { return .nextcloud }
        if n.contains("vaultwarden") || n.contains("bitwarden") { return .vaultwarden }
        if n.contains("immich")         { return .immich }
        if n.contains("paperless")      { return .paperless }
        if n.contains("frigate")        { return .frigate }
        if n.contains("ntfy")           { return .ntfy }
        return .generic
    }
}
