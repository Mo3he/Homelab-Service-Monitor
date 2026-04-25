import SwiftUI

struct OverallHealthView: View {
    let vm: HomeViewModel
    @ObservedObject private var live = LiveDataStore.shared
    @Environment(\.dismiss) private var dismiss

    private var online:   [Service] { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .online   } }
    private var degraded: [Service] { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .degraded } }
    private var offline:  [Service] { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .offline  } }
    private var unknown:  [Service] { vm.services.filter { (live.liveData[$0.id]?.status ?? $0.status) == .unknown  } }
    private var total:    Int       { vm.services.count }

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
        NavigationStack {
            List {
                summarySection
                if !offline.isEmpty  { statusSection(services: offline,  status: .offline)  }
                if !degraded.isEmpty { statusSection(services: degraded, status: .degraded) }
                if !online.isEmpty   { statusSection(services: online,   status: .online)   }
                if !unknown.isEmpty  { statusSection(services: unknown,  status: .unknown)  }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("System Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Summary card

    private var summarySection: some View {
        Section {
            VStack(spacing: 20) {
                HStack(spacing: 16) {
                    StatusIndicatorView(status: overallHealth, size: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(overallHealth.label)
                            .font(.title2.bold())
                        if let date = vm.lastRefreshed {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2)
                                Text(date, style: .relative)
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }

                // Progress bar breakdown
                if total > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 3) {
                            bar(count: online.count,   total: total, color: .green,  width: geo.size.width)
                            bar(count: degraded.count, total: total, color: .orange, width: geo.size.width)
                            bar(count: offline.count,  total: total, color: .red,    width: geo.size.width)
                            if unknown.count > 0 {
                                bar(count: unknown.count, total: total, color: .gray, width: geo.size.width)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .frame(height: 10)
                }

                // Count pills
                HStack(spacing: 10) {
                    pill(count: online.count,   label: "Online",   color: .green)
                    pill(count: degraded.count, label: "Degraded", color: .orange)
                    pill(count: offline.count,  label: "Offline",  color: .red)
                    pill(count: unknown.count,  label: "Unknown",  color: .secondary)
                    Spacer()
                    Text("\(total) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func bar(count: Int, total: Int, color: Color, width: CGFloat) -> some View {
        if count > 0 {
            let w = max(6, CGFloat(count) / CGFloat(total) * width)
            color
                .frame(width: w, height: 10)
        }
    }

    @ViewBuilder
    private func pill(count: Int, label: String, color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text("\(count) \(label)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
            }
        }
    }

    // MARK: - Per-status service list

    private func statusSection(services: [Service], status: ServiceStatus) -> some View {
        Section {
            ForEach(services) { service in
                HStack(spacing: 12) {
                    Image(systemName: service.icon)
                        .foregroundStyle(status.color)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name)
                            .font(.subheadline.weight(.medium))
                        if let group = service.group, !group.isEmpty {
                            Text(group)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if let latency = live.liveData[service.id]?.latencyMs ?? service.latencyMs,
                       status != .offline, !service.serviceType.isCloudService {
                        Text("\(Int(latency)) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: status.icon)
                        .foregroundStyle(status.color)
                        .font(.system(size: 14))
                }
                .padding(.vertical, 2)
            }
        } header: {
            Label("\(services.count) \(status.label)", systemImage: status.icon)
                .foregroundStyle(status.color)
                .font(.caption.weight(.semibold))
        }
    }
}
