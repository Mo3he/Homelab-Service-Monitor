import Foundation

/// A user-configured summary notification covering one or more services.
struct MetricSummarySchedule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// User-visible name shown as the notification title.
    var name: String
    /// Services included in this summary.
    var serviceIDs: [UUID]
    /// Cached display names for services (used when a service is later deleted).
    var serviceNames: [String]
    /// Metric labels to include from each service. Empty = all metrics (up to 5 per service).
    var metricLabels: [String]
    var scheduleType: ScheduleType
    var isEnabled: Bool = true

    enum ScheduleType: Codable, Equatable, Hashable {
        case daily(hour: Int, minute: Int)
        case interval(hours: Int)

        var displayName: String {
            switch self {
            case .daily(let h, let m):
                let date = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
                return "Daily at " + date.formatted(date: .omitted, time: .shortened)
            case .interval(let h):
                return h == 1 ? "Every hour" : "Every \(h) hours"
            }
        }
    }
}
