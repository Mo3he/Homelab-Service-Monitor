import SwiftUI

struct EventLogView: View {
    @ObservedObject var vm: HomeViewModel

    var body: some View {
        NavigationStack {
            Group {
                if vm.events.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(vm.events) { event in
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

                                Text(event.timestamp, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
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
