import SwiftUI

/// iPad root: sidebar of services + persistent detail panel + event log in a third column.
struct iPadRootView: View {
    @EnvironmentObject private var vm: HomeViewModel
    @ObservedObject private var network = NetworkMonitor.shared
    @State private var selectedServiceID: UUID? = nil
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showSettings = false
    @State private var addServiceRequest: AddServiceItem? = nil
    @State private var editingService: Service?
    @State private var serviceToDelete: Service?
    @State private var showServicePicker = false
    @State private var hasAppeared = false
    // scrollPosition removed - List naturally preserves scroll when ForEach identity is stable
    @AppStorage("autoRefreshInterval") private var refreshInterval: Double = 30

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            detailPanel
        } detail: {
            eventLogPanel
        }
        .sheet(item: $addServiceRequest) { req in
            AddServiceView(serviceType: req.serviceType) { vm.addService($0) }
        }
        .sheet(isPresented: $showServicePicker) {
            ServicePickerView { type in
                addServiceRequest = AddServiceItem(serviceType: type)
            }
        }
        .sheet(item: $editingService) { svc in
            AddServiceView(existing: svc) { vm.updateService($0) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
        }
        .alert(
            "Delete \(serviceToDelete?.name ?? "service")?",
            isPresented: .init(get: { serviceToDelete != nil }, set: { if !$0 { serviceToDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let svc = serviceToDelete { vm.removeService(svc) }
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
        .onDisappear { vm.stopAutoRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            vm.stopAutoRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard hasAppeared else { return }
            vm.startAutoRefresh()
        }
        .onChange(of: refreshInterval) { _, _ in vm.startAutoRefresh() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedServiceID) {
            if !network.canReachLocal && vm.services.contains(where: \.isLocalNetwork) {
                networkBanner
            }
            if !vm.services.isEmpty {
                overallStatusRow
            }
            serviceRows
        }
        .listStyle(.sidebar)
            .searchable(text: $vm.searchText, prompt: "Search services")
        .navigationTitle("Peekr")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 12) {
                    Button { vm.refreshAll() } label: {
                        if vm.isRefreshing { ProgressView().scaleEffect(0.8) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(vm.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showServicePicker = true } label: {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var overallStatusRow: some View {
        iPadOverallStatusRow(vm: vm)
    }

    @ViewBuilder
    private var serviceRows: some View {
        let grouped = !vm.groups.isEmpty && vm.searchText.isEmpty && vm.statusFilter == nil
        if grouped {
            ForEach(vm.groups, id: \.self) { group in
                let inGroup = vm.filteredServices.filter { $0.group == group }
                if !inGroup.isEmpty {
                    Section(group) { rows(for: inGroup) }
                }
            }
            let ungrouped = vm.filteredServices.filter { $0.group == nil || $0.group!.isEmpty }
            if !ungrouped.isEmpty {
                Section("Other") { rows(for: ungrouped) }
            }
        } else {
            Section("Services") { rows(for: vm.filteredServices) }
        }
    }

    private func rows(for list: [Service]) -> some View {
        ForEach(list) { service in
            sidebarRow(service: service)
                .tag(service.id)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { serviceToDelete = service } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button { editingService = service } label: {
                        Label("Edit", systemImage: "pencil")
                    }.tint(.blue)
                }
                .contextMenu {
                    Button { editingService = service } label: { Label("Edit", systemImage: "pencil") }
                    Button { vm.duplicateService(service) } label: { Label("Duplicate", systemImage: "doc.on.doc") }
                    Button { Task { await vm.checkAndFetch(service) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Divider()
                    Button(role: .destructive) { serviceToDelete = service } label: { Label("Delete", systemImage: "trash") }
                }
        }
        .onMove { vm.moveServices(from: $0, to: $1) }
    }

    private func sidebarRow(service: Service) -> some View {
        iPadSidebarRow(service: service)
    }

    @ViewBuilder
    private var networkBanner: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: network.isOnWiFi ? "wifi.exclamationmark" : "wifi.slash")
                    .foregroundStyle(.orange)
                Text(network.isOnWiFi ? "Local services may be unreachable on this WiFi." : "Off WiFi - local services paused.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if network.isOnWiFi {
                    Button("Check") { network.reprobeAndOverride() }
                        .font(.caption.bold()).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    // MARK: - Content (detail)

    @ViewBuilder
    private var detailPanel: some View {
        if let id = selectedServiceID, let service = vm.services.first(where: { $0.id == id }) {
            iPadDetailView(serviceID: id, vm: vm)
                .id(id)
        } else {
            ContentUnavailableView("Select a Service", systemImage: "server.rack", description: Text("Choose a service from the sidebar to see its status and metrics."))
        }
    }

    // MARK: - Detail (event log)

    private var eventLogPanel: some View {
        EventLogView(vm: vm)
    }
}

private struct iPadOverallStatusRow: View {
    let vm: HomeViewModel
    @ObservedObject private var live = LiveDataStore.shared

    private var onlineCount: Int   { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .online   }.count }
    private var offlineCount: Int  { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .offline  }.count }
    private var overallHealth: ServiceStatus {
        if vm.services.isEmpty { return .unknown }
        let statuses = vm.services.map { live.liveData[$0.id]?.status ?? $0.status }
        if statuses.allSatisfy({ $0 == .online }) { return .online }
        if statuses.contains(.offline) { return .offline }
        if statuses.contains(.degraded) { return .degraded }
        return .unknown
    }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                StatusIndicatorView(status: overallHealth, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(overallHealth.label).font(.subheadline.bold())
                    Text("\(onlineCount) online · \(offlineCount) offline")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let date = vm.lastRefreshed {
                    Text(date, style: .relative)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        } header: { Text("Overall Health") }
    }
}

private struct iPadSidebarRow: View {
    let service: Service
    @ObservedObject private var live = LiveDataStore.shared

    var body: some View {
        let status = live.effectiveStatus(for: service)
        let liveMs = live.liveData[service.id]?.latencyMs ?? service.latencyMs
        HStack(spacing: 10) {
            StatusIndicatorView(status: status, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(service.displayURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let ms = liveMs {
                Text(String(format: "%.0f ms", ms))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
