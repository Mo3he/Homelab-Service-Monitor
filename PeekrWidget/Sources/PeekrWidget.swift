import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Shared data key

private let servicesKey = "peekr.services.v3"

// Minimal decodable mirror of Service - only the fields we need in the widget
private struct WidgetService: Decodable {
    let id: String?
    let name: String?
    let status: String?
    let latencyMs: Double?
    let host: String?
    let serviceType: String?
}

// MARK: - Aggregate entry (overview widget)

struct WidgetEntry: TimelineEntry {
    let date: Date
    let total: Int
    let online: Int
    let offline: Int
    let degraded: Int
}

// MARK: - Single-service entry (configurable widget)

struct ServiceWidgetEntry: TimelineEntry {
    let date: Date
    let serviceName: String
    let serviceIcon: String
    let status: String        // "online" / "offline" / "degraded" / "unknown"
    let latencyMs: Double?
}

// MARK: - AppIntent configuration for the single-service widget

struct ServiceWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Service"
    static var description = IntentDescription("Choose a service to pin to this widget.")

    @Parameter(title: "Service Name", default: "")
    var serviceName: String
}

// MARK: - Providers

struct PeekrWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: .now, total: 6, online: 5, offline: 1, degraded: 0)
    }
    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(aggregateEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let e = aggregateEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: e.date) ?? e.date
        completion(Timeline(entries: [e], policy: .after(next)))
    }
    private func aggregateEntry() -> WidgetEntry {
        let services = loadServices()
        let online   = services.filter { $0.status == "online" }.count
        let offline  = services.filter { $0.status == "offline" }.count
        let degraded = services.filter { $0.status == "degraded" }.count
        return WidgetEntry(date: .now, total: services.count, online: online, offline: offline, degraded: degraded)
    }
}

struct ServiceWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = ServiceWidgetIntent
    typealias Entry = ServiceWidgetEntry

    func placeholder(in context: Context) -> ServiceWidgetEntry {
        ServiceWidgetEntry(date: .now, serviceName: "Grafana", serviceIcon: "chart.bar.fill", status: "online", latencyMs: 12)
    }
    func snapshot(for intent: ServiceWidgetIntent, in context: Context) async -> ServiceWidgetEntry {
        entry(for: intent)
    }
    func timeline(for intent: ServiceWidgetIntent, in context: Context) async -> Timeline<ServiceWidgetEntry> {
        let e = entry(for: intent)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: e.date) ?? e.date
        return Timeline(entries: [e], policy: .after(next))
    }
    private func entry(for intent: ServiceWidgetIntent) -> ServiceWidgetEntry {
        let services = loadServices()
        let target = intent.serviceName.lowercased()
        let match = target.isEmpty
            ? services.first
            : services.first { ($0.name ?? "").lowercased().contains(target) }
        guard let svc = match else {
            return ServiceWidgetEntry(date: .now, serviceName: intent.serviceName.isEmpty ? "No service" : intent.serviceName,
                                      serviceIcon: "questionmark.circle", status: "unknown", latencyMs: nil)
        }
        return ServiceWidgetEntry(
            date: .now,
            serviceName: svc.name ?? "Service",
            serviceIcon: iconFor(type: svc.serviceType),
            status: svc.status ?? "unknown",
            latencyMs: svc.latencyMs
        )
    }
}

// MARK: - Helpers

private func loadServices() -> [WidgetService] {
    // Read from the App Group shared container so we see the same data as the main app.
    let ud = UserDefaults(suiteName: "group.com.mblieden.peekr") ?? .standard
    guard let data = ud.data(forKey: servicesKey),
          let services = try? JSONDecoder().decode([WidgetService].self, from: data)
    else { return [] }
    return services
}

private func iconFor(type: String?) -> String {
    switch type {
    case "home_assistant": return "house.fill"
    case "adguard": return "shield.fill"
    case "grafana": return "chart.bar.fill"
    case "portainer": return "shippingbox.fill"
    case "jellyfin": return "play.tv.fill"
    case "qbittorrent": return "arrow.down.circle.fill"
    case "proxmox": return "server.rack"
    case "truenas": return "externaldrive.fill"
    case "traefik": return "arrow.triangle.branch"
    case "pihole": return "circle.slash.fill"
    case "nextcloud": return "cloud.fill"
    case "immich": return "photo.fill"
    case "frigate": return "video.fill"
    default: return "circle.fill"
    }
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "online":   return .green
    case "offline":  return .red
    case "degraded": return .orange
    default:         return .secondary
    }
}

// MARK: - Views

struct PeekrWidgetEntryView: View {
    let entry: WidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:  smallView
        case .systemMedium: mediumView
        case .accessoryCircular:    accessoryCircularView
        case .accessoryRectangular: accessoryRectangularView
        default: smallView
        }
    }

    private var overallColor: Color {
        if entry.total == 0 { return .secondary }
        if entry.offline > 0 { return .red }
        if entry.degraded > 0 { return .orange }
        return .green
    }

    private var overallLabel: String {
        if entry.total == 0 { return "No services" }
        if entry.offline > 0 { return "\(entry.offline) offline" }
        if entry.degraded > 0 { return "\(entry.degraded) degraded" }
        return "All online"
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Peekr")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(overallColor).frame(width: 14, height: 14)
            Text(overallLabel).font(.headline.bold()).foregroundStyle(overallColor)
            Text("\(entry.online)/\(entry.total) online").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
    }

    private var mediumView: some View {
        HStack(spacing: 24) {
            smallView
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                statRow(count: entry.online,   label: "Online",   color: .green,  icon: "checkmark.circle.fill")
                if entry.degraded > 0 {
                    statRow(count: entry.degraded, label: "Degraded", color: .orange, icon: "exclamationmark.circle.fill")
                }
                if entry.offline > 0 {
                    statRow(count: entry.offline,  label: "Offline",  color: .red,    icon: "xmark.circle.fill")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    private func statRow(count: Int, label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text("\(count) \(label)").font(.subheadline.weight(.medium))
        }
    }

    private var accessoryCircularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: entry.offline > 0 ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.title3.bold())
                Text("\(entry.online)/\(entry.total)")
                    .font(.caption2.bold().monospacedDigit())
            }
        }
        .widgetLabel { Text("Peekr") }
    }

    private var accessoryRectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Peekr", systemImage: "server.rack")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if entry.total == 0 {
                Text("No services").font(.headline)
            } else if entry.offline == 0 && entry.degraded == 0 {
                Text("All \(entry.online) online").font(.headline)
            } else {
                HStack(spacing: 4) {
                    Text("\(entry.online)/\(entry.total)").font(.headline.monospacedDigit())
                    Text("online").font(.subheadline).foregroundStyle(.secondary)
                }
                if entry.offline > 0 {
                    Label("\(entry.offline) offline", systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ServiceWidgetEntryView: View {
    let entry: ServiceWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var color: Color { statusColor(entry.status) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: entry.serviceIcon).font(.body.bold())
                    Circle().fill(color).frame(width: 6, height: 6)
                }
            }
            .widgetLabel { Text(entry.serviceName) }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.serviceName, systemImage: entry.serviceIcon)
                    .font(.caption2.weight(.semibold))
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(entry.status.capitalized).font(.headline)
                }
                if let ms = entry.latencyMs {
                    Text(String(format: "%.0f ms", ms)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: entry.serviceIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(entry.serviceName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Circle().fill(color).frame(width: 14, height: 14)
                Text(entry.status.capitalized).font(.headline.bold()).foregroundStyle(color)
                if let ms = entry.latencyMs {
                    Text(String(format: "%.0f ms", ms)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        }
    }
}

// MARK: - Widget bundle

@main
struct PeekrWidgetBundle: WidgetBundle {
    var body: some Widget {
        PeekrOverviewWidget()
        PeekrServiceWidget()
    }
}

struct PeekrOverviewWidget: Widget {
    let kind = "PeekrWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PeekrWidgetProvider()) { entry in
            PeekrWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Peekr Overview")
        .description("See the overall health of all your services.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct PeekrServiceWidget: Widget {
    let kind = "PeekrServiceWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ServiceWidgetIntent.self, provider: ServiceWidgetProvider()) { entry in
            ServiceWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Peekr Service")
        .description("Pin a specific service and see its live status.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

