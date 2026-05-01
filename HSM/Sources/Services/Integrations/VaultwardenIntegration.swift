import SwiftUI

struct VaultwardenIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        let base = baseURL(service)

        // Public alive endpoint - no auth needed
        guard let aliveURL = URL(string: "\(base)/alive") else { throw IntegrationError.badURL }
        var aliveReq = URLRequest(url: aliveURL)
        aliveReq.timeoutInterval = 8
        let (_, aliveResp) = try await URLSession.shared.data(for: aliveReq)
        let alive = (aliveResp as? HTTPURLResponse)?.statusCode == 200

        var metrics: [ServiceMetric] = [
            ServiceMetric(label: "Status", value: alive ? "Running" : "Down", icon: alive ? "checkmark.circle.fill" : "xmark.circle.fill", color: alive ? .green : .red, isAlert: !alive)
        ]

        // Admin endpoint (requires admin token)
        if let token = service.apiKey, !token.isEmpty,
           let diagURL = URL(string: "\(base)/admin/diagnostics") {
            let headers = ["Authorization": "Bearer \(token)"]
            if let diag = try? await fetchJSON(url: diagURL, headers: headers) as? [String: Any] {
                if let version = diag["version"] as? [String: Any],
                   let server = version["server"] as? String {
                    metrics.insert(ServiceMetric(label: "Version", value: server, icon: "tag.fill", color: .secondary), at: 0)
                }
                if let users = diag["users_count"] as? Int {
                    metrics.append(ServiceMetric(label: "Users", value: "\(users)", icon: "person.2.fill", color: .primary))
                }
            }
        }

        return metrics
    }
}
