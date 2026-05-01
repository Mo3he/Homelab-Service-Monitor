import SwiftUI

/// Full-detail view opened when tapping a summary notification.
/// Shows live status and all metrics for every service in the schedule.
struct SummaryDetailView: View {
    let schedule: MetricSummarySchedule

    @EnvironmentObject private var vm: HomeViewModel
    @ObservedObject private var live = LiveDataStore.shared
    @Environment(\.dismiss) private var dismiss

    private var services: [Service] {
        schedule.serviceIDs.compactMap { id in vm.services.first { $0.id == id } }
    }

    private var isRefreshing: Bool {
        services.contains { live.checkingIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if services.isEmpty {
                    ContentUnavailableView(
                        "Services not found",
                        systemImage: "questionmark.circle",
                        description: Text("The services in this summary may have been removed.")
                    )
                } else {
                    ForEach(services) { service in
                        serviceSection(service)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(schedule.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            for service in services {
                                await vm.checkAndFetch(service)
                            }
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                }
            }
            .onAppear {
                // Trigger a refresh so the user sees fresh data immediately
                Task {
                    for service in services {
                        await vm.checkAndFetch(service)
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private func serviceSection(_ service: Service) -> some View {
        let status = live.effectiveStatus(for: service)
        let metrics = live.metrics[service.id] ?? []
        let checking = live.checkingIDs.contains(service.id)

        return Section {
            // Status row
            HStack(spacing: 12) {
                if checking {
                    ProgressView().frame(width: 32, height: 32)
                } else {
                    StatusIndicatorView(status: status, size: 32)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(checking ? "Refreshing..." : status.label)
                        .font(.headline)
                    if let lastChecked = live.liveData[service.id]?.lastChecked ?? service.lastChecked {
                        (Text("Refreshed ") + Text(lastChecked, style: .relative) + Text(" ago"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let latency = live.liveData[service.id]?.latencyMs ?? service.latencyMs,
                   !service.serviceType.isCloudService {
                    Text(String(format: "%.0f ms", latency))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            if metrics.isEmpty && !checking {
                Text("No metrics available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(metrics) { metric in
                    metricRow(metric)
                }
            }
        } header: {
            Text(service.name)
        }
    }

    private func metricRow(_ metric: ServiceMetric) -> some View {
        HStack(spacing: 10) {
            Image(systemName: metric.icon)
                .foregroundStyle(metric.color)
                .frame(width: 22)
            Text(metric.label)
                .font(.subheadline)
            Spacer()
            Text(metric.value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(metric.isAlert ? .orange : .secondary)
            if metric.isAlert {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
