import SwiftUI

struct NotificationSchedulesView: View {
    @ObservedObject var vm: HomeViewModel
    @State private var schedules: [MetricSummarySchedule] = []
    @State private var editingSchedule: MetricSummarySchedule?
    @State private var showingAdd = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if schedules.isEmpty {
                    ContentUnavailableView(
                        "No Notification Schedules",
                        systemImage: "bell.slash",
                        description: Text("Add a schedule to receive periodic metric summaries for one or more services.")
                    )
                } else {
                    ForEach(schedules) { schedule in
                        scheduleRow(schedule)
                    }
                    .onDelete { indices in
                        schedules.remove(atOffsets: indices)
                        SummaryNotificationManager.shared.schedules = schedules
                    }
                }

                Section {
                    Text("Summary notifications show live metrics at a scheduled time. Each summary can cover multiple services and works even when the app is closed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Summary Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                MetricSummaryEditView(vm: vm, existing: nil) { newSchedule in
                    schedules.append(newSchedule)
                    SummaryNotificationManager.shared.schedules = schedules
                }
            }
            .sheet(item: $editingSchedule) { schedule in
                MetricSummaryEditView(vm: vm, existing: schedule) { updated in
                    if let idx = schedules.firstIndex(where: { $0.id == updated.id }) {
                        schedules[idx] = updated
                        SummaryNotificationManager.shared.schedules = schedules
                    }
                }
            }
            .onAppear {
                schedules = SummaryNotificationManager.shared.schedules
            }
        }
    }

    private func scheduleRow(_ schedule: MetricSummarySchedule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.name)
                    .font(.headline)
                    .foregroundStyle(schedule.isEnabled ? .primary : .secondary)
                Text(schedule.scheduleType.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                let names = schedule.serviceNames.joined(separator: ", ")
                if !names.isEmpty {
                    Text(names)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { schedule.isEnabled },
                set: { newVal in
                    if let idx = schedules.firstIndex(where: { $0.id == schedule.id }) {
                        schedules[idx].isEnabled = newVal
                        SummaryNotificationManager.shared.schedules = schedules
                    }
                }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { editingSchedule = schedule }
    }
}

// MARK: - Edit / Create Sheet

struct MetricSummaryEditView: View {
    @ObservedObject var vm: HomeViewModel
    let existing: MetricSummarySchedule?
    let onSave: (MetricSummarySchedule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var scheduleName: String = ""
    @State private var selectedServiceIDs: Set<UUID> = []
    @State private var selectedMetricLabels: Set<String> = []
    @State private var scheduleType: ScheduleTypeOption = .daily
    @State private var intervalHours: Int = 4
    @State private var dailyTime: Date = {
        var c = DateComponents(); c.hour = 9; c.minute = 0
        return Calendar.current.date(from: c) ?? Date()
    }()

    @ObservedObject private var live = LiveDataStore.shared

    enum ScheduleTypeOption: String, CaseIterable {
        case daily = "Daily at time"
        case interval = "Every N hours"
    }

    var availableMetrics: [ServiceMetric] {
        // Union of all metrics from currently selected services, deduplicated by label
        var seen = Set<String>()
        return selectedServiceIDs.flatMap { id in
            live.metrics[id] ?? []
        }.filter { seen.insert($0.label).inserted }
    }

    var derivedName: String {
        let names = vm.services
            .filter { selectedServiceIDs.contains($0.id) }
            .map(\.name)
        return names.joined(separator: " + ")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Name
                Section("Name") {
                    TextField(derivedName.isEmpty ? "Summary name" : derivedName, text: $scheduleName)
                        .autocorrectionDisabled()
                }

                // Service multi-select
                Section {
                    ForEach(vm.services) { svc in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(svc.name).font(.body)
                                Text(svc.serviceType.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedServiceIDs.contains(svc.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedServiceIDs.contains(svc.id) {
                                selectedServiceIDs.remove(svc.id)
                            } else {
                                selectedServiceIDs.insert(svc.id)
                            }
                            // Clear metric selection when services change
                            selectedMetricLabels = []
                        }
                    }
                } header: {
                    Text("Services")
                } footer: {
                    if selectedServiceIDs.isEmpty {
                        Text("Select at least one service.")
                    } else {
                        Text("\(selectedServiceIDs.count) service\(selectedServiceIDs.count == 1 ? "" : "s") selected.")
                    }
                }

                // Schedule type
                Section("Schedule") {
                    Picker("Type", selection: $scheduleType) {
                        ForEach(ScheduleTypeOption.allCases, id: \.self) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .pickerStyle(.segmented)

                    if scheduleType == .daily {
                        DatePicker("Time", selection: $dailyTime, displayedComponents: .hourAndMinute)
                    } else {
                        Stepper("Every \(intervalHours) hour\(intervalHours == 1 ? "" : "s")",
                                value: $intervalHours, in: 1...24)
                    }
                }

                // Metric filter (optional)
                if !availableMetrics.isEmpty {
                    Section {
                        ForEach(availableMetrics) { metric in
                            HStack {
                                Image(systemName: metric.icon)
                                    .foregroundStyle(metric.color)
                                    .frame(width: 22)
                                Text(metric.label)
                                Spacer()
                                if selectedMetricLabels.contains(metric.label) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedMetricLabels.contains(metric.label) {
                                    selectedMetricLabels.remove(metric.label)
                                } else {
                                    selectedMetricLabels.insert(metric.label)
                                }
                            }
                        }
                    } header: {
                        Text("Metrics to include")
                    } footer: {
                        Text(selectedMetricLabels.isEmpty
                             ? "All metrics will be included (up to \(selectedServiceIDs.count > 1 ? "3" : "5") per service)."
                             : "\(selectedMetricLabels.count) metric\(selectedMetricLabels.count == 1 ? "" : "s") selected.")
                    }
                } else if !selectedServiceIDs.isEmpty {
                    Section {
                        Label("Refresh the selected services to load their metrics.", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(selectedServiceIDs.isEmpty)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { loadExisting() }
        }
    }

    private func save() {
        let cal = Calendar.current
        let type: MetricSummarySchedule.ScheduleType
        if scheduleType == .daily {
            type = .daily(
                hour: cal.component(.hour, from: dailyTime),
                minute: cal.component(.minute, from: dailyTime)
            )
        } else {
            type = .interval(hours: intervalHours)
        }

        let orderedServices = vm.services.filter { selectedServiceIDs.contains($0.id) }
        let finalName = scheduleName.trimmingCharacters(in: .whitespaces).isEmpty
            ? derivedName
            : scheduleName.trimmingCharacters(in: .whitespaces)

        var schedule = existing ?? MetricSummarySchedule(
            id: UUID(),
            name: finalName,
            serviceIDs: orderedServices.map(\.id),
            serviceNames: orderedServices.map(\.name),
            metricLabels: Array(selectedMetricLabels),
            scheduleType: type
        )
        schedule.name = finalName
        schedule.serviceIDs = orderedServices.map(\.id)
        schedule.serviceNames = orderedServices.map(\.name)
        schedule.metricLabels = Array(selectedMetricLabels)
        schedule.scheduleType = type

        onSave(schedule)
        dismiss()
    }

    private func loadExisting() {
        guard let e = existing else { return }
        scheduleName = e.name
        selectedServiceIDs = Set(e.serviceIDs)
        selectedMetricLabels = Set(e.metricLabels)
        switch e.scheduleType {
        case .daily(let h, let m):
            scheduleType = .daily
            dailyTime = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        case .interval(let h):
            scheduleType = .interval
            intervalHours = h
        }
    }
}

