import Foundation
import Combine
import SwiftUI
import os

/// Live display state for a service. Kept separate from the persisted `Service` model so that
/// background refresh can update display without touching `store.services` - which prevents
/// the SwiftUI List from losing its scroll position.
struct ServiceLiveData {
    var status: ServiceStatus = .unknown
    var latencyMs: Double?
    var httpStatusCode: Int?
    var lastChecked: Date?
    var usingFailover: Bool = false
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var services: [Service] = []
    @Published var isRefreshing = false
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
    /// Service IDs whose check is currently in-flight. Used by nextCheckDue() to avoid
    /// re-scheduling a service that is already timing out (e.g. a slow TCP failover).
    private var inFlightServiceIDs: Set<UUID> = []

    private let groupOrderKey = "peekr.groupOrder"
    private var groupOrderCache: [String] = []
    private var groupOrder: [String] {
        get { groupOrderCache }
        set {
            groupOrderCache = newValue
            UserDefaults.standard.set(newValue, forKey: groupOrderKey)
        }
    }

    static let otherSentinel = "__other__"

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
        if let saved = UserDefaults.standard.stringArray(forKey: groupOrderKey) {
            groupOrderCache = saved
        }

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

    /// Distinct named groups in user-defined order (never includes the otherSentinel).
    var groups: [String] {
        let existing = Set(services.compactMap(\.group).filter { !$0.isEmpty })
        let ordered = groupOrderCache.filter { $0 != Self.otherSentinel && existing.contains($0) }
        let new = existing.subtracting(Set(ordered)).sorted()
        return ordered + new
    }

    /// Full display order for group sections, including the "Other" (ungrouped) sentinel.
    func displayGroupOrder(hasOther: Bool) -> [String] {
        let named = groups
        guard hasOther else { return named }
        if groupOrderCache.contains(Self.otherSentinel) {
            let namedSet = Set(named)
            var result: [String] = []
            for entry in groupOrderCache {
                if entry == Self.otherSentinel { result.append(entry) }
                else if namedSet.contains(entry) { result.append(entry) }
            }
            let included = Set(result.filter { $0 != Self.otherSentinel })
            for g in named where !included.contains(g) { result.append(g) }
            return result
        }
        return named + [Self.otherSentinel]
    }

    func setGroupOrder(_ order: [String]) {
        groupOrder = order
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
        let statuses = services.map { live.effectiveStatus(for: $0) }
        let known = statuses.filter { $0 != .unknown && $0 != .checking }
        guard !known.isEmpty else { return .unknown }
        if known.allSatisfy({ $0 == .online }) { return .online }
        if known.contains(.offline) { return .offline }
        if known.contains(.degraded) { return .degraded }
        return .unknown
    }

    // MARK: - Refresh

    /// Manual refresh (button / pull-to-refresh). Uses the same non-disruptive batch path as
    /// the background refresh, but sets isRefreshing=true for the loading indicator.
    func refreshAll() {
        if DemoMode.isEnabled { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        AppLogger.refresh.debug("Manual refresh triggered for \(self.services.count) service(s)")
        #if !targetEnvironment(macCatalyst)
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        #endif
        Task {
            await performBackgroundRefresh(force: true)
            isRefreshing = false
            #if !targetEnvironment(macCatalyst)
            haptic.notificationOccurred(.success)
            #endif
        }
    }

    /// Interactive single-service refresh (swipe action, service detail pull-to-refresh).
    /// Shows a per-row checking indicator. Writes to liveData AND persists to store.
    func checkAndFetch(_ service: Service) async {
        if DemoMode.isEnabled { return }
        if !network.canReachService(service) { return }
        guard store.services.contains(where: { $0.id == service.id }) else { return }

        AppLogger.refresh.debug("checkAndFetch: \(service.name, privacy: .public)")

        live.setChecking(service.id, true)
        defer { live.setChecking(service.id, false) }

        let previousStatus = live.liveData[service.id]?.status ?? service.status
        var updated = service

        var usingFailover = false
        if !service.serviceType.isCloudService {
            let rawTimeout = UserDefaults.standard.double(forKey: "requestTimeoutSeconds")
            let timeout = max(1, min(rawTimeout > 0 ? rawTimeout : 5, 60))
            do {
                let result = try await PingService.shared.check(service, timeout: timeout)
                updated.latencyMs      = result.latencyMs
                updated.httpStatusCode = result.httpStatusCode
                usingFailover          = result.usedFailover
                let baseStatus: ServiceStatus = result.httpStatusCode.map {
                    (200..<400).contains($0) || $0 == 401 || $0 == 403 ? .online : .degraded
                } ?? .online
                if baseStatus == .online,
                   let threshold = service.latencyDegradedMs, result.latencyMs > threshold {
                    updated.status = .degraded
                } else {
                    updated.status = baseStatus
                }
                live.consecutiveFailures[service.id] = 0
            } catch {
                // A cancelled error means the request was interrupted (TCP reset, iOS
                // killed the task, etc.) — not a genuine service outage. Preserve the
                // previous status so a single hiccup doesn't flip the row to offline.
                if (error as? URLError)?.code == .cancelled {
                    AppLogger.refresh.info("checkAndFetch: \(service.name, privacy: .public) ping cancelled (transient), preserving previous status")
                    return
                }
                let failures = (live.consecutiveFailures[service.id] ?? 0) + 1
                live.consecutiveFailures[service.id] = failures
                let retryThreshold = UserDefaults.standard.integer(forKey: "retryCountBeforeOffline")
                let threshold = retryThreshold > 0 ? retryThreshold : 1
                if failures < threshold {
                    AppLogger.refresh.info("checkAndFetch: \(service.name, privacy: .public) failure \(failures)/\(threshold), not yet offline")
                    return
                }
                updated.status         = .offline
                updated.latencyMs      = nil
                updated.httpStatusCode = nil
                updated.lastChecked    = Date()
                AppLogger.refresh.error("checkAndFetch: \(service.name, privacy: .public) ping failed: \(error.localizedDescription, privacy: .public)")
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
        AppLogger.refresh.info("checkAndFetch: \(service.name, privacy: .public) -> \(updated.status.rawValue, privacy: .public) (\(Int(updated.latencyMs ?? 0))ms HTTP \(updated.httpStatusCode.map(String.init) ?? "n/a", privacy: .public))")
        if !service.serviceType.isCloudService {
            historyStore.record(serviceID: updated.id, status: updated.status, latencyMs: updated.latencyMs)
            uptimeStore.record(serviceID: updated.id, status: updated.status)
        }
        live.setLive(ServiceLiveData(status: updated.status, latencyMs: updated.latencyMs,
                                     httpStatusCode: updated.httpStatusCode,
                                     lastChecked: updated.lastChecked,
                                     usingFailover: usingFailover), for: updated.id)
        store.update(updated)

        if usingFailover, let fh = service.failoverHost {
            updated.host = fh.trimmingCharacters(in: .whitespaces)
        }
        let integration = IntegrationProvider.integration(for: updated)
        do {
            var fetched = try await integration.fetchMetrics(service: updated)
            if let latency = updated.latencyMs {
                fetched.insert(ServiceMetric(label: "Response Time", value: "\(Int(latency)) ms", icon: "clock", color: .secondary), at: 0)
            }
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
                AppLogger.refresh.error("checkAndFetch: \(service.name, privacy: .public) metrics auth failed")
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
            AppLogger.refresh.error("checkAndFetch: \(service.name, privacy: .public) metrics error: \(error.localizedDescription, privacy: .public)")
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
            MetricAlertStore.shared.removeAllRules(for: id)
            historyStore.remove(serviceID: id)
            uptimeStore.remove(serviceID: id)
            KeychainHelper.delete(account: "ugnas-session-\(id.uuidString)")
            KeychainHelper.delete(account: "ugnas-trust-\(id.uuidString)")
        }
        store.remove(at: offsets)
    }

    func moveServices(from source: IndexSet, to destination: Int) {
        store.move(from: source, to: destination)
    }

    func applyReorder(_ ordered: [Service]) {
        store.reorder(to: ordered)
    }

    func applyReorder(_ orderedServices: [Service], groupOrder orderedGroups: [String]) {
        store.reorder(to: orderedServices)
        setGroupOrder(orderedGroups)
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
            let globalOffline  = UserDefaults.standard.object(forKey: "globalOfflineNotificationsEnabled")  as? Bool ?? true
            let globalRecovery = UserDefaults.standard.object(forKey: "globalRecoveryNotificationsEnabled") as? Bool ?? true
            if new == .offline && (old == .online || old == .degraded) && globalOffline {
                Task { await NotificationService.postOfflineAlert(for: service) }
            } else if (new == .online || new == .degraded) && old == .offline && globalRecovery {
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
        if DemoMode.isEnabled { return }
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
        // Only consider services that are currently reachable. Unreachable services
        // (e.g. local-network services when off Wi-Fi) are skipped by performBackgroundRefresh
        // and never get their lastChecked updated, so including them would make nextCheckDue()
        // always return 1 and cause the loop to spin and repeatedly check whatever IS reachable.
        let durations: [Double] = store.services.compactMap { service in
            guard network.canReachService(service) else { return nil }
            let interval = service.checkInterval ?? refreshInterval
            // Services whose check is in-flight are treated as not-yet-due so the loop
            // doesn't pile up checks during a slow TCP timeout or failover attempt.
            if inFlightServiceIDs.contains(service.id) { return interval }
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
        if DemoMode.isEnabled { return }
        let now = Date()
        let current = store.services
        guard !current.isEmpty else { return }

        // Accumulate all results locally; apply in one batch at the end.
        // These never touch vm.services or any @Published on HomeViewModel.
        var newLiveData  = live.liveData
        var newMetrics   = live.metrics
        var newErrors    = live.metricsError

        // Determine which services are due this cycle before launching any I/O.
        var toCheck: [(Service, ServiceStatus)] = []
        for service in current {
            guard !Task.isCancelled else { break }
            if !force {
                let interval = service.checkInterval ?? refreshInterval
                let lastCheck = live.liveData[service.id]?.lastChecked ?? service.lastChecked
                let due = lastCheck.map { now.timeIntervalSince($0) >= interval } ?? true
                guard due else { continue }
            }
            if !network.canReachService(service) { continue }
            guard store.services.contains(where: { $0.id == service.id }) else { continue }
            let previousStatus = live.liveData[service.id]?.status ?? service.status
            toCheck.append((service, previousStatus))
        }

        guard !toCheck.isEmpty else { return }

        // Mark services as in-flight so nextCheckDue() treats them as not-yet-due while
        // their checks are running (prevents re-scheduling during slow TCP timeouts).
        let inFlightIDs = Set(toCheck.map { $0.0.id })
        inFlightServiceIDs.formUnion(inFlightIDs)
        defer { inFlightServiceIDs.subtract(inFlightIDs) }

        // Run all due checks concurrently so a slow/timing-out service doesn't block others.
        // @MainActor is explicit: child tasks don't inherit isolation automatically in Swift 5.9+.
        await withTaskGroup(of: Void.self) { group in
            for (service, previousStatus) in toCheck {
                group.addTask { @MainActor in
                    var liveEntry = ServiceLiveData(lastChecked: Date())

                    if service.serviceType.isCloudService {
                        let integration = IntegrationProvider.integration(for: service)
                        do {
                            var fetched = try await integration.fetchMetrics(service: service)
                            fetched = self.applyMetricOrder(fetched, serviceID: service.id)
                            liveEntry.status = fetched.isEmpty ? .degraded : .online
                            newLiveData[service.id] = liveEntry
                            newMetrics[service.id]  = fetched
                            newErrors.removeValue(forKey: service.id)
                            self.uptimeStore.record(serviceID: service.id, status: liveEntry.status)
                            var tmp = service; tmp.status = liveEntry.status
                            self.recordTransition(previousStatus: previousStatus, service: tmp)
                        } catch let e as IntegrationError {
                            switch e {
                            case .authFailed:
                                liveEntry.status = .degraded
                                newLiveData[service.id] = liveEntry
                                newMetrics[service.id]  = []
                                newErrors[service.id]   = "Authentication failed. Check your credentials in Edit."
                                self.uptimeStore.record(serviceID: service.id, status: liveEntry.status)
                            case .transient:
                                newErrors[service.id] = e.localizedDescription
                            case .serviceError, .unexpectedFormat, .badURL:
                                liveEntry.status = .degraded
                                newLiveData[service.id] = liveEntry
                                newMetrics[service.id]  = []
                                newErrors[service.id]   = e.localizedDescription
                                self.uptimeStore.record(serviceID: service.id, status: liveEntry.status)
                            }
                        } catch {
                            liveEntry.status = .degraded
                            newLiveData[service.id] = liveEntry
                            newMetrics[service.id]  = []
                            newErrors[service.id]   = error.localizedDescription
                            self.uptimeStore.record(serviceID: service.id, status: liveEntry.status)
                        }
                        return
                    }

                    do {
                        let rawTimeout = UserDefaults.standard.double(forKey: "requestTimeoutSeconds")
                        let timeout = max(1, min(rawTimeout > 0 ? rawTimeout : 5, 60))
                        let result = try await PingService.shared.check(service, timeout: timeout)
                        liveEntry.latencyMs      = result.latencyMs
                        liveEntry.httpStatusCode = result.httpStatusCode
                        liveEntry.usingFailover  = result.usedFailover
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
                        // If the network probe says we're not on the local network, preserve
                        // last-known status instead of marking offline — mirrors the behaviour
                        // of non-failover local services that are skipped entirely when off-network.
                        if service.isLocalNetwork && !self.network.canReachLocal { return }
                        // A cancelled error is transient (TCP reset, iOS killed the task) —
                        // not a genuine outage. Skip the update entirely.
                        if (error as? URLError)?.code == .cancelled {
                            AppLogger.refresh.info("[BG] \(service.name, privacy: .public) ping cancelled (transient), preserving previous status")
                            return
                        }
                        liveEntry.status = .offline
                        newLiveData[service.id] = liveEntry
                        newMetrics[service.id]  = []
                        newErrors.removeValue(forKey: service.id)
                        var tmp = service; tmp.status = .offline
                        self.recordTransition(previousStatus: previousStatus, service: tmp)
                        self.historyStore.record(serviceID: service.id, status: .offline, latencyMs: nil)
                        self.uptimeStore.record(serviceID: service.id, status: .offline)
                        return
                    }

                    newLiveData[service.id] = liveEntry
                    var tmp = service; tmp.status = liveEntry.status
                    self.recordTransition(previousStatus: previousStatus, service: tmp)
                    self.historyStore.record(serviceID: service.id, status: liveEntry.status, latencyMs: liveEntry.latencyMs)
                    self.uptimeStore.record(serviceID: service.id, status: liveEntry.status)

                    var serviceForMetrics = service
                    if liveEntry.usingFailover, let fh = service.failoverHost {
                        serviceForMetrics.host = fh.trimmingCharacters(in: .whitespaces)
                    }
                    let integration = IntegrationProvider.integration(for: serviceForMetrics)
                    do {
                        var fetched = try await integration.fetchMetrics(service: serviceForMetrics)
                        fetched = self.applyMetricOrder(fetched, serviceID: service.id)
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
            }
        }

        // Apply to LiveDataStore - completely separate from HomeViewModel's @Published properties.
        // HomeView never observes LiveDataStore, so the List is never re-rendered by this.
        live.applyBatch(liveData: newLiveData, metrics: newMetrics, errors: newErrors)
        live.lastRefreshed = Date()
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}
