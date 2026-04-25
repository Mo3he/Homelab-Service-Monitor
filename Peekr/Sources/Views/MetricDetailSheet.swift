import SwiftUI

struct MetricDetailSheet: View {
    let metric: ServiceMetric
    let serviceName: String
    let serviceID: UUID
    @Environment(\.dismiss) private var dismiss

    private var history: [MetricSnapshot] {
        MetricHistoryStore.shared.snapshots(serviceID: serviceID, label: metric.label)
    }

    // MARK: - Trend

    private enum TrendDirection {
        case up, down, stable

        var systemImage: String {
            switch self {
            case .up:     return "arrow.up"
            case .down:   return "arrow.down"
            case .stable: return "minus"
            }
        }
        var label: String {
            switch self {
            case .up:     return "Rising"
            case .down:   return "Falling"
            case .stable: return "Stable"
            }
        }
    }

    private var trendDirection: TrendDirection {
        guard history.count >= 3 else { return .stable }
        let ref = history[max(0, history.count - 4)]
        let cur = history[history.count - 1]
        guard let refVal = numericPrefix(ref.value),
              let curVal = numericPrefix(cur.value) else { return .stable }
        let delta = curVal - refVal
        let threshold = max(abs(refVal) * 0.04, 0.1)
        if delta > threshold  { return .up }
        if delta < -threshold { return .down }
        return .stable
    }

    private func numericPrefix(_ s: String) -> Double? {
        Scanner(string: s).scanDouble()
    }

    var body: some View {
        NavigationStack {
            List {
                // Current value + trend
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(metric.color.opacity(0.15))
                                .frame(width: 48, height: 48)
                            Image(systemName: metric.icon)
                                .font(.title2)
                                .foregroundStyle(metric.color)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.label)
                                .font(.headline)
                            Text(metric.value)
                                .font(.title2.monospacedDigit().bold())
                                .foregroundStyle(metric.isAlert ? metric.color : .primary)
                            if history.count >= 3 {
                                let t = trendDirection
                                Label(t.label, systemImage: t.systemImage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                // Recent readings
                if history.count >= 2 {
                    Section("Recent readings") {
                        ForEach(Array(history.reversed().prefix(10))) { snap in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(snap.isAlert ? Color.orange : Color.green)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel(snap.isAlert ? "Alert" : "Normal")
                                Text(snap.value)
                                    .font(.subheadline.monospacedDigit())
                                Spacer()
                                Text(snap.timestamp, style: .relative) + Text(" ago")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section("Recent readings") {
                        Text("Refresh this service a few more times to build up a reading history.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Description
                if let desc = MetricDescriptions.description(for: metric.label) {
                    Section("About this metric") {
                        Text(desc)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }

                // Thresholds
                if let thresholds = MetricDescriptions.thresholds(for: metric.label) {
                    Section("Thresholds") {
                        ForEach(thresholds, id: \.label) { t in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(t.color)
                                    .frame(width: 10, height: 10)
                                Text(t.label)
                                    .font(.subheadline)
                                Spacer()
                                Text(t.range)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Alert indicator
                if metric.isAlert {
                    Section {
                        Label("This metric is in an alert state and may need attention.", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(serviceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Descriptions

enum MetricDescriptions {
    struct Threshold {
        let label: String
        let range: String
        let color: Color
    }

    static func description(for label: String) -> String? {
        switch label.lowercased() {
        case "cpu":               return "Current processor utilization across all cores. High sustained CPU usage can cause slowdowns and instability."
        case "ram":               return "How much physical memory is in use. When RAM fills up, the system may start swapping to disk, significantly slowing performance."
        case "disk":              return "Storage space used on the primary filesystem. Running out of disk space can cause services to fail."
        case "load":              return "System load average over the last minute. Represents how many processes are competing for CPU time. On a 4-core system, a load of 4.0 means all cores are busy."
        case "swap":              return "Virtual memory (disk used as RAM overflow). High swap usage usually means the system is under memory pressure."
        case "network":           return "Current network throughput on the primary interface. Shows inbound (\u{2193}) and outbound (\u{2191}) data rates."
        case "uptime":            return "How long the system has been running without a restart."
        case "memory":            return "Physical RAM usage. On routers and small devices, this shows available memory for active processes."
        case "wan":               return "Status of the WAN (internet-facing) network interface."
        case "wan ip":            return "The public IP address assigned to the WAN interface."
        case "active interfaces": return "Number of network interfaces currently up and active on the device."
        case "dhcp clients":      return "Number of devices currently assigned IP addresses via DHCP."
        case "version":           return "The software version currently running on this service."
        case "active streams":    return "Number of media streams currently being played to clients."
        case "transcoding":       return "Number of streams being re-encoded on-the-fly. Transcoding is CPU-intensive; direct play is preferred."
        case "connected clients": return "Number of client applications currently connected to the server."
        case "movies":            return "Total number of movies in the library."
        case "tv shows":          return "Total number of TV series in the library."
        case "episodes":          return "Total number of individual TV episodes across all series."
        case "songs":             return "Total number of music tracks in the library."
        case "movie libraries":   return "Number of configured movie library sections."
        case "tv libraries":      return "Number of configured TV show library sections."
        case "music libraries":   return "Number of configured music library sections."
        case "environments":      return "Number of Docker environments (endpoints) managed by Portainer."
        case "running":           return "Number of Docker containers currently in a running state."
        case "stopped":           return "Number of Docker containers that exist but are not running. Stopped containers still consume disk space."
        case "images":            return "Total number of Docker images stored across all environments."
        case "volumes":           return "Total number of Docker named volumes across all environments."
        case "entities":          return "Total number of entities registered in Home Assistant. Entities represent devices, sensors, and services."
        case "lights":            return "Home Assistant light entities - shows how many are currently on vs total."
        case "switches":          return "Home Assistant switch entities - shows how many are currently on vs total."
        case "binary_sensors":    return "Home Assistant binary sensors (on/off sensors like door contacts, motion detectors)."
        case "unavailable":       return "Entities in an unavailable state, usually due to a disconnected device or integration error."
        case "updates available": return "Home Assistant integrations, add-ons, or core components with available updates."
        case "blocked today":     return "Number of DNS requests blocked today by Pi-hole. Blocked queries are typically ads and tracking domains."
        case "block rate":        return "Percentage of DNS queries blocked today. A rate between 10-30% is typical for most networks."
        case "queries today":     return "Total DNS queries processed today across all clients."
        case "clients":           return "Number of unique devices that have made DNS queries."
        case "blocklist":         return "Total number of domains in the active blocklist."
        case "gravity updated":   return "How long ago the Pi-hole blocklist (gravity) was last updated. Updates are recommended weekly."
        case "status":            return "Whether the Pi-hole DNS blocking is currently active."
        case "http routers":      return "Number of HTTP routing rules configured in Traefik."
        case "errored routes":    return "Traefik routes that are not in an enabled state, often due to misconfiguration or unreachable backends."
        case "services":          return "Backend services registered in Traefik that traffic can be routed to."
        case "middlewares":       return "Middleware plugins configured in Traefik for request/response transformation."
        case "pools healthy":     return "Number of TrueNAS storage pools in a healthy state."
        case "critical alerts":   return "Active critical-level alerts on the TrueNAS system requiring immediate attention."
        case "update available":  return "A software update is available for this system."
        case "nodes":             return "Number of Proxmox hypervisor nodes in the cluster."
        case "vms running":       return "Number of QEMU virtual machines and LXC containers currently running."
        case "cpu%":              return "Average CPU utilization across all Proxmox nodes."
        case "ram%":              return "Average RAM utilization across all Proxmox nodes."
        case "download speed":    return "Current aggregate download throughput across all active torrents."
        case "upload speed":      return "Current aggregate upload throughput to peers."
        case "torrents":          return "Total number of torrents and their download/seeding state breakdown."
        case "free space":        return "Available disk space on the storage drive."
        case "series":            return "Total number of TV series tracked in Sonarr."
        case "monitored":         return "Series configured to automatically download new episodes."
        case "missing":           return "Monitored movies that have not yet been downloaded."
        case "queue":             return "Items currently being downloaded or awaiting import."
        case "photos":            return "Total number of photos managed by Immich."
        case "videos":            return "Total number of videos managed by Immich."
        case "storage used":      return "Total disk space used by the media library."
        case "albums":            return "Number of albums created in Immich."
        case "cameras":           return "Number of cameras configured in Frigate and how many are actively detecting motion."
        case "detection fps":     return "Frames per second being processed by the object detection pipeline."
        case "cpu (detect)":      return "CPU usage of the Frigate object detection process."
        case "events today":      return "Number of detection events recorded today."
        case "documents":         return "Total number of documents stored in Paperless-ngx."
        case "inbox":             return "Documents in the inbox awaiting tagging and filing."
        case "tags":              return "Number of tags configured for document organization."
        case "correspondents":    return "Number of correspondent contacts configured."
        case "doc types":         return "Number of document type categories configured."
        case "pending tasks":     return "Background tasks queued for processing (e.g., OCR, thumbnail generation)."
        case "location":          return "The Home Assistant instance location name."
        case "pending requests":  return "Media requests submitted through Overseerr awaiting approval."
        case "total users":       return "Number of user accounts registered in Overseerr."
        case "users":             return "Total registered user accounts."
        case "database":          return "Grafana database backend status."
        case "datasources":       return "Number of data source connections configured in Grafana."
        case "dashboards":        return "Number of dashboards created in Grafana."
        case "alerts firing":     return "Number of Grafana alerting rules currently in a firing state."
        case "active now":        return "Users active in the last 5 minutes."
        case "files":             return "Total number of files stored in Nextcloud."
        case "app updates":       return "Nextcloud applications with available updates."
        case "wifi clients":      return "Devices currently connected to a UniFi wireless access point."
        case "lan clients":       return "Devices currently connected to the UniFi network via wired or wireless."
        case "wan latency":       return "Round-trip ping time to the internet as measured by the UniFi controller."
        default:                  return nil
        }
    }

    static func thresholds(for label: String) -> [Threshold]? {
        switch label.lowercased() {
        case "cpu":
            return [
                Threshold(label: "Normal",   range: "0 - 70%",  color: .green),
                Threshold(label: "Warning",  range: "70 - 90%", color: .orange),
                Threshold(label: "Critical", range: "> 90%",    color: .red),
            ]
        case "ram":
            return [
                Threshold(label: "Normal",   range: "0 - 75%",  color: .green),
                Threshold(label: "Warning",  range: "75 - 90%", color: .orange),
                Threshold(label: "Critical", range: "> 90%",    color: .red),
            ]
        case "disk":
            return [
                Threshold(label: "Normal",   range: "0 - 80%",  color: .green),
                Threshold(label: "Warning",  range: "80 - 95%", color: .orange),
                Threshold(label: "Critical", range: "> 95%",    color: .red),
            ]
        case "swap":
            return [
                Threshold(label: "Normal",   range: "0 - 50%",  color: .green),
                Threshold(label: "Warning",  range: "50 - 80%", color: .orange),
                Threshold(label: "Critical", range: "> 80%",    color: .red),
            ]
        case "load":
            return [
                Threshold(label: "Normal",  range: "0 - 1.0",   color: .green),
                Threshold(label: "Warning", range: "1.0 - 2.0", color: .orange),
                Threshold(label: "High",    range: "> 2.0",      color: .red),
            ]
        case "free space":
            return [
                Threshold(label: "Normal",   range: "> 50 GB",    color: .green),
                Threshold(label: "Warning",  range: "10 - 50 GB", color: .orange),
                Threshold(label: "Critical", range: "< 10 GB",    color: .red),
            ]
        case "block rate":
            return [
                Threshold(label: "Typical",   range: "10 - 30%", color: .green),
                Threshold(label: "Very high", range: "> 50%",    color: .orange),
            ]
        case "wan latency":
            return [
                Threshold(label: "Normal",  range: "< 100 ms", color: .green),
                Threshold(label: "Warning", range: "> 100 ms", color: .orange),
            ]
        case "cpu (detect)":
            return [
                Threshold(label: "Normal",   range: "0 - 80%", color: .green),
                Threshold(label: "Critical", range: "> 80%",   color: .red),
            ]
        default:
            return nil
        }
    }
}
