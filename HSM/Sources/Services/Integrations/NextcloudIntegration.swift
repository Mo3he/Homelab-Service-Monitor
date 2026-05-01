import SwiftUI

struct NextcloudIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let username = service.username, !username.isEmpty,
              let password = service.password, !password.isEmpty else {
            return [ServiceMetric(label: "Credentials required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let creds = Data("\(username):\(password)".utf8).base64EncodedString()
        let headers: [String: String] = [
            "Authorization": "Basic \(creds)",
            "OCS-APIRequest": "true"
        ]

        guard let url = URL(string: "\(base)/ocs/v2.php/apps/serverinfo/api/v1/info?format=json") else { throw IntegrationError.badURL }
        async let infoResult    = fetchJSON(url: url, headers: headers)
        async let updatesResult = fetchJSON(url: URL(string: "\(base)/ocs/v2.php/apps/updatenotification/api/v1/applist/stable?format=json")!, headers: headers)

        let json = try await infoResult

        guard let ocs   = (json as? [String: Any])?["ocs"] as? [String: Any],
              let data  = ocs["data"] as? [String: Any]
        else { throw IntegrationError.unexpectedFormat }

        var metrics: [ServiceMetric] = []

        if let nc = data["nextcloud"] as? [String: Any] {
            if let system = nc["system"] as? [String: Any] {
                if let version = system["version"] as? String {
                    metrics.append(ServiceMetric(label: "Version", value: version, icon: "tag.fill", color: .secondary))
                }
                if let freespace = system["freespace"] as? Int {
                    let gb = Double(freespace) / 1_073_741_824
                    metrics.append(ServiceMetric(label: "Free space", value: String(format: "%.1f GB", gb), icon: "internaldrive", color: gb < 5 ? .orange : .primary, isAlert: gb < 5))
                }
            }
            if let storage = nc["storage"] as? [String: Any] {
                if let users = storage["num_users"] as? Int {
                    metrics.append(ServiceMetric(label: "Users", value: "\(users)", icon: "person.2.fill", color: .primary))
                }
                if let files = storage["num_files"] as? Int {
                    let formatted = files > 1000 ? String(format: "%.0fk", Double(files) / 1000) : "\(files)"
                    metrics.append(ServiceMetric(label: "Files", value: formatted, icon: "doc.fill", color: .secondary))
                }
            }
        }

        if let activeUsers = (data["activeUsers"] as? [String: Any])?["last5minutes"] as? Int {
            metrics.append(ServiceMetric(label: "Active now", value: "\(activeUsers)", icon: "person.fill.checkmark", color: activeUsers > 0 ? .green : .secondary))
        }

        if let updatesJSON = try? await updatesResult as? [String: Any],
           let updatesOcs = updatesJSON["ocs"] as? [String: Any],
           let updatesData = updatesOcs["data"] as? [String: Any],
           let apps = updatesData["apps"] as? [String: Any] {
            let count = apps.count
            metrics.append(ServiceMetric(label: "App updates", value: "\(count)", icon: "arrow.down.circle.fill", color: count > 0 ? .orange : .secondary, isAlert: count > 0))
        }

        return metrics
    }
}
