import SwiftUI

/// Dark mode icon (default). Render at 1024×1024 in the simulator, screenshot it,
/// then drop the PNG into AppIcon.appiconset/AppIcon-1024.png.
struct AppIconView: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Background
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.10, blue: 0.22),
                        Color(red: 0.04, green: 0.06, blue: 0.14)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Rack enclosure
                RoundedRectangle(cornerRadius: s * 0.048)
                    .fill(Color(red: 0.10, green: 0.14, blue: 0.26))
                    .overlay(
                        RoundedRectangle(cornerRadius: s * 0.048)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1.5)
                    )
                    .frame(width: s * 0.52, height: s * 0.72)
                    .shadow(color: .black.opacity(0.5), radius: s * 0.04)

                // Rack units
                VStack(spacing: s * 0.026) {
                    rackUnit(s: s, dotColor: Color(red: 0.2, green: 0.9, blue: 0.4))
                    rackUnit(s: s, dotColor: Color(red: 0.2, green: 0.9, blue: 0.4))
                    rackUnit(s: s, dotColor: Color(red: 1.0, green: 0.65, blue: 0.0))
                    rackUnit(s: s, dotColor: Color(red: 0.95, green: 0.25, blue: 0.25))
                }
            }
        }
        .ignoresSafeArea()
    }

    private func rackUnit(s: CGFloat, dotColor: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.018)
                .fill(Color(red: 0.14, green: 0.20, blue: 0.36))
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.018)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )

            HStack(spacing: 0) {
                // Left edge accent bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(dotColor.opacity(0.7))
                    .frame(width: s * 0.010, height: s * 0.046)
                    .padding(.leading, s * 0.022)

                // Drive slots
                HStack(spacing: s * 0.012) {
                    ForEach(0..<4) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(red: 0.09, green: 0.13, blue: 0.24))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                            .frame(width: s * 0.042, height: s * 0.046)
                    }
                }
                .padding(.leading, s * 0.018)

                Spacer()

                // Status LED
                Circle()
                    .fill(dotColor)
                    .frame(width: s * 0.030, height: s * 0.030)
                    .shadow(color: dotColor.opacity(0.9), radius: s * 0.022)
                    .padding(.trailing, s * 0.030)
            }
        }
        .frame(width: s * 0.42, height: s * 0.072)
    }
}

#Preview("Dark") {
    AppIconView()
        .frame(width: 1024, height: 1024)
}

// MARK: - Light Mode Icon

/// Light mode icon variant. Render at 1024×1024 in the simulator, screenshot it,
/// then add the PNG as a resource named "AppIconLight@2x.png" / "AppIconLight@3x.png".
/// After adding the PNG files, uncomment the CFBundleIcons block in Info.plist.
struct AppIconLightView: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Light background
                LinearGradient(
                    colors: [
                        Color.white,
                        Color.white
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Rack enclosure
                RoundedRectangle(cornerRadius: s * 0.048)
                    .fill(Color(red: 0.97, green: 0.98, blue: 1.00))
                    .overlay(
                        RoundedRectangle(cornerRadius: s * 0.048)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1.5)
                    )
                    .frame(width: s * 0.52, height: s * 0.72)
                    .shadow(color: .black.opacity(0.10), radius: s * 0.03)

                // Rack units
                VStack(spacing: s * 0.026) {
                    rackUnit(s: s, dotColor: Color(red: 0.13, green: 0.73, blue: 0.28))
                    rackUnit(s: s, dotColor: Color(red: 0.13, green: 0.73, blue: 0.28))
                    rackUnit(s: s, dotColor: Color(red: 0.95, green: 0.60, blue: 0.00))
                    rackUnit(s: s, dotColor: Color(red: 0.88, green: 0.18, blue: 0.18))
                }
            }
        }
        .ignoresSafeArea()
    }

    private func rackUnit(s: CGFloat, dotColor: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.018)
                .fill(Color(red: 0.91, green: 0.93, blue: 0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: s * 0.018)
                        .stroke(Color.black.opacity(0.07), lineWidth: 1)
                )

            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(dotColor.opacity(0.8))
                    .frame(width: s * 0.010, height: s * 0.046)
                    .padding(.leading, s * 0.022)

                HStack(spacing: s * 0.012) {
                    ForEach(0..<4) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(red: 0.84, green: 0.87, blue: 0.95))
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                            )
                            .frame(width: s * 0.042, height: s * 0.046)
                    }
                }
                .padding(.leading, s * 0.018)

                Spacer()

                Circle()
                    .fill(dotColor)
                    .frame(width: s * 0.030, height: s * 0.030)
                    .shadow(color: dotColor.opacity(0.5), radius: s * 0.018)
                    .padding(.trailing, s * 0.030)
            }
        }
        .frame(width: s * 0.42, height: s * 0.072)
    }
}

#Preview("Light") {
    AppIconLightView()
        .frame(width: 1024, height: 1024)
}
