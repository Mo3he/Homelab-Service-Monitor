import SwiftUI

struct AddServiceView: View {
    @Environment(\.dismiss) private var dismiss

    let existing: Service?
    /// When set from the menu, we lock the service type and show its tailored form.
    let presetType: ServiceType?
    var onSave: (Service) -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var scheme: ServiceScheme
    @State private var group: String
    @State private var apiKey: String
    @State private var username: String
    @State private var password: String
    @State private var showValidationError = false
    @State private var isSanitizing = false
    @State private var checkInterval: Double
    @State private var notificationsEnabled: Bool

    private static let intervalOptions: [(label: String, value: Double)] = [
        ("Default (global)", 0),
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("15 minutes", 900),
    ]

    init(existing: Service? = nil, serviceType: ServiceType? = nil, onSave: @escaping (Service) -> Void) {
        self.existing    = existing
        self.presetType  = existing == nil ? serviceType : nil
        self.onSave      = onSave
        let preset       = existing == nil ? serviceType : nil
        _name            = State(initialValue: existing?.name ?? "")
        _host            = State(initialValue: existing?.host ?? "")
        let presetPort   = preset?.isCloudService == true ? 0 : (preset?.defaultPort ?? 0)
        _port            = State(initialValue: existing.map { String($0.port) } ?? (presetPort > 0 ? String(presetPort) : ""))
        _scheme          = State(initialValue: existing?.scheme ?? preset?.defaultScheme ?? .http)
        _group           = State(initialValue: existing?.group ?? "")
        _apiKey          = State(initialValue: existing?.apiKey ?? "")
        _username        = State(initialValue: existing?.username ?? "")
        _password        = State(initialValue: existing?.password ?? "")
        _checkInterval   = State(initialValue: existing?.checkInterval ?? 0)
        _notificationsEnabled = State(initialValue: existing?.notificationsEnabled ?? true)
    }

    private var isEditing: Bool { existing != nil }

    /// The effective service type: locked to presetType when adding, otherwise auto-detected from name.
    private var effectiveType: ServiceType {
        if let preset = presetType { return preset }
        if let existing { return existing.serviceType }
        return ServiceType.detect(from: name)
    }

    private var isCloudService: Bool { effectiveType.isCloudService }

    var body: some View {
        NavigationStack {
            Form {
                if isCloudService {
                    cloudServiceForm
                } else {
                    selfHostedForm
                }
            }
            .navigationTitle(isEditing ? "Edit \(effectiveType.displayName)" : "Add \(presetType?.displayName ?? "Service")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { submit() }
                        .disabled(!isValid)
                }
            }
            .alert("Invalid Input", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(isCloudService
                     ? "Please enter a name."
                     : "Please enter a valid host and port number.")
            }
        }
    }

    // MARK: - Cloud service form (GitHub, Claude, Copilot...)

    @ViewBuilder
    private var cloudServiceForm: some View {
        Section {
            TextField("Name", text: $name)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Service")
        } footer: {
            Text("\(effectiveType.displayName) is a cloud service. No host or port required.")
        }

        Section {
            if effectiveType.authMode == .tokenWithRepo {
                TextField(effectiveType.usernameLabel, text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            SecureField(effectiveType.apiKeyLabel, text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Authentication")
        } footer: {
            if let hint = effectiveType.apiKeyHint {
                Text(hint)
            }
        }

        Section {
            Picker("Check Interval", selection: $checkInterval) {
                ForEach(Self.intervalOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            Toggle("Notifications", isOn: $notificationsEnabled)
        } header: {
            Text("Options")
        }
    }

    // MARK: - Self-hosted service form

    @ViewBuilder
    private var selfHostedForm: some View {
        Section("Service Details") {
            TextField("Name (e.g. Glances)", text: $name)
                .textInputAutocapitalization(.words)

            Picker("Scheme", selection: $scheme) {
                ForEach(ServiceScheme.allCases, id: \.self) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: scheme) { _, new in
                if port.isEmpty && new.defaultPort > 0 { port = String(new.defaultPort) }
            }

            TextField("Host or IP address", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: host) { _, newValue in
                    guard !isSanitizing else { return }
                    isSanitizing = true
                    sanitizeHost(newValue)
                    isSanitizing = false
                }

            TextField("Port", text: $port)
                .keyboardType(.numberPad)

            TextField("Group (optional)", text: $group)
                .textInputAutocapitalization(.words)

            Picker("Check Interval", selection: $checkInterval) {
                ForEach(Self.intervalOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }

            Toggle("Notifications", isOn: $notificationsEnabled)
        }

        authSection
            .onChange(of: effectiveType) { oldType, newType in
                guard oldType != newType else { return }
                apiKey   = ""
                username = ""
                password = ""
            }

        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                Text(effectiveType == .generic
                     ? "Peekr will check HTTP status and response time."
                     : "Detected as \(effectiveType.displayName). Peekr will fetch live metrics from its API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Auth section (self-hosted only)

    @ViewBuilder
    private var authSection: some View {
        switch effectiveType.authMode {
        case .tokenWithRepo:
            Section {
                TextField(effectiveType.usernameLabel, text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(effectiveType.apiKeyLabel, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Authentication")
            } footer: {
                if let hint = effectiveType.apiKeyHint { Text(hint) }
            }

        case .token:
            Section {
                SecureField(effectiveType.apiKeyLabel, text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Authentication")
            } footer: {
                if let hint = effectiveType.apiKeyHint { Text(hint) }
            }

        case .credentials:
            Section {
                TextField(effectiveType.usernameLabel, text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Authentication")
            } footer: {
                if let hint = effectiveType.credentialsHint { Text(hint) }
            }

        case .none:
            EmptyView()
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return false }
        if isCloudService { return true }
        return !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil
    }

    // MARK: - Host sanitizer (self-hosted)

    private func sanitizeHost(_ raw: String) {
        var value = raw
        for prefix in ["https://", "http://", "tcp://"] {
            if value.lowercased().hasPrefix(prefix) {
                let schemeName = String(prefix.dropLast(3))
                if let s = ServiceScheme(rawValue: schemeName) { scheme = s }
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        if let slashIdx = value.firstIndex(of: "/") {
            value = String(value[..<slashIdx])
        }
        if let colonIdx = value.lastIndex(of: ":") {
            let potentialPort = String(value[value.index(after: colonIdx)...])
            if let portNum = Int(potentialPort), portNum > 0, portNum <= 65535 {
                value = String(value[..<colonIdx])
                if port.isEmpty { port = String(portNum) }
            }
        }
        if value != raw { host = value }
    }

    // MARK: - Submit

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        if isCloudService {
            guard !trimmedName.isEmpty else { showValidationError = true; return }
            // Cloud services get a hardcoded host; port is irrelevant but must be valid.
            let cloudHost = effectiveType.cloudServiceHost ?? "0.0.0.0"
            var service = Service(
                id: existing?.id ?? UUID(),
                name: trimmedName,
                host: cloudHost,
                port: 443,
                scheme: .https,
                group: nil,
                apiKey:   apiKey.isEmpty   ? nil : apiKey.trimmingCharacters(in: .whitespaces),
                username: username.isEmpty ? nil : username.trimmingCharacters(in: .whitespaces),
                password: nil
            )
            service.serviceType          = effectiveType
            service.status               = existing?.status ?? .unknown
            service.lastChecked          = existing?.lastChecked
            service.checkInterval        = checkInterval > 0 ? checkInterval : nil
            service.notificationsEnabled = notificationsEnabled
            onSave(service)
            dismiss()
            return
        }

        guard let portInt = Int(port), portInt > 0, portInt <= 65535 else {
            showValidationError = true
            return
        }
        var service = Service(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            host: host.trimmingCharacters(in: .whitespaces),
            port: portInt,
            scheme: scheme,
            group: group.trimmingCharacters(in: .whitespaces).isEmpty ? nil : group.trimmingCharacters(in: .whitespaces),
            apiKey:   apiKey.isEmpty   ? nil : apiKey.trimmingCharacters(in: .whitespaces),
            username: username.isEmpty ? nil : username.trimmingCharacters(in: .whitespaces),
            password: password.isEmpty ? nil : password
        )
        service.status         = existing?.status ?? .unknown
        service.latencyMs      = existing?.latencyMs
        service.lastChecked    = existing?.lastChecked
        service.httpStatusCode = existing?.httpStatusCode
        service.checkInterval  = checkInterval > 0 ? checkInterval : nil
        service.notificationsEnabled = notificationsEnabled
        onSave(service)
        dismiss()
    }
}

