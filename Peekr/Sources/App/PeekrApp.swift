import SwiftUI
import BackgroundTasks
import UserNotifications

// MARK: - Notification name

extension Notification.Name {
    static let openSummarySchedule = Notification.Name("peekr.openSummarySchedule")
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
struct PeekrApp: App {
    private let bgTaskID = "com.mblieden.peekr.refresh"
    private let notifDelegate = NotificationResponseHandler()

    /// One HomeViewModel for the whole app. Injected into every Scene so iPhone, iPad,
    /// and the Mac menu bar all read/write the same in-memory state and event log.
    @StateObject private var vm = HomeViewModel()

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handleBackgroundRefresh(task: refreshTask)
        }
        // Request notification permission on first launch - non-blocking
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        UNUserNotificationCenter.current().delegate = notifDelegate
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
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
        MenuBarExtra("Peekr", systemImage: menuBarIcon) {
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
        let interval = UserDefaults.standard.double(forKey: "bgRefreshInterval")
        let seconds = interval > 0 ? interval : 900  // default 15 min; 0 = disabled
        guard interval != 0 else { return }
        let request = BGAppRefreshTaskRequest(identifier: bgTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleBackgroundRefresh(task: BGAppRefreshTask) {
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
}
