import SwiftUI

/// Presented as a sheet from ServicePickerView. Scans the local network for known
/// self-hosted services via mDNS/Bonjour and lets the user tap one to pre-fill
/// AddServiceView with the detected type, host, and port.
struct ServiceDiscoveryView: View {
    /// Passed in from ServicePickerView so results survive sheet dismissal.
    @ObservedObject var discovery: NetworkDiscoveryService

    /// Called when the user selects a discovered service.
    /// serviceType is nil for unidentified (Generic) services so AddServiceView
    /// lets the user pick the type freely while still pre-filling host and port.
    let onSelect: (ServiceType?, String, Int) -> Void

    @Environment(\..dismiss) private var dismiss
    @ObservedObject private var store = ServiceStore.shared

    /// Results with already-added services filtered out (matched on host + port).
    private var filteredResults: [DiscoveredNetworkService] {
        let existing = Set(store.services.map { "\($0.host):\($0.port)" })
        return discovery.results.filter { !existing.contains("\($0.host):\($0.port)") }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredResults.isEmpty {
                    emptyState
                } else {
                    resultsList
                }
            }
            .navigationTitle("Network Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if discovery.isScanning {
                        ProgressView()
                    } else {
                        Button("Scan Again") { discovery.startScan() }
                    }
                }
            }
        }
        .onAppear {
            // Only start a scan automatically on the very first open.
            // If the user comes back after adding a service, keep existing results.
            if discovery.results.isEmpty && !discovery.isScanning {
                discovery.startScan()
            }
        }
        .onDisappear { discovery.stopScan() }
    }

    // MARK: - Empty / Scanning State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            if discovery.isScanning {
                ProgressView()
                    .controlSize(.large)
                Text("Scanning your network...")
                    .font(.headline)
                if discovery.scanProgress > 0 {
                    ProgressView(value: discovery.scanProgress)
                        .padding(.horizontal, 40)
                    Text("\(Int(discovery.scanProgress * 100))% scanned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Looking for Home Assistant, Plex, Jellyfin, and more.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            } else {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No services found")
                    .font(.headline)
                Text("Make sure you're on the same Wi-Fi network as your self-hosted services.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Scan Again") { discovery.startScan() }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
            Spacer()
        }
    }

    // MARK: - Results List

    private var resultsList: some View {
        List(filteredResults) { service in
            Button {
                dismiss()
                onSelect(service.serviceType == .generic ? nil : service.serviceType, service.host, service.port)
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.systemFill))
                            .frame(width: 44, height: 44)
                        Image(systemName: service.serviceType.icon)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 18, weight: .medium))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(service.host + ":" + String(service.port))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(service.serviceType.displayName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if service.serviceType == .generic {
                            Text("Tap to identify")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .overlay(alignment: .bottom) {
            if discovery.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(discovery.scanProgress > 0 ? "Scanning... \(Int(discovery.scanProgress * 100))%" : "Scanning...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 12)
            }
        }
    }
}
