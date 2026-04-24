import Foundation

struct Service: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var scheme: ServiceScheme
    var serviceType: ServiceType
    var group: String?       // user-defined group/tag for organization
    var apiKey: String?      // token-based auth (Home Assistant, Portainer, Jellyfin, GitHub)
    var username: String?    // credential-based auth (AdGuard, qBittorrent)
    var password: String?    // credential-based auth
    var status: ServiceStatus
    var lastChecked: Date?
    var latencyMs: Double?
    var httpStatusCode: Int?
    /// Override the global auto-refresh interval for this service (seconds). nil = use global setting.
    var checkInterval: Double?

    // Explicit CodingKeys so that adding new optional fields never breaks
    // decoding of older stored data (missing keys decode as nil).
    enum CodingKeys: String, CodingKey {
        case id, name, host, port, scheme, serviceType, group
        case apiKey, username, password
        case status, lastChecked, latencyMs, httpStatusCode
        case checkInterval
    }

    init(id: UUID = UUID(), name: String, host: String, port: Int, scheme: ServiceScheme = .http,
         group: String? = nil, apiKey: String? = nil, username: String? = nil, password: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.scheme = scheme
        self.serviceType = ServiceType.detect(from: name)
        self.group = group
        self.apiKey = apiKey
        self.username = username
        self.password = password
        self.status = .unknown
        self.checkInterval = nil
    }

    var url: URL? {
        URL(string: "\(scheme.rawValue)://\(host):\(port)")
    }

    var displayURL: String {
        "\(scheme.rawValue)://\(host):\(port)"
    }

    var icon: String { serviceType.icon }

    /// Whether this service is only reachable on a local network (private IP or .local hostname).
    var isLocalNetwork: Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || h == "localhost" { return true }
        // RFC 1918 private ranges + link-local
        let parts = h.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }
}

enum ServiceScheme: String, Codable, CaseIterable {
    case http, https, tcp

    var defaultPort: Int {
        switch self {
        case .http:  return 80
        case .https: return 443
        case .tcp:   return 0      // no conventional default; user must specify
        }
    }

    var label: String { rawValue.uppercased() }
    var isHTTP: Bool { self == .http || self == .https }
}
