import SwiftUI
import BackgroundTasks
import UserNotifications

// MARK: - Notification name

extension Notification.Name {
    static let openSummarySchedule = Notification.Name("net.mohome.hsm.openSummarySchedule")
}

// MARK: - UNUserNotificationCenterDelegate

/// Handles notification taps so that tapping a summary notification navigates into the app.
private final class NotificationResponseHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        if id.hasPrefix("summary-"),
           let uuid = UUID(uuidString: String(id.dropFirst("summary-".count))) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .openSummarySchedule,
                    object: nil,
                    userInfo: ["scheduleID": uuid]
                )
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}

// MARK: - App

@main
struct HSMApp: App {
    private let bgTaskID = "net.mohome.hsm.refresh"
    private let bgProcessingTaskID = "net.mohome.hsm.processing"
    private let notifDelegate = NotificationResponseHandler()

    /// One HomeViewModel for the whole app. Injected into every Scene so iPhone, iPad,
    /// and the Mac menu bar all read/write the same in-memory state and event log.
    @StateObject private var vm = HomeViewModel()

    init() {
        // Register UserDefaults defaults so reads from the BG scheduler agree with
        // SwiftUI's @AppStorage defaults in SettingsView. Without this, a fresh install
        // would read 0 here and silently disable background refresh.
        UserDefaults.standard.register(defaults: [
            "bgRefreshInterval": 900.0,
            "autoRefreshInterval": 30.0,
            "historyRetentionDays": 0,
            "globalRecoveryNotificationsEnabled": true,
            "requestTimeoutSeconds": 5.0,
            "retryCountBeforeOffline": 1
        ])

        // Demo mode: seeds realistic fake services for App Store screenshots.
        // No-op when DemoMode.isEnabled is false.
        MainActor.assumeIsolated { DemoMode.seedIfNeeded() }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handleBackgroundRefresh(task: refreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgProcessingTaskID, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            Self.handleBackgroundProcessing(task: processingTask)
        }
        // Request notification permission on first launch - non-blocking
        if !DemoMode.isEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        UNUserNotificationCenter.current().delegate = notifDelegate
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    LiveDataStore.shared.flushMetricsToDisk()
                    scheduleBackgroundRefresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    Task { @MainActor in await SummaryNotificationManager.shared.rescheduleAll() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    UNUserNotificationCenter.current().setBadgeCount(0)
                }
        }

        // MenuBarExtra is macOS-only (NOT available on Mac Catalyst, despite the README's
        // historical claim). Gate it behind a true macOS target so the Catalyst build
        // compiles. If a native macOS target is added later, the menu bar lights up
        // automatically — no further changes needed here.
        #if os(macOS) && !targetEnvironment(macCatalyst)
        MenuBarExtra("HSM", systemImage: menuBarIcon) {
            MenuBarStatusView()
                .environmentObject(vm)
        }
        #endif
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    private var menuBarIcon: String {
        let store = ServiceStore.shared
        if store.services.contains(where: { $0.status == .offline })   { return "exclamationmark.circle.fill" }
        if store.services.contains(where: { $0.status == .degraded })  { return "exclamationmark.triangle.fill" }
        if store.services.allSatisfy({ $0.status == .online })         { return "checkmark.circle.fill" }
        return "circle.dashed"
    }
    #endif

    private func scheduleBackgroundRefresh() {
        Self.scheduleBackgroundRefresh(taskID: bgTaskID)
        Self.scheduleBackgroundProcessing(taskID: bgProcessingTaskID)
    }

    private static func scheduleBackgroundRefresh(taskID: String) {
        let interval = UserDefaults.standard.double(forKey: "bgRefreshInterval")
        guard interval > 0 else { return }  // 0 = user disabled
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    // Schedules a BGProcessingTask for reliable overnight refresh (runs on charger/WiFi).
    // The system is far more likely to honor this when the device is charging overnight,
    // filling the gaps left by BGAppRefreshTask's aggressive throttling.
    private static func scheduleBackgroundProcessing(taskID: String) {
        let request = BGProcessingTaskRequest(identifier: taskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Reschedule the next task FIRST so we don't miss the next slot if the work
        // takes the whole budget or hits the expiration handler.
        scheduleBackgroundRefresh(taskID: task.identifier)

        // Single Task owns the work. Set expirationHandler before any await to ensure
        // the system can cancel cleanly even if the runtime expires the task immediately.
        let work = Task<Bool, Never> {
            await BackgroundRefreshCoordinator.refreshAll()
            return !Task.isCancelled
        }

        task.expirationHandler = { work.cancel() }

        Task {
            let success = await work.value
            task.setTaskCompleted(success: success)
        }
    }

    private static func handleBackgroundProcessing(task: BGProcessingTask) {
        scheduleBackgroundProcessing(taskID: task.identifier)

        let work = Task<Bool, Never> {
            await BackgroundRefreshCoordinator.refreshAll()
            return !Task.isCancelled
        }

        task.expirationHandler = { work.cancel() }

        Task {
            let success = await work.value
            task.setTaskCompleted(success: success)
        }
    }
}
