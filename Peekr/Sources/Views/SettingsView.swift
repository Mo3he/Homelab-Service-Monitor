import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var vm: HomeViewModel
    @ObservedObject private var net = NetworkMonitor.shared
    @AppStorage("autoRefreshInterval") private var interval: Double = 30
    @AppStorage("bgRefreshInterval") private var bgInterval: Double = 900
    @AppStorage("globalOfflineNotificationsEnabled") private var offlineNotificationsEnabled: Bool = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @State private var showImporter = false
    @State private var importResultMessage: String?
    @State private var showNotificationSchedules = false

    private let intervalOptions: [(label: String, seconds: Double)] = [
        ("5 seconds",   5),
        ("10 seconds",  10),
        ("15 seconds",  15),
        ("30 seconds",  30),
        ("45 seconds",  45),
        ("1 minute",    60),
        ("90 seconds",  90),
        ("2 minutes",   120),
        ("3 minutes",   180),
        ("5 minutes",   300),
        ("10 minutes",  600),
        ("15 minutes",  900),
        ("30 minutes",  1800),
        ("1 hour",      3600),
        ("Manual only", 0),
    ]

    private let bgIntervalOptions: [(label: String, seconds: Double)] = [
        ("5 minutes",  300),
        ("10 minutes", 600),
        ("15 minutes", 900),
        ("30 minutes", 1800),
        ("1 hour",     3600),
        ("2 hours",    7200),
        ("4 hours",    14400),
        ("Disabled",   0),
    ]

    var body: some View {
        NavigationStack {
            Form {
                networkInfoSection

                Section("Notifications") {
                    Toggle(isOn: $offlineNotificationsEnabled) {
                        Label("Offline & Recovery Alerts", systemImage: "bell.badge.waveform")
                    }

                    NavigationLink {
                        MetricAlertsSettingsView(vm: vm)
                    } label: {
                        HStack {
                            Label("Metric Alerts", systemImage: "chart.line.uptrend.xyaxis")
                            Spacer()
                            let count = MetricAlertStore.shared.rules.count
                            if count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button {
                        showNotificationSchedules = true
                    } label: {
                        Label("Summary Notifications", systemImage: "bell.badge")
                    }
                }

                Section {
                    Picker("Auto-refresh", selection: $interval) {
                        ForEach(intervalOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Auto-Refresh Interval")
                } footer: {
                    Text("Services are checked one at a time in sequence. Pull down on the home screen to refresh all immediately.")
                }

                Section {
                    Picker("Background Refresh", selection: $bgInterval) {
                        ForEach(bgIntervalOptions, id: \.seconds) { opt in
                            Text(opt.label).tag(opt.seconds)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Background Refresh Interval")
                } footer: {
                    Text("How often Peekr checks your services while in the background. iOS may delay or skip refreshes to preserve battery.")
                }



                Section("Data") {
                    if let data = vm.exportJSON() {
                        ShareLink(
                            item: data,
                            preview: SharePreview("Peekr Services", image: Image(systemName: "square.and.arrow.up"))
                        ) {
                            Label("Export Services", systemImage: "square.and.arrow.up")
                        }
                    }

                    let reportHTML = UptimeReportGenerator.generate(services: vm.services)
                    let reportFile = HTMLFile(data: reportHTML, filename: "peekr-report.html")
                    ShareLink(
                        item: reportFile,
                        preview: SharePreview("Peekr Status Report", image: Image(systemName: "chart.bar.doc.horizontal"))
                    ) {
                        Label("Export Status Report", systemImage: "chart.bar.doc.horizontal")
                    }
                    .disabled(vm.services.isEmpty)

                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Services", systemImage: "square.and.arrow.down")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Link(destination: URL(string: "https://www.buymeacoffee.com/mo3he")!) {
                        HStack {
                            Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isPresented {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showNotificationSchedules) {
                NotificationSchedulesView(vm: vm)
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else {
                        importResultMessage = "Could not access the file."
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let data = try Data(contentsOf: url)
                        let count = vm.importServices(from: data)
                        importResultMessage = count > 0 ? "Imported \(count) service(s)." : "No new services found."
                    } catch {
                        importResultMessage = "Import failed: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    importResultMessage = "Import failed: \(error.localizedDescription)"
                }
            }
            .alert("Import",
                   isPresented: Binding(get: { importResultMessage != nil },
                                        set: { if !$0 { importResultMessage = nil } })) {
                Button("OK", role: .cancel) { importResultMessage = nil }
            } message: {
                Text(importResultMessage ?? "")
            }
        }
    }

    // MARK: - Network Info

    private var networkInfoSection: some View {
        Section {
            HStack {
                if net.isOnWiFi {
                    Label("WiFi", systemImage: "wifi")
                } else if net.likelyVPN {
                    Label("VPN", systemImage: "lock.shield")
                } else if net.isConnected {
                    Label("Cellular", systemImage: "antenna.radiowaves.left.and.right")
                } else {
                    Label("Offline", systemImage: "wifi.slash")
                }
                Spacer()
                Text(net.canReachLocal ? "Local reachable" : "Local unreachable")
                    .font(.subheadline)
                    .foregroundStyle(net.canReachLocal ? .green : .orange)
            }
        } header: {
            Text("Network")
        } footer: {
            Text("Local checks are automatically paused when your services can't be reached on the current network.")
        }
    }
}
