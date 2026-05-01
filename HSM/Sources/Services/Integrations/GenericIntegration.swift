import SwiftUI

struct GenericIntegration: ServiceIntegration {
    func fetchMetrics(service: Service) async throws -> [ServiceMetric] {
        // For services without a specific integration, just return HTTP status
        guard let url = service.url else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return [ServiceMetric(
            label: "HTTP Status",
            value: "\(code)",
            icon: code < 400 ? "checkmark.circle.fill" : "xmark.circle.fill",
            color: code < 400 ? .green : .red
        )]
    }
}

enum IntegrationError: LocalizedError, Equatable {
    case badURL
    case unexpectedFormat
    case authFailed
    /// Transient upstream issue (429/502/503/504). Caller should preserve previous
    /// metrics and back off rather than wipe the row.
    case transient(retryAfter: TimeInterval?)
    /// Non-transient 5xx. Report to user as a service-side error.
    case serviceError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .badURL:                     return "Invalid URL"
        case .unexpectedFormat:           return "Unexpected API response"
        case .authFailed:                 return "Authentication failed"
        case .transient(let retryAfter):
            if let r = retryAfter { return "Temporarily unavailable. Retry in \(Int(r))s." }
            return "Temporarily unavailable. Backing off."
        case .serviceError(let code):     return "Service error (HTTP \(code))"
        }
    }
}
