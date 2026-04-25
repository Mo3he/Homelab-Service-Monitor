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
    @Published var isRefreshing = false
    @Published var lastRefreshed: Date?
    @Published var searchText = ""
    @Published var statusFilter: ServiceStatus? = nil

    /// Live per-service state lives here - in a SEPARATE ObservableObject so that
    /// HomeView (which only observes HomeViewModel) is never re-rendered by refresh.
    let live = LiveDataStore.shared
    /// Status event log lives in a singleton so background refresh can append to it
    /// even when no HomeViewModel is on-screen.
    let eventStore = StatusEventStore.shared

    @AppStorage("autoRefreshInterval") private var refreshInterval: Double = 30

    private let store = ServiceStore.shared
    private let network = NetworkMonitor.shared
    private let historyStore = StatusHistoryStore.shared
    private let uptimeStore = UptimeStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var autoRefreshTask: Task<Void, Never>?

    private let metricOrderKey = "peekr.metricOrder"
    private var metricOrderCache: [String: [String]] = [:]
    private var metricOrder: [String: [String]] {
        get { metricOrderCache }
        set {
            metricOrderCache = newValue
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: metricOrderKey)
        }
    }

    init() {
        // Load metric ordering / hidden labels into in-memory caches once at init,
        // so the computed-property accessors don't decode JSON on every read.
        if let data = UserDefaults.standard.data(forKey: metricOrderKey),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            metricOrderCache = dict
        }
        if let data = UserDefaults.standard.data(forKey: hiddenMetricsKey),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            hiddenMetricsCache = dict
        }

        store.$services
            .assign(to: \.services, on: self)
            .store(in: &cancellables)
        // Seed live display state from persisted service data so the UI shows last-known values
        // before the first check completes.
        live.seed(from: store.services)
        // Seed hidden metric labels so ServiceRowView filters correctly from launch.
        for (keyStr, labels) in hiddenMetricsCache {
            if let id = UUID(uuidString: keyStr) {
                live.hiddenMetricLabels[id] = Set(labels)
            }
        }
        // Re-publish StatusEventStore changes through HomeViewModel so existing views
        // that bind to `vm.events` keep working without changes.
        eventStore.$events
            .assign(to: \.events, on: self)
            .store(in: &cancellables)
    }

    /// Mirrors `StatusEventStore.events` so existing views (`EventLogView(vm:)`) keep
    /// working without rewrites.
    @Published private(set) var events: [StatusEvent] = []

    // MARK: - Filtered list

    var filteredServices: [Service] {
        var list = services
        if let filter = statusFilter {
            list = list.filter { effectiveStatus(for: $0) == filter }
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

    // MARK: - Computed counts (read from LiveDataStore)

    func effectiveStatus(for service: Service) -> ServiceStatus {
        live.effectiveStatus(for: service)
    }

    var onlineCount: Int   { services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .online   }.count }
    var degradedCount: Int { services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .degraded }.count }
    var offlineCount: Int  { services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .offline  }.count }

    var overallHealth: ServiceStatus {
        if services.isEmpty { return .unknown }
        if isRefreshing { return .checking }
        let statuses = services.map { live.liveData[$0.id]?.status ?? $0.status }
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

        live.setChecking(service.id, true)
        defer { live.setChecking(service.id, false) }

        let previousStatus = live.liveData[service.id]?.status ?? service.status
        var updated = service

        if !service.serviceType.isCloudService {
            do {
                let result = try await PingService.shared.check(service)
                updated.latencyMs      = result.latencyMs
                updated.httpStatusCode = result.httpStatusCode
                let baseStatus: ServiceStatus = result.httpStatusCode.map {
                    (200..<400).contains($0) || $0 == 401 || $0 == 403 ? .online : .degraded
                } ?? .online
                if baseStatus == .online,
                   let threshold = service.latencyDegradedMs, result.latencyMs > threshold {
                    updated.status = .degraded
                } else {
                    updated.status = baseStatus
                }
            } catch {
                updated.status         = .offline
                updated.latencyMs      = nil
                updated.httpStatusCode = nil
                updated.lastChecked    = Date()
                live.setLive(ServiceLiveData(status: .offline, lastChecked: updated.lastChecked), for: service.id)
                store.update(updated)
                live.setMetrics([], for: service.id)
                live.setError(nil, for: service.id)
                recordTransition(previousStatus: previousStatus, service: updated)
                historyStore.record(serviceID: service.id, status: .offline, latencyMs: nil)
                uptimeStore.record(serviceID: service.id, status: .offline)
                return
            }
        }

        updated.lastChecked = Date()
        recordTransition(previousStatus: previousStatus, service: updated)
        if !service.serviceType.isCloudService {
            historyStore.record(serviceID: updated.id, status: updated.status, latencyMs: updated.latencyMs)
            uptimeStore.record(serviceID: updated.id, status: updated.status)
        }
        live.setLive(ServiceLiveData(status: updated.status, latencyMs: updated.latencyMs,
                                     httpStatusCode: updated.httpStatusCode,
                                     lastChecked: updated.lastChecked), for: updated.id)
        store.update(updated)

        let integration = IntegrationProvider.integration(for: updated)
        do {
            var fetched = try await integration.fetchMetrics(service: updated)
            fetched = applyMetricOrder(fetched, serviceID: updated.id)
            live.setMetrics(fetched, for: updated.id)
            live.setError(nil, for: updated.id)
            // For cloud services, set status based on whether metrics fetch succeeded
            if service.serviceType.isCloudService && updated.status == .unknown {
                updated.status = fetched.isEmpty ? .degraded : .online
                live.liveData[updated.id]?.status = updated.status
            }
            // Check per-metric alert rules
            if updated.notificationsEnabled {
                let alertStore = MetricAlertStore.shared
                for metric in fetched where alertStore.shouldFire(metric: metric, serviceID: updated.id) {
                    Task { await NotificationService.postMetricAlert(for: updated, metric: metric) }
                }
            }
        } catch let error as IntegrationError {
            switch error {
            case .authFailed:
                live.setMetrics([], for: updated.id)
                live.setError("Authentication failed. Check your credentials in Edit.", for: updated.id)
                if service.serviceType.isCloudService {
                    live.liveData[updated.id]?.status = .degraded
                }
            case .transient:
                // Preserve last-good metrics; just surface the error message so the user
                // knows the row is being throttled/backed off, not stale.
                live.setError(error.localizedDescription, for: updated.id)
            case .serviceError, .unexpectedFormat, .badURL:
                live.setMetrics([], for: updated.id)
                live.setError(error.localizedDescription, for: updated.id)
                if service.serviceType.isCloudService {
                    live.liveData[updated.id]?.status = .degraded
                }
            }
        } catch {
            live.setMetrics([], for: updated.id)
            live.setError(error.localizedDescription, for: updated.id)
            if service.serviceType.isCloudService {
                live.liveData[updated.id]?.status = .degraded
            }
        }
    }

    // MARK: - Mutations

    func addService(_ service: Service) {
        live.setLive(ServiceLiveData(status: .unknown), for: service.id)
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
        live.setLive(ServiceLiveData(status: .unknown), for: copy.id)
        store.add(copy)
        Task { await checkAndFetch(copy) }
    }

    func removeService(_ service: Service) {
        live.remove(id: service.id)
        removeMetricOrder(for: service.id)
        MetricAlertStore.shared.removeAllRules(for: service.id)
        historyStore.remove(serviceID: service.id)
        uptimeStore.remove(serviceID: service.id)
        KeychainHelper.delete(account: "ugnas-session-\(service.id.uuidString)")
        KeychainHelper.delete(account: "ugnas-trust-\(service.id.uuidString)")
        store.remove(id: service.id)
    }

    func removeServices(at offsets: IndexSet) {
        for idx in offsets {
            let id = services[idx].id
            live.remove(id: id)
            removeMetricOrder(for: id)
            historyStore.remove(serviceID: id)
            uptimeStore.remove(serviceID: id)
        }
        store.remove(at: offsets)
    }

    func moveServices(from source: IndexSet, to destination: Int) {
        store.move(from: source, to: destination)
    }

    func applyReorder(_ ordered: [Service]) {
        store.reorder(to: ordered)
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
        let new = live.liveData[service.id]?.status ?? service.status
        guard old != new, old != .unknown, old != .checking else { return }

        // Persist to the shared event store (also keeps `vm.events` in sync via the
        // assign in init).
        eventStore.recordTransition(previousStatus: old, newStatus: new, service: service)

        // Haptic on meaningful transitions (foreground only; BG path doesn't get here)
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
        eventStore.clear()
    }

    // MARK: - Metric ordering

    func moveMetrics(for serviceID: UUID, from source: IndexSet, to destination: Int) {
        // Operate on visible metrics only; hidden ones are appended after
        var visible = visibleMetrics(for: serviceID)
        visible.move(fromOffsets: source, toOffset: destination)
        let hidden = hiddenMetricItems(for: serviceID)
        let newFull = visible + hidden
        live.setMetrics(newFull, for: serviceID)
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
    private var hiddenMetricsCache: [String: [String]] = [:]
    private var hiddenMetricsStore: [String: [String]] {
        get { hiddenMetricsCache }
        set {
            hiddenMetricsCache = newValue
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: hiddenMetricsKey)
        }
    }

    func visibleMetrics(for serviceID: UUID) -> [ServiceMetric] {
        let all = live.metrics[serviceID] ?? []
        let hidden = Set(hiddenMetricsStore[serviceID.uuidString] ?? [])
        return all.filter { !hidden.contains($0.label) }
    }

    func hiddenMetricItems(for serviceID: UUID) -> [ServiceMetric] {
        let all = live.metrics[serviceID] ?? []
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
        // Sync to LiveDataStore so ServiceRowView picks it up immediately
        live.hiddenMetricLabels[serviceID] = set
    }

    // MARK: - Metric alert rules

    func hasMetricAlert(serviceID: UUID, label: String) -> Bool {
        MetricAlertStore.shared.hasRule(serviceID: serviceID, label: label)
    }

    func metricAlertRule(serviceID: UUID, label: String) -> MetricAlertStore.Rule? {
        MetricAlertStore.shared.rule(serviceID: serviceID, label: label)
    }

    func setMetricAlertRule(_ rule: MetricAlertStore.Rule, serviceID: UUID, label: String) {
        MetricAlertStore.shared.setRule(rule, serviceID: serviceID, label: label)
        objectWillChange.send()
    }

    func removeMetricAlert(serviceID: UUID, label: String) {
        MetricAlertStore.shared.removeRule(serviceID: serviceID, label: label)
        objectWillChange.send()
    }

    func toggleMetricAlert(serviceID: UUID, metric: ServiceMetric) {
        let store = MetricAlertStore.shared
        if store.hasRule(serviceID: serviceID, label: metric.label) {
            store.removeRule(serviceID: serviceID, label: metric.label)
        } else {
            let rule: MetricAlertStore.Rule = metric.isAlert ? .whenAlert : .whenValueChanges
            store.setRule(rule, serviceID: serviceID, label: metric.label)
        }
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
            while !Task.isCancelled {
                if !isRefreshing {
                    await performBackgroundRefresh()
                }
                // Sleep exactly until the next service is due, rather than polling every 10s.
                // This prevents unnecessary CPU wakeups between refresh cycles.
                let sleepDuration = nextCheckDue()
                try? await Task.sleep(for: .seconds(sleepDuration))
            }
        }
    }

    /// Returns the number of seconds until the earliest next-due service check.
    /// Minimum 1 second, maximum refreshInterval.
    private func nextCheckDue() -> Double {
        let now = Date()
        let durations = store.services.map { service -> Double in
            let interval = service.checkInterval ?? refreshInterval
            guard let last = live.liveData[service.id]?.lastChecked ?? service.lastChecked else { return 1 }
            return max(interval - now.timeIntervalSince(last), 1)
        }
        return durations.min() ?? refreshInterval
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
        // These never touch vm.services or any @Published on HomeViewModel.
        var newLiveData  = live.liveData
        var newMetrics   = live.metrics
        var newErrors    = live.metricsError

        for service in current {
            guard !Task.isCancelled else { break }

            if !force {
                let interval = service.checkInterval ?? refreshInterval
                let lastCheck = live.liveData[service.id]?.lastChecked ?? service.lastChecked
                let due = lastCheck.map { now.timeIntervalSince($0) >= interval } ?? true
                guard due else { continue }
            }

            if !network.canReachLocal && service.isLocalNetwork { continue }
            guard store.services.contains(where: { $0.id == service.id }) else { continue }

            let previousStatus = live.liveData[service.id]?.status ?? service.status
            var liveEntry = ServiceLiveData(lastChecked: Date())

            if service.serviceType.isCloudService {
                let integration = IntegrationProvider.integration(for: service)
                do {
                    var fetched = try await integration.fetchMetrics(service: service)
                    fetched = applyMetricOrder(fetched, serviceID: service.id)
                    liveEntry.status = fetched.isEmpty ? .degraded : .online
                    newLiveData[service.id] = liveEntry
                    newMetrics[service.id]  = fetched
                    newErrors.removeValue(forKey: service.id)
                    var tmp = service; tmp.status = liveEntry.status
                    recordTransition(previousStatus: previousStatus, service: tmp)
                } catch let e as IntegrationError {
                    switch e {
                    case .authFailed:
                        liveEntry.status = .degraded
                        newLiveData[service.id] = liveEntry
                        newMetrics[service.id]  = []
                        newErrors[service.id]   = "Authentication failed. Check your credentials in Edit."
                    case .transient:
                        // Keep the previous status + metrics; just surface a backoff note.
                        newErrors[service.id] = e.localizedDescription
                    case .serviceError, .unexpectedFormat, .badURL:
                        liveEntry.status = .degraded
                        newLiveData[service.id] = liveEntry
                        newMetrics[service.id]  = []
                        newErrors[service.id]   = e.localizedDescription
                    }
                } catch {
                    liveEntry.status = .degraded
                    newLiveData[service.id] = liveEntry
                    newMetrics[service.id]  = []
                    newErrors[service.id]   = error.localizedDescription
                }
                continue
            }

            do {
                let result  = try await PingService.shared.check(service)
                liveEntry.latencyMs      = result.latencyMs
                liveEntry.httpStatusCode = result.httpStatusCode
                let baseStatus: ServiceStatus = result.httpStatusCode.map {
                    (200..<400).contains($0) || $0 == 401 || $0 == 403 ? .online : .degraded
                } ?? .online
                if baseStatus == .online,
                   let threshold = service.latencyDegradedMs, result.latencyMs > threshold {
                    liveEntry.status = .degraded
                } else {
                    liveEntry.status = baseStatus
                }
            } catch {
                liveEntry.status = .offline
                newLiveData[service.id] = liveEntry
                newMetrics[service.id]  = []
                newErrors.removeValue(forKey: service.id)
                var tmp = service; tmp.status = .offline
                recordTransition(previousStatus: previousStatus, service: tmp)
                historyStore.record(serviceID: service.id, status: .offline, latencyMs: nil)
                uptimeStore.record(serviceID: service.id, status: .offline)
                continue
            }

            newLiveData[service.id] = liveEntry
            var tmp = service; tmp.status = liveEntry.status
            recordTransition(previousStatus: previousStatus, service: tmp)
            historyStore.record(serviceID: service.id, status: liveEntry.status, latencyMs: liveEntry.latencyMs)
            uptimeStore.record(serviceID: service.id, status: liveEntry.status)

            let integration = IntegrationProvider.integration(for: service)
            do {
                var fetched = try await integration.fetchMetrics(service: service)
                fetched = applyMetricOrder(fetched, serviceID: service.id)
                newMetrics[service.id] = fetched
                newErrors.removeValue(forKey: service.id)
            } catch let e as IntegrationError {
                switch e {
                case .authFailed:
                    newMetrics[service.id] = []
                    newErrors[service.id]  = "Authentication failed. Check your credentials in Edit."
                case .transient:
                    // Preserve last-good metrics on transient failures.
                    newErrors[service.id] = e.localizedDescription
                case .serviceError, .unexpectedFormat, .badURL:
                    newMetrics[service.id] = []
                    newErrors[service.id]  = e.localizedDescription
                }
            } catch {
                newMetrics[service.id] = []
                newErrors[service.id]  = error.localizedDescription
            }
        }

        // Apply to LiveDataStore - completely separate from HomeViewModel's @Published properties.
        // HomeView never observes LiveDataStore, so the List is never re-rendered by this.
        live.applyBatch(liveData: newLiveData, metrics: newMetrics, errors: newErrors)
        lastRefreshed = Date()
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}
