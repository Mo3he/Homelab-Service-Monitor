import Foundation

/// Records a status transition for the event log (Alerts tab).
struct StatusEvent: Identifiable, Codable {
    var id: UUID = UUID()
    var serviceID: UUID
    var serviceName: String
    var oldStatus: ServiceStatus
    var newStatus: ServiceStatus
    var timestamp: Date = Date()

    // v2 context fields -- optional so existing persisted events decode without error
    var latencyMs: Double? = nil
    var httpStatusCode: Int? = nil
    var errorDetail: String? = nil

    var hasDetail: Bool {
        errorDetail != nil || httpStatusCode != nil || latencyMs != nil
    }
}
