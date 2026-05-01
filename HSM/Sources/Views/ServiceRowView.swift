import SwiftUI

struct ServiceRowView: View {
    let service: Service
    @ObservedObject private var live = LiveDataStore.shared

    private var liveEntry: ServiceLiveData? { live.liveData[service.id] }
    private var metrics: [ServiceMetric] { live.visibleMetrics(for: service.id) }
    private var effectiveStatus: ServiceStatus { live.effectiveStatus(for: service) }

    private var displayLatency: Double?     { liveEntry?.latencyMs      ?? service.latencyMs }
    private var displayCode: Int?           { liveEntry?.httpStatusCode  ?? service.httpStatusCode }
    private var displayLastChecked: Date?   { liveEntry?.lastChecked     ?? service.lastChecked }
    private var displayURL: String {
        if liveEntry?.usingFailover == true, let fu = service.failoverDisplayURL { return fu }
        return service.friendlyDisplayURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                serviceIcon
                serviceInfo
                Spacer(minLength: 8)
                latencyBadge
            }

            // Always reserve height for services with integrations so rows don't jump when metrics load
            if service.serviceType != .generic {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(metrics) { metric in
                            MetricChip(metric: metric)
                        }
                    }
                }
                .frame(height: 26)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
    }

    // MARK: - Subviews

    private var serviceIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(effectiveStatus == .unknown
                          ? Color(.systemFill)
                          : effectiveStatus.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: service.icon)
                    .foregroundStyle(effectiveStatus == .unknown ? .secondary : effectiveStatus.color)
                    .font(.system(size: 18, weight: .medium))
            }

            if effectiveStatus != .unknown {
                Circle()
                    .fill(effectiveStatus.color)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var serviceInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(service.name)
                .font(.body.weight(.semibold))
                .lineLimit(1)
            if let code = displayCode, !(200..<300).contains(code) {
                Text("HTTP \(code) · \(displayURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(displayURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var latencyBadge: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let latency = displayLatency {
                Text(String(format: "%.0f ms", latency))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(latencyColor(latency))
            }
            if let date = displayLastChecked {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func latencyColor(_ ms: Double) -> Color {
        switch ms {
        case ..<100: return .green
        case ..<300: return .orange
        default:     return .red
        }
    }
}

// MARK: - Metric Chip

/// Static version of ServiceRowView with zero observers - safe to use in reorder mode.
/// Reads directly from `service` so LiveDataStore publishing never invalidates it.
struct ReorderRowView: View {
    let service: Service

    private var status: ServiceStatus { service.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                // Icon
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(status == .unknown
                                  ? Color(.systemFill)
                                  : status.color.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: service.icon)
                            .foregroundStyle(status == .unknown ? .secondary : status.color)
                            .font(.system(size: 18, weight: .medium))
                    }
                    if status != .unknown {
                        Circle()
                            .fill(status.color)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                }
                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if let code = service.httpStatusCode, !(200..<300).contains(code) {
                        Text("HTTP \(code) · \(service.friendlyDisplayURL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(service.friendlyDisplayURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                // Latency
                if let latency = service.latencyMs {
                    Text(String(format: "%.0f ms", latency))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(latencyColor(latency))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
    }

    private func latencyColor(_ ms: Double) -> Color {
        switch ms {
        case ..<100: return .green
        case ..<300: return .orange
        default:     return .red
        }
    }
}

// MARK: - Metric Chip

struct MetricChip: View {
    let metric: ServiceMetric

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: metric.icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(metric.color)
            Text(metric.value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(metric.isAlert ? metric.color : .primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(Color(.tertiarySystemFill))
                .overlay(Capsule().fill(metric.color.opacity(0.08)))
        }
        .overlay(Capsule().stroke(metric.color.opacity(0.25), lineWidth: 0.5))
    }
}
