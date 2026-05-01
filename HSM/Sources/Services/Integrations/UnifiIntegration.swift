import SwiftUI

struct UnifiIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let username = service.username, !username.isEmpty,
              let password = service.password, !password.isEmpty else {
            return [ServiceMetric(label: "Credentials required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)

        // Login
        guard let loginURL = URL(string: "\(base)/api/login") else { throw IntegrationError.badURL }
        var loginReq = URLRequest(url: loginURL)
        loginReq.httpMethod = "POST"
        loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginReq.timeoutInterval = 8
        loginReq.httpBody = try? JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let (_, loginResp) = try await URLSession.shared.data(for: loginReq)
        if let http = loginResp as? HTTPURLResponse, http.statusCode == 400 { throw IntegrationError.authFailed }

        // Fetch stats
        let headers = ["Cookie": (loginResp as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String ?? ""]
        guard let siteURL = URL(string: "\(base)/api/s/default/stat/health") else { throw IntegrationError.badURL }
        let healthJSON = try await fetchJSON(url: siteURL, headers: headers)

        var metrics: [ServiceMetric] = []

        if let root = healthJSON as? [String: Any],
           let data = root["data"] as? [[String: Any]] {
            for subsystem in data {
                guard let sub = subsystem["subsystem"] as? String,
                      let status = subsystem["status"] as? String else { continue }
                switch sub {
                case "wlan":
                    let clients = subsystem["num_user"] as? Int ?? 0
                    metrics.append(ServiceMetric(label: "WiFi clients", value: "\(clients)", icon: "wifi", color: status == "ok" ? .green : .orange))
                case "lan":
                    let clients = subsystem["num_user"] as? Int ?? 0
                    metrics.append(ServiceMetric(label: "LAN clients", value: "\(clients)", icon: "network", color: status == "ok" ? .green : .orange))
                case "www":
                    let latency = subsystem["latency"] as? Int ?? 0
                    metrics.append(ServiceMetric(label: "WAN latency", value: "\(latency) ms", icon: "globe", color: latency > 100 ? .orange : .primary))
                    if let ip = subsystem["wan_ip"] as? String {
                        metrics.append(ServiceMetric(label: "WAN IP", value: ip, icon: "network", color: .secondary))
                    }
                default:
                    break
                }
            }
        }

        return metrics
    }
}
