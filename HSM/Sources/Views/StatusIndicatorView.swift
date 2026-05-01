import SwiftUI

struct StatusIndicatorView: View {
    let status: ServiceStatus
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    var body: some View {
        ZStack {
            // Pulsing ring uses scaleEffect (visual-only, doesn't affect layout).
            // Skipped entirely when the user prefers reduced motion.
            if status == .checking && !reduceMotion {
                Circle()
                    .stroke(status.color.opacity(pulseOpacity), lineWidth: 2)
                    .scaleEffect(pulseScale)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                            pulseScale = 1.5
                            pulseOpacity = 0
                        }
                    }
                    .onDisappear {
                        pulseScale = 1.0
                        pulseOpacity = 0.6
                    }
            }

            Circle()
                .fill(status.color.opacity(0.15))

            Image(systemName: status.icon)
                .foregroundStyle(status.color)
                .font(.system(size: size * 0.48, weight: .semibold))
                .symbolEffect(.pulse, isActive: status == .checking && !reduceMotion)
        }
        .frame(width: size, height: size) // fixed frame — pulsing ring uses scaleEffect so layout is stable
        .accessibilityLabel(status.label)
        .accessibilityHint(status == .checking ? "Refreshing service status" : "")
    }
}
