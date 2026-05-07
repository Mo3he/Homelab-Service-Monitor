import SwiftUI

struct EventLogView: View {
    @ObservedObject var vm: HomeViewModel
    @State private var expandedEventID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if vm.events.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(vm.events) { event in
                            EventLogRow(event: event, isExpanded: expandedEventID == event.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard event.hasDetail else { return }
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedEventID = expandedEventID == event.id ? nil : event.id
                                    }
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Status Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !vm.events.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) {
                            vm.clearEvents()
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No Events Yet")
                .font(.title2.bold())
            Text("Status changes will appear here\nas services go online or offline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct EventLogRow: View {
    let event: StatusEvent
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: event.newStatus.icon)
                    .foregroundStyle(event.newStatus.color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.serviceName)
                        .font(.subheadline.bold())
                    HStack(spacing: 4) {
                        Text(event.oldStatus.label)
                            .foregroundStyle(event.oldStatus.color)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(event.newStatus.label)
                            .foregroundStyle(event.newStatus.color)
                    }
                    .font(.caption)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(event.timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if event.hasDetail {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 2)

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    Divider()
                        .padding(.vertical, 4)
                    if let detail = event.errorDetail {
                        Label(detail, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let code = event.httpStatusCode {
                        Label("HTTP \(code)", systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let latency = event.latencyMs {
                        Label("\(Int(latency)) ms response time", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
