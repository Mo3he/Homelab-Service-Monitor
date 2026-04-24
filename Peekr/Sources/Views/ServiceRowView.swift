import SwiftUI

struct ServiceRowView: View {
    let service: Service
    let metrics: [ServiceMetric]
    var effectiveStatus: ServiceStatus
    /// Live values from HomeViewModel.liveData — take priority over the service struct fields.
    var liveLatencyMs: Double? = nil
    var liveHttpStatusCode: Int? = nil
    var liveLastChecked: Date? = nil

    private var displayLatency: Double?     { liveLatencyMs      ?? service.latencyMs }
    private var displayCode: Int?           { liveHttpStatusCode  ?? service.httpStatusCode }
    private var displayLastChecked: Date?   { liveLastChecked     ?? service.lastChecked }

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
                        let visible = Array(metrics.prefix(4))
                        let overflow = metrics.count - visible.count
                        ForEach(visible) { metric in
                            MetricChip(metric: metric)
                        }
                        if overflow > 0 {
                            Text("+\(overflow)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.leading, 58)
                }
                .frame(height: 26)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
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
            if let code = displayCode {
                Text("HTTP \(code) · \(service.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(service.displayURL)
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
        .background(metric.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(metric.color.opacity(0.2), lineWidth: 0.5))
    }
}
