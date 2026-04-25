import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var pendingSummary: MetricSummarySchedule?

    var body: some View {
        Group {
            if sizeClass == .regular {
                iPadRootView()
            } else {
                iPhoneRootView()
            }
        }
        .onAppear {
            if !hasCompletedOnboarding { showOnboarding = true }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                hasCompletedOnboarding = true
                showOnboarding = false
            }
        }
        .sheet(item: $pendingSummary) { schedule in
            SummaryDetailView(schedule: schedule)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSummarySchedule)) { note in
            if let id = note.userInfo?["scheduleID"] as? UUID {
                pendingSummary = SummaryNotificationManager.shared.schedules.first { $0.id == id }
            }
        }
    }
}

/// iPhone: tab bar with Services, Status Log, Add, and Settings tabs.
private struct iPhoneRootView: View {
    @EnvironmentObject private var vm: HomeViewModel

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Services", systemImage: "square.grid.2x2.fill") }

            EventLogView(vm: vm)
                .tabItem { Label("Log", systemImage: "clock.arrow.circlepath") }

            SettingsView(vm: vm)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
