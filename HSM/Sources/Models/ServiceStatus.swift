import SwiftUI

enum ServiceStatus: String, Codable {
    case online, degraded, offline, checking, unknown

    var color: Color {
        switch self {
        case .online:    return .green
        case .degraded:  return .orange
        case .offline:   return .red
        case .checking:  return .yellow
        case .unknown:   return .gray
        }
    }

    var icon: String {
        switch self {
        case .online:    return "checkmark.circle.fill"
        case .degraded:  return "exclamationmark.circle.fill"
        case .offline:   return "xmark.circle.fill"
        case .checking:  return "arrow.clockwise.circle.fill"
        case .unknown:   return "questionmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .online:    return "Online"
        case .degraded:  return "Degraded"
        case .offline:   return "Offline"
        case .checking:  return "Refreshing"
        case .unknown:   return "Unknown"
        }
    }
}
