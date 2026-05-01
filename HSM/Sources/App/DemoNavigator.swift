import SwiftUI

/// Renders a specific screen as the root view based on `UserDefaults` key `hsm.demoScreen`.
/// Used for App Store screenshot capture so we can launch the simulator straight into any view
/// without driving the UI via taps. Returns nil when the key is unset or DemoMode is off.
@MainActor
enum DemoNavigator {
    enum Screen: String {
        case home
        case serviceDetail
        case systemHealth
        case metricDetail
        case metricAlertConfig
        case summaryNotifications
        case addService
        case settings
        case eventLog
        case metricAlertsList
    }

    static var current: Screen? {
        guard DemoMode.isEnabled,
              let raw = UserDefaults.standard.string(forKey: "hsm.demoScreen"),
              let s = Screen(rawValue: raw) else { return nil }
        return s
    }

    @ViewBuilder
    static func view(for screen: Screen, vm: HomeViewModel) -> some View {
        switch screen {
        case .home:
            ContentView()
        case .serviceDetail:
            if let service = ServiceStore.shared.services.first(where: { $0.serviceType == .homeAssistant }) {
                NavigationStack { ServiceDetailView(serviceID: service.id, vm: vm) }
            } else { Text("missing service") }
        case .systemHealth:
            NavigationStack { OverallHealthView(vm: vm) }
        case .metricDetail:
            if let glances = ServiceStore.shared.services.first(where: { $0.serviceType == .glances }),
               let cpu = LiveDataStore.shared.metrics[glances.id]?.first(where: { $0.label == "CPU" }) {
                MetricDetailSheet(metric: cpu, serviceName: glances.name, serviceID: glances.id)
            } else { Text("missing metric") }
        case .metricAlertConfig:
            if let ha = ServiceStore.shared.services.first(where: { $0.serviceType == .homeAssistant }),
               let updates = LiveDataStore.shared.metrics[ha.id]?.first(where: { $0.label == "Updates available" }) {
                MetricAlertConfigSheet(metric: updates, serviceID: ha.id, vm: vm)
            } else { Text("missing metric") }
        case .summaryNotifications:
            NotificationSchedulesView(vm: vm)
        case .addService:
            ServicePickerView(onSelect: { _, _, _ in })
        case .settings:
            NavigationStack { SettingsView(vm: vm) }
        case .eventLog:
            NavigationStack { EventLogView(vm: vm) }
        case .metricAlertsList:
            NavigationStack { MetricAlertsSettingsView(vm: vm) }
        }
    }
}
