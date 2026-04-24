import SwiftUI

struct GlancesIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)
        let api = await resolvedAPIBase(base: base)

        async let cpu  = fetchJSON(url: URL(string: "\(api)/cpu")!)
        async let mem  = fetchJSON(url: URL(string: "\(api)/mem")!)
        async let fs   = fetchJSON(url: URL(string: "\(api)/fs")!)
        async let load = fetchJSON(url: URL(string: "\(api)/load")!)
        async let net  = fetchJSON(url: URL(string: "\(api)/network")!)

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

        return metrics
    }

    /// Cache resolved API version per base URL so we only probe once per host.
    private static var versionCache: [String: String] = [:]

    /// Try Glances API v4 first; fall back to v3 for older installations.
    private func resolvedAPIBase(base: String) async -> String {
        if let cached = GlancesIntegration.versionCache[base] { return cached }
        let resolved: String
        if let url = URL(string: "\(base)/api/4/cpu"),
           let result = try? await fetchJSON(url: url) as? [String: Any],
           result["total"] != nil {
            resolved = "\(base)/api/4"
        } else {
            resolved = "\(base)/api/3"
        }
        GlancesIntegration.versionCache[base] = resolved
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