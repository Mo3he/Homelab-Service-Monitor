import SwiftUI

/// Shared model for triggering AddServiceView from the add menu.
struct AddServiceItem: Identifiable {
    let id = UUID()
    let serviceType: ServiceType?
    /// Pre-filled host when the item comes from a network scan. Empty string when not applicable.
    var prefilledHost: String = ""
    /// Pre-filled port when the item comes from a network scan. 0 when not applicable.
    var prefilledPort: Int = 0
}

/// A standalone Menu button for adding services. Extracted from HomeView/iPadRootView so that
/// background refreshes (which cause parent body re-evaluations) cannot close the open menu -
/// SwiftUI maintains the menu state on the stable struct identity, not the parent's body.
struct AddServiceMenuButton: View {
    let onSelect: (ServiceType?) -> Void

    var body: some View {
        Menu {
            ForEach(ServiceType.allCases.filter { $0 != .generic }, id: \.self) { type in
                Button {
                    onSelect(type)
                } label: {
                    Label(type.displayName, systemImage: type.icon)
                }
            }
            Divider()
            Button {
                onSelect(nil)
            } label: {
                Label("Other / Custom", systemImage: "server.rack")
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}
