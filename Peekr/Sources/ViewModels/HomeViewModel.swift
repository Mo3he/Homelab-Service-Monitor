import Foundation
import Combine
import SwiftUI

/// Live display state for a service. Kept separate from the persisted `Service` model so that
/// background refresh can update display without touching `store.services` - which prevents
/// the SwiftUI List from losing its scroll position.
struct ServiceLiveData {
    var status: ServiceStatus = .unknown
    var latencyMs: Double?
    var httpStatusCode: Int?
    var lastChecked: Date?
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var services: [Service] = []
    /// Live display state updated on every check. Does NOT flow through `store.services`.
    @Published var liveData: [UUID: ServiceLiveData] = [:]
    @Published var metrics: [UUID: [ServiceMetric]] = [:]
    @Published var metricsError: [UUID: String] = [:]
    @Published var isRefreshing = false
    @Published var lastRefreshed: Date?
    @Published var searchText = ""
    @Published var statusFilter: ServiceStatus? = nil

    @Published private(set) var checkingIDs: Set<UUID> = []
    @Published private(set) var events: [StatusEvent] = []

    @AppStorage("autoRefreshInterval") private var refreshInterval: Double = 30

    private let store = ServiceStore.shared
    private let network = NetworkMonitor.shared
    private let historyStore = StatusHistoryStore.shared
    private let uptimeStore = UptimeStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var autoRefreshTask: Task<Void, Never>?

    private let maxEvents = 200
    private let eventsKey = "peekr.statusEvents"

    private let metricOrderKey = "peekr.metricOrder"
    private var metricOrder: [String: [String]] {
        get {
            guard let data = UserDefaults.standard.data(forKey: metricOrderKey),
                  let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: metricOrderKey)
        }
    }

    init() {
        store.$services
            .assign(to: \.services, on: self)
            .store(in: &cancellables)
        // Seed live display state from persisted service data so the UI shows last-known values
        // before the first check completes.
        liveData = Dictionary(uniqueKeysWithValues: store.services.map { s in
            (s.id, ServiceLiveData(status: s.status, latencyMs: s.latencyMs,
                                   httpStatusCode: s.httpStatusCode, lastChecked: s.lastChecked))
        })
        loadEvents()
    }

    // MARK: - Filtered list

    var filteredServices: [Service] {
        var list = services
        if let filter = statusFilter {
            let filtered = list.filter { $0.status == filter }
            // Auto-clear stale filter: if it matches nothing and services have loaded, drop it
            if filtered.isEmpty && !services.isEmpty && !isRefreshing {
                Task { @MainActor in statusFilter = nil }
                return list
            }
            list = filtered
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.host.lowercased().contains(q) ||
                ($0.group?.lowercased().contains(q) == true)
            }
        }
        return list
    }

    /// Distinct groups from all services, sorted.
    var groups: [String] {
        Array(Set(services.compactMap(\.group))).sorted()
    }

    // MARK: - Computed counts

    func effectiveStatus(for service: Service) -> ServiceStatus {
        if checkingIDs.contains(service.id) { return .checking }
        let status = liveData[service.id]?.status ?? service.status
        // If off-WiFi and service is local-only, show as unknown rather than stale offline
        if !network.canReachLocal && service.isLocalNetwork && status == .offline {
            return .unknown
        }
        return status
    }

    var onlineCount: Int   { services.filter { (liveData[$0.id]?.status ?? $0.status) == .online   }.count }
    var degradedCount: Int { services.filter { (liveData[$0.id]?.status ?? $0.status) == .degraded }.count }
    var offlineCount: Int  { services.filter { (liveData[$0.id]?.status ?? $0.status) == .offline  }.count }

    var overallHealth: ServiceStatus {
        if services.isEmpty { return .unknown }
        if isRefreshing { return .checking }
        let statuses = services.map { liveData[$0.id]?.status ?? $0.status }
        if statuses.allSatisfy({ $0 == .online }) { return .online }
        if statuses.contains(.offline) { return .offline }
        if statuses.contains(.degraded) { return .degraded }
        return .unknown
    }

    // MARK: - Refresh

    /// Manual refresh (button / pull-to-refresh). Uses the same non-disruptive batch path as
    /// the background refresh, but sets isRefreshing=true for the loading indicator.
    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        #if !targetEnvironment(macCatalyst)
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        #endif
        Task {
            await performBackgroundRefresh(force: true)
            isRefreshing = false
            lastRefreshed = Date()
            #if !targetEnvironment(macCatalyst)
            haptic.notificationOccurred(.success)
            #endif
        }
    }

    /// Interactive single-service refresh (swipe action, service detail pull-to-refresh).
    /// Shows a per-row checking indicator. Writes to liveData AND persists to store.
    func checkAndFetch(_ service: Service) async {
        if !network.canReachLocal && service.isLocalNetwork { return }
        guard store.services.contains(where: { $0.id == service.id }) else { return }

        checkingIDs.insert(service.id)
        defer { checkingIDs.remove(service.id) }

        let previousStatus = liveData[service.id]?.status ?? service.status
        var updated = service

        if !service.serviceType.isCloudService {
            do {
                let result = try await PingService.shared.check(service)
                updated.latencyMs      = result.latencyMs
                updated.httpStatusCode = result.httpStatusCode
                updated.status = result.httpStatusCode.map {
                    (200..<400).contains($0) || $0 == 401 || $0 == 403 ? .online : .degraded
                } ?? .online
            } catch {
                updated.status         = .offline
                updated.latencyMs      = nil
                updated.httpStatusCode = nil
                updated.lastChecked    = Date()
                liveData[service.id]   = ServiceLiveData(status: .offline, lastChecked: updated.lastChecked)
                store.update(updated)
                metrics[service.id] = []
                metricsError.removeValue(forKey: service.id)
                recordTransition(previousStatus: previousStatus, service: updated)
                historyStore.record(serviceID: service.id, status: .offline, latencyMs: nil)
                uptimeStore.record(serviceID: service.id, status: .offline)
                return
            }
        }

        updated.lastChecked = Date()
        liveData[updated.id] = ServiceLiveData(status: updated.status, latencyMs: updated.latencyMs,
                                               httpStatusCode: updated.httpStatusCode,
                                               lastChecked: updated.lastChecked)
        store.update(updated)
        recordTransition(previousStatus: previousStatus, service: updated)
        if !service.serviceType.isCloudService {
            historyStore.record(serviceID: updated.id, status: updated.status, latencyMs: updated.latencyMs)
            uptimeStore.record(serviceID: updated.id, status: updated.status)
        }

        let integration = IntegrationProvider.integration(for: updated)
        do {
            var fetched = try await integration.fetchMetrics(service: updated)
            fetched = applyMetricOrder(fetched, serviceID: updated.id)
            metrics[updated.id] = fetched
            metricsError.removeValue(forKey: updated.id)
            // For cloud services, set status based on whether metrics fetch succeeded
            if service.serviceType.isCloudService && updated.status == .unknown {
                updated.status = fetched.isEmpty ? .degraded : .online
                liveData[updated.id]?.status = updated.status
            }
        } catch let error as IntegrationError where error == .authFailed {
            metrics[updated.id] = []
            metricsError[updated.id] = "Authentication failed. Check your credentials in Edit."
            if service.serviceType.isCloudService {
                liveData[updated.id]?.status = .degraded
            }
        } catch {
            metrics[updated.id] = []
            metricsError[updated.id] = error.localizedDescription
            if service.serviceType.isCloudService {
                liveData[updated.id]?.status = .degraded
            }
        }
    }

    // MARK: - Mutations

    func addService(_ service: Service) {
        liveData[service.id] = ServiceLiveData(status: .unknown)
        store.add(service)
        Task { await checkAndFetch(service) }
    }

    func updateService(_ service: Service) {
        store.update(service)
        Task { await checkAndFetch(service) }
    }

    func duplicateService(_ service: Service) {
        var copy = service
        copy.id = UUID()
        copy.name = "\(service.name) (Copy)"
        copy.status = .unknown
        copy.lastChecked = nil
        copy.latencyMs = nil
        copy.httpStatusCode = nil
        liveData[copy.id] = ServiceLiveData(status: .unknown)
        store.add(copy)
        Task { await checkAndFetch(copy) }
    }

    func removeService(_ service: Service) {
        liveData.removeValue(forKey: service.id)
        metrics.removeValue(forKey: service.id)
        metricsError.removeValue(forKey: service.id)
        removeMetricOrder(for: service.id)
        historyStore.remove(serviceID: service.id)
        uptimeStore.remove(serviceID: service.id)
        store.remove(id: service.id)
    }

    func removeServices(at offsets: IndexSet) {
        for idx in offsets {
            let id = services[idx].id
            liveData.removeValue(forKey: id)
            metrics.removeValue(forKey: id)
            metricsError.removeValue(forKey: id)
            removeMetricOrder(for: id)
            historyStore.remove(serviceID: id)
            uptimeStore.remove(serviceID: id)
        }
        store.remove(at: offsets)
    }

    func moveServices(from source: IndexSet, to destination: Int) {
        store.move(from: source, to: destination)
    }

    /// Used by grouped sections: move a set of service IDs to just before `beforeID` (or end).
    func moveServices(sourceIDs: [UUID], before beforeID: UUID?) {
        var list = services
        let moving = sourceIDs.compactMap { id in list.first { $0.id == id } }
        list.removeAll { sourceIDs.contains($0.id) }
        if let beforeID, let dest = list.firstIndex(where: { $0.id == beforeID }) {
            list.insert(contentsOf: moving, at: dest)
        } else {
            list.append(contentsOf: moving)
        }
        // Map back to store indices
        let oldOrder = services
        var fromOffsets = IndexSet()
        var toOffset = list.count
        for id in sourceIDs {
            if let i = oldOrder.firstIndex(where: { $0.id == id }) { fromOffsets.insert(i) }
        }
        if let beforeID, let j = list.firstIndex(where: { $0.id == beforeID }) {
            toOffset = j
        }
        store.move(from: fromOffsets, to: toOffset)
    }

    // MARK: - Status events

    private func recordTransition(previousStatus old: ServiceStatus, service: Service) {
        let new = liveData[service.id]?.status ?? service.status
        guard old != new, old != .unknown, old != .checking else { return }
        let event = StatusEvent(
            serviceID: service.id,
            serviceName: service.name,
            oldStatus: old,
            newStatus: new
        )
        events.insert(event, at: 0)
        if events.count > maxEvents { events = Array(events.prefix(maxEvents)) }
        saveEvents()

        // Haptic on meaningful transitions
        #if !targetEnvironment(macCatalyst)
        let gen = UINotificationFeedbackGenerator()
        if new == .offline {
            gen.notificationOccurred(.error)
        } else if old == .offline && (new == .online || new == .degraded) {
            gen.notificationOccurred(.success)
        }
        #endif

        // Push notification (if enabled for this service)
        if service.notificationsEnabled {
            if new == .offline && (old == .online || old == .degraded) {
                Task { await NotificationService.postOfflineAlert(for: service) }
            } else if (new == .online || new == .degraded) && old == .offline {
                Task { await NotificationService.postRecoveryAlert(for: service) }
            }
        }
    }

    func clearEvents() {
        events.removeAll()
        saveEvents()
    }

    private func saveEvents() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: eventsKey)
    }

    private func loadEvents() {
        guard let data = UserDefaults.standard.data(forKey: eventsKey),
              let decoded = try? JSONDecoder().decode([StatusEvent].self, from: data)
        else { return }
        events = decoded
    }

    // MARK: - Metric ordering

    func moveMetrics(for serviceID: UUID, from source: IndexSet, to destination: Int) {
        // Operate on visible metrics only; hidden ones are appended after
        var visible = visibleMetrics(for: serviceID)
        visible.move(fromOffsets: source, toOffset: destination)
        let hidden = hiddenMetricItems(for: serviceID)
        let newFull = visible + hidden
        metrics[serviceID] = newFull
        var order = metricOrder
        order[serviceID.uuidString] = newFull.map(\.label)
        metricOrder = order
    }

    private func applyMetricOrder(_ fetched: [ServiceMetric], serviceID: UUID) -> [ServiceMetric] {
        guard let saved = metricOrder[serviceID.uuidString], !saved.isEmpty else { return fetched }
        let indexed = Dictionary(uniqueKeysWithValues: fetched.map { ($0.label, $0) })
        let ordered = saved.compactMap { indexed[$0] }
        let remaining = fetched.filter { !saved.contains($0.label) }
        return ordered + remaining
    }

    private func removeMetricOrder(for id: UUID) {
        var order = metricOrder
        order.removeValue(forKey: id.uuidString)
        metricOrder = order
        var hm = hiddenMetricsStore
        hm.removeValue(forKey: id.uuidString)
        hiddenMetricsStore = hm
    }

    // MARK: - Metric visibility

    private let hiddenMetricsKey = "peekr.hiddenMetrics"
    private var hiddenMetricsStore: [String: [String]] {
        get {
            guard let data = UserDefaults.standard.data(forKey: hiddenMetricsKey),
                  let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: hiddenMetricsKey)
        }
    }

    func visibleMetrics(for serviceID: UUID) -> [ServiceMetric] {
        let all = metrics[serviceID] ?? []
        let hidden = Set(hiddenMetricsStore[serviceID.uuidString] ?? [])
        return all.filter { !hidden.contains($0.label) }
    }

    func hiddenMetricItems(for serviceID: UUID) -> [ServiceMetric] {
        let all = metrics[serviceID] ?? []
        let hidden = Set(hiddenMetricsStore[serviceID.uuidString] ?? [])
        return all.filter { hidden.contains($0.label) }
    }

    func setMetricHidden(_ isHidden: Bool, serviceID: UUID, label: String) {
        var hm = hiddenMetricsStore
        let key = serviceID.uuidString
        var set = Set(hm[key] ?? [])
        if isHidden { set.insert(label) } else { set.remove(label) }
        hm[key] = Array(set)
        hiddenMetricsStore = hm
        objectWillChange.send()
    }

    // MARK: - Export / Import

    func exportJSON() -> Data? {
        try? JSONEncoder().encode(services)
    }

    func importServices(from data: Data) -> Int {
        guard let imported = try? JSONDecoder().decode([Service].self, from: data) else { return 0 }
        var count = 0
        for var svc in imported {
            // Avoid duplicating by ID
            guard !services.contains(where: { $0.id == svc.id }) else { continue }
            svc.status = .unknown
            svc.lastChecked = nil
            store.add(svc)
            count += 1
        }
        return count
    }

    // MARK: - Auto-refresh

    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        guard refreshInterval > 0 else { return }
        autoRefreshTask = Task {
            let pollInterval: Double = 10
            while !Task.isCancelled {
                if !isRefreshing {
                    await performBackgroundRefresh()
                }
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    /// Silent background refresh. Writes ONLY to `liveData` and `metrics` — never to
    /// `store.services`. This means `vm.services` stays completely stable → SwiftUI List
    /// cannot lose its scroll position regardless of how many services are checked.
    ///
    /// `force` = true skips the per-service interval check (used by manual refreshAll).
    private func performBackgroundRefresh(force: Bool = false) async {
        let now = Date()
        let current = store.services
        guard !current.isEmpty else { return }

        // Accumulate all results locally; apply in one batch at the end.
        var newLiveData  = liveData
        var newMetrics   = metrics
        var newErrors    = metricsError

        for service in current {
            guard !Task.isCancelled else { break }

            if !force {
                let interval = service.checkInterval ?? refreshInterval
                let lastCheck = liveData[service.id]?.lastChecked ?? service.lastChecked
                let due = lastCheck.map { now.timeIntervalSince($0) >= interval } ?? true
                guard due else { continue }
            }

            if !network.canReachLocal && service.isLocalNetwork { continue }
            guard store.services.contains(where: { $0.id == service.id }) else { continue }

            let previousStatus = liveData[service.id]?.status ?? service.status
            var live = ServiceLiveData(lastChecked: Date())

            if service.serviceType.isCloudService {
                // Cloud services: skip the ping, go straight to metrics.
                let integration = IntegrationProvider.integration(for: service)
                do {
                    var fetched = try await integration.fetchMetrics(service: service)
                    fetched = applyMetricOrder(fetched, serviceID: service.id)
                    live.status = fetched.isEmpty ? .degraded : .online
                    newLiveData[service.id] = live
                    newMetrics[service.id]  = fetched
                    newErrors.removeValue(forKey: service.id)
                    var tmp = service; tmp.status = live.status
                    recordTransition(previousStatus: previousStatus, service: tmp)
                } catch let e as IntegrationError where e == .authFailed {
                    live.status = .degraded
                    newLiveData[service.id] = live
                    newMetrics[service.id]  = []
                    newErrors[service.id]   = "Authentication failed. Check your credentials in Edit."
                } catch {
                    live.status = .degraded
                    newLiveData[service.id] = live
                    newMetrics[service.id]  = []
                    newErrors[service.id]   = error.localizedDescription
                }
                continue
            }

            do {
                let result  = try await PingService.shared.check(service)
                live.latencyMs      = result.latencyMs
                live.httpStatusCode = result.httpStatusCode
                live.status = result.httpStatusCode.map {
                    (200..<400).contains($0) || $0 == 401 || $0 == 403 ? .online : .degraded
                } ?? .online
            } catch {
                live.status = .offline
                newLiveData[service.id] = live
                newMetrics[service.id]  = []
                newErrors.removeValue(forKey: service.id)
                var tmp = service; tmp.status = .offline
                recordTransition(previousStatus: previousStatus, service: tmp)
                historyStore.record(serviceID: service.id, status: .offline, latencyMs: nil)
                uptimeStore.record(serviceID: service.id, status: .offline)
                continue
            }

            newLiveData[service.id] = live
            var tmp = service; tmp.status = live.status
            recordTransition(previousStatus: previousStatus, service: tmp)
            historyStore.record(serviceID: service.id, status: live.status, latencyMs: live.latencyMs)
            uptimeStore.record(serviceID: service.id, status: live.status)

            let integration = IntegrationProvider.integration(for: service)
            do {
                var fetched = try await integration.fetchMetrics(service: service)
                fetched = applyMetricOrder(fetched, serviceID: service.id)
                newMetrics[service.id] = fetched
                newErrors.removeValue(forKey: service.id)
            } catch let e as IntegrationError where e == .authFailed {
                newMetrics[service.id] = []
                newErrors[service.id]  = "Authentication failed. Check your credentials in Edit."
            } catch {
                newMetrics[service.id] = []
                newErrors[service.id]  = error.localizedDescription
            }
        }

        // Apply all state in one synchronous block. `services` is untouched → the
        // List's ForEach identity is 100% stable → scroll position is preserved.
        liveData     = newLiveData   // 1 publish
        metrics      = newMetrics    // 1 publish
        metricsError = newErrors     // 1 publish
        lastRefreshed = Date()
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}
