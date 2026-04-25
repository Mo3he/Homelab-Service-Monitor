#if os(macOS) && !targetEnvironment(macCatalyst)
import SwiftUI

/// Compact service list shown in the macOS menu bar popover.
struct MenuBarStatusView: View {
    @EnvironmentObject private var vm: HomeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Peekr", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                Button {
                    vm.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(vm.isRefreshing ? .degrees(360) : .zero)
                        .animation(vm.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: vm.isRefreshing)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isRefreshing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if vm.services.isEmpty {
                Text("No services configured")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(vm.services) { service in
                            menuRow(service: service)
                            Divider().padding(.leading, 36)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()

            // Summary footer
            HStack {
                Circle().fill(vm.overallHealth.color).frame(width: 8, height: 8)
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let date = vm.lastRefreshed {
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    private var footerText: String {
        let online = vm.onlineCount
        let total  = vm.services.count
        let offline = vm.offlineCount
        if offline > 0 { return "\(offline) offline, \(online)/\(total) online" }
        return "\(online)/\(total) online"
    }

    private func menuRow(service: Service) -> some View {
        HStack(spacing: 10) {
            Image(systemName: service.icon)
                .foregroundStyle(vm.effectiveStatus(for: service).color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(service.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let ms = service.latencyMs {
                Text(String(format: "%.0f ms", ms))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Circle()
                .fill(vm.effectiveStatus(for: service).color)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
#endif
