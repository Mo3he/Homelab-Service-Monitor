import SwiftUI

struct IconPickerView: View {
    @Binding var selectedIcon: String
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    // Curated set of SF Symbols suitable for service icons
    static let icons: [String] = [
        // Networking / servers
        "server.rack", "externaldrive.fill", "externaldrive.connected.to.line.below.fill",
        "network", "wifi", "wifi.router.fill", "wifi.circle.fill",
        "antenna.radiowaves.left.and.right", "dot.radiowaves.left.and.right",
        "globe", "globe.americas.fill", "link", "link.circle.fill",
        "arrow.triangle.branch", "arrow.triangle.swap", "arrow.triangle.2.circlepath",
        // Security
        "lock.fill", "lock.shield.fill", "lock.open.fill", "key.fill",
        "shield.fill", "shield.lefthalf.filled", "checkmark.shield.fill",
        // Media
        "play.rectangle.fill", "play.tv.fill", "tv.and.mediabox",
        "film.stack.fill", "photo.stack.fill", "camera.fill",
        "music.note", "music.note.list", "headphones",
        "bell.fill", "bell.badge.fill",
        "video.fill", "video.circle.fill",
        // Apps / services
        "house.fill", "building.2.fill", "building.fill",
        "cloud.fill", "icloud.fill", "icloud.and.arrow.up.fill",
        "doc.text.fill", "doc.fill", "folder.fill",
        "chart.line.uptrend.xyaxis", "chart.bar.fill", "waveform",
        "gauge.with.dots.needle.33percent", "gauge.medium", "speedometer",
        "shippingbox.fill", "cube.fill", "cube.box.fill",
        "magnifyingglass", "magnifyingglass.circle.fill",
        "person.crop.circle", "person.crop.circle.badge.plus", "person.3.fill",
        "gear", "gearshape.fill", "gearshape.2.fill",
        "terminal.fill", "chevron.left.forwardslash.chevron.right",
        "curlybraces", "curlybraces.square.fill", "wrench.and.screwdriver.fill",
        // Downloads / arrows
        "arrow.down.circle.fill", "arrow.up.circle.fill",
        "arrow.down.to.line.alt", "arrow.up.to.line.alt",
        // Misc
        "bolt.fill", "bolt.horizontal.fill",
        "sparkle", "star.fill", "sparkles",
        "heart.fill", "hand.thumbsup.fill",
        "exclamationmark.triangle.fill", "checkmark.circle.fill",
        "info.circle.fill", "questionmark.circle.fill",
        "tag.fill", "bookmark.fill",
        "calendar", "clock.fill",
        "map.fill", "location.fill",
        "printer.fill", "scanner.fill",
        "desktopcomputer", "laptopcomputer", "iphone",
        "cpu.fill", "memorychip.fill",
        "sun.max.fill", "moon.fill", "cloud.rain.fill",
        "leaf.fill", "drop.fill",
        "flame.fill", "snowflake",
    ]

    private var filtered: [String] {
        guard !searchText.isEmpty else { return Self.icons }
        return Self.icons.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filtered, id: \.self) { name in
                        iconCell(name)
                    }
                }
                .padding()
            }
            .searchable(text: $searchText, prompt: "Search icons")
            .navigationTitle("Choose Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func iconCell(_ name: String) -> some View {
        let isSelected = name == selectedIcon
        return Button {
            selectedIcon = name
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                    .frame(width: 56, height: 56)
                Image(systemName: name)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
        }
        .buttonStyle(.plain)
    }
}
