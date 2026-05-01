import SwiftUI

struct ProxmoxIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let username = service.username, !username.isEmpty,
              let password = service.password, !password.isEmpty else {
            return [ServiceMetric(label: "Credentials required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)

        // Authenticate
        guard let authURL = URL(string: "\(base)/api2/json/access/ticket") else { throw IntegrationError.badURL }
        var authReq = URLRequest(url: authURL)
        authReq.httpMethod = "POST"
        authReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authReq.timeoutInterval = 8
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        authReq.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
        let (authData, authResp) = try await URLSession.shared.data(for: authReq)
        if let http = authResp as? HTTPURLResponse, http.statusCode == 401 { throw IntegrationError.authFailed }

        guard let authJSON = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let data = authJSON["data"] as? [String: Any],
              let ticket = data["ticket"] as? String,
              let csrf = data["CSRFPreventionToken"] as? String
        else { throw IntegrationError.unexpectedFormat }

        let cookies = "PVEAuthCookie=\(ticket)"
        let headers = ["Cookie": cookies, "CSRFPreventionToken": csrf]

        // Fetch nodes
        guard let nodesURL = URL(string: "\(base)/api2/json/nodes") else { throw IntegrationError.badURL }
        let nodesJSON = try await fetchJSON(url: nodesURL, headers: headers)
        guard let nodesData = nodesJSON as? [String: Any],
              let nodes = nodesData["data"] as? [[String: Any]]
        else { throw IntegrationError.unexpectedFormat }

        var metrics: [ServiceMetric] = []
        let onlineNodes = nodes.filter { ($0["status"] as? String) == "online" }
        metrics.append(ServiceMetric(label: "Nodes", value: "\(onlineNodes.count)/\(nodes.count)", icon: "server.rack", color: onlineNodes.count == nodes.count ? .green : .orange))

        var totalVMs = 0
        var runningVMs = 0
        for node in onlineNodes {
            guard let nodeName = node["node"] as? String,
                  let vmURL = URL(string: "\(base)/api2/json/nodes/\(nodeName)/qemu") else { continue }
            if let vmJSON = try? await fetchJSON(url: vmURL, headers: headers) as? [String: Any],
               let vms = vmJSON["data"] as? [[String: Any]] {
                totalVMs += vms.count
                runningVMs += vms.filter { ($0["status"] as? String) == "running" }.count
            }
            // LXC containers
            if let ctURL = URL(string: "\(base)/api2/json/nodes/\(nodeName)/lxc"),
               let ctJSON = try? await fetchJSON(url: ctURL, headers: headers) as? [String: Any],
               let cts = ctJSON["data"] as? [[String: Any]] {
                totalVMs += cts.count
                runningVMs += cts.filter { ($0["status"] as? String) == "running" }.count
            }
        }
        if totalVMs > 0 {
            metrics.append(ServiceMetric(label: "VMs running", value: "\(runningVMs)/\(totalVMs)", icon: "cpu.fill", color: runningVMs == totalVMs ? .green : .orange))
        }

        // CPU / memory from first online node
        if let first = onlineNodes.first {
            if let cpu = first["cpu"] as? Double {
                let pct = Int(cpu * 100)
                metrics.append(ServiceMetric(label: "CPU", value: "\(pct)%", icon: "cpu", color: pct > 80 ? .red : .primary, isAlert: pct > 80))
            }
            if let mem = first["mem"] as? Int, let maxmem = first["maxmem"] as? Int, maxmem > 0 {
                let pct = Int(Double(mem) / Double(maxmem) * 100)
                metrics.append(ServiceMetric(label: "RAM", value: "\(pct)%", icon: "memorychip", color: pct > 85 ? .orange : .primary, isAlert: pct > 85))
            }
        }

        return metrics
    }
}
