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
    case ugreenNas       = "ugreen_nas"
    case claude          = "claude"
    case copilot         = "copilot"
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
        case .ntfy:           return "ntfy"        case .ugreenNas:      return "UGREEN NAS"        case .claude:         return "Claude"
        case .copilot:        return "GitHub Copilot"
        case .generic:        return "Generic"
        }
    }

    var isCloudService: Bool {
        switch self {
        case .github, .claude, .copilot: return true
        default: return false
        }
    }

    var cloudServiceHost: String? {
        switch self {
        case .github:   return "api.github.com"
        case .claude:   return "api.anthropic.com"
        case .copilot:  return "api.github.com"
        default:        return nil
        }
    }

    enum AuthMode { case none, token, credentials, tokenWithRepo }

    var authMode: AuthMode {
        switch self {
        case .homeAssistant, .portainer, .jellyfin: return .token
        case .github:                               return .tokenWithRepo
        case .grafana:                              return .token
        case .claude, .copilot:                     return .token
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
        case .ntfy:        return .none        case .ugreenNas:     return .token        default:           return .none
        }
    }

    var apiKeyLabel: String {
        switch self {
        case .homeAssistant: return "Long-Lived Access Token"
        case .github:        return "Personal Access Token (optional)"
        case .claude:        return "API Key"
        case .copilot:       return "Personal Access Token"
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
        case .ugreenNas:     return "TOTP Secret"
        default:             return "API Key"
        }
    }

    var usernameLabel: String {
        switch self {
        case .github:        return "Repository (owner/repo, optional)"
        case .nginxProxyMgr: return "Email"
        case .unifi:         return "Username"
        default:             return "Username"
        }
    }

    var apiKeyHint: String? {
        switch self {
        case .homeAssistant: return "Settings → Profile → Long-Lived Access Tokens"
        case .github:        return "Optional: enter owner/repo to track stars, forks, issues and CI status. Token: GitHub Settings > Developer settings > Personal access tokens."
        case .claude:        return "Requires a paid Anthropic API account (separate from Claude Pro). Go to console.anthropic.com to create an API key. Not available with a claude.ai Pro subscription."
        case .copilot:       return "Requires a GitHub Personal Access Token (classic) with read:user scope. Go to github.com/settings/tokens. Only shows plan details for individual (personal) Copilot subscriptions - org-managed seats will only show your account name and API rate limit."
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
        case .ugreenNas:     return "1. Open your NAS web UI in a browser and log in.\n2. Press F12 to open DevTools, then click the Console tab.\n3. Look for a line that says: [setToken] token: followed by a long code.\n4. Copy that code and paste it here.\n\nTip: if you don't see it, log out and log back in while the Console is open."
        default:             return nil
        }
    }

    /// Path to use for latency measurement instead of the root URL.
    /// Returns nil for services where the root URL is a fine ping target.
    var pingPath: String? {
        switch self {
        // Root URL for these serves a full web UI — use a lightweight API path instead.
        case .proxmox:    return "/api2/json/version"
        case .nextcloud:  return "/status.php"
        default: return nil
        }
    }

    /// Whether to use a raw TCP port-open check instead of HTTP for latency.
    /// Use this when the service's HTTP root is unreliable for HEAD/GET pings
    /// (e.g. POST-only endpoints, non-standard response codes).
    var prefersTCPPing: Bool {
        switch self {
        case .glances, .openWrt: return true
        default: return false
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
        case .nextcloud:     return "Use your Nextcloud username and an app password (Settings → Security → Devices & sessions)."        case .ugreenNas:     return "Use your UGOS Pro login credentials. For TOTP Secret: open your authenticator app, find the UGREEN NAS entry, and export or copy the secret key (usually shown as a QR code or text when you set up 2FA)."        default:             return nil
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
        case .ugreenNas:      return "externaldrive.fill"
        case .claude:        return "sparkle"
        case .copilot:       return "chevron.left.forwardslash.chevron.right"
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
        case .ugreenNas:      return 9443
        case .claude:        return 443
        case .copilot:       return 443
        case .generic:       return 80
        }
    }

    var defaultScheme: ServiceScheme {
        switch self {
        case .github, .nextcloud: return .https
        case .proxmox, .unifi:    return .https
        case .ugreenNas:          return .https
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
        if n.contains("claude")         { return .claude }
        if n.contains("copilot")        { return .copilot }
        if n.contains("ugreen") || n.contains("ugos") || n.contains("ugnas") { return .ugreenNas }
        return .generic
    }
}
