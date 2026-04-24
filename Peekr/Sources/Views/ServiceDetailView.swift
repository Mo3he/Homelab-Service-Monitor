import SwiftUI

struct ServiceDetailView: View {
    let serviceID: UUID
    @ObservedObject var vm: HomeViewModel

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var editingService: Service?

    private var service: Service? { vm.services.first { $0.id == serviceID } }
    private var metrics: [ServiceMetric] { vm.metrics[serviceID] ?? [] }
    private var metricsError: String? { vm.metricsError[serviceID] }
    private var effectiveStatus: ServiceStatus {
        guard let service else { return .unknown }
        return vm.effectiveStatus(for: service)
    }
    private var history: [StatusSnapshot] {
        StatusHistoryStore.shared.snapshots(for: serviceID)
    }

    var body: some View {
        NavigationStack {
            if let service {
                List {
                    statusSection(service: service)
                    sparklineSection
                    uptimeSection
                    metricsSection
                    historySection
                }
                .environment(\.editMode, .constant(.active))
                .refreshable { await vm.checkAndFetch(service) }
                .listStyle(.insetGrouped)
                .navigationTitle(service.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if let url = service.url {
                            Button { openURL(url) } label: {
                                Label("Open", systemImage: "safari")
                            }
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            Task { await vm.checkAndFetch(service) }
                        } label: {
                            if vm.checkingIDs.contains(serviceID) {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        Button {
                            editingService = service
                        } label: {
                            Image(systemName: "pencil")
                        }
                        Button("Close") { dismiss() }
                    }
                }
                .sheet(item: $editingService) { svc in
                    AddServiceView(existing: svc) { vm.updateService($0) }
                }
            }
        }
    }

    private func statusSection(service: Service) -> some View {
        Section("Status") {
            HStack(spacing: 14) {
                StatusIndicatorView(status: effectiveStatus, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(effectiveStatus.label)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(service.displayURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if service.isLocalNetwork {
                            Label("Local", systemImage: "wifi")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                Spacer()
                if !service.serviceType.isCloudService, let latency = service.latencyMs {
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.0f ms", latency))
                            .font(.title3.bold().monospacedDigit())
                        Text("latency")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            if !service.serviceType.isCloudService, let code = service.httpStatusCode {
                LabeledContent("HTTP Status", value: "\(code)")
            }
            if let date = service.lastChecked {
                LabeledContent("Last checked") {
                    Text(date, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var sparklineSection: some View {
        if let service, !service.serviceType.isCloudService, history.count >= 2 {
            Section("Latency Trend") {
                SparklineView(snapshots: history, height: 40)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var uptimeSection: some View {
        if let service, !service.serviceType.isCloudService {
            let u24 = UptimeStore.shared.uptimePercent(for: serviceID, days: 1)
            let u7  = UptimeStore.shared.uptimePercent(for: serviceID, days: 7)
            let u30 = UptimeStore.shared.uptimePercent(for: serviceID, days: 30)
            if u24 != nil || u7 != nil || u30 != nil {
                Section("Uptime") {
                    if let v = u24 { uptimeRow(label: "24 hours", percent: v) }
                    if let v = u7  { uptimeRow(label: "7 days",   percent: v) }
                    if let v = u30 { uptimeRow(label: "30 days",  percent: v) }
                }
            }
        }
    }

    private func uptimeRow(label: String, percent: Double) -> some View {
        let color: Color = percent >= 99 ? .green : percent >= 95 ? .orange : .red
        return LabeledContent(label) {
            Text(String(format: "%.1f%%", percent)).foregroundStyle(color).monospacedDigit()
        }
    }

    private var visibleMetrics: [ServiceMetric] { vm.visibleMetrics(for: serviceID) }
    private var hiddenMetricItems: [ServiceMetric] { vm.hiddenMetricItems(for: serviceID) }

    @ViewBuilder
    private var metricsSection: some View {
        if !metrics.isEmpty || metricsError != nil {
            Section("Live Metrics") {
                ForEach(visibleMetrics) { metric in
                    HStack {
                        Image(systemName: metric.icon)
                            .foregroundStyle(metric.color)
                            .frame(width: 24)
                        Text(metric.label)
                            .foregroundStyle(metric.isAlert ? metric.color : .primary)
                        Spacer()
                        Text(metric.value)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(metric.isAlert ? metric.color : .secondary)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            vm.setMetricHidden(true, serviceID: serviceID, label: metric.label)
                        } label: {
                            Label("Hide Metric", systemImage: "eye.slash")
                        }
                    }
                }
                .onMove { vm.moveMetrics(for: serviceID, from: $0, to: $1) }

                if let error = metricsError, visibleMetrics.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if !hiddenMetricItems.isEmpty {
            Section {
                ForEach(hiddenMetricItems) { metric in
                    HStack {
                        Image(systemName: metric.icon)
                            .foregroundStyle(metric.color.opacity(0.4))
                            .frame(width: 24)
                        Text(metric.label)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            vm.setMetricHidden(false, serviceID: serviceID, label: metric.label)
                        } label: {
                            Image(systemName: "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Hidden Metrics")
            } footer: {
                Text("Tap the eye icon or long-press a metric to manage visibility.")
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            Section("Recent Checks") {
                ForEach(history.prefix(10)) { snap in
                    HStack {
                        Image(systemName: snap.status.icon)
                            .foregroundStyle(snap.status.color)
                            .frame(width: 20)
                        Text(snap.status.label)
                            .font(.subheadline)
                        Spacer()
                        if let ms = snap.latencyMs {
                            Text(String(format: "%.0f ms", ms))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(snap.timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
