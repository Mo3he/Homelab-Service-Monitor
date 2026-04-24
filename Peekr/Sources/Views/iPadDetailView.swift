import SwiftUI

/// Persistent detail panel used in the iPad split view.
/// Unlike ServiceDetailView it has no dismiss button - it lives in the middle column.
struct iPadDetailView: View {
    let serviceID: UUID
    @ObservedObject var vm: HomeViewModel

    @Environment(\.openURL) private var openURL
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
        Group {
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
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 16) {
                            if let url = service.url {
                                Button { openURL(url) } label: {
                                    Label("Open", systemImage: "safari")
                                }
                            }
                            Button { editingService = service } label: {
                                Image(systemName: "pencil")
                            }
                            Button {
                                Task { await vm.checkAndFetch(service) }
                            } label: {
                                if vm.checkingIDs.contains(serviceID) {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                        }
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
                    Text(effectiveStatus.label).font(.headline)
                    HStack(spacing: 6) {
                        Text(service.displayURL).font(.caption).foregroundStyle(.secondary)
                        if service.isLocalNetwork {
                            Label("Local", systemImage: "wifi")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                if let latency = service.latencyMs {
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.0f ms", latency))
                            .font(.title3.bold().monospacedDigit())
                        Text("latency").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            if let code = service.httpStatusCode {
                LabeledContent("HTTP Status", value: "\(code)")
            }
            if let date = service.lastChecked {
                LabeledContent("Last checked") {
                    Text(date, style: .relative).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var sparklineSection: some View {
        if history.count >= 2 {
            Section("Latency Trend") {
                SparklineView(snapshots: history, height: 40).padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var uptimeSection: some View {
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

    private func uptimeRow(label: String, percent: Double) -> some View {
        let color: Color = percent >= 99 ? .green : percent >= 95 ? .orange : .red
        return LabeledContent(label) {
            Text(String(format: "%.1f%%", percent)).foregroundStyle(color).monospacedDigit()
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        if !metrics.isEmpty {
            Section("Live Metrics") {
                ForEach(metrics) { metric in
                    HStack {
                        Image(systemName: metric.icon).foregroundStyle(metric.color).frame(width: 24)
                        Text(metric.label).foregroundStyle(metric.isAlert ? metric.color : .primary)
                        Spacer()
                        Text(metric.value)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(metric.isAlert ? metric.color : .secondary)
                    }
                }
                .onMove { vm.moveMetrics(for: serviceID, from: $0, to: $1) }
            }
        } else if let error = metricsError {
            Section("Live Metrics") {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            Section("Recent Checks") {
                ForEach(history.prefix(10)) { snap in
                    HStack {
                        Image(systemName: snap.status.icon).foregroundStyle(snap.status.color).frame(width: 20)
                        Text(snap.status.label).font(.subheadline)
                        Spacer()
                        if let ms = snap.latencyMs {
                            Text(String(format: "%.0f ms", ms))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(snap.timestamp, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
