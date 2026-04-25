import Foundation
import UserNotifications

/// Manages scheduling and content for summary notifications.
@MainActor
final class SummaryNotificationManager {
    static let shared = SummaryNotificationManager()
    private init() {}

    private let storageKey = "peekr.summarySchedules"

    var schedules: [MetricSummarySchedule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([MetricSummarySchedule].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: storageKey)
            Task { await rescheduleAll() }
        }
    }

    // MARK: - Scheduling

    /// Cancel and re-create all UNNotificationRequests from current schedules.
    func rescheduleAll() async {
        let center = UNUserNotificationCenter.current()

        // Remove all existing summary notifications
        let pending = await center.pendingNotificationRequests()
        let ids = pending.filter { $0.identifier.hasPrefix("summary-") }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)

        let enabled = schedules.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }

        // Only prompt for authorization if it's still undetermined; otherwise honor the
        // existing setting. Repeatedly calling requestAuthorization on every schedule write
        // is noisy and pointless once the user has answered.
        guard await ensureAuthorization(center: center) else { return }

        let services = ServiceStore.shared.services
        let liveMetrics = LiveDataStore.shared.metrics

        for schedule in enabled {
            let content = buildContent(for: schedule, services: services, liveMetrics: liveMetrics)
            let trigger = buildTrigger(for: schedule.scheduleType)

            let request = UNNotificationRequest(
                identifier: "summary-\(schedule.id.uuidString)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    private func ensureAuthorization(center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Content building

    private func buildContent(for schedule: MetricSummarySchedule,
                              services: [Service],
                              liveMetrics: [UUID: [ServiceMetric]]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = schedule.name

        // Collect matching services
        let matchedServices = schedule.serviceIDs.compactMap { id in
            services.first(where: { $0.id == id })
        }

        if matchedServices.isEmpty {
            content.body = "No data available."
            content.interruptionLevel = .passive
            return content
        }

        var bodyLines: [String] = []
        var totalAlerts = 0

        for service in matchedServices {
            let allMetrics = liveMetrics[service.id] ?? []
            totalAlerts += allMetrics.filter(\.isAlert).count

            let metricsToShow: [ServiceMetric]
            if schedule.metricLabels.isEmpty {
                metricsToShow = Array(allMetrics.prefix(matchedServices.count > 1 ? 3 : 5))
            } else {
                metricsToShow = allMetrics.filter { schedule.metricLabels.contains($0.label) }
            }

            if metricsToShow.isEmpty {
                if matchedServices.count > 1 {
                    bodyLines.append("\(service.name): no data")
                } else {
                    bodyLines.append("Tap to check current status.")
                }
            } else {
                let metricStr = metricsToShow.map { "\($0.label): \($0.value)" }.joined(separator: ", ")
                if matchedServices.count > 1 {
                    bodyLines.append("\(service.name): \(metricStr)")
                } else {
                    bodyLines.append(metricStr)
                }
            }
        }

        content.body = bodyLines.joined(separator: "\n")
        content.sound = .default

        if totalAlerts > 0 {
            content.badge = totalAlerts as NSNumber
            content.interruptionLevel = .timeSensitive
        } else {
            content.interruptionLevel = .passive
        }

        return content
    }

    // MARK: - Trigger building

    private func buildTrigger(for type: MetricSummarySchedule.ScheduleType) -> UNNotificationTrigger {
        switch type {
        case .daily(let hour, let minute):
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            return UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        case .interval(let hours):
            return UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(hours * 3600),
                repeats: true
            )
        }
    }
}
