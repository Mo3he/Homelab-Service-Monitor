import SwiftUI

struct GlancesIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)
        let api = await resolvedAPIBase(base: base)

        async let cpu     = fetchJSON(url: URL(string: "\(api)/cpu")!)
        async let mem     = fetchJSON(url: URL(string: "\(api)/mem")!)
        async let fs      = fetchJSON(url: URL(string: "\(api)/fs")!)
        async let load    = fetchJSON(url: URL(string: "\(api)/load")!)
        async let net     = fetchJSON(url: URL(string: "\(api)/network")!)
        async let swap    = fetchJSON(url: URL(string: "\(api)/memswap")!)
        async let sensors = fetchJSON(url: URL(string: "\(api)/sensors")!)

        var metrics: [ServiceMetric] = []

        if let c = try? await cpu as? [String: Any],
           let total = c["total"] as? Double {
            metrics.append(ServiceMetric(
                label: "CPU",
                value: String(format: "%.1f%%", total),
                icon: "cpu",
                color: gaugeColor(total, warn: 70, crit: 90)
            ))
        }

        if let m = try? await mem as? [String: Any],
           let pct = m["percent"] as? Double {
            let used  = (m["used"]  as? Int).map { formatBytes($0) } ?? ""
            let total = (m["total"] as? Int).map { formatBytes($0) } ?? ""
            metrics.append(ServiceMetric(
                label: "RAM",
                value: total.isEmpty ? String(format: "%.1f%%", pct) : "\(used) / \(total)",
                icon: "memorychip",
                color: gaugeColor(pct, warn: 75, crit: 90)
            ))
        }

        if let disks = try? await fs as? [[String: Any]],
           let root = disks.first(where: { ($0["mnt_point"] as? String) == "/" }) ?? disks.first,
           let pct = root["percent"] as? Double {
            let used  = (root["used"]  as? Int).map { formatBytes($0) } ?? ""
            let size  = (root["size"]  as? Int).map { formatBytes($0) } ?? ""
            metrics.append(ServiceMetric(
                label: "Disk",
                value: size.isEmpty ? String(format: "%.1f%%", pct) : "\(used) / \(size)",
                icon: "internaldrive",
                color: gaugeColor(pct, warn: 80, crit: 95)
            ))
        }

        if let l = try? await load as? [String: Any],
           let min1 = l["min1"] as? Double {
            metrics.append(ServiceMetric(
                label: "Load",
                value: String(format: "%.2f", min1),
                icon: "waveform.path.ecg",
                color: .primary
            ))
        }

        if let nets = try? await net as? [[String: Any]],
           let iface = nets.first(where: { ($0["interface_name"] as? String)?.hasPrefix("eth") == true || ($0["interface_name"] as? String)?.hasPrefix("en") == true }) ?? nets.first {
            let rx = (iface["rx"] as? Int).map { formatBytesPerSec($0) } ?? "0"
            let tx = (iface["tx"] as? Int).map { formatBytesPerSec($0) } ?? "0"
            metrics.append(ServiceMetric(
                label: "Network",
                value: "↓\(rx)  ↑\(tx)",
                icon: "arrow.up.arrow.down",
                color: .blue
            ))
        }

        if let s = try? await swap as? [String: Any],
           let pct = s["percent"] as? Double, pct > 0 {
            let used  = (s["used"]  as? Int).map { formatBytes($0) } ?? ""
            let total = (s["total"] as? Int).map { formatBytes($0) } ?? ""
            metrics.append(ServiceMetric(
                label: "Swap",
                value: total.isEmpty ? String(format: "%.1f%%", pct) : "\(used) / \(total)",
                icon: "arrow.up.arrow.down.square",
                color: gaugeColor(pct, warn: 50, crit: 80)
            ))
        }

        if let sensorList = try? await sensors as? [[String: Any]] {
            // Show up to 3 temperature sensors (CPU first, then others)
            let temps = sensorList.filter {
                let unit = $0["unit"] as? String ?? ""
                let type_ = $0["type"] as? String ?? ""
                return unit == "C" || type_.contains("temperature") || type_ == "temperature_core"
            }
            let sorted = temps.sorted { a, b in
                let aLabel = (a["label"] as? String ?? "").lowercased()
                let bLabel = (b["label"] as? String ?? "").lowercased()
                let aCPU = aLabel.contains("cpu") || aLabel.contains("core") || aLabel.contains("package")
                let bCPU = bLabel.contains("cpu") || bLabel.contains("core") || bLabel.contains("package")
                if aCPU != bCPU { return aCPU }
                return aLabel < bLabel
            }
            for sensor in sorted.prefix(3) {
                guard let label = sensor["label"] as? String,
                      let value = sensor["value"] as? Double, value > 0 else { continue }
                let icon = label.lowercased().contains("cpu") || label.lowercased().contains("core") || label.lowercased().contains("package")
                    ? "cpu" : "thermometer.medium"
                metrics.append(ServiceMetric(
                    label: label,
                    value: String(format: "%.0f°C", value),
                    icon: icon,
                    color: gaugeColor(value, warn: 70, crit: 85),
                    isAlert: value >= 85
                ))
            }
        }

        return metrics
    }

    /// Cache resolved API version per base URL so we only probe once per host.
    /// Entry expires after 24 hours so a v3→v4 upgrade is picked up without an app restart.
    private static var versionCache: [String: (base: String, expiry: Date)] = [:]

    /// Try Glances API v4 first; fall back to v3 for older installations.
    private func resolvedAPIBase(base: String) async -> String {
        if let entry = GlancesIntegration.versionCache[base], entry.expiry > Date() {
            return entry.base
        }
        let resolved: String
        if let url = URL(string: "\(base)/api/4/cpu"),
           let result = try? await fetchJSON(url: url) as? [String: Any],
           result["total"] != nil {
            resolved = "\(base)/api/4"
        } else {
            resolved = "\(base)/api/3"
        }
        GlancesIntegration.versionCache[base] = (base: resolved, expiry: Date().addingTimeInterval(86400))
        return resolved
    }

    private func gaugeColor(_ val: Double, warn: Double, crit: Double) -> SwiftUI.Color {
        if val >= crit { return .red }
        if val >= warn { return .orange }
        return .green
    }

    private func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        if gb >= 1  { return String(format: "%.1f GB", gb) }
        if mb >= 1  { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", kb)
    }

    private func formatBytesPerSec(_ bps: Int) -> String {
        let kb = Double(bps) / 1024
        let mb = kb / 1024
        if mb >= 1  { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", kb)
    }
}