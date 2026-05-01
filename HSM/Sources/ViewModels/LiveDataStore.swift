import SwiftUI
import WidgetKit

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
    @Published var lastRefreshed: Date?
    /// Consecutive ping failures per service before marking offline.
    var consecutiveFailures: [UUID: Int] = [:]
    /// Hidden metric labels per service - kept here so ServiceRowView can filter without vm.
    @Published var hiddenMetricLabels: [UUID: Set<String>] = [:]

    private let metricsStorageKey = "hsm.lastKnownMetrics"
    private var saveTask: Task<Void, Never>?

    private init() {}

    // MARK: - Accessors

    func effectiveStatus(for service: Service) -> ServiceStatus {
        if checkingIDs.contains(service.id) { return .checking }
        let status = liveData[service.id]?.status ?? service.status
        if service.isLocalNetwork && !NetworkMonitor.shared.canReachService(service) && status == .offline {
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
        MetricHistoryStore.shared.record(serviceID: id, metrics: m)
        saveMetrics()
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
        for (id, m) in newM {
            MetricHistoryStore.shared.record(serviceID: id, metrics: m)
        }
        saveMetrics()
    }

    func remove(id: UUID) {
        liveData.removeValue(forKey: id)
        metrics.removeValue(forKey: id)
        metricsError.removeValue(forKey: id)
        hiddenMetricLabels.removeValue(forKey: id)
        consecutiveFailures.removeValue(forKey: id)
        checkingIDs.remove(id)
        MetricHistoryStore.shared.remove(serviceID: id)
        saveMetrics()
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
        loadMetrics()
    }

    // MARK: - Metrics persistence

    /// Lightweight Codable mirror of ServiceMetric for disk storage.
    private struct PersistedMetric: Codable {
        var label: String
        var value: String
        var icon: String
        var colorName: String
        var isAlert: Bool

        init(from metric: ServiceMetric) {
            self.label = metric.label
            self.value = metric.value
            self.icon = metric.icon
            self.colorName = PersistedMetric.colorToName(metric.color)
            self.isAlert = metric.isAlert
        }

        func toServiceMetric() -> ServiceMetric {
            ServiceMetric(label: label, value: value, icon: icon,
                          color: PersistedMetric.nameToColor(colorName), isAlert: isAlert)
        }

        private static func colorToName(_ color: Color) -> String {
            if color == .red { return "red" }
            if color == .orange { return "orange" }
            if color == .yellow { return "yellow" }
            if color == .green { return "green" }
            if color == .blue { return "blue" }
            if color == .purple { return "purple" }
            if color == .pink { return "pink" }
            if color == .gray { return "gray" }
            if color == .secondary { return "secondary" }
            if color == .mint { return "mint" }
            if color == .cyan { return "cyan" }
            if color == .indigo { return "indigo" }
            if color == .brown { return "brown" }
            if color == .teal { return "teal" }
            return "primary"
        }

        private static func nameToColor(_ name: String) -> Color {
            switch name {
            case "red": return .red
            case "orange": return .orange
            case "yellow": return .yellow
            case "green": return .green
            case "blue": return .blue
            case "purple": return .purple
            case "pink": return .pink
            case "gray": return .gray
            case "secondary": return .secondary
            case "mint": return .mint
            case "cyan": return .cyan
            case "indigo": return .indigo
            case "brown": return .brown
            case "teal": return .teal
            default: return .primary
            }
        }
    }

    private static let appGroupMetricsFileURL: URL? = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.net.mohome.hsm")?            .appendingPathComponent("lastKnownMetrics.json")
    }()

    private static let metricsFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lastKnownMetrics.json")
    }()

    private func saveMetrics() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.writeMetricsFile()
        }
    }

    /// Write metrics to disk immediately (used when the app is about to background).
    func flushMetricsToDisk() {
        saveTask?.cancel()
        saveTask = nil
        writeMetricsFile()
    }

    private func writeMetricsFile() {
        let encoded: [String: [PersistedMetric]] = metrics.reduce(into: [:]) { dict, pair in
            dict[pair.key.uuidString] = pair.value.map(PersistedMetric.init)
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? data.write(to: Self.metricsFileURL, options: .atomic)
        if let url = Self.appGroupMetricsFileURL {
            try? data.write(to: url, options: .atomic)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "HSMServiceWidget")
    }

    private func loadMetrics() {
        // Migrate from UserDefaults if the file doesn't exist yet.
        if !FileManager.default.fileExists(atPath: Self.metricsFileURL.path),
           let legacy = UserDefaults.standard.data(forKey: metricsStorageKey) {
            try? legacy.write(to: Self.metricsFileURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: metricsStorageKey)
        }
        guard let data = try? Data(contentsOf: Self.metricsFileURL),
              let decoded = try? JSONDecoder().decode([String: [PersistedMetric]].self, from: data)
        else { return }
        for (key, persisted) in decoded {
            guard let uuid = UUID(uuidString: key), metrics[uuid] == nil else { continue }
            metrics[uuid] = persisted.map { $0.toServiceMetric() }
        }
    }
}
