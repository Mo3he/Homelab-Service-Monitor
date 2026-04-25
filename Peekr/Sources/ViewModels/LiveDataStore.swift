import SwiftUI

/// Holds all per-service live display state: ping results, metrics, errors, and checking indicators.
///
/// This is a **separate** ObservableObject from HomeViewModel deliberately.
/// HomeView observes HomeViewModel (for the service list, search, filter).
/// ServiceRowView and ServiceDetailView observe LiveDataStore (for per-row status/metrics).
/// Because HomeView never imports LiveDataStore, changes here do NOT cause the List to re-render,
/// which is what preserves scroll position during background refresh.
@MainActor
final class LiveDataStore: ObservableObject {
    static let shared = LiveDataStore()

    @Published var liveData: [UUID: ServiceLiveData] = [:]
    @Published var metrics: [UUID: [ServiceMetric]] = [:]
    @Published var metricsError: [UUID: String] = [:]
    @Published private(set) var checkingIDs: Set<UUID> = []
    /// Hidden metric labels per service - kept here so ServiceRowView can filter without vm.
    @Published var hiddenMetricLabels: [UUID: Set<String>] = [:]

    private init() {}

    // MARK: - Accessors

    func effectiveStatus(for service: Service) -> ServiceStatus {
        if checkingIDs.contains(service.id) { return .checking }
        let networkOK = NetworkMonitor.shared.canReachLocal
        let status = liveData[service.id]?.status ?? service.status
        if !networkOK && service.isLocalNetwork && status == .offline {
            return .unknown
        }
        return status
    }

    // MARK: - Live data mutators (called by HomeViewModel refresh paths)

    func setChecking(_ id: UUID, _ checking: Bool) {
        if checking { checkingIDs.insert(id) } else { checkingIDs.remove(id) }
    }

    func setLive(_ live: ServiceLiveData, for id: UUID) {
        liveData[id] = live
    }

    func setMetrics(_ m: [ServiceMetric], for id: UUID) {
        metrics[id] = m
    }

    func setError(_ error: String?, for id: UUID) {
        if let error { metricsError[id] = error } else { metricsError.removeValue(forKey: id) }
    }

    /// Batch-apply a full refresh result in one publish cycle each.
    func applyBatch(liveData newLD: [UUID: ServiceLiveData],
                    metrics newM: [UUID: [ServiceMetric]],
                    errors newE: [UUID: String]) {
        liveData     = newLD
        metrics      = newM
        metricsError = newE
    }

    func remove(id: UUID) {
        liveData.removeValue(forKey: id)
        metrics.removeValue(forKey: id)
        metricsError.removeValue(forKey: id)
        hiddenMetricLabels.removeValue(forKey: id)
        checkingIDs.remove(id)
    }

    func visibleMetrics(for id: UUID) -> [ServiceMetric] {
        let all = metrics[id] ?? []
        let hidden = hiddenMetricLabels[id] ?? []
        return hidden.isEmpty ? all : all.filter { !hidden.contains($0.label) }
    }

    func seed(from services: [Service]) {
        for s in services where liveData[s.id] == nil {
            liveData[s.id] = ServiceLiveData(status: s.status, latencyMs: s.latencyMs,
                                             httpStatusCode: s.httpStatusCode, lastChecked: s.lastChecked)
        }
    }
}
