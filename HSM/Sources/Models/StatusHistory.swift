import Foundation

/// Records recent status check results per service for sparkline display.
struct StatusSnapshot: Identifiable, Codable {
    var id: Date { timestamp }
    var latencyMs: Double?
    var status: ServiceStatus
    var timestamp: Date
}

/// Stores the last N snapshots per service in UserDefaults.
@MainActor
final class StatusHistoryStore: ObservableObject {
    static let shared = StatusHistoryStore()
    private init() { load() }

    private let key = "hsm.statusHistory"
    private let maxPerService = 30

    @Published private(set) var history: [UUID: [StatusSnapshot]] = [:]

    func record(serviceID: UUID, status: ServiceStatus, latencyMs: Double?) {
        let snap = StatusSnapshot(latencyMs: latencyMs, status: status, timestamp: Date())
        var snaps = history[serviceID, default: []]
        snaps.append(snap)
        let retentionDays = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
            snaps = snaps.filter { $0.timestamp > cutoff }
        }
        if snaps.count > maxPerService { snaps.removeFirst(snaps.count - maxPerService) }
        history[serviceID] = snaps
        save()
    }

    func clearAll() {
        history.removeAll()
        save()
    }

    func snapshots(for serviceID: UUID) -> [StatusSnapshot] {
        history[serviceID, default: []]
    }

    /// DEMO: append a snapshot with an explicit timestamp (used by `DemoMode` only).
    func recordDemo(serviceID: UUID, status: ServiceStatus, latencyMs: Double?, timestamp: Date) {
        let snap = StatusSnapshot(latencyMs: latencyMs, status: status, timestamp: timestamp)
        var snaps = history[serviceID, default: []]
        snaps.append(snap)
        if snaps.count > maxPerService { snaps.removeFirst(snaps.count - maxPerService) }
        history[serviceID] = snaps
    }

    func remove(serviceID: UUID) {
        history.removeValue(forKey: serviceID)
        save()
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: history.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        // Migrate from UserDefaults if the file doesn't exist yet.
        if !FileManager.default.fileExists(atPath: Self.fileURL.path),
           let legacy = UserDefaults.standard.data(forKey: key) {
            try? legacy.write(to: Self.fileURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: key)
        }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: [StatusSnapshot]].self, from: data)
        else { return }
        history = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in
            UUID(uuidString: k).map { ($0, v) }
        })
    }

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("statusHistory.json")
    }()
}
