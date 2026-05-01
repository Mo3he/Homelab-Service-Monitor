import Foundation
import Security
import os

/// Persists service metadata to an App Group UserDefaults container (shared with the widget)
/// and syncs it via iCloud KV store. Credentials are never synced - they stay in the local Keychain.
@MainActor
final class ServiceStore: ObservableObject {
    static let shared = ServiceStore()

    @Published private(set) var services: [Service] = []

    private let key = "hsm.services.v3"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Last-saved credential snapshot per service. Used to skip redundant Keychain writes
    /// on every `save()` (move/reorder/status updates don't touch creds, so we shouldn't
    /// hit `SecItem*` for every one).
    private var savedCredsSnapshot: [UUID: CredsTriple] = [:]
    private struct CredsTriple: Equatable {
        let apiKey: String?
        let username: String?
        let password: String?
    }
    private let icloud = NSUbiquitousKeyValueStore.default

    private let defaults = UserDefaults(suiteName: "group.net.mohome.hsm") ?? .standard

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: icloud, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            if reason == NSUbiquitousKeyValueStoreServerChange ||
               reason == NSUbiquitousKeyValueStoreInitialSyncChange {
                Task { @MainActor in self.mergeFromiCloud() }
            }
        }
        icloud.synchronize()
        load()
    }

    func add(_ service: Service) {
        AppLogger.store.debug("Adding service: \(service.name, privacy: .public)")
        services.append(service)
        save()
    }

    func remove(at offsets: IndexSet) {
        for idx in offsets {
            AppLogger.store.debug("Removing service: \(self.services[idx].name, privacy: .public)")
            deleteCredentials(for: services[idx].id)
        }
        services.remove(atOffsets: offsets)
        save()
    }

    func remove(id: UUID) {
        if let svc = services.first(where: { $0.id == id }) {
            AppLogger.store.debug("Removing service by id: \(svc.name, privacy: .public)")
        }
        deleteCredentials(for: id)
        services.removeAll { $0.id == id }
        save()
    }

    func update(_ service: Service) {
        guard let idx = services.firstIndex(where: { $0.id == service.id }) else { return }
        services[idx] = service
        save()
    }

    /// Update multiple services in a single `@Published` assignment (one objectWillChange, one save).
    func batchUpdate(_ updates: [Service]) {
        var copy = services
        var changed = false
        for updated in updates {
            if let idx = copy.firstIndex(where: { $0.id == updated.id }) {
                copy[idx] = updated
                changed = true
            }
        }
        if changed {
            services = copy
            save()
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        services.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func reorder(to ordered: [Service]) {
        services = ordered
        save()
    }

    /// DEMO: replaces the in-memory list without writing to Keychain or UserDefaults.
    /// Used only by `DemoMode` for App Store screenshots.
    func replaceForDemo(_ list: [Service]) {
        services = list
    }

    // MARK: - Persistence

    private func save() {
        AppLogger.store.debug("Saving \(self.services.count) service(s)")
        // Strip credentials before writing; push them to Keychain instead.
        let sanitized = services.map { s -> Service in
            saveCredentials(for: s)
            var copy = s
            copy.apiKey   = nil
            copy.username = nil
            copy.password = nil
            return copy
        }
        guard let data = try? encoder.encode(sanitized) else { return }
        // Write to UserDefaults (App Group suite when entitlements are active - see PAID_ACCOUNT above)
        defaults.set(data, forKey: key)
        // Keep the TLS-trust registry in sync so sessions know which hosts are user-trusted.
        InsecureTrustRegistry.shared.reload(from: services)
        icloud.set(data, forKey: key)
        icloud.synchronize()
    }

    private func mergeFromiCloud() {
        guard let data = icloud.data(forKey: key),
              let remote = try? decoder.decode([Service].self, from: data)
        else { return }

        var merged = services
        for var remoteService in remote {
            remoteService.apiKey   = KeychainHelper.load(account: keychainKey("apikey",   id: remoteService.id))
            remoteService.username = KeychainHelper.load(account: keychainKey("username", id: remoteService.id))
            remoteService.password = KeychainHelper.load(account: keychainKey("password", id: remoteService.id))

            if let localIdx = merged.firstIndex(where: { $0.id == remoteService.id }) {
                let local = merged[localIdx]
                let useRemote: Bool
                switch (local.lastChecked, remoteService.lastChecked) {
                case (.none, .some): useRemote = true
                case (.some, .none): useRemote = false
                case (.some(let l), .some(let r)): useRemote = r > l
                case (.none, .none): useRemote = false
                }
                if useRemote {
                    var updated = remoteService
                    updated.status         = local.status
                    updated.latencyMs      = local.latencyMs
                    updated.lastChecked    = local.lastChecked
                    updated.httpStatusCode = local.httpStatusCode
                    merged[localIdx] = updated
                }
            } else {
                merged.append(remoteService)
            }
        }
        services = merged
        let sanitized = merged.map { s -> Service in
            var copy = s; copy.apiKey = nil; copy.username = nil; copy.password = nil; return copy
        }
        if let data = try? encoder.encode(sanitized) {
            defaults.set(data, forKey: key)
        }
    }

    private func load() {
        // Migrate any data written to UserDefaults.standard before App Group was added
        if defaults.data(forKey: key) == nil,
           let legacy = UserDefaults.standard.data(forKey: key) {
            defaults.set(legacy, forKey: key)
        }

        guard
            let data = defaults.data(forKey: key),
            let decoded = try? decoder.decode([Service].self, from: data)
        else {
            AppLogger.store.info("No persisted services found, loading sample data")
            services = Self.sampleServices
            // Keep the trust registry in sync even on the empty path so it never lags
            // behind `services` on a code path that skips `save()`.
            InsecureTrustRegistry.shared.reload(from: services)
            return
        }
        // Restore credentials from Keychain, falling back to any value still in UserDefaults JSON
        // (migration path for users upgrading from a build that stored credentials in UserDefaults).
        services = decoded.map { s in
            var copy = s
            copy.apiKey   = KeychainHelper.load(account: keychainKey("apikey",    id: s.id))
                         ?? legacyKeychainLoad(account: keychainKey("apikey",    id: s.id))
                         ?? s.apiKey
            copy.username = KeychainHelper.load(account: keychainKey("username",  id: s.id))
                         ?? legacyKeychainLoad(account: keychainKey("username",  id: s.id))
                         ?? s.username
            copy.password = KeychainHelper.load(account: keychainKey("password",  id: s.id))
                         ?? legacyKeychainLoad(account: keychainKey("password",  id: s.id))
                         ?? s.password
            return copy
        }
        AppLogger.store.info("Loaded \(self.services.count) service(s) from storage")
        // Persist immediately so any migrated credentials land in the new Keychain format
        // and are removed from UserDefaults.
        save()
    }

    /// Reads keychain items stored by older builds that did not set kSecAttrService.
    private func legacyKeychainLoad(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String:  kSecMatchLimitOne,
            kSecReturnData as String:  true
        ]
        var result: AnyObject?
        guard Security.SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Keychain helpers

    private func keychainKey(_ field: String, id: UUID) -> String {
        "hsm.\(field).\(id.uuidString)"
    }

    private func saveCredentials(for service: Service) {
        let id = service.id
        let current = CredsTriple(
            apiKey:   service.apiKey?.isEmpty   == false ? service.apiKey   : nil,
            username: service.username?.isEmpty == false ? service.username : nil,
            password: service.password?.isEmpty == false ? service.password : nil
        )
        if savedCredsSnapshot[id] == current { return }

        let prev = savedCredsSnapshot[id]
        if current.apiKey != prev?.apiKey {
            if let v = current.apiKey { KeychainHelper.save(v, account: keychainKey("apikey", id: id)) }
            else                      { KeychainHelper.delete(account: keychainKey("apikey", id: id)) }
        }
        if current.username != prev?.username {
            if let v = current.username { KeychainHelper.save(v, account: keychainKey("username", id: id)) }
            else                        { KeychainHelper.delete(account: keychainKey("username", id: id)) }
        }
        if current.password != prev?.password {
            if let v = current.password { KeychainHelper.save(v, account: keychainKey("password", id: id)) }
            else                        { KeychainHelper.delete(account: keychainKey("password", id: id)) }
        }
        savedCredsSnapshot[id] = current
    }

    private func deleteCredentials(for id: UUID) {
        KeychainHelper.delete(account: keychainKey("apikey",   id: id))
        KeychainHelper.delete(account: keychainKey("username", id: id))
        KeychainHelper.delete(account: keychainKey("password", id: id))
        savedCredsSnapshot.removeValue(forKey: id)
    }

    private static let sampleServices: [Service] = []
}
