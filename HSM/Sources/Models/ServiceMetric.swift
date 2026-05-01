import SwiftUI

struct ServiceMetric: Identifiable {
    var id = UUID()
    var label: String
    var value: String
    var icon: String
    var color: Color = .primary
    var isAlert: Bool = false
}
