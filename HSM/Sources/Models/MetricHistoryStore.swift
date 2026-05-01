import Foundation

/// A single recorded reading of a metric at a point in time.
struct MetricSnapshot: Identifiable, Codable {
    var id: UUID = UUID()
    var value: String
    var isAlert: Bool
    var timestamp: Date
}

/// Stores the last N readings per service+metric key.
/// Keys are formatted as "\(serviceID.uuidString)|\(label.lowercased())".
/// Persisted to UserDefaults so history survives short app restarts.
@MainActor
final class MetricHistoryStore {
    static let shared = MetricHistoryStore()
    private init() { load() }

    private let storageKey = "hsm.metricHistory"
    private let maxPerMetric = 50

    private var history: [String: [MetricSnapshot]] = [:]

    // MARK: - Writing

    func record(serviceID: UUID, metrics: [ServiceMetric]) {
        let now = Date()
        var dirty = false
        for m in metrics {
            let key = "\(serviceID.uuidString)|\(m.label.lowercased())"
            var snaps = history[key, default: []]
            // Debounce: skip if same value recorded < 5 seconds ago
            if let last = snaps.last, last.value == m.value,
               now.timeIntervalSince(last.timestamp) < 5 { continue }
            snaps.append(MetricSnapshot(value: m.value, isAlert: m.isAlert, timestamp: now))
            if snaps.count > maxPerMetric { snaps.removeFirst(snaps.count - maxPerMetric) }
            history[key] = snaps
            dirty = true
        }
        if dirty { save() }
    }

    // MARK: - Reading

    func snapshots(serviceID: UUID, label: String) -> [MetricSnapshot] {
        history["\(serviceID.uuidString)|\(label.lowercased())"] ?? []
    }

    /// DEMO: synthesize a 10-point reading history at staggered timestamps (used by `DemoMode` only).
    /// Pass `values` to vary readings across timestamps; otherwise `value` repeats for all 10.
    func recordDemo(serviceID: UUID, label: String, value: String, isAlert: Bool,
                    values: [String]? = nil) {
        let key = "\(serviceID.uuidString)|\(label.lowercased())"
        let now = Date()
        let offsets: [TimeInterval] = [-50, -118, -138, -179, -260, -270, -303, -318, -379, -466]
        history[key] = offsets.enumerated().map { (idx, dt) in
            let v: String
            if let values, !values.isEmpty {
                v = values[idx % values.count]
            } else {
                v = value
            }
            return MetricSnapshot(value: v, isAlert: isAlert, timestamp: now.addingTimeInterval(dt))
        }
    }

    // MARK: - Cleanup

    func remove(serviceID: UUID) {
        let prefix = serviceID.uuidString
        history = history.filter { !$0.key.hasPrefix(prefix) }
        save()
    }

    // MARK: - Persistence

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metricHistory.json")
    }()

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        // Migrate from UserDefaults if the file doesn't exist yet.
        if !FileManager.default.fileExists(atPath: Self.fileURL.path),
           let legacy = UserDefaults.standard.data(forKey: storageKey) {
            try? legacy.write(to: Self.fileURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: [MetricSnapshot]].self, from: data)
        else { return }
        history = decoded
    }
}
