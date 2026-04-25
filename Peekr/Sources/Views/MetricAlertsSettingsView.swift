import SwiftUI

struct MetricAlertsSettingsView: View {
    @ObservedObject var vm: HomeViewModel
    @ObservedObject private var alertStore = MetricAlertStore.shared

    private struct AlertEntry: Identifiable {
        let id: String         // "serviceID:label"
        let serviceName: String
        let label: String
        let rule: MetricAlertStore.Rule
        let serviceID: UUID
    }

    private var entries: [AlertEntry] {
        alertStore.rules.compactMap { key, rule in
            let parts = key.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let uuid = UUID(uuidString: String(parts[0])) else { return nil }
            let label = String(parts[1])
            let name = vm.services.first(where: { $0.id == uuid })?.name ?? "Unknown Service"
            return AlertEntry(id: key, serviceName: name, label: label, rule: rule, serviceID: uuid)
        }
        .sorted { a, b in
            a.serviceName == b.serviceName ? a.label < b.label : a.serviceName < b.serviceName
        }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Metric Alerts",
                    systemImage: "bell.slash",
                    description: Text("Open a service's detail view and tap the bell icon on a metric to set up an alert.")
                )
            } else {
                List {
                    ForEach(groupedEntries, id: \.serviceName) { group in
                        Section(group.serviceName) {
                            ForEach(group.entries) { entry in
                                HStack(spacing: 12) {
                                    Image(systemName: conditionIcon(entry.rule))
                                        .foregroundStyle(.orange)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.label)
                                            .font(.subheadline)
                                        Text(conditionDescription(entry.rule))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .onDelete { indices in
                                delete(indices: indices, in: group.entries)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Metric Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                EditButton()
            }
        }
    }

    // MARK: - Grouped data

    private struct ServiceGroup {
        let serviceName: String
        let entries: [AlertEntry]
    }

    private var groupedEntries: [ServiceGroup] {
        let names = Array(Set(entries.map(\.serviceName))).sorted()
        return names.map { name in
            ServiceGroup(
                serviceName: name,
                entries: entries.filter { $0.serviceName == name }
            )
        }
    }

    // MARK: - Helpers

    private func conditionIcon(_ rule: MetricAlertStore.Rule) -> String {
        switch rule.kind {
        case .whenAlert:        return "exclamationmark.triangle"
        case .whenValueChanges: return "arrow.triangle.2.circlepath"
        case .threshold:        return "slider.horizontal.3"
        }
    }

    private func conditionDescription(_ rule: MetricAlertStore.Rule) -> String {
        switch rule.kind {
        case .whenAlert:
            return "When flagged"
        case .whenValueChanges:
            return "When value changes"
        case .threshold:
            var parts: [String] = []
            if let a = rule.thresholdAbove { parts.append("above \(formatThresholdValue(a))") }
            if let b = rule.thresholdBelow { parts.append("below \(formatThresholdValue(b))") }
            return parts.isEmpty ? "Custom threshold" : parts.joined(separator: ", ")
        }
    }

    private func delete(indices: IndexSet, in groupEntries: [AlertEntry]) {
        for i in indices {
            let entry = groupEntries[i]
            MetricAlertStore.shared.removeRule(serviceID: entry.serviceID, label: entry.label)
        }
    }
}
