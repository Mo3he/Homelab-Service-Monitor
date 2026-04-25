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
    @EnvironmentObject private var vm: HomeViewModel
    @ObservedObject private var network = NetworkMonitor.shared
    @State private var addServiceRequest: AddServiceItem? = nil
    @State private var editingService: Service?
    @State private var detailService: Service?
    @State private var serviceToDelete: Service?
    @State private var showServicePicker = false
    @State private var hasAppeared = false

    @State private var showOverallHealth = false
    @State private var isReordering = false
    @State private var isSearchActive = false
    // scrollPosition removed - List naturally preserves scroll when ForEach identity is stable
    @AppStorage("autoRefreshInterval") private var refreshInterval: Double = 30

    var body: some View {
        NavigationStack {
            serviceList
                .navigationTitle("Peekr")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !isSearchActive {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { isSearchActive = true } label: {
                                Image(systemName: "magnifyingglass")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showServicePicker = true } label: {
                            Image(systemName: "plus")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }
                .sheet(item: $addServiceRequest) { req in
                    AddServiceView(serviceType: req.serviceType) { vm.addService($0) }
                }
                .sheet(isPresented: $showServicePicker) {
                    ServicePickerView { type in
                        addServiceRequest = AddServiceItem(serviceType: type)
                    }
                }
                .sheet(item: $editingService) { service in
                    AddServiceView(existing: service) { vm.updateService($0) }
                }
                .sheet(item: $detailService) { service in
                    ServiceDetailView(serviceID: service.id, vm: vm)
                }
                .sheet(isPresented: $showOverallHealth) {
                    OverallHealthView(vm: vm)
                }
                .alert(
                    "Delete \(serviceToDelete?.name ?? "service")?",
                    isPresented: .init(
                        get: { serviceToDelete != nil },
                        set: { if !$0 { serviceToDelete = nil } }
                    )
                ) {
                    Button("Delete", role: .destructive) {
                        if let svc = serviceToDelete {
                            vm.removeService(svc)
                        }
                        serviceToDelete = nil
                    }
                    Button("Cancel", role: .cancel) { serviceToDelete = nil }
                } message: {
                    Text("This service and its history will be removed.")
                }
                .onAppear {
                    if !hasAppeared {
                        hasAppeared = true
                        vm.refreshAll()
                    }
                    vm.startAutoRefresh()
                }
                .onDisappear {
                    vm.stopAutoRefresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    vm.stopAutoRefresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    guard hasAppeared else { return }
                    vm.startAutoRefresh()
                }
                .onChange(of: refreshInterval) { _, _ in
                    vm.startAutoRefresh()
                }
                .onChange(of: isReordering) { _, reordering in
                    if reordering {
                        vm.stopAutoRefresh()
                    } else {
                        vm.startAutoRefresh()
                    }
                }
        }
    }

    @ViewBuilder
    private var serviceList: some View {
        if isSearchActive {
            List {
                if !network.canReachLocal && vm.services.contains(where: \.isLocalNetwork) {
                    networkBanner
                }
                if !vm.services.isEmpty {
                    overallStatusSection
                }
                servicesSection
            }
            .environment(\.editMode, .constant(isReordering ? .active : .inactive))
            .listStyle(.insetGrouped)
            .searchable(text: $vm.searchText, isPresented: $isSearchActive, prompt: "Search services")
            .refreshable { vm.refreshAll() }
        } else {
            List {
                if !network.canReachLocal && vm.services.contains(where: \.isLocalNetwork) {
                    networkBanner
                }
                if !vm.services.isEmpty {
                    overallStatusSection
                }
                servicesSection
            }
            .environment(\.editMode, .constant(isReordering ? .active : .inactive))
            .listStyle(.insetGrouped)
            .refreshable { vm.refreshAll() }
            .onChange(of: vm.searchText) { _, _ in vm.searchText = "" }
        }
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

    // Delegate to a separate struct that observes LiveDataStore.
    // This way live data changes never cause HomeView body (and the List) to re-evaluate.
    private var overallStatusSection: some View {
        OverallStatusSection(vm: vm, onTap: { showOverallHealth = true })
    }

    // MARK: - Services (grouped or flat)

    @ViewBuilder
    private var servicesSection: some View {
        if isReordering {
            ReorderServicesSection(services: vm.services, isReordering: $isReordering) { ordered in
                vm.applyReorder(ordered)
            }
        } else if vm.services.isEmpty {
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
                ServiceRowView(service: service)
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
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
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                Text(header)
                if !vm.services.isEmpty {
                    HStack(spacing: 8) {
                        filterChip(label: "All", filter: nil)
                        filterChip(label: "Online", filter: .online)
                        filterChip(label: "Degraded", filter: .degraded)
                        filterChip(label: "Offline", filter: .offline)
                        Spacer()
                        Button("Reorder") {
                            withAnimation { isReordering = true }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }
            .textCase(nil)
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

                Text("Add a service to start monitoring your homelab and cloud APIs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showServicePicker = true
            } label: {
                Label("Add Your First Service", systemImage: "plus.circle.fill")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
    }
}

/// Isolated view that observes LiveDataStore for live counts and health status.
/// By putting this in its own struct, only THIS view re-renders on live data changes,
/// not the parent HomeView that owns the List.
private struct OverallStatusSection: View {
    let vm: HomeViewModel
    let onTap: () -> Void
    @ObservedObject private var live = LiveDataStore.shared

    private var onlineCount: Int   { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .online   }.count }
    private var degradedCount: Int { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .degraded }.count }
    private var offlineCount: Int  { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .offline  }.count }
    private var overallHealth: ServiceStatus {
        if vm.services.isEmpty { return .unknown }
        if vm.isRefreshing { return .checking }
        let statuses = vm.services.map { live.liveData[$0.id]?.status ?? $0.status }
        if statuses.allSatisfy({ $0 == .online }) { return .online }
        if statuses.contains(.offline) { return .offline }
        if statuses.contains(.degraded) { return .degraded }
        return .unknown
    }

    var body: some View {
        Section {
            Button(action: onTap) {
                HStack(spacing: 16) {
                    StatusIndicatorView(status: overallHealth, size: 50)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(overallHealth.label)
                            .font(.title3.bold())

                        HStack(spacing: 6) {
                            Label("\(onlineCount) online", systemImage: "circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                                .labelStyle(CompactLabelStyle())
                                .fixedSize()
                            if degradedCount > 0 {
                                Text("\u{00b7}").foregroundStyle(.tertiary).font(.caption)
                                Label("\(degradedCount) degraded", systemImage: "circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                                    .labelStyle(CompactLabelStyle())
                                    .fixedSize()
                            }
                            if offlineCount > 0 {
                                Text("\u{00b7}").foregroundStyle(.tertiary).font(.caption)
                                Label("\(offlineCount) offline", systemImage: "circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.red)
                                    .labelStyle(CompactLabelStyle())
                                    .fixedSize()
                            }
                        }
                    }

                    Spacer()

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
                            Text("\u{2013}")
                                .font(.caption)
                                .foregroundStyle(.clear)
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        } header: {
            Text("Overall Health")
        }
    }
}

// MARK: - Reorder Section (isolated child view)
/// Keeps the reorder buffer as local @State so onMove mutations only re-render
/// this view, not HomeView - preventing the drag handle from flickering.
private struct ReorderServicesSection: View {
    @Binding var isReordering: Bool
    let onCommit: ([Service]) -> Void
    @State private var buffer: [Service]

    init(services: [Service], isReordering: Binding<Bool>, onCommit: @escaping ([Service]) -> Void) {
        _isReordering = isReordering
        _buffer = State(initialValue: services)
        self.onCommit = onCommit
    }

    var body: some View {
        Section {
            ForEach(buffer) { service in
                HStack(spacing: 14) {
                    Image(systemName: service.icon)
                        .foregroundStyle(service.status.color)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name)
                            .font(.body.weight(.semibold))
                        Text(service.displayURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .onMove { src, dst in
                buffer.move(fromOffsets: src, toOffset: dst)
            }
        } header: {
            HStack {
                Text("Services")
                Spacer()
                Button("Done") {
                    onCommit(buffer)
                    isReordering = false
                }
                .font(.caption)
                .textCase(nil)
            }
        }
    }
}
