import SwiftUI

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @StateObject private var network = NetworkMonitor.shared
    @State private var addServiceRequest: AddServiceItem? = nil
    @State private var editingService: Service?
    @State private var detailService: Service?
    @State private var showSettings = false
    @State private var serviceToDelete: Service?
    // scrollPosition removed - List naturally preserves scroll when ForEach identity is stable
    @AppStorage("autoRefreshInterval") private var refreshInterval: Double = 30

    var body: some View {
        NavigationStack {
            List {
                if !network.canReachLocal && vm.services.contains(where: \.isLocalNetwork) {
                    networkBanner
                }
                if !vm.services.isEmpty {
                    overallStatusSection
                    statusFilterPicker
                }
                servicesSection
            }
            .listStyle(.insetGrouped)
            .searchable(text: $vm.searchText, prompt: "Search services")
            .refreshable { vm.refreshAll() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        refreshButton
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        EditButton()
                        AddServiceMenuButton { type in
                            addServiceRequest = AddServiceItem(serviceType: type)
                        }
                    }
                }
            }
            .sheet(item: $addServiceRequest) { req in
                AddServiceView(serviceType: req.serviceType) { vm.addService($0) }
            }
            .sheet(item: $editingService) { service in
                AddServiceView(existing: service) { vm.updateService($0) }
            }
            .sheet(item: $detailService) { service in
                ServiceDetailView(serviceID: service.id, vm: vm)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(vm: vm)
            }
            .confirmationDialog(
                "Delete \(serviceToDelete?.name ?? "service")?",
                isPresented: .init(
                    get: { serviceToDelete != nil },
                    set: { if !$0 { serviceToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let svc = serviceToDelete {
                        vm.removeService(svc)
                    }
                    serviceToDelete = nil
                }
            } message: {
                Text("This service and its history will be removed.")
            }
            .onAppear {
                vm.refreshAll()
                vm.startAutoRefresh()
            }
            .onDisappear {
                vm.stopAutoRefresh()
            }
            .onChange(of: refreshInterval) { _, _ in
                vm.startAutoRefresh()
            }
        }
    }

    // MARK: - Toolbar

    private var refreshButton: some View {
        Button { vm.refreshAll() } label: {
            if vm.isRefreshing {
                ProgressView().scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(vm.isRefreshing)
    }

    // MARK: - Network Banner

    private var networkBanner: some View {
        Section {
            HStack(spacing: 10) {
                if network.isProbing {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: network.isOnWiFi ? "wifi.exclamationmark" : "wifi.slash")
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(network.isOnWiFi ? "Not Your Home Network" : "Off WiFi")
                        .font(.subheadline.bold())
                    Text(network.isOnWiFi
                         ? "Local services couldn't be reached on this WiFi. They are paused to avoid timeouts."
                         : "Local services are paused while you're away from your home network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if network.isOnWiFi {
                    Button("Check anyway") {
                        network.reprobeAndOverride()
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Status Filter

    private var statusFilterPicker: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(label: "All", filter: nil)
                    filterChip(label: "Online", filter: .online)
                    filterChip(label: "Degraded", filter: .degraded)
                    filterChip(label: "Offline", filter: .offline)
                }
                .padding(.horizontal, 4)
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    }

    private func filterChip(label: String, filter: ServiceStatus?) -> some View {
        let isSelected = vm.statusFilter == filter
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                vm.statusFilter = isSelected ? nil : filter
            }
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) filter")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(isSelected ? "Tap to show all services" : "Tap to filter by \(label.lowercased())")
    }

    // MARK: - Sections

    private var overallStatusSection: some View {
        Section {
            HStack(spacing: 16) {
                StatusIndicatorView(status: vm.overallHealth, size: 50)

                VStack(alignment: .leading, spacing: 5) {
                    Text(vm.overallHealth.label)
                        .font(.title3.bold())

                    HStack(spacing: 6) {
                        Label("\(vm.onlineCount) online", systemImage: "circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                            .labelStyle(CompactLabelStyle())
                        // Always reserve space for degraded/offline labels to keep section height stable
                        Text("\u{00b7}").foregroundStyle(.tertiary).font(.caption)
                            .opacity(vm.degradedCount > 0 ? 1 : 0)
                        Label("\(vm.degradedCount) degraded", systemImage: "circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .labelStyle(CompactLabelStyle())
                            .opacity(vm.degradedCount > 0 ? 1 : 0)
                        Text("\u{00b7}").foregroundStyle(.tertiary).font(.caption)
                            .opacity(vm.offlineCount > 0 ? 1 : 0)
                        Label("\(vm.offlineCount) offline", systemImage: "circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                            .labelStyle(CompactLabelStyle())
                            .opacity(vm.offlineCount > 0 ? 1 : 0)
                    }
                }

                Spacer()

                // Always reserve space for the timestamp so the section never changes height
                VStack(alignment: .trailing, spacing: 2) {
                    Text("checked")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    if let date = vm.lastRefreshed {
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    } else {
                        Text("–")
                            .font(.caption)
                            .foregroundStyle(.clear)
                    }
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Overall Health")
        }
    }

    // MARK: - Services (grouped or flat)

    @ViewBuilder
    private var servicesSection: some View {
        if vm.services.isEmpty {
            Section {
                emptyState
            }
        } else if vm.filteredServices.isEmpty {
            Section {
                ContentUnavailableView.search(text: vm.searchText)
            }
        } else if !vm.searchText.isEmpty || vm.statusFilter != nil || vm.groups.isEmpty {
            // Search / filter active, or no groups defined: flat list under one header
            serviceRows(for: vm.filteredServices, header: "Services")
        } else {
            // Grouped view
            let ungrouped = vm.filteredServices.filter { $0.group == nil || $0.group!.isEmpty }
            ForEach(vm.groups, id: \.self) { group in
                let inGroup = vm.filteredServices.filter { $0.group == group }
                if !inGroup.isEmpty {
                    serviceRows(for: inGroup, header: group)
                }
            }
            if !ungrouped.isEmpty {
                serviceRows(for: ungrouped, header: vm.groups.isEmpty ? "Services" : "Other")
            }
        }
    }

    private func serviceRows(for list: [Service], header: String) -> some View {
        Section {
            ForEach(list) { service in
                Button {
                    detailService = service
                } label: {
                    ServiceRowView(
                        service: service,
                        metrics: vm.metrics[service.id] ?? [],
                        effectiveStatus: vm.effectiveStatus(for: service),
                        liveLatencyMs: vm.liveData[service.id]?.latencyMs,
                        liveHttpStatusCode: vm.liveData[service.id]?.httpStatusCode,
                        liveLastChecked: vm.liveData[service.id]?.lastChecked
                    )
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        serviceToDelete = service
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editingService = service
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        Task { await vm.checkAndFetch(service) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .tint(.green)
                }
                .contextMenu {
                    Button {
                        editingService = service
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button {
                        vm.duplicateService(service)
                    } label: {
                        Label("Duplicate", systemImage: "doc.on.doc")
                    }
                    Button {
                        Task { await vm.checkAndFetch(service) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    Button(role: .destructive) {
                        serviceToDelete = service
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onMove { indices, dest in
                // onMove in a grouped section: map back to vm.services indices
                let ids = list.map(\.id)
                let sourceIDs = indices.map { ids[$0] }
                let destID = dest < ids.count ? ids[dest] : nil
                vm.moveServices(sourceIDs: sourceIDs, before: destID)
            }
        } header: {
            Text(header)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            VStack(spacing: 8) {
                Text("No Services Yet")
                    .font(.title3.bold())

                (Text("Tap ") + Text(Image(systemName: "plus")) + Text(" to add your first service."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
    }
}
