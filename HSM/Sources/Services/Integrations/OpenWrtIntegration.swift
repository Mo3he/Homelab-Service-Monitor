import SwiftUI

struct OpenWrtIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)
        let username = service.username ?? "root"
        let password = service.password ?? ""

        guard let ubusURL = URL(string: "\(base)/ubus") else { throw IntegrationError.badURL }

        // Login via ubus JSON-RPC
        let loginBody: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "call",
            "params": ["00000000000000000000000000000000", "session", "login",
                       ["username": username, "password": password]]
        ]
        var loginReq = URLRequest(url: ubusURL)
        loginReq.httpMethod = "POST"
        loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginReq.httpBody = try? JSONSerialization.data(withJSONObject: loginBody)
        let (loginData, _) = try await URLSession.shared.data(for: loginReq)

        guard let loginJSON = try? JSONSerialization.jsonObject(with: loginData) as? [String: Any],
              let result = loginJSON["result"] as? [Any],
              result.count >= 2,
              (result[0] as? Int) == 0,
              let sessionData = result[1] as? [String: Any],
              let session = sessionData["ubus_rpc_session"] as? String else {
            return [ServiceMetric(label: "Auth failed", value: "Check credentials", icon: "xmark.circle.fill", color: .red, isAlert: true)]
        }

        // Fetch system info, board model, and all interfaces in parallel
        async let infoResult   = ubusCall(url: ubusURL, session: session, object: "system", method: "info")
        async let boardResult  = ubusCall(url: ubusURL, session: session, object: "system", method: "board")
        async let ifDumpResult = ubusCall(url: ubusURL, session: session, object: "network.interface", method: "dump")

        var metrics: [ServiceMetric] = []

        if let info = try? await infoResult {
            if let uptime = info["uptime"] as? Int {
                metrics.append(ServiceMetric(label: "Uptime", value: formatUptime(uptime), icon: "clock.fill", color: .primary))
            }
            if let load = info["load"] as? [Int], let load1 = load.first {
                let avg = Double(load1) / 65536.0
                metrics.append(ServiceMetric(
                    label: "Load",
                    value: String(format: "%.2f", avg),
                    icon: "waveform.path.ecg",
                    color: avg > 2.0 ? .red : avg > 1.0 ? .orange : .green
                ))
            }
            if let mem = info["memory"] as? [String: Int],
               let total = mem["total"], let free = mem["free"], total > 0 {
                let used = total - free
                let pct = Double(used) / Double(total) * 100
                metrics.append(ServiceMetric(
                    label: "Memory",
                    value: "\(formatBytes(used)) / \(formatBytes(total))",
                    icon: "memorychip",
                    color: pct > 90 ? .red : pct > 75 ? .orange : .green
                ))
            }
        }

        if let board = try? await boardResult, let model = board["model"] as? String {
            metrics.append(ServiceMetric(label: "Model", value: model, icon: "wifi.router.fill", color: .secondary))
        }

        // Find WAN interface dynamically (works on OpenWrt, EdgeRouter X, and other variants)
        if let dump = try? await ifDumpResult,
           let ifaces = dump["interface"] as? [[String: Any]] {
            let wan = ifaces.first(where: { ($0["interface"] as? String)?.lowercased().contains("wan") == true && ($0["up"] as? Bool) == true })
                   ?? ifaces.first(where: { ($0["up"] as? Bool) == true && ($0["interface"] as? String) != "loopback" && ($0["interface"] as? String) != "lo" && ($0["ipv4-address"] as? [[String: Any]])?.isEmpty == false })
            if let wan {
                let up = (wan["up"] as? Bool) == true
                metrics.append(ServiceMetric(
                    label: "WAN",
                    value: up ? "Connected" : "Disconnected",
                    icon: up ? "network" : "network.slash",
                    color: up ? .green : .red,
                    isAlert: !up
                ))
                if let ipv4 = (wan["ipv4-address"] as? [[String: Any]])?.first,
                   let ip = ipv4["address"] as? String {
                    metrics.append(ServiceMetric(label: "WAN IP", value: ip, icon: "globe", color: .secondary))
                }
            }
            let activeCount = ifaces.filter { ($0["up"] as? Bool) == true && ($0["interface"] as? String) != "loopback" && ($0["interface"] as? String) != "lo" }.count
            if activeCount > 0 {
                metrics.append(ServiceMetric(label: "Active interfaces", value: "\(activeCount)", icon: "network", color: .secondary))
            }
        }

        return metrics
    }

    private func ubusCall(url: URL, session: String, object: String, method: String) async throws -> [String: Any] {
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "call",
            "params": [session, object, method, [:] as [String: String]]
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [Any],
              result.count >= 2,
              (result[0] as? Int) == 0,
              let resultData = result[1] as? [String: Any] else {
            throw IntegrationError.unexpectedFormat
        }
        return resultData
    }

    private func formatUptime(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", mb)
    }
}
