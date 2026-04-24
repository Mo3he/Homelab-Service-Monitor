import AppIntents
import Foundation

// MARK: - Refresh all services

struct RefreshAllServicesIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh All Services"
    static var description = IntentDescription("Checks all Peekr services immediately and returns an overview.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = ServiceStore.shared
        let services = await MainActor.run { store.services }
        guard !services.isEmpty else {
            return .result(dialog: "No services configured in Peekr.")
        }
        await withTaskGroup(of: Void.self) { group in
            for service in services {
                group.addTask {
                    _ = try? await PingService.shared.check(service)
                }
            }
        }
        let latest = await MainActor.run { store.services }
        let online = latest.filter { $0.status == .online }.count
        let offline = latest.filter { $0.status == .offline }.count
        let total = latest.count
        var dialog = "\(online) of \(total) services online."
        if offline > 0 { dialog += " \(offline) offline." }
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - App Shortcuts (appear automatically in Shortcuts app)

struct PeekrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAllServicesIntent(),
            phrases: [
                "Refresh \(.applicationName)",
                "Check \(.applicationName) services",
                "Ping \(.applicationName)"
            ],
            shortTitle: "Refresh Services",
            systemImageName: "arrow.clockwise.circle.fill"
        )
    }
}
