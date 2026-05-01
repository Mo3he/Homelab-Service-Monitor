import Foundation

/// Records a status transition for the event log (Alerts tab).
struct StatusEvent: Identifiable, Codable {
    var id: UUID = UUID()
    var serviceID: UUID
    var serviceName: String
    var oldStatus: ServiceStatus
    var newStatus: ServiceStatus
    var timestamp: Date = Date()
}
