import SwiftUI

struct PaperlessIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        guard let key = service.apiKey, !key.isEmpty else {
            return [ServiceMetric(label: "API token required", value: "Swipe → Edit", icon: "key.fill", color: .orange)]
        }
        let base = baseURL(service)
        let headers = ["Authorization": "Token \(key)"]

        async let statsResult = fetchJSON(url: URL(string: "\(base)/api/statistics/")!, headers: headers)
        async let tasksResult = fetchJSON(url: URL(string: "\(base)/api/tasks/?status=PENDING")!, headers: headers)

        var metrics: [ServiceMetric] = []

        if let stats = try? await statsResult as? [String: Any] {
            if let docs = stats["documents_total"] as? Int {
                metrics.append(ServiceMetric(label: "Documents", value: "\(docs)", icon: "doc.fill", color: .primary))
            }
            if let inbox = stats["documents_inbox"] as? Int {
                metrics.append(ServiceMetric(
                    label: "Inbox",
                    value: "\(inbox)",
                    icon: "tray.fill",
                    color: inbox > 0 ? .orange : .secondary,
                    isAlert: inbox > 0
                ))
            }
            if let tags = stats["tags_total"] as? Int {
                metrics.append(ServiceMetric(label: "Tags", value: "\(tags)", icon: "tag.fill", color: .secondary))
            }
            if let correspondents = stats["correspondents_total"] as? Int, correspondents > 0 {
                metrics.append(ServiceMetric(label: "Correspondents", value: "\(correspondents)", icon: "person.text.rectangle.fill", color: .secondary))
            }
            if let docTypes = stats["document_types_total"] as? Int, docTypes > 0 {
                metrics.append(ServiceMetric(label: "Doc types", value: "\(docTypes)", icon: "list.bullet.rectangle.fill", color: .secondary))
            }
        }

        if let tasks = try? await tasksResult as? [[String: Any]] {
            if !tasks.isEmpty {
                metrics.append(ServiceMetric(label: "Pending tasks", value: "\(tasks.count)", icon: "clock.fill", color: .orange, isAlert: true))
            }
        }

        return metrics
    }
}
