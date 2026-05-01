import SwiftUI

/// Full-page service picker presented when the user taps "+".
/// Shows all available service types grouped by category with search.
struct ServicePickerView: View {
    /// Called with (serviceType, prefilledHost, prefilledPort). Host and port are empty/0 when
    /// the user picks from the list manually; they are pre-filled when coming from network scan.
    let onSelect: (ServiceType?, String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showDiscovery = false
    @StateObject private var discovery = NetworkDiscoveryService()
    private var cloudServices: [ServiceType] {
        // Put Claude and Copilot at the bottom since they have limited availability
        let priority: [ServiceType] = [.github]
        let other = ServiceType.allCases.filter { $0.isCloudService && !priority.contains($0) && matchesSearch($0) }
        return priority.filter { matchesSearch($0) } + other
    }

    private var selfHostedServices: [ServiceType] {
        ServiceType.allCases.filter { !$0.isCloudService && $0 != .generic && matchesSearch($0) }
            .sorted { $0.displayName < $1.displayName }
    }

    private var showCustom: Bool {
        searchText.isEmpty || "custom".contains(searchText.lowercased()) || "other".contains(searchText.lowercased()) || "generic".contains(searchText.lowercased())
    }

    private func matchesSearch(_ type: ServiceType) -> Bool {
        guard !searchText.isEmpty else { return true }
        return type.displayName.lowercased().contains(searchText.lowercased())
    }

    var body: some View {
        NavigationStack {
            List {
                if !selfHostedServices.isEmpty {
                    Section("Self-Hosted") {
                        ForEach(selfHostedServices, id: \.self) { type in
                            serviceRow(type)
                        }
                    }
                }

                if !cloudServices.isEmpty {
                    Section("Cloud APIs") {
                        ForEach(cloudServices, id: \.self) { type in
                            serviceRow(type)
                        }
                    }
                }

                if showCustom {
                    Section {
                        Button {
                            dismiss()
                            onSelect(nil, "", 0)
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(.systemFill))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 18, weight: .medium))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Other / Custom")
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text("Any HTTP, HTTPS, or TCP endpoint")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if cloudServices.isEmpty && selfHostedServices.isEmpty && !showCustom {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Search services")
            .navigationTitle("Add Service")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan") {
                        showDiscovery = true
                    }
                }
            }
            .sheet(isPresented: $showDiscovery) {
                ServiceDiscoveryView(discovery: discovery) { type, host, port in
                    dismiss()
                    onSelect(type, host, port)
                }
            }
        }
    }

    private func serviceRow(_ type: ServiceType) -> some View {
        Button {
            dismiss()
            onSelect(type, "", 0)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconBackground(for: type))
                        .frame(width: 44, height: 44)
                    Image(systemName: type.icon)
                        .foregroundStyle(iconColor(for: type))
                        .font(.system(size: 18, weight: .medium))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(subtitle(for: type))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func iconBackground(for type: ServiceType) -> Color {
        iconColor(for: type).opacity(0.15)
    }

    private func iconColor(for type: ServiceType) -> Color {
        switch type {
        case .homeAssistant:  return .blue
        case .adGuard:        return .green
        case .grafana:        return .orange
        case .github:         return .primary
        case .portainer:      return .blue
        case .nginxProxyMgr:  return .green
        case .glances:        return .teal
        case .jellyfin:       return .purple
        case .qBittorrent:    return .blue
        case .openWrt:        return .green
        case .plex:           return .yellow
        case .sonarr:         return .blue
        case .radarr:         return .yellow
        case .prowlarr:       return .purple
        case .overseerr:      return .blue
        case .proxmox:        return .orange
        case .truenas:        return .blue
        case .traefik:        return .blue
        case .unifi:          return .blue
        case .pihole:         return .red
        case .nextcloud:      return .blue
        case .vaultwarden:    return .blue
        case .immich:         return .yellow
        case .paperless:      return .green
        case .frigate:        return .blue
        case .ntfy:           return .purple
        case .ugreenNas:      return Color(red: 0.0, green: 0.6, blue: 0.8)
        case .claude:         return Color(red: 0.8, green: 0.5, blue: 0.3)
        case .copilot:        return .primary
        case .generic:        return .secondary
        }
    }

    private func subtitle(for type: ServiceType) -> String {
        switch type {
        case .homeAssistant:  return "Home automation platform"
        case .adGuard:        return "DNS-based ad blocking"
        case .grafana:        return "Metrics dashboards and alerting"
        case .github:         return "Repository stats, CI status, rate limits"
        case .portainer:      return "Container management"
        case .nginxProxyMgr:  return "Reverse proxy manager"
        case .glances:        return "System resource monitoring"
        case .jellyfin:       return "Media server"
        case .qBittorrent:    return "Torrent client"
        case .openWrt:        return "Router / network OS"
        case .plex:           return "Media server"
        case .sonarr:         return "TV show management"
        case .radarr:         return "Movie management"
        case .prowlarr:       return "Indexer manager"
        case .overseerr:      return "Media request management"
        case .proxmox:        return "Virtualisation platform"
        case .truenas:        return "Network attached storage"
        case .traefik:        return "Reverse proxy and load balancer"
        case .unifi:          return "Ubiquiti network controller"
        case .pihole:         return "DNS-based ad blocking"
        case .nextcloud:      return "File hosting and collaboration"
        case .vaultwarden:    return "Bitwarden-compatible password manager"
        case .immich:         return "Photo and video management"
        case .paperless:      return "Document management"
        case .frigate:        return "NVR with object detection"
        case .ntfy:           return "Push notification service"
        case .ugreenNas:      return "Network attached storage (UGOS Pro)"
        case .claude:         return "Anthropic API - model access and quotas"
        case .copilot:        return "GitHub Copilot - subscription and usage"
        case .generic:        return "Any HTTP, HTTPS, or TCP endpoint"
        }
    }
}
