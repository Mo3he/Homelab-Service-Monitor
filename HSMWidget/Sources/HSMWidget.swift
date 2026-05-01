import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Shared data key

private let servicesKey = "hsm.services.v3"

// Minimal decodable mirror of Service - only the fields we need in the widget
struct WidgetService: Decodable {
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
    let services: [WidgetService]
}

// MARK: - Metrics snapshot (mirrors LiveDataStore.PersistedMetric JSON format)

struct WidgetMetric: Decodable {
    let label: String
    let value: String
    let icon: String
    let colorName: String
    let isAlert: Bool

    var color: Color {
        switch colorName {
        case "red":       return .red
        case "orange":    return .orange
        case "yellow":    return .yellow
        case "green":     return .green
        case "blue":      return .blue
        case "purple":    return .purple
        case "pink":      return .pink
        case "gray":      return .gray
        case "secondary": return .secondary
        case "mint":      return .mint
        case "cyan":      return .cyan
        case "indigo":    return .indigo
        case "brown":     return .brown
        case "teal":      return .teal
        default:          return .primary
        }
    }
}

// MARK: - Multi-service monitor entry (large widget)

struct MonitorEntry: TimelineEntry {
    let date: Date
    let cards: [ServiceCard]
}

struct ServiceCard {
    let name: String
    let icon: String
    let status: String
    let latencyMs: Double?
    let metrics: [WidgetMetric]
}

// MARK: - Single-service entry (configurable widget)

struct ServiceWidgetEntry: TimelineEntry {
    let date: Date
    let serviceName: String
    let serviceIcon: String
    let status: String        // "online" / "offline" / "degraded" / "unknown"
    let latencyMs: Double?
    let metrics: [WidgetMetric]
}

// MARK: - AppEntity + Query for the service picker

struct ServiceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Service"
    static var defaultQuery = ServiceEntityQuery()

    var id: String
    var name: String
    var serviceType: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            image: .init(systemName: iconFor(type: serviceType))
        )
    }
}

struct ServiceEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ServiceEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ServiceEntity] {
        allEntities()
    }
    private func allEntities() -> [ServiceEntity] {
        let ud = UserDefaults(suiteName: "group.net.mohome.hsm") ?? .standard
        guard let data = ud.data(forKey: servicesKey),
              let services = try? JSONDecoder().decode([WidgetService].self, from: data)
        else { return [] }
        return services.compactMap { svc in
            guard let id = svc.id, let name = svc.name else { return nil }
            return ServiceEntity(id: id, name: name, serviceType: svc.serviceType)
        }
    }
}

// MARK: - AppIntent configuration for the single-service widget

struct MonitorWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Monitor"
    static var description = IntentDescription("Choose up to 4 services to monitor with their metrics.")

    @Parameter(title: "Services")
    var services: [ServiceEntity]?
}

struct ServiceWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Service"
    static var description = IntentDescription("Choose a service to pin to this widget.")

    @Parameter(title: "Service")
    var service: ServiceEntity?
}

struct OverviewWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Overview"
    static var description = IntentDescription("Choose which services to show.")

    @Parameter(title: "Services")
    var services: [ServiceEntity]?
}

// MARK: - Providers

struct MonitorWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = MonitorWidgetIntent
    typealias Entry = MonitorEntry

    func placeholder(in context: Context) -> MonitorEntry {
        MonitorEntry(date: .now, cards: [])
    }
    func snapshot(for intent: MonitorWidgetIntent, in context: Context) async -> MonitorEntry {
        makeEntry(for: intent)
    }
    func timeline(for intent: MonitorWidgetIntent, in context: Context) async -> Timeline<MonitorEntry> {
        let e = makeEntry(for: intent)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: e.date) ?? e.date
        return Timeline(entries: [e], policy: .after(next))
    }
    private func makeEntry(for intent: MonitorWidgetIntent) -> MonitorEntry {
        let all = loadServices()
        let selectedIDs = intent.services?.map { $0.id } ?? []
        let ordered: [WidgetService] = selectedIDs.isEmpty ? [] : selectedIDs.compactMap { sid in
            all.first { $0.id == sid }
        }
        let cards = ordered.prefix(4).map { svc -> ServiceCard in
            let metrics = svc.id.flatMap { loadMetrics(for: $0) } ?? []
            return ServiceCard(
                name: svc.name ?? "Service",
                icon: iconFor(type: svc.serviceType),
                status: svc.status ?? "unknown",
                latencyMs: svc.latencyMs,
                metrics: metrics
            )
        }
        return MonitorEntry(date: .now, cards: Array(cards))
    }
}

struct HSMWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = OverviewWidgetIntent
    typealias Entry = WidgetEntry

    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: .now, total: 6, online: 5, offline: 1, degraded: 0, services: [])
    }
    func snapshot(for intent: OverviewWidgetIntent, in context: Context) async -> WidgetEntry {
        aggregateEntry(for: intent)
    }
    func timeline(for intent: OverviewWidgetIntent, in context: Context) async -> Timeline<WidgetEntry> {
        let e = aggregateEntry(for: intent)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: e.date) ?? e.date
        return Timeline(entries: [e], policy: .after(next))
    }
    private func aggregateEntry(for intent: OverviewWidgetIntent) -> WidgetEntry {
        let all = loadServices()
        let selectedIDs = intent.services?.map { $0.id } ?? []
        // If services are selected, scope everything to that subset
        let pool = selectedIDs.isEmpty ? all : all.filter { svc in
            guard let id = svc.id else { return false }
            return selectedIDs.contains(id)
        }
        let online   = pool.filter { $0.status == "online" }.count
        let offline  = pool.filter { $0.status == "offline" }.count
        let degraded = pool.filter { $0.status == "degraded" }.count
        // Medium view shows the selected services as rows; empty selection = show tip
        let selected: [WidgetService] = selectedIDs.isEmpty ? [] : Array(pool.prefix(8))
        return WidgetEntry(date: .now, total: pool.count, online: online, offline: offline, degraded: degraded, services: selected)
    }
}

struct ServiceWidgetProvider: AppIntentTimelineProvider {
    typealias Intent = ServiceWidgetIntent
    typealias Entry = ServiceWidgetEntry

    func placeholder(in context: Context) -> ServiceWidgetEntry {
        ServiceWidgetEntry(date: .now, serviceName: "Grafana", serviceIcon: "chart.bar.fill", status: "online", latencyMs: 12, metrics: [])
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
        let match: WidgetService?
        if let selectedId = intent.service?.id {
            match = services.first { $0.id == selectedId } ?? services.first
        } else {
            match = services.first
        }
        guard let svc = match else {
            return ServiceWidgetEntry(date: .now, serviceName: intent.service?.name ?? "No service",
                                      serviceIcon: "questionmark.circle", status: "unknown", latencyMs: nil, metrics: [])
        }
        let metrics = svc.id.flatMap { loadMetrics(for: $0) } ?? []
        return ServiceWidgetEntry(
            date: .now,
            serviceName: svc.name ?? "Service",
            serviceIcon: iconFor(type: svc.serviceType),
            status: svc.status ?? "unknown",
            latencyMs: svc.latencyMs,
            metrics: metrics
        )
    }
}

// MARK: - Helpers

private func loadServices() -> [WidgetService] {
    let ud = UserDefaults(suiteName: "group.net.mohome.hsm") ?? .standard
    guard let data = ud.data(forKey: servicesKey),
          let services = try? JSONDecoder().decode([WidgetService].self, from: data)
    else { return [] }
    return services
}

private func loadMetrics(for serviceId: String) -> [WidgetMetric] {
    guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.net.mohome.hsm"),
          let data = try? Data(contentsOf: dir.appendingPathComponent("lastKnownMetrics.json")),
          let decoded = try? JSONDecoder().decode([String: [WidgetMetric]].self, from: data)
    else { return [] }
    return decoded[serviceId] ?? []
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
    case "frigate":     return "video.fill"
    case "ugreen_nas":  return "externaldrive.connected.to.line.below.fill"
    case "glances":     return "gauge.open.with.lines.needle.33percent"
    case "plex":        return "play.rectangle.fill"
    case "sonarr":      return "tv.fill"
    case "radarr":      return "film.fill"
    case "prowlarr":    return "magnifyingglass"
    case "overseerr":   return "list.bullet.rectangle"
    case "unifi":       return "wifi.router.fill"
    case "vaultwarden": return "lock.fill"
    case "paperless":   return "doc.fill"
    case "ntfy":        return "bell.fill"
    case "github":      return "chevron.left.forwardslash.chevron.right"
    case "nginx_proxy_manager": return "arrow.triangle.2.circlepath"
    case "openwrt":     return "network"
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

// MARK: - Refresh intent

// MARK: - Views

struct HSMWidgetEntryView: View {
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
                Text("HSM")
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
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("HSM")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !entry.services.isEmpty {
                    Text("\(entry.online)/\(entry.total) online")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(overallColor)
                }
            }
            .padding(.bottom, 6)
            if entry.services.isEmpty {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "hand.tap")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Long press to edit")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Choose which services to show here.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Per-service rows in two columns
                let items = entry.services
                let half = Int(ceil(Double(items.count) / 2.0))
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.prefix(half).enumerated()), id: \.offset) { _, svc in
                            serviceRow(svc)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.dropFirst(half).enumerated()), id: \.offset) { _, svc in
                            serviceRow(svc)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func serviceRow(_ svc: WidgetService) -> some View {
        let status = svc.status ?? "unknown"
        let sColor = statusColor(status)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: iconFor(type: svc.serviceType))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(svc.name ?? "Service")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Circle().fill(sColor).frame(width: 5, height: 5)
                Text(status.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(sColor)
                if let ms = svc.latencyMs {
                    Text(String(format: "%.0f ms", ms))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.bottom, 6)
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
        .widgetLabel { Text("HSM") }
    }

    private var accessoryRectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("HSM", systemImage: "server.rack")
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
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow.padding(.bottom, 6)
            if entry.metrics.isEmpty {
                metricCell(icon: "circle.fill", iconColor: color,
                           label: entry.status.capitalized, value: "")
                if let ms = entry.latencyMs {
                    metricCell(icon: "timer", iconColor: .secondary,
                               label: "Latency", value: String(format: "%.0f ms", ms))
                }
            } else {
                ForEach(Array(entry.metrics.prefix(4).enumerated()), id: \.offset) { _, m in
                    metricCell(icon: m.icon, iconColor: m.color, label: m.label, value: m.value)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow.padding(.bottom, 6)
            if entry.metrics.isEmpty {
                Spacer()
                Text("No metrics available").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                let items = Array(entry.metrics.prefix(8))
                let half = Int(ceil(Double(items.count) / 2.0))
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.prefix(half).enumerated()), id: \.offset) { _, m in
                            metricCell(icon: m.icon, iconColor: m.color, label: m.label, value: m.value)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.dropFirst(half).enumerated()), id: \.offset) { _, m in
                            metricCell(icon: m.icon, iconColor: m.color, label: m.label, value: m.value)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.serviceIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.serviceName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Circle().fill(color).frame(width: 7, height: 7)
            Text(entry.status.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .fixedSize()
            if let ms = entry.latencyMs {
                Text(String(format: "%.0f ms", ms))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
    }

    /// Capsule chip matching the app's MetricChip style.
    private func metricChip(icon: String, iconColor: Color, value: String, isAlert: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(iconColor)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isAlert ? iconColor : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(Color.primary.opacity(0.07))
                .overlay(Capsule().fill(iconColor.opacity(0.08)))
        }
        .overlay(Capsule().stroke(iconColor.opacity(0.25), lineWidth: 0.5))
    }

    /// Two-line cell: icon + label on top, value below.
    private func metricCell(icon: String, iconColor: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(iconColor)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Widget bundle

@main
struct HSMWidgetBundle: WidgetBundle {
    var body: some Widget {
        HSMOverviewWidget()
        HSMServiceWidget()
        HSMMonitorWidget()
    }
}

struct HSMOverviewWidget: Widget {
    let kind = "HSMWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: OverviewWidgetIntent.self, provider: HSMWidgetProvider()) { entry in
            HSMWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("HSM Overview")
        .description("See the health of your services. Tap to choose which ones to show.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct HSMMonitorWidget: Widget {
    let kind = "HSMMonitorWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: MonitorWidgetIntent.self, provider: MonitorWidgetProvider()) { entry in
            MonitorWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("HSM Monitor")
        .description("Monitor up to 4 services and their key metrics.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Monitor widget view

struct MonitorWidgetView: View {
    let entry: MonitorEntry

    var body: some View {
        if entry.cards.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("Long press to edit")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Choose up to 4 services to monitor.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 5) {
                ForEach(Array(entry.cards.enumerated()), id: \.offset) { _, card in
                    serviceCard(card)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
    }

    private func serviceCard(_ card: ServiceCard) -> some View {
        let color = statusColor(card.status)
        return VStack(alignment: .leading, spacing: 3) {
            // Card header
            HStack(spacing: 5) {
                Image(systemName: card.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(card.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Circle().fill(color).frame(width: 7, height: 7)
                Text(card.status.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .fixedSize()
                if let ms = card.latencyMs {
                    Text(String(format: "%.0f ms", ms))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            // Metrics as chips
            if !card.metrics.isEmpty {
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
                    ForEach(Array(card.metrics.prefix(6).enumerated()), id: \.offset) { _, m in
                        metricChipCard(icon: m.icon, iconColor: m.color, label: m.label, value: m.value, isAlert: m.isAlert)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Two-line cell: icon + label on top, value below with a pill background.
    private func metricChipCard(icon: String, iconColor: Color, label: String, value: String, isAlert: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(isAlert ? iconColor : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    Capsule().fill(Color.primary.opacity(0.07))
                        .overlay(Capsule().fill(iconColor.opacity(0.1)))
                }
                .overlay(Capsule().stroke(iconColor.opacity(0.25), lineWidth: 0.5))
        }
    }
}

struct HSMServiceWidget: Widget {
    let kind = "HSMServiceWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ServiceWidgetIntent.self, provider: ServiceWidgetProvider()) { entry in
            ServiceWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("HSM Service")
        .description("Pin a specific service and see its live status.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

