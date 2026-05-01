import SwiftUI
import LocalAuthentication

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var vm: HomeViewModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("requireBiometrics") private var requireBiometrics: Bool = false
    @State private var isLocked: Bool = UserDefaults.standard.bool(forKey: "requireBiometrics")
    @State private var showOnboarding = false
    @State private var pendingSummary: MetricSummarySchedule?

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some View {
        Group {
            if let demo = DemoNavigator.current, demo != .home {
                DemoNavigator.view(for: demo, vm: vm)
            } else if sizeClass == .regular {
                iPadRootView()
            } else {
                iPhoneRootView()
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .overlay {
            if isLocked {
                AppLockView(onAuthenticate: authenticate)
                    .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if requireBiometrics {
                if phase == .background { isLocked = true }
                if phase == .active && isLocked { authenticate() }
            }
        }
        .onChange(of: requireBiometrics) { _, enabled in
            if enabled { isLocked = true; authenticate() }
            else { isLocked = false }
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

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                                localizedReason: "Unlock Homelab Service Monitor") { success, _ in
            DispatchQueue.main.async {
                if success { isLocked = false }
            }
        }
    }
}

// MARK: - App lock overlay

private struct AppLockView: View {
    let onAuthenticate: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "lock.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.secondary)
                Text("HSM Locked")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onAuthenticate) {
                    Label("Unlock", systemImage: "faceid")
                        .padding(.horizontal, 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
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
