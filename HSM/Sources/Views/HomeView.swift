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

    fileprivate enum ReorderMode { case none, services, groups }

    @State private var showOverallHealth = false
    @State private var reorderMode: ReorderMode = .none
    @State private var isSearchActive = false
    @FocusState private var searchFocused: Bool
    // scrollPosition removed - List naturally preserves scroll when ForEach identity is stable
    @AppStorage("autoRefreshInterval") private var refreshInterval: Double = 30

    var body: some View {
        NavigationStack {
            serviceList
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            isSearchActive.toggle()
                            if isSearchActive {
                                searchFocused = true
                            } else {
                                vm.searchText = ""
                            }
                        } label: {
                            Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                        }
                        Spacer()
                        Button { showServicePicker = true } label: {
                            Image(systemName: "plus")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }
                .sheet(item: $addServiceRequest) { req in
                    AddServiceView(serviceType: req.serviceType,
                                   prefilledHost: req.prefilledHost,
                                   prefilledPort: req.prefilledPort) { vm.addService($0) }
                }
                .sheet(isPresented: $showServicePicker) {
                    ServicePickerView { type, host, port in
                        addServiceRequest = AddServiceItem(serviceType: type,
                                                          prefilledHost: host,
                                                          prefilledPort: port)
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
                .onChange(of: reorderMode) { _, mode in
                    if mode != .none {
                        vm.stopAutoRefresh()
                    } else {
                        vm.startAutoRefresh()
                    }
                }
        }
    }

    @ViewBuilder
    private var serviceList: some View {
        List {
            if !network.isConnected {
                noInternetBanner
            } else if !network.canReachLocal && vm.services.contains(where: \.isLocalNetwork) {
                networkBanner
            }
            if isSearchActive {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search services", text: $vm.searchText)
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .onSubmit { searchFocused = false }
                        if !vm.searchText.isEmpty {
                            Button { vm.searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Button("Cancel") {
                            isSearchActive = false
                            vm.searchText = ""
                            searchFocused = false
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            if !vm.services.isEmpty {
                overallStatusSection
            }
            servicesSection
        }
        .environment(\.editMode, .constant(reorderMode != .none ? .active : .inactive))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color(.systemGroupedBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .refreshable { vm.refreshAll() }
    }

    // MARK: - Network Banner

    private var noInternetBanner: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Internet Connection")
                        .font(.subheadline.bold())
                    Text("All service checks are paused. Shown status is from the last successful check.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

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
                    Button("Refresh anyway") {
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
        if reorderMode == .services {
            let hasUngrouped = vm.services.contains { $0.group == nil || $0.group!.isEmpty }
            ReorderServicesSection(
                services: vm.services,
                displayGroupOrder: vm.displayGroupOrder(hasOther: hasUngrouped),
                reorderMode: $reorderMode
            ) { ordered in
                vm.applyReorder(ordered)
            }
        } else if reorderMode == .groups {
            let hasUngrouped = vm.services.contains { $0.group == nil || $0.group!.isEmpty }
            ReorderGroupsSection(
                groups: vm.displayGroupOrder(hasOther: hasUngrouped),
                reorderMode: $reorderMode
            ) { orderedGroups in
                vm.setGroupOrder(orderedGroups)
            }
        } else if vm.services.isEmpty {
            Section {
                emptyState
            }
        } else if vm.filteredServices.isEmpty {
            Section {
                if vm.searchText.isEmpty {
                    ContentUnavailableView(
                        "No \(vm.statusFilter?.label ?? "Services") Found",
                        systemImage: vm.statusFilter?.icon ?? "magnifyingglass",
                        description: Text("No services match this filter.")
                    )
                } else {
                    ContentUnavailableView.search(text: vm.searchText)
                }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Services")
                    HStack(spacing: 8) {
                        filterChip(label: "All", filter: nil)
                        filterChip(label: "Online", filter: .online)
                        filterChip(label: "Degraded", filter: .degraded)
                        filterChip(label: "Offline", filter: .offline)
                        Spacer()
                    }
                }
                .textCase(nil)
            }
        } else if !vm.searchText.isEmpty || vm.statusFilter != nil || vm.groups.isEmpty {
            // Search / filter active, or no groups defined: flat list under one header
            serviceRows(for: vm.filteredServices, header: "Services")
        } else {
            // Grouped view
            let ungrouped = vm.filteredServices.filter { $0.group == nil || $0.group!.isEmpty }
            let displayOrder = vm.displayGroupOrder(hasOther: !ungrouped.isEmpty)
            ForEach(displayOrder, id: \.self) { entry in
                if entry == HomeViewModel.otherSentinel {
                    if !ungrouped.isEmpty {
                        serviceRows(for: ungrouped, header: "Other")
                    }
                } else {
                    let inGroup = vm.filteredServices.filter { $0.group == entry }
                    if !inGroup.isEmpty {
                        serviceRows(for: inGroup, header: entry)
                    }
                }
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
                        Menu {
                            Button {
                                withAnimation { reorderMode = .services }
                            } label: {
                                Label("Reorder Services", systemImage: "arrow.up.arrow.down")
                            }
                            let hasUngroupedForMenu = vm.services.contains { $0.group == nil || $0.group!.isEmpty }
                            let totalGroupSections = vm.groups.count + (hasUngroupedForMenu ? 1 : 0)
                            if totalGroupSections >= 2 {
                                Button {
                                    withAnimation { reorderMode = .groups }
                                } label: {
                                    Label("Reorder Groups", systemImage: "folder")
                                }
                            }
                        } label: {
                            Text("Reorder")
                                .font(.caption)
                                .textCase(nil)
                        }
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

    var body: some View {
        Section {
            Button(action: onTap) {
                OverallStatusContent(vm: vm)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        } header: {
            Text("Overall Health")
        }
    }
}

/// Isolated content view so LiveDataStore changes don't cause the parent List to re-layout.
private struct OverallStatusContent: View {
    let vm: HomeViewModel
    @ObservedObject private var live = LiveDataStore.shared

    private var onlineCount: Int   { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .online   }.count }
    private var degradedCount: Int { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .degraded }.count }
    private var offlineCount: Int  { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .offline  }.count }
    private var overallHealth: ServiceStatus {
        if vm.services.isEmpty { return .unknown }
        if vm.isRefreshing { return .checking }
        let statuses = vm.services.map { live.effectiveStatus(for: $0) }
        let known = statuses.filter { $0 != .unknown && $0 != .checking }
        guard !known.isEmpty else { return .unknown }
        if known.allSatisfy({ $0 == .online }) { return .online }
        if known.contains(.offline) { return .offline }
        if known.contains(.degraded) { return .degraded }
        return .unknown
    }

    var body: some View {
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
                Text("refreshed")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                if let date = live.lastRefreshed {
                    RelativeTimestamp(date: date)
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
        .padding(.horizontal, 12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [overallHealth.color.opacity(0.12), overallHealth.color.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
            .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [overallHealth.color.opacity(0.3), .white.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        )
        .foregroundStyle(.primary)
    }
}

/// Displays a relative timestamp that updates on a 60-second timer instead of
/// using `Text(date, style: .relative)` which can cause parent List layout passes.
private struct RelativeTimestamp: View {
    let date: Date
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(date, style: .relative)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .id(Int(now.timeIntervalSince1970) / 60)
            .onReceive(timer) { now = $0 }
    }
}

// MARK: - Reorder sections (isolated child views so onMove mutations don't re-render HomeView)

private struct ReorderServicesSection: View {
    @Binding var reorderMode: HomeView.ReorderMode
    let onCommit: ([Service]) -> Void
    let displayGroupOrder: [String]
    @State private var flatBuffer: [Service]
    @State private var groupBuffers: [(key: String, label: String, services: [Service])]

    init(services: [Service], displayGroupOrder: [String],
         reorderMode: Binding<HomeView.ReorderMode>,
         onCommit: @escaping ([Service]) -> Void) {
        _reorderMode = reorderMode
        self.onCommit = onCommit
        self.displayGroupOrder = displayGroupOrder
        if displayGroupOrder.isEmpty {
            _flatBuffer    = State(initialValue: services)
            _groupBuffers  = State(initialValue: [])
        } else {
            _flatBuffer = State(initialValue: [])
            _groupBuffers = State(initialValue: displayGroupOrder.map { key in
                let label = key == HomeViewModel.otherSentinel ? "Other" : key
                let grouped: [Service] = key == HomeViewModel.otherSentinel
                    ? services.filter { $0.group == nil || $0.group!.isEmpty }
                    : services.filter { $0.group == key }
                return (key: key, label: label, services: grouped)
            })
        }
    }

    var body: some View {
        if displayGroupOrder.isEmpty {
            Section {
                ForEach(flatBuffer) { service in serviceRow(service) }
                    .onMove { src, dst in flatBuffer.move(fromOffsets: src, toOffset: dst) }
            } header: {
                sectionHeader("Services")
            }
        } else {
            ForEach(groupBuffers.indices, id: \.self) { idx in
                Section {
                    ForEach(groupBuffers[idx].services) { service in serviceRow(service) }
                        .onMove { src, dst in groupBuffers[idx].services.move(fromOffsets: src, toOffset: dst) }
                } header: {
                    if idx == 0 { sectionHeader(groupBuffers[idx].label) }
                    else { Text(groupBuffers[idx].label) }
                }
            }
        }
    }

    private func serviceRow(_ service: Service) -> some View {
        HStack(spacing: 14) {
            Image(systemName: service.icon)
                .foregroundStyle(service.status.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.body.weight(.semibold))
                Text(service.friendlyDisplayURL).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Done") {
                let result = displayGroupOrder.isEmpty
                    ? flatBuffer
                    : groupBuffers.flatMap { $0.services }
                onCommit(result)
                reorderMode = .none
            }
            .font(.caption)
            .textCase(nil)
        }
    }
}

private struct ReorderGroupsSection: View {
    @Binding var reorderMode: HomeView.ReorderMode
    let onCommit: ([String]) -> Void
    @State private var buffer: [String]

    init(groups: [String], reorderMode: Binding<HomeView.ReorderMode>,
         onCommit: @escaping ([String]) -> Void) {
        _reorderMode = reorderMode
        _buffer      = State(initialValue: groups)
        self.onCommit = onCommit
    }

    var body: some View {
        Section {
            ForEach(buffer, id: \.self) { group in
                let isOther = group == HomeViewModel.otherSentinel
                HStack(spacing: 14) {
                    Image(systemName: isOther ? "tray.fill" : "folder.fill")
                        .foregroundStyle(isOther ? Color.secondary : Color.accentColor)
                        .frame(width: 28)
                    Text(isOther ? "Other" : group)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isOther ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .onMove { src, dst in buffer.move(fromOffsets: src, toOffset: dst) }
        } header: {
            HStack {
                Text("Groups")
                Spacer()
                Button("Done") {
                    onCommit(buffer)
                    reorderMode = .none
                }
                .font(.caption)
                .textCase(nil)
            }
        }
    }
}
