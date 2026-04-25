import SwiftUI

struct MetricAlertConfigSheet: View {
    let metric: ServiceMetric
    let serviceID: UUID
    @ObservedObject var vm: HomeViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: MetricAlertStore.Rule.Kind
    @State private var aboveText: String
    @State private var belowText: String

    init(metric: ServiceMetric, serviceID: UUID, vm: HomeViewModel) {
        self.metric = metric
        self.serviceID = serviceID
        self.vm = vm

        let existing = MetricAlertStore.shared.rule(serviceID: serviceID, label: metric.label)
        _selectedKind  = State(initialValue: existing?.kind ?? (metric.isAlert ? .whenAlert : .whenValueChanges))
        _aboveText     = State(initialValue: existing?.thresholdAbove.map { formatThresholdValue($0) } ?? "")
        _belowText     = State(initialValue: existing?.thresholdBelow.map { formatThresholdValue($0) } ?? "")
    }

    private var currentNumeric: Double? { MetricAlertStore.extractNumeric(from: metric.value) }

    private var isValid: Bool {
        switch selectedKind {
        case .whenAlert, .whenValueChanges: return true
        case .threshold:
            return Double(aboveText) != nil || Double(belowText) != nil
        }
    }

    private var hasExistingRule: Bool {
        vm.hasMetricAlert(serviceID: serviceID, label: metric.label)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: metric.icon)
                            .foregroundStyle(metric.color)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.label)
                                .font(.headline)
                            Text("Current: \(metric.value)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Alert condition") {
                    Picker("Condition", selection: $selectedKind) {
                        Label("When flagged", systemImage: "exclamationmark.triangle")
                            .tag(MetricAlertStore.Rule.Kind.whenAlert)
                        Label("When value changes", systemImage: "arrow.triangle.2.circlepath")
                            .tag(MetricAlertStore.Rule.Kind.whenValueChanges)
                        Label("Custom threshold", systemImage: "slider.horizontal.3")
                            .tag(MetricAlertStore.Rule.Kind.threshold)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if selectedKind == .threshold {
                    Section {
                        HStack {
                            Text("Above")
                            Spacer()
                            TextField(currentNumeric.map { formatThresholdValue($0) } ?? "e.g. 80", text: $aboveText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                        }
                        HStack {
                            Text("Below")
                            Spacer()
                            TextField(currentNumeric.map { formatThresholdValue($0) } ?? "e.g. 10", text: $belowText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                        }
                    } header: {
                        Text("Threshold")
                    } footer: {
                        if let num = currentNumeric {
                            Text("Current value reads as \(formatThresholdValue(num)). Set Above and/or Below limits - a notification fires when the value first crosses a limit.")
                        } else {
                            Text("Set Above and/or Below limits. A notification fires when the value first crosses a limit.")
                        }
                    }
                }

                if hasExistingRule {
                    Section {
                        Button(role: .destructive) {
                            vm.removeMetricAlert(serviceID: serviceID, label: metric.label)
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Label("Remove Alert", systemImage: "bell.slash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        var rule = MetricAlertStore.Rule(kind: selectedKind)
        if selectedKind == .threshold {
            rule.thresholdAbove = Double(aboveText)
            rule.thresholdBelow = Double(belowText)
        }
        vm.setMetricAlertRule(rule, serviceID: serviceID, label: metric.label)
        dismiss()
    }
}

func formatThresholdValue(_ v: Double) -> String {
    v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(format: "%.2f", v)
}
