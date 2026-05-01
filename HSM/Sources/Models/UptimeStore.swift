import Foundation

/// A lightweight record of a single service check result used to compute uptime %.
private struct UptimeRecord: Codable {
    let timestamp: Date
    let isOnline: Bool   // true = .online; false = .degraded, .offline, etc.
}

/// Tracks per-service uptime records on disk (not UserDefaults - can be larger).
/// Keeps up to 31 days of data, pruning records older than that on each write.
@MainActor
final class UptimeStore {
    static let shared = UptimeStore()
    private init() { load() }

    // Internal: service UUID → ordered records (oldest first)
    private var records: [UUID: [UptimeRecord]] = [:]

    private let maxAge: TimeInterval = 31 * 24 * 3600
    // Safety cap: ~8640 records = 30 days at 5-min intervals
    private let maxPerService = 8640

    // MARK: - Record

    func record(serviceID: UUID, status: ServiceStatus) {
        let rec = UptimeRecord(timestamp: Date(), isOnline: status == .online)
        var list = records[serviceID, default: []]
        list.append(rec)
        let cutoff = Date().addingTimeInterval(-maxAge)
        list = list.filter { $0.timestamp > cutoff }
        if list.count > maxPerService { list = Array(list.suffix(maxPerService)) }
        records[serviceID] = list
        save()
    }

    /// DEMO: insert a record with an explicit timestamp (used by `DemoMode` only).
    func recordDemo(serviceID: UUID, status: ServiceStatus, timestamp: Date) {
        let rec = UptimeRecord(timestamp: timestamp, isOnline: status == .online)
        var list = records[serviceID, default: []]
        list.append(rec)
        records[serviceID] = list.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Query

    /// Uptime percentage for this service over the last `days` days.
    /// Returns nil if there are fewer than 2 data points in the window.
    func uptimePercent(for serviceID: UUID, days: Int) -> Double? {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let list = records[serviceID, default: []].filter { $0.timestamp > cutoff }
        guard list.count >= 2 else { return nil }
        let online = list.filter(\.isOnline).count
        return Double(online) / Double(list.count) * 100.0
    }

    // MARK: - Lifecycle

    func remove(serviceID: UUID) {
        records.removeValue(forKey: serviceID)
        save()
    }

    // MARK: - Persistence (file-based)

    private var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("hsm_uptime.json")
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [UptimeRecord]].self, from: data)
        else { return }
        records = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in
            UUID(uuidString: k).map { ($0, v) }
        })
    }
}
