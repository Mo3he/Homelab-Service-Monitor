import Foundation
import Network
import Combine

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

    /// Whether we expect local-network services to be reachable right now.
    var canReachLocal: Bool {
        if userOverride { return true }
        if likelyVPN { return true }
        if !isOnWiFi { return false }
        // If we haven't probed yet, assume reachable (first launch / probe in progress)
        guard let home = isHomeNetwork else { return true }
        return home
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "peekr.networkMonitor")
    private let probeQueue = DispatchQueue(label: "peekr.probe")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOnWiFi = self.isOnWiFi
                self.isConnected = path.status == .satisfied
                self.isOnWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                self.likelyVPN = path.usesInterfaceType(.other)

                // Network changed - reset probe result and user override
                if self.isOnWiFi != wasOnWiFi {
                    self.isHomeNetwork = nil
                    self.userOverride = false
                }

                if self.isOnWiFi {
                    await self.probeLocalReachability()
                } else {
                    self.isHomeNetwork = nil
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
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
            var resumed = false

            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 2) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }
}
