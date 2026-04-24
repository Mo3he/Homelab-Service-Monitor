import SwiftUI

struct OnboardingView: View {
    var onDismiss: () -> Void

    @State private var page = 0

    private let pages: [(icon: String, color: Color, title: String, body: String)] = [
        (
            "server.rack",
            .blue,
            "Welcome to Peekr",
            "Monitor all your self-hosted services in one place. Status, latency, and live metrics - always at a glance."
        ),
        (
            "plus.circle.fill",
            .green,
            "Add Your Services",
            "Tap + and pick a service type. Peekr auto-detects the right API and pre-fills the port. Just enter your host and any credentials."
        ),
        (
            "chart.line.uptrend.xyaxis",
            .purple,
            "Live Metrics",
            "For supported services like AdGuard, Grafana, Portainer and more, Peekr fetches live stats directly from the API."
        ),
        (
            "wifi.exclamationmark",
            .orange,
            "Network Aware",
            "Local services are automatically paused when you're away from your home network - no false alarms, no timeouts."
        ),
        (
            "bell.badge.fill",
            .red,
            "Stay Notified",
            "Background checks run every 15 minutes. If a service goes offline you'll get a notification straight away."
        ),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { idx, p in
                    pageView(p).tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)

            VStack(spacing: 20) {
                // Dot indicators
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: i == page ? 8 : 6, height: i == page ? 8 : 6)
                            .animation(.spring(duration: 0.3), value: page)
                    }
                }

                if page < pages.count - 1 {
                    HStack {
                        Button("Skip") { onDismiss() }
                            .foregroundStyle(.secondary)
                            .font(.subheadline)

                        Spacer()

                        Button {
                            withAnimation { page += 1 }
                        } label: {
                            Label("Next", systemImage: "arrow.right")
                                .labelStyle(.titleAndIcon)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 32)
                } else {
                    Button {
                        onDismiss()
                    } label: {
                        Text("Get Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.horizontal, 32)
                }
            }
            .padding(.bottom, 48)
        }
        .ignoresSafeArea(edges: .top)
    }

    private func pageView(_ p: (icon: String, color: Color, title: String, body: String)) -> some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(p.color.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: p.icon)
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(p.color)
            }

            VStack(spacing: 12) {
                Text(p.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(p.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
            Spacer()
        }
    }
}
