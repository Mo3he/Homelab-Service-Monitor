import WidgetKit
import SwiftUI

// MARK: - Shared data model (read from UserDefaults App Group when available, else plain UserDefaults)

private let servicesKey = "peekr.services.v3"

struct WidgetEntry: TimelineEntry {
    let date: Date
    let total: Int
    let online: Int
    let offline: Int
    let degraded: Int
}

// MARK: - Provider

struct PeekrWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: .now, total: 6, online: 5, offline: 1, degraded: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let e = entry()
        // Refresh every 15 minutes
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: e.date) ?? e.date
        completion(Timeline(entries: [e], policy: .after(next)))
    }

    private func entry() -> WidgetEntry {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: servicesKey),
              let services = try? JSONDecoder().decode([WidgetService].self, from: data)
        else {
            return WidgetEntry(date: .now, total: 0, online: 0, offline: 0, degraded: 0)
        }
        let online   = services.filter { $0.status == "online" }.count
        let offline  = services.filter { $0.status == "offline" }.count
        let degraded = services.filter { $0.status == "degraded" }.count
        return WidgetEntry(date: .now, total: services.count, online: online, offline: offline, degraded: degraded)
    }
}

// Minimal decodable mirror of Service - only the fields we need
private struct WidgetService: Decodable {
    let status: String?
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
            Circle()
                .fill(overallColor)
                .frame(width: 14, height: 14)
            Text(overallLabel)
                .font(.headline.bold())
                .foregroundStyle(overallColor)
            Text("\(entry.online)/\(entry.total) online")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            Image(systemName: icon)
                .foregroundStyle(color)
            Text("\(count) \(label)")
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Lock screen widgets

    /// Circular: service rack icon with online count
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

    /// Rectangular: "X/Y online · N offline" or "All online"
    private var accessoryRectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Peekr", systemImage: "server.rack")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if entry.total == 0 {
                Text("No services").font(.headline)
            } else if entry.offline == 0 && entry.degraded == 0 {
                Text("All \(entry.online) online")
                    .font(.headline)
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

// MARK: - Widget

@main
struct PeekrWidget: Widget {
    let kind = "PeekrWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PeekrWidgetProvider()) { entry in
            PeekrWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Peekr")
        .description("See the health of your self-hosted services at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}
