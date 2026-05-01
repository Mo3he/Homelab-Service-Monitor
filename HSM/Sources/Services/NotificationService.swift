import Foundation
import UserNotifications
import os

enum NotificationService {
    static func postOfflineAlert(for service: Service) async {
        AppLogger.notify.info("Posting offline alert for \(service.name, privacy: .public)")
        let content = UNMutableNotificationContent()
        content.title = "\(service.name) is offline"
        content.body = "\(service.displayURL) is not responding."
        content.sound = .default
        // `.timeSensitive` requires the `com.apple.developer.usernotifications.time-sensitive`
        // entitlement (declared in HSM.entitlements). Without an active paid Apple
        // Developer Program, the entitlements file isn't linked into the build (see
        // `PAID_ACCOUNT` in project.yml) and the system silently downgrades to `.active`.
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "offline-\(service.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func postRecoveryAlert(for service: Service) async {
        AppLogger.notify.info("Posting recovery alert for \(service.name, privacy: .public)")
        // Cancel any pending offline alert for this service
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["offline-\(service.id.uuidString)"])

        let content = UNMutableNotificationContent()
        content.title = "\(service.name) is back online"
        content.body = "\(service.displayURL) is responding again."
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: "recovery-\(service.id.uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func postMetricAlert(for service: Service, metric: ServiceMetric) async {
        let content = UNMutableNotificationContent()
        content.title = "\(service.name): \(metric.label)"
        content.body = metric.value.isEmpty ? "Value changed" : metric.value
        content.sound = .default
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: "metric-\(service.id.uuidString)-\(abs(metric.label.hashValue))",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
