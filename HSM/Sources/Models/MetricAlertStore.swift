import Foundation

/// Stores per-metric alert rules and tracks previously-seen state to avoid duplicate notifications.
final class MetricAlertStore: ObservableObject {
    static let shared = MetricAlertStore()
    private init() { load() }

    struct Rule: Codable, Equatable {
        enum Kind: String, Codable, CaseIterable {
            case whenAlert        // notify when metric.isAlert becomes true
            case whenValueChanges // notify when metric.value string changes
            case threshold        // notify when numeric value crosses a user-defined limit
        }
        var kind: Kind
        var thresholdAbove: Double? = nil  // fire when extracted number > this
        var thresholdBelow: Double? = nil  // fire when extracted number < this

        static let whenAlert        = Rule(kind: .whenAlert)
        static let whenValueChanges = Rule(kind: .whenValueChanges)
    }

    // Legacy condition type used only for migration
    private enum LegacyCondition: String, Codable {
        case whenAlert, whenValueChanges
    }

    private let rulesKey      = "hsm.metricAlertRules2"
    private let legacyRulesKey = "hsm.metricAlertRules"
    private let lastValuesKey = "hsm.metricLastValues"
    private let lastAlertKey  = "hsm.metricLastAlertState"

    // "serviceID:label" -> rule
    @Published private(set) var rules: [String: Rule] = [:]
    // "serviceID:label" -> last seen value (for whenValueChanges dedup)
    private var lastValues: [String: String] = [:]
    // "serviceID:label" -> last "breached" state (for whenAlert and threshold dedup)
    private var lastAlertState: [String: Bool] = [:]

    private func ruleKey(_ serviceID: UUID, _ label: String) -> String {
        "\(serviceID.uuidString):\(label)"
    }

    func hasRule(serviceID: UUID, label: String) -> Bool {
        rules[ruleKey(serviceID, label)] != nil
    }

    func rule(serviceID: UUID, label: String) -> Rule? {
        rules[ruleKey(serviceID, label)]
    }

    func setRule(_ rule: Rule, serviceID: UUID, label: String) {
        rules[ruleKey(serviceID, label)] = rule
        save()
    }

    func removeRule(serviceID: UUID, label: String) {
        let k = ruleKey(serviceID, label)
        rules.removeValue(forKey: k)
        lastValues.removeValue(forKey: k)
        lastAlertState.removeValue(forKey: k)
        save()
    }

    func removeAllRules(for serviceID: UUID) {
        let prefix = serviceID.uuidString + ":"
        rules          = rules.filter          { !$0.key.hasPrefix(prefix) }
        lastValues     = lastValues.filter     { !$0.key.hasPrefix(prefix) }
        lastAlertState = lastAlertState.filter { !$0.key.hasPrefix(prefix) }
        save()
    }

    /// Returns true if a notification should fire for this metric right now.
    /// Mutates internal state to prevent duplicate notifications.
    func shouldFire(metric: ServiceMetric, serviceID: UUID) -> Bool {
        let k = ruleKey(serviceID, metric.label)
        guard let rule = rules[k] else { return false }

        switch rule.kind {
        case .whenAlert:
            let wasAlert = lastAlertState[k] ?? false
            if metric.isAlert && !wasAlert {
                lastAlertState[k] = true
                saveLastState()
                return true
            }
            if !metric.isAlert && wasAlert {
                lastAlertState[k] = false
                saveLastState()
            }
            return false

        case .whenValueChanges:
            let prev = lastValues[k]
            lastValues[k] = metric.value
            saveLastValues()
            return prev != nil && prev != metric.value

        case .threshold:
            guard let num = Self.extractNumeric(from: metric.value) else { return false }
            let isBreached = Self.checkThreshold(value: num, above: rule.thresholdAbove, below: rule.thresholdBelow)
            let wasBreached = lastAlertState[k] ?? false
            if isBreached && !wasBreached {
                lastAlertState[k] = true
                saveLastState()
                return true
            }
            if !isBreached && wasBreached {
                lastAlertState[k] = false
                saveLastState()
            }
            return false
        }
    }

    static func checkThreshold(value: Double, above: Double?, below: Double?) -> Bool {
        if let a = above, value > a { return true }
        if let b = below, value < b { return true }
        return false
    }

    /// Extracts the first floating-point number from a metric value string.
    /// e.g. "75°C" → 75.0, "9.3 GB free" → 9.3, "42%" → 42.0
    static func extractNumeric(from string: String) -> Double? {
        let pattern = #"-?\d+\.?\d*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range, in: string) else { return nil }
        return Double(string[range])
    }

    // MARK: - Persistence

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let rulesFileURL      = dir.appendingPathComponent("metricAlertRules.json")
    private static let lastValuesFileURL = dir.appendingPathComponent("metricAlertLastValues.json")
    private static let lastAlertFileURL  = dir.appendingPathComponent("metricAlertLastState.json")

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: Self.rulesFileURL, options: .atomic)
        }
        saveLastValues()
        saveLastState()
    }

    private func saveLastValues() {
        if let data = try? JSONEncoder().encode(lastValues) {
            try? data.write(to: Self.lastValuesFileURL, options: .atomic)
        }
    }

    private func saveLastState() {
        if let data = try? JSONEncoder().encode(lastAlertState) {
            try? data.write(to: Self.lastAlertFileURL, options: .atomic)
        }
    }

    private func load() {
        // Migrate from UserDefaults if files don't exist yet.
        migrateIfNeeded(key: rulesKey, to: Self.rulesFileURL)
        migrateIfNeeded(key: lastValuesKey, to: Self.lastValuesFileURL)
        migrateIfNeeded(key: lastAlertKey, to: Self.lastAlertFileURL)

        // Try new format first
        if let data = try? Data(contentsOf: Self.rulesFileURL),
           let decoded = try? JSONDecoder().decode([String: Rule].self, from: data) {
            rules = decoded
        } else if let data = UserDefaults.standard.data(forKey: legacyRulesKey),
                  let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            // Migrate old Condition strings to new Rule format
            rules = legacy.compactMapValues {
                switch $0 {
                case "whenAlert":        return .whenAlert
                case "whenValueChanges": return .whenValueChanges
                default:                 return nil
                }
            }
            save() // persist migrated data in new format
        }
        if let data = try? Data(contentsOf: Self.lastValuesFileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            lastValues = dict
        }
        if let data = try? Data(contentsOf: Self.lastAlertFileURL),
           let dict = try? JSONDecoder().decode([String: Bool].self, from: data) {
            lastAlertState = dict
        }
    }

    private func migrateIfNeeded(key: String, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path),
           let legacy = UserDefaults.standard.data(forKey: key) {
            try? legacy.write(to: url, options: .atomic)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
