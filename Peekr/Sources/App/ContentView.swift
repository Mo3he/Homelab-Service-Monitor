import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

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
    }
}

/// iPhone: tab bar with Services + Status Log tabs.
private struct iPhoneRootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Services", systemImage: "square.grid.2x2.fill") }

            EventLogTabView()
                .tabItem { Label("Status Log", systemImage: "clock.arrow.circlepath") }
        }
    }
}

/// Wrapper so the EventLogView gets its own HomeViewModel that shares the same store data.
private struct EventLogTabView: View {
    @StateObject private var vm = HomeViewModel()

    var body: some View {
        EventLogView(vm: vm)
    }
}
