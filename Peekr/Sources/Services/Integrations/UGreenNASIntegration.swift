import SwiftUI

struct UGreenNASIntegration: ServiceIntegration {

    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let token = service.apiKey, !token.isEmpty else {
            return [ServiceMetric(
                label: "Session token required",
                value: "Swipe → Edit",
                icon: "key.fill",
                color: .orange
            )]
        }

        let base = baseURL(service)

        async let machineResult  = fetchJSON(url: URL(string: "\(base)/ugreen/v1/sysinfo/machine/common?token=\(token)")!)
        async let firmwareResult = fetchJSON(url: URL(string: "\(base)/ugreen/v1/firmware/version/is_new?token=\(token)")!)
        async let volumesResult  = fetchJSON(url: URL(string: "\(base)/ugreen/v1/filemgr/getVolumes?token=\(token)")!)

        var metrics: [ServiceMetric] = []

        // Machine info: uptime, version, CPU temp, RAM
        if let machine = try? await machineResult as? [String: Any] {
            // Check for auth failure (UGOS returns code 1024 on session expiry)
            if let code = machine["code"] as? Int, code == 1024 {
                return [ServiceMetric(
                    label: "Session expired",
                    value: "Update token in settings",
                    icon: "lock.rotation",
                    color: .orange,
                    isAlert: true
                )]
            }

            if let common = (machine["data"] as? [String: Any])?["common"] as? [String: Any] {
                let version = common["system_version"] as? String ?? ""
                if !version.isEmpty {
                    metrics.append(ServiceMetric(
                        label: "OS Version",
                        value: version,
                        icon: "tag.fill",
                        color: .secondary
                    ))
                }

                if let uptime = common["run_time"] as? Int {
                    metrics.append(ServiceMetric(
                        label: "Uptime",
                        value: formatUptime(uptime),
                        icon: "clock.fill",
                        color: .secondary
                    ))
                }
            }

            if let hardware = (machine["data"] as? [String: Any])?["hardware"] as? [String: Any] {
                if let cpus = hardware["cpu"] as? [[String: Any]], let cpu = cpus.first,
                   let temp = cpu["temperature"] as? Int {
                    let tempColor: Color = temp >= 80 ? .red : temp >= 70 ? .orange : .green
                    metrics.append(ServiceMetric(
                        label: "CPU Temp",
                        value: "\(temp)°C",
                        icon: "thermometer.medium",
                        color: tempColor,
                        isAlert: temp >= 80
                    ))
                }

                if let mems = hardware["mem"] as? [[String: Any]] {
                    let totalBytes = mems.compactMap { $0["size"] as? Int }.reduce(0, +)
                    if totalBytes > 0 {
                        metrics.append(ServiceMetric(
                            label: "RAM",
                            value: formatBytes(totalBytes),
                            icon: "memorychip.fill",
                            color: .secondary
                        ))
                    }
                }
            }
        }

        // Firmware update check
        if let fw = try? await firmwareResult as? [String: Any],
           let data = fw["data"] as? [String: Any],
           let hasVersion = data["has_version"] as? Bool, hasVersion {
            let publishVer = data["publish_version"] as? Int
            let verStr = publishVer.map { formatFirmwareVersion($0) } ?? "Available"
            metrics.append(ServiceMetric(
                label: "Update available",
                value: verStr,
                icon: "arrow.down.circle.fill",
                color: .orange,
                isAlert: true
            ))
        }

        // Volume storage
        if let vols = try? await volumesResult as? [String: Any],
           let volData = vols["data"] as? [String: Any],
           let result = volData["result"] as? [[String: Any]] {
            for vol in result {
                let name = vol["name"] as? String ?? "Volume"
                let free = vol["free"] as? Int ?? 0
                let total = vol["all"] as? Int ?? 0
                let describe = vol["describe"] as? String ?? ""
                let label = describe.isEmpty ? name : "\(name) (\(describe))"
                let usedPct = total > 0 ? Double(total - free) / Double(total) : 0
                let color: Color = usedPct >= 0.9 ? .red : usedPct >= 0.75 ? .orange : .green
                metrics.append(ServiceMetric(
                    label: label,
                    value: "\(formatBytes(free)) free",
                    icon: "externaldrive.fill",
                    color: color,
                    isAlert: usedPct >= 0.9
                ))
            }
        }

        return metrics
    }

    private func formatUptime(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        if days > 0 { return "\(days)d \(hours)h" }
        let mins = (seconds % 3600) / 60
        return "\(hours)h \(mins)m"
    }

    private func formatBytes(_ bytes: Int) -> String {
        let tb = Double(bytes) / 1_000_000_000_000
        if tb >= 1 { return String(format: "%.1f TB", tb) }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        return String(format: "%.0f MB", mb)
    }

    private func formatFirmwareVersion(_ v: Int) -> String {
        // e.g. 114010107 -> 1.14.1.0107 (1 digit major, 2 digit minor, 2 digit patch, 4 digit build)
        let s = String(format: "%09d", v)
        let major = Int(s.prefix(1)) ?? 0
        let minor = Int(s.dropFirst(1).prefix(2)) ?? 0
        let patch = Int(s.dropFirst(3).prefix(2)) ?? 0
        let build = String(s.suffix(4))
        return "\(major).\(minor).\(patch).\(build)"
    }
}
