import Foundation
import Combine
import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var services: [Service] = []
    @Published var metrics: [UUID: [ServiceMetric]] = [:]
    @Published var metricsError: [UUID: String] = [:]
    @Published var isRefreshing = false
    @Published var lastRefreshed: Date?
    @Published var searchText = ""
    @Published var statusFilter: ServiceStatus? = nil

    /// IDs currently being checked. Used to show the checking indicator without
    /// writing .checking to the store (which causes a double-render flash).
    @Published private(set) var checkingIDs: Set<UUID> = []

    /// Status events for the event log (Alerts tab).
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

    // Persisted metric display order: service UUID string -> ordered array of metric labels
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
        // If off-WiFi and service is local-only, show as unknown rather than stale offline
        if !network.canReachLocal && service.isLocalNetwork && service.status == .offline {
            return .unknown
        }
        return service.status
    }

    var onlineCount: Int   { services.filter { $0.status == .online }.count }
    var degradedCount: Int { services.filter { $0.status == .degraded }.count }
    var offlineCount: Int  { services.filter { $0.status == .offline }.count }

    var overallHealth: ServiceStatus {
        if services.isEmpty { return .unknown }
        // Only show .checking during a full manual refresh, not individual auto-refresh
        if isRefreshing { return .checking }
        if services.allSatisfy({ $0.status == .online }) { return .online }
        if services.contains(where: { $0.status == .offline }) { return .offline }
        if services.contains(where: { $0.status == .degraded }) { return .degraded }
        return .unknown
    }

    // MARK: - Refresh

    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        #if !targetEnvironment(macCatalyst)
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        #endif
        Task {
            await withTaskGroup(of: Void.self) { group in
                for service in services {
                    group.addTask { [weak self] in await self?.checkAndFetch(service) }
                }
            }
            isRefreshing = false
            lastRefreshed = Date()
            #if !targetEnvironment(macCatalyst)
            haptic.notificationOccurred(.success)
            #endif
        }
    }

    func checkAndFetch(_ service: Service) async {
        // Skip local-only services when not on WiFi to avoid pointless timeouts
        if !network.canReachLocal && service.isLocalNetwork { return }

        // Verify the service still exists (stale snapshot guard)
        guard store.services.contains(where: { $0.id == service.id }) else { return }

        checkingIDs.insert(service.id)
        defer { checkingIDs.remove(service.id) }

        let previousStatus = service.status
        var updated = service

        do {
            let result = try await PingService.shared.check(service)
            updated.latencyMs = result.latencyMs
            updated.httpStatusCode = result.httpStatusCode
            if let code = result.httpStatusCode {
                updated.status = (200..<400).contains(code) || code == 401 || code == 403 ? .online : .degraded
            } else {
                updated.status = .online
            }
        } catch {
            updated.status = .offline
            updated.latencyMs = nil
            updated.httpStatusCode = nil
            updated.lastChecked = Date()
            store.update(updated)
            metrics[service.id] = []
            metricsError.removeValue(forKey: service.id)
            recordTransition(service: updated, from: previousStatus)
            historyStore.record(serviceID: service.id, status: .offline, latencyMs: nil)
            uptimeStore.record(serviceID: service.id, status: .offline)
            return
        }

        updated.lastChecked = Date()
        store.update(updated)
        recordTransition(service: updated, from: previousStatus)
        historyStore.record(serviceID: updated.id, status: updated.status, latencyMs: updated.latencyMs)
        uptimeStore.record(serviceID: updated.id, status: updated.status)

        let integration = IntegrationProvider.integration(for: updated)
        do {
            var fetched = try await integration.fetchMetrics(service: updated)
            fetched = applyMetricOrder(fetched, serviceID: updated.id)
            metrics[updated.id] = fetched
            metricsError.removeValue(forKey: updated.id)
        } catch let error as IntegrationError where error == .authFailed {
            metrics[updated.id] = []
            metricsError[updated.id] = "Authentication failed. Check your credentials in Edit."
        } catch {
            metrics[updated.id] = []
            metricsError[updated.id] = error.localizedDescription
        }
    }

    // MARK: - Mutations

    func addService(_ service: Service) {
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
        store.add(copy)
        Task { await checkAndFetch(copy) }
    }

    func removeService(_ service: Service) {
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

    private func recordTransition(service: Service, from old: ServiceStatus) {
        let new = service.status
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
            // Poll every 10 s; each service is only checked when its own interval has elapsed.
            let pollInterval: Double = 10
            while !Task.isCancelled {
                if !isRefreshing {
                    let now = Date()
                    let current = store.services
                    for service in current {
                        guard !Task.isCancelled else { break }
                        let interval = service.checkInterval ?? refreshInterval
                        let due = service.lastChecked.map { now.timeIntervalSince($0) >= interval } ?? true
                        if due { await checkAndFetch(service) }
                    }
                    if !current.isEmpty { lastRefreshed = Date() }
                }
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}
