import Foundation
import Network
import Combine
import Darwin

/// Monitors network path changes and probes whether local-network services are
/// reachable on the current WiFi. No entitlements required.
///
/// When the WiFi connection changes, a fast TCP probe is sent to the first local
/// service in the store. If it responds, `isHomeNetwork` is true and all local
/// services are checked normally. If not, local services are skipped and a banner
/// is shown. The user can override with "Check anyway".
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnWiFi = true
    @Published private(set) var isConnected = true
    @Published private(set) var likelyVPN = false

    /// Result of the last local-network probe. `nil` means not yet probed.
    @Published private(set) var isHomeNetwork: Bool? = nil
    /// True while a probe is in flight.
    @Published private(set) var isProbing = false
    /// User tapped "Check anyway" - stays true until the next network change.
    @Published var userOverride = false
    /// Current device IPv4 address on the active WiFi interface. Updated on each network change.
    @Published private(set) var currentLocalIP: String? = nil

    /// Whether we expect local-network services to be reachable right now.
    var canReachLocal: Bool {
        if userOverride { return true }
        if likelyVPN { return true }
        if !isOnWiFi { return false }
        // While probing, keep showing the last-known result to avoid UI flashing.
        // Only block if we have never probed or the last probe was negative.
        if isProbing { return isHomeNetwork ?? false }
        guard let home = isHomeNetwork else { return false }
        return home
    }

    /// Whether a specific service should be checked right now.
    func canReachService(_ service: Service) -> Bool {
        // If there is no network path at all, skip every service — checking would just
        // produce a flood of timeouts that mark everything offline when the real cause
        // is a dropped connection (airplane mode, VPN failed to connect, etc.).
        guard isConnected else { return false }
        guard service.isLocalNetwork else { return true }
        // A configured failover host means the service may be reachable via VPN even when
        // the primary local address is unreachable — always attempt so PingService can fall back.
        if let fh = service.failoverHost, !fh.isEmpty { return true }
        return canReachLocal
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.mohome.hsm.networkMonitor")
    private let probeQueue = DispatchQueue(label: "net.mohome.hsm.probe")
    /// Debounce timer to coalesce rapid NWPathMonitor updates.
    private var debounceTask: Task<Void, Never>?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        let wasOnWiFi = isOnWiFi
        isConnected = path.status == .satisfied
        isOnWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        likelyVPN = path.usesInterfaceType(.other)

        if !isOnWiFi {
            debounceTask?.cancel()
            isHomeNetwork = nil
            userOverride = false
            currentLocalIP = nil
            return
        }

        // WiFi state changed (was off, now on): reset override so a fresh probe runs.
        if isOnWiFi != wasOnWiFi {
            userOverride = false
        }

        currentLocalIP = Self.currentWiFiIPv4()

        // Debounce: NWPathMonitor often fires multiple updates in quick succession.
        // Wait briefly before probing to coalesce them into a single probe.
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled else { return }
            await self.probeLocalReachability()
        }
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Device IP

    /// Returns the IPv4 address on the primary WiFi interface (en0) or wired (en1).
    private static func currentWiFiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            guard (name == "en0" || name == "en1"),
                  let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: hostname)
        }
        return nil
    }

    /// Re-run the local reachability probe (e.g. after user taps "Check anyway").
    func reprobeAndOverride() {
        userOverride = true
        Task { await probeLocalReachability() }
    }

    // MARK: - Probe

    /// Attempts a fast TCP connection to local services in the store, trying each in turn.
    /// If any responds within 2 seconds, we're on the home network.
    private func probeLocalReachability() async {
        let localServices = ServiceStore.shared.services.filter(\.isLocalNetwork)
        guard !localServices.isEmpty else {
            // No local services configured - nothing to probe
            isHomeNetwork = true
            return
        }

        isProbing = true
        defer { isProbing = false }

        // Try all local services concurrently; succeed as soon as any one responds
        let reachable = await withTaskGroup(of: Bool.self) { group in
            for service in localServices {
                let port = UInt16(clamping: service.port)
                guard port > 0 else { continue }
                group.addTask { await self.quickTCPProbe(host: service.host, port: port) }
            }
            for await result in group {
                if result {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
        isHomeNetwork = reachable
    }

    /// Fast TCP connect with a 2-second timeout. Returns true if the port is open.
    private func quickTCPProbe(host: String, port: UInt16) async -> Bool {
        let queue = self.probeQueue
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            // Wrap the resumed flag in a reference type so the state-update closure and
            // the asyncAfter timeout share the same value without Swift 6 complaining
            // about captured-var-in-concurrent-code (both run on `queue`, so this is
            // safe in practice; the box just makes that explicit to the compiler).
            let state = ProbeState()

            connection.stateUpdateHandler = { connState in
                guard !state.resumed else { return }
                switch connState {
                case .ready:
                    state.resumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    state.resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 2) {
                guard !state.resumed else { return }
                state.resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }
}

/// Reference-type holder for the probe's `resumed` flag. Both the state-update closure
/// and the timeout closure run serially on `NetworkMonitor.probeQueue`, so no atomic is
/// needed.
private final class ProbeState: @unchecked Sendable {
    var resumed = false
}
