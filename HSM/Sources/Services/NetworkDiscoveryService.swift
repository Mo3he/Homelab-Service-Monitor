import Foundation
import Network
import Darwin

// MARK: - Discovered Service Model

struct DiscoveredNetworkService: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let host: String
    let port: Int
    let serviceType: ServiceType
}

// MARK: - Service Probe

/// Describes how to find and verify a specific self-hosted service.
/// TCP connect confirms the port is open; the HTTP request confirms it's actually
/// the right service (not a macOS system process using the same port).
struct ServiceProbe {
    let port: Int
    let serviceType: ServiceType
    /// "http" or "https". Self-signed certs are accepted since we're on a LAN.
    let scheme: String
    /// API path to GET after TCP succeeds. Should be unauthenticated and cheap.
    let verifyPath: String
    /// String that must appear anywhere in the response body.
    /// nil = any 2xx-4xx HTTP status is good enough.
    let verifySignal: String?
}

// MARK: - Insecure URLSession delegate (accepts self-signed certs on LAN)

private final class InsecureSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - mDNS NetService Resolver

/// Resolves a Bonjour service endpoint to a human-readable hostname and port.
/// Kept solely to upgrade raw IPs found by the TCP sweep to friendly names.
private final class NetServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let completion: (String?, Int?) -> Void

    init(name: String, type: String, domain: String, completion: @escaping (String?, Int?) -> Void) {
        self.service = NetService(domain: domain, type: type, name: name)
        self.completion = completion
        super.init()
        service.delegate = self
    }

    func start() {
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5)
    }

    func stop() {
        service.remove(from: .main, forMode: .common)
        service.stop()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let rawHost = sender.hostName.map { h -> String in
            var cleaned = h.hasSuffix(".") ? String(h.dropLast()) : h
            if cleaned.hasSuffix(".local") { cleaned = String(cleaned.dropLast(".local".count)) }
            return cleaned
        }
        let host: String?
        if let h = rawHost, Self.looksLikeHexUUID(h) {
            host = Self.firstIPv4(from: sender.addresses) ?? rawHost
        } else {
            host = rawHost
        }
        let port = sender.port == -1 ? nil : sender.port
        completion(host, port)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        completion(nil, nil)
    }

    private static func looksLikeHexUUID(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: "-", with: "")
        guard stripped.count >= 16 else { return false }
        return stripped.allSatisfy { $0.isHexDigit }
    }

    private static func firstIPv4(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        for data in addresses {
            let ip = data.withUnsafeBytes { ptr -> String? in
                guard let addr = ptr.baseAddress else { return nil }
                guard addr.load(as: sockaddr.self).sa_family == UInt8(AF_INET) else { return nil }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var inAddr = addr.load(as: sockaddr_in.self).sin_addr
                guard inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buf)
            }
            if let ip { return ip }
        }
        return nil
    }
}

// MARK: - Discovery Service

// File-private global so nonisolated static methods can access it without
// inheriting @MainActor isolation from the class.
private let _discoveryTCPQueue = DispatchQueue(label: "net.mohome.hsm.tcp", qos: .utility,
                                               attributes: .concurrent)

/// Discovers services via two parallel strategies:
///
/// 1. **TCP + HTTP sweep** - probes every IP on the /24 subnet on each known port,
///    then makes a real HTTP request to a service-specific endpoint to confirm it's
///    actually that service (not a macOS system process on the same port).
///
/// 2. **mDNS/Bonjour** - runs in parallel; when it resolves a service already found
///    by the sweep, it upgrades the raw IP to a human-readable hostname.
@MainActor
final class NetworkDiscoveryService: ObservableObject {
    @Published private(set) var results: [DiscoveredNetworkService] = []
    @Published private(set) var isScanning = false
    /// 0.0–1.0 progress of the TCP sweep phase. Reset to 0 when a new scan starts.
    @Published private(set) var scanProgress: Double = 0

    private var scanTask: Task<Void, Never>?
    private var mdnsBrowsers: [NWBrowser] = []
    private var mdnsResolvers: [NetServiceResolver] = []
    private let mdnsQueue = DispatchQueue(label: "net.mohome.hsm.discovery.mdns", qos: .userInitiated)

    // URLSession shared across all HTTP verifications. Accepts self-signed certs.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config,
                          delegate: InsecureSessionDelegate(),
                          delegateQueue: nil)
    }()

    // Shared queue for all TCP probe callbacks - avoids spawning thousands of DispatchQueues.
    // Defined as a file-private global above the class to avoid @MainActor isolation issues.

    // MARK: - Probe definitions

    /// After TCP confirms a port is open, we GET scheme://host:port/verifyPath and
    /// check that the response body contains verifySignal. This eliminates false
    /// positives caused by macOS system services (AirPlay on 5000, etc.).
    ///
    /// For services that require authentication on their API, we hit the web UI root
    /// (/) which always returns the app name in HTML without any credentials.
    static let probes: [ServiceProbe] = [
        ServiceProbe(port: 8123,  serviceType: .homeAssistant, scheme: "http",
                     verifyPath: "/api/",                 verifySignal: "API running"),
        ServiceProbe(port: 3000,  serviceType: .grafana,       scheme: "http",
                     verifyPath: "/api/health",           verifySignal: "database"),
        ServiceProbe(port: 9000,  serviceType: .portainer,     scheme: "http",
                     verifyPath: "/",                     verifySignal: "Portainer"),
        ServiceProbe(port: 81,    serviceType: .nginxProxyMgr, scheme: "http",
                     verifyPath: "/",                     verifySignal: nil),
        ServiceProbe(port: 61208, serviceType: .glances,       scheme: "http",
                     verifyPath: "/api/3/version",        verifySignal: nil),
        ServiceProbe(port: 61208, serviceType: .glances,       scheme: "http",
                     verifyPath: "/api/4/version",        verifySignal: nil),
        ServiceProbe(port: 8096,  serviceType: .jellyfin,      scheme: "http",
                     verifyPath: "/System/Info/Public",   verifySignal: "ServerName"),
        ServiceProbe(port: 32400, serviceType: .plex,          scheme: "http",
                     verifyPath: "/",                     verifySignal: "Plex"),
        // Sonarr/Radarr/Prowlarr require an API key - use web UI root which
        // embeds the app name in HTML without credentials.
        ServiceProbe(port: 8989,  serviceType: .sonarr,        scheme: "http",
                     verifyPath: "/",                     verifySignal: "Sonarr"),
        ServiceProbe(port: 7878,  serviceType: .radarr,        scheme: "http",
                     verifyPath: "/",                     verifySignal: "Radarr"),
        ServiceProbe(port: 9696,  serviceType: .prowlarr,      scheme: "http",
                     verifyPath: "/",                     verifySignal: "Prowlarr"),
        ServiceProbe(port: 5055,  serviceType: .overseerr,     scheme: "http",
                     verifyPath: "/",                     verifySignal: "Overseerr"),
        ServiceProbe(port: 8006,  serviceType: .proxmox,       scheme: "https",
                     verifyPath: "/api2/json/version",    verifySignal: "version"),
        ServiceProbe(port: 8443,  serviceType: .unifi,         scheme: "https",
                     verifyPath: "/manage/account/login", verifySignal: "UniFi"),
        ServiceProbe(port: 2283,  serviceType: .immich,        scheme: "http",
                     verifyPath: "/api/server/about",     verifySignal: "version"),
        ServiceProbe(port: 5000,  serviceType: .frigate,       scheme: "http",
                     verifyPath: "/api/version",          verifySignal: "version"),
        ServiceProbe(port: 9443,  serviceType: .ugreenNas,     scheme: "https",
                     verifyPath: "/",                     verifySignal: nil),
        ServiceProbe(port: 8000,  serviceType: .vaultwarden,   scheme: "http",
                     verifyPath: "/alive",                verifySignal: "Alive"),
        // qBittorrent - default 8080 and common alt port 8888
        ServiceProbe(port: 8080,  serviceType: .qBittorrent,   scheme: "http",
                     verifyPath: "/api/v2/app/version",   verifySignal: nil),
        ServiceProbe(port: 8888,  serviceType: .qBittorrent,   scheme: "http",
                     verifyPath: "/api/v2/app/version",   verifySignal: nil),
        // AdGuard Home - common ports: 3000 (default setup), 80, 86, 3001
        ServiceProbe(port: 3000,  serviceType: .adGuard,       scheme: "http",
                     verifyPath: "/control/status",       verifySignal: "dns"),
        ServiceProbe(port: 80,    serviceType: .adGuard,       scheme: "http",
                     verifyPath: "/control/status",       verifySignal: "dns"),
        ServiceProbe(port: 86,    serviceType: .adGuard,       scheme: "http",
                     verifyPath: "/control/status",       verifySignal: "dns"),
        ServiceProbe(port: 3001,  serviceType: .adGuard,       scheme: "http",
                     verifyPath: "/control/status",       verifySignal: "dns"),
        // Pi-hole web UI
        ServiceProbe(port: 80,    serviceType: .pihole,        scheme: "http",
                     verifyPath: "/admin/api.php",        verifySignal: "domains_being_blocked"),
        // OpenWrt / LuCI - default port 80; LuCI HTML always contains "LuCI"
        ServiceProbe(port: 80,    serviceType: .openWrt,       scheme: "http",
                     verifyPath: "/",                     verifySignal: "LuCI"),
    ]

    // MARK: - mDNS types (hostname resolution only)

    static let mdnsTypes: [(mdns: String, serviceType: ServiceType)] = [
        ("_home-assistant._tcp",  .homeAssistant),
        ("_plexmediaserver._tcp", .plex),
        ("_jellyfin._tcp",        .jellyfin),
        ("_unifi._tcp",           .unifi),
        ("_adguard-home._tcp",    .adGuard),
        ("_portainer._tcp",       .portainer),
        ("_proxmox._tcp",         .proxmox),
        ("_grafana._tcp",         .grafana),
        ("_pihole._tcp",          .pihole),
        ("_sonarr._tcp",          .sonarr),
        ("_radarr._tcp",          .radarr),
        ("_prowlarr._tcp",        .prowlarr),
        ("_overseerr._tcp",       .overseerr),
        ("_nextcloud._tcp",       .nextcloud),
        ("_traefik._tcp",         .traefik),
        ("_immich._tcp",          .immich),
        ("_ntfy._tcp",            .ntfy),
        ("_frigate._tcp",         .frigate),
    ]

    // MARK: - Public API

    func startScan() {
        stopScan()
        results = []
        isScanning = true
        startMDNS()
        scanTask = Task {
            await runSweep()
            // Let mDNS keep running briefly to upgrade IPs to hostnames.
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { stopScan() }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        mdnsBrowsers.forEach { $0.cancel() }
        mdnsBrowsers = []
        mdnsResolvers.forEach { $0.stop() }
        mdnsResolvers = []
        isScanning = false
        scanProgress = 0
    }

    // MARK: - mDNS (hostname resolution)

    private func startMDNS() {
        for (mdnsType, serviceType) in Self.mdnsTypes {
            let descriptor = NWBrowser.Descriptor.bonjour(type: mdnsType, domain: nil)
            let browser = NWBrowser(for: descriptor, using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] (_: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) in
                for change in changes {
                    if case .added(let result) = change {
                        Task { @MainActor [weak self] in
                            self?.handleMDNSResult(result, knownType: serviceType)
                        }
                    }
                }
            }
            browser.start(queue: mdnsQueue)
            mdnsBrowsers.append(browser)
        }
    }

    private func handleMDNSResult(_ result: NWBrowser.Result, knownType: ServiceType) {
        guard case .service(let name, let type, let domain, _) = result.endpoint else { return }
        let nsType   = type.hasSuffix(".")   ? type   : type + "."
        let nsDomain = domain.hasSuffix(".") ? domain : domain + "."

        let resolver = NetServiceResolver(name: name, type: nsType, domain: nsDomain) { [weak self] host, port in
            Task { @MainActor [weak self] in
                guard let self, let host, let port else { return }
                let resolvedPort = port == 0 ? knownType.defaultPort : port
                // Upgrade an existing IP-based result to a friendly hostname.
                if let idx = self.results.firstIndex(where: { $0.port == resolvedPort }) {
                    let existing = self.results[idx]
                    self.results[idx] = DiscoveredNetworkService(
                        name: name, host: host, port: resolvedPort, serviceType: existing.serviceType
                    )
                } else {
                    self.addResult(name: name, host: host, port: resolvedPort, serviceType: knownType)
                }
            }
        }
        mdnsResolvers.append(resolver)
        resolver.start()
    }

    // MARK: - TCP + HTTP Sweep

    private func runSweep() async {
        // Try to read the real netmask; fall back to /24 so the sweep always runs.
        let hosts: [String]
        if let (localIP, netmask) = Self.currentIPAndMask() {
            hosts = Self.hostsInSubnet(ip: localIP, mask: netmask)
        } else if let localIP = NetworkMonitor.shared.currentLocalIP,
                  let subnet = Self.extractSubnet(from: localIP) {
            hosts = (1...254).map { "\(subnet).\($0)" }
        } else {
            return
        }
        guard !hosts.isEmpty else { return }

        // Build port → probes map so each unique port is TCP-probed only once per host.
        var portToProbes: [Int: [ServiceProbe]] = [:]
        for probe in Self.probes {
            portToProbes[probe.port, default: []].append(probe)
        }
        let uniquePorts = Array(portToProbes.keys)

        // Phase 1 — batch TCP scan.
        // Open 100 non-blocking sockets and poll() all of them in one syscall.
        // This avoids spawning a GCD thread per probe, which was the main bottleneck.
        let allTargets = hosts.flatMap { host in uniquePorts.map { (host, $0) } }
        let batchSize = 100
        let totalBatches = max(1, (allTargets.count + batchSize - 1) / batchSize)
        var openPairs: [(host: String, port: Int)] = []

        for (batchIndex, batchStart) in stride(from: 0, to: allTargets.count, by: batchSize).enumerated() {
            guard !Task.isCancelled else { return }
            let batch = Array(allTargets[batchStart ..< min(batchStart + batchSize, allTargets.count)])
            let open = await Self.tcpProbeMany(batch)
            openPairs.append(contentsOf: open)
            scanProgress = Double(batchIndex + 1) / Double(totalBatches)
        }

        guard !Task.isCancelled, !openPairs.isEmpty else { return }

        // Phase 2 — HTTP verify open ports concurrently.
        await withTaskGroup(of: Void.self) { group in
            for (host, port) in openPairs {
                guard let probes = portToProbes[port] else { continue }
                for probe in probes {
                    group.addTask {
                        guard await NetworkDiscoveryService.httpVerify(host: host, probe: probe) else { return }
                        await MainActor.run {
                            self.addResult(name: probe.serviceType.displayName, host: host, port: port, serviceType: probe.serviceType)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func addResult(name: String, host: String, port: Int, serviceType: ServiceType) {
        guard !results.contains(where: { $0.host == host && $0.port == port }) else { return }
        results.append(DiscoveredNetworkService(name: name, host: host, port: port, serviceType: serviceType))
    }

    /// Reads the IPv4 address and netmask for the primary WiFi/Ethernet interface.
    /// Uses inet_ntop directly on sin_addr rather than getnameinfo, because
    /// ifa_netmask sockaddrs often have sa_len == 0 on iOS, causing getnameinfo to fail.
    nonisolated private static func currentIPAndMask() -> (ip: String, mask: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            guard (name == "en0" || name == "en1"),
                  let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  let netmaskAddr = ifa.pointee.ifa_netmask else { continue }
            // Extract IP using inet_ntop on sin_addr directly.
            var ipIn = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipIn, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            // Extract netmask using inet_ntop on the mask's sin_addr directly.
            var maskIn = netmaskAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var maskBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &maskIn, &maskBuf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip   = String(cString: ipBuf)
            let mask = String(cString: maskBuf)
            // Sanity check: mask must not be all-zeros
            guard mask != "0.0.0.0" else { continue }
            return (ip, mask)
        }
        return nil
    }

    nonisolated private static func extractSubnet(from ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    /// Returns all host addresses (excluding network and broadcast) in the subnet
    /// defined by the given IP and dotted-decimal netmask. Capped at 2048 hosts
    /// so a misconfigured /8 doesn't trigger a huge scan.
    nonisolated private static func hostsInSubnet(ip: String, mask: String) -> [String] {
        let toOctets: (String) -> [UInt32]? = { s in
            let parts = s.split(separator: ".").compactMap { UInt32($0) }
            return parts.count == 4 ? parts : nil
        }
        guard let ipParts = toOctets(ip), let maskParts = toOctets(mask) else { return [] }
        let ipInt   = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
        let maskInt = (maskParts[0] << 24) | (maskParts[1] << 16) | (maskParts[2] << 8) | maskParts[3]
        let network   = ipInt & maskInt
        let broadcast = network | (~maskInt)
        let hostCount = Int(broadcast &- network) - 1
        guard hostCount > 0, hostCount <= 2048 else { return [] }
        return (1...hostCount).map { offset -> String in
            let h = network + UInt32(offset)
            return "\((h >> 24) & 0xFF).\((h >> 16) & 0xFF).\((h >> 8) & 0xFF).\(h & 0xFF)"
        }
    }

    /// Opens all sockets in `targets` non-blocking simultaneously, then loops
    /// poll() within a 500 ms window until every socket has responded (RST/SYN-ACK)
    /// or the deadline expires. Returns only the (host, port) pairs that connected.
    /// Silent — no NWConnection log spam.
    nonisolated private static func tcpProbeMany(_ targets: [(String, Int)]) async -> [(host: String, port: Int)] {
        await withCheckedContinuation { continuation in
            _discoveryTCPQueue.async {
                // Open all sockets and start non-blocking connects.
                struct Entry { var fd: Int32; let host: String; let port: Int }
                var pending: [Entry] = []
                for (host, port) in targets {
                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
                    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { continue }
                    let fd = socket(AF_INET, SOCK_STREAM, 0)
                    guard fd >= 0 else { continue }
                    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    pending.append(Entry(fd: fd, host: host, port: port))
                }

                var results: [(host: String, port: Int)] = []
                // Loop poll() until all sockets are done or 500 ms wall-clock expires.
                // poll() returns as soon as ANY socket is ready, so we re-call with
                // the remaining sockets and shrinking timeout to collect all of them.
                let deadlineNs = DispatchTime.now().uptimeNanoseconds + 500_000_000
                while !pending.isEmpty {
                    let nowNs = DispatchTime.now().uptimeNanoseconds
                    guard nowNs < deadlineNs else { break }
                    let msLeft = Int32((deadlineNs - nowNs) / 1_000_000)
                    guard msLeft > 0 else { break }
                    var pollfds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                    _ = poll(&pollfds, nfds_t(pollfds.count), msLeft)
                    var stillPending: [Entry] = []
                    for (i, pfd) in pollfds.enumerated() {
                        let e = pending[i]
                        if pfd.revents != 0 {
                            var soError: Int32 = 0
                            var soLen = socklen_t(MemoryLayout<Int32>.size)
                            getsockopt(e.fd, SOL_SOCKET, SO_ERROR, &soError, &soLen)
                            close(e.fd)
                            if soError == 0 { results.append((host: e.host, port: e.port)) }
                        } else {
                            stillPending.append(e)
                        }
                    }
                    pending = stillPending
                }
                // Close any that never responded within the deadline.
                for e in pending { close(e.fd) }
                continuation.resume(returning: results)
            }
        }
    }

    /// GETs the probe's verify path and checks the response contains the expected signal.
    /// Returns false for network errors, timeouts, or missing signal.
    nonisolated private static func httpVerify(host: String, probe: ServiceProbe) async -> Bool {
        guard let url = URL(string: "\(probe.scheme)://\(host):\(probe.port)\(probe.verifyPath)") else {
            return false
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...499).contains(http.statusCode) else { return false }
            if let signal = probe.verifySignal {
                let body = String(data: data, encoding: .utf8) ?? ""
                return body.contains(signal)
            }
            return true
        } catch {
            return false
        }
    }
}
