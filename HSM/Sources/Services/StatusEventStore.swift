import Foundation
import Combine

/// Single source of truth for the in-app status event log. Decoupled from HomeViewModel
/// so that BackgroundRefreshCoordinator can record transitions when the app is woken
/// in the background — without those, push notifications would fire but the in-app
/// "Status Log" tab would stay empty.
@MainActor
final class StatusEventStore: ObservableObject {
    static let shared = StatusEventStore()

    @Published private(set) var events: [StatusEvent] = []

    private let storageKey = "hsm.statusEvents"
    private let maxEvents = 200

    private init() { load() }

    /// Records a transition. No-op when the transition is meaningless (no change,
    /// from .unknown, or from .checking — the latter two are seed states, not real
    /// "the service moved offline" events).
    func recordTransition(previousStatus old: ServiceStatus,
                          newStatus new: ServiceStatus,
                          service: Service,
                          latencyMs: Double? = nil,
                          httpStatusCode: Int? = nil,
                          errorDetail: String? = nil) {
        guard old != new, old != .unknown, old != .checking else { return }
        let event = StatusEvent(
            serviceID: service.id,
            serviceName: service.name,
            oldStatus: old,
            newStatus: new,
            latencyMs: latencyMs,
            httpStatusCode: httpStatusCode,
            errorDetail: errorDetail
        )
        events.insert(event, at: 0)
        if events.count > maxEvents { events = Array(events.prefix(maxEvents)) }
        save()
    }

    func clear() {
        events.removeAll()
        save()
    }

    /// DEMO: append a fully-formed event (used by `DemoMode` only).
    func appendDemo(_ event: StatusEvent) {
        events.append(event)
        events.sort { $0.timestamp > $1.timestamp }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private func load() {
        // Migrate from UserDefaults if the file doesn't exist yet.
        if !FileManager.default.fileExists(atPath: Self.fileURL.path),
           let legacy = UserDefaults.standard.data(forKey: storageKey) {
            try? legacy.write(to: Self.fileURL, options: .atomic)
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([StatusEvent].self, from: data)
        else { return }
        events = decoded
    }

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("statusEvents.json")
    }()
}

/// Returns a human-readable failure reason suitable for display in the Status Log.
func statusEventErrorDetail(_ error: Error) -> String {
    if let ie = error as? IntegrationError {
        return ie.localizedDescription
    }
    if let ue = error as? URLError {
        switch ue.code {
        case .timedOut:                        return "Request timed out"
        case .cannotConnectToHost:             return "Cannot connect to host"
        case .cannotFindHost:                  return "Host not found"
        case .networkConnectionLost:           return "Network connection lost"
        case .notConnectedToInternet:          return "No internet connection"
        case .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot: return "Certificate not trusted"
        case .badServerResponse:               return "Bad server response"
        default:                               return ue.localizedDescription
        }
    }
    return error.localizedDescription
}
