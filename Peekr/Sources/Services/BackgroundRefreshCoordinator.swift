import Foundation
import UserNotifications

/// Single source of truth for "refresh every service and update both the persisted store
/// and the live UI cache." Used by the BG task path so live state stays consistent with
/// `store.services` after the system wakes the app.
///
/// HomeViewModel.performBackgroundRefresh handles the foreground path because it also
/// updates events/haptics/etc. on the active view model. This coordinator covers the
/// lower bar of "BG refresh must not let LiveDataStore go stale."
@MainActor
enum BackgroundRefreshCoordinator {
    static func refreshAll() async {
        if DemoMode.isEnabled { return }
        let store        = ServiceStore.shared
        let live         = LiveDataStore.shared
        let network      = NetworkMonitor.shared
        let historyStore = StatusHistoryStore.shared
        let uptimeStore  = UptimeStore.shared
        let eventStore   = StatusEventStore.shared

        let services = store.services
        guard !services.isEmpty else { return }

        var newLiveData = live.liveData
        var newMetrics  = live.metrics
        var newErrors   = live.metricsError
        var pendingStoreUpdates: [Service] = []

        for service in services {
            guard !Task.isCancelled else { break }
            if !network.canReachLocal && service.isLocalNetwork { continue }

            let previousStatus = live.liveData[service.id]?.status ?? service.status
            var liveEntry = ServiceLiveData(lastChecked: Date())

            if service.serviceType.isCloudService {
                let integration = IntegrationProvider.integration(for: service)
                do {
                    let fetched = try await integration.fetchMetrics(service: service)
                    liveEntry.status = fetched.isEmpty ? .degraded : .online
                    newLiveData[service.id] = liveEntry
                    newMetrics[service.id]  = fetched
                    newErrors.removeValue(forKey: service.id)
                    pendingStoreUpdates.append(merged(service: service, liveEntry: liveEntry))
                    eventStore.recordTransition(previousStatus: previousStatus,
                                                newStatus: liveEntry.status,
                                                service: service)
                } catch IntegrationError.transient(let retryAfter) {
                    // Transient: keep prior live state + metrics, surface backoff message.
                    newErrors[service.id] = IntegrationError.transient(retryAfter: retryAfter).localizedDescription
                } catch {
                    liveEntry.status = .degraded
                    newLiveData[service.id] = liveEntry
                    newMetrics[service.id]  = []
                    newErrors[service.id]   = error.localizedDescription
                    pendingStoreUpdates.append(merged(service: service, liveEntry: liveEntry))
                }
                continue
            }

            do {
                let result = try await PingService.shared.check(service)
                liveEntry.latencyMs      = result.latencyMs
                liveEntry.httpStatusCode = result.httpStatusCode
                let baseStatus: ServiceStatus = result.httpStatusCode.map {
                    (200..<400).contains($0) || $0 == 401 || $0 == 403 ? .online : .degraded
                } ?? .online
                if baseStatus == .online,
                   let threshold = service.latencyDegradedMs, result.latencyMs > threshold {
                    liveEntry.status = .degraded
                } else {
                    liveEntry.status = baseStatus
                }
            } catch {
                liveEntry.status = .offline
                newLiveData[service.id] = liveEntry
                newMetrics[service.id]  = []
                newErrors.removeValue(forKey: service.id)
                historyStore.record(serviceID: service.id, status: .offline, latencyMs: nil)
                uptimeStore.record(serviceID: service.id, status: .offline)
                pendingStoreUpdates.append(merged(service: service, liveEntry: liveEntry))
                eventStore.recordTransition(previousStatus: previousStatus,
                                            newStatus: .offline,
                                            service: service)
                let globalOffline = UserDefaults.standard.object(forKey: "globalOfflineNotificationsEnabled") as? Bool ?? true
                if (previousStatus == .online || previousStatus == .degraded)
                   && service.notificationsEnabled && globalOffline {
                    await NotificationService.postOfflineAlert(for: service)
                }
                continue
            }

            newLiveData[service.id] = liveEntry
            historyStore.record(serviceID: service.id, status: liveEntry.status, latencyMs: liveEntry.latencyMs)
            uptimeStore.record(serviceID: service.id, status: liveEntry.status)
            pendingStoreUpdates.append(merged(service: service, liveEntry: liveEntry))
            eventStore.recordTransition(previousStatus: previousStatus,
                                        newStatus: liveEntry.status,
                                        service: service)
            let globalOffline = UserDefaults.standard.object(forKey: "globalOfflineNotificationsEnabled") as? Bool ?? true
            if previousStatus == .offline && (liveEntry.status == .online || liveEntry.status == .degraded)
               && service.notificationsEnabled && globalOffline {
                await NotificationService.postRecoveryAlert(for: service)
            }

            let integration = IntegrationProvider.integration(for: service)
            do {
                let fetched = try await integration.fetchMetrics(service: service)
                newMetrics[service.id] = fetched
                newErrors.removeValue(forKey: service.id)
            } catch IntegrationError.transient(let retryAfter) {
                newErrors[service.id] = IntegrationError.transient(retryAfter: retryAfter).localizedDescription
            } catch {
                newMetrics[service.id] = []
                newErrors[service.id]  = error.localizedDescription
            }
        }

        // One publish for the persisted store, one publish for the live cache.
        if !pendingStoreUpdates.isEmpty {
            store.batchUpdate(pendingStoreUpdates)
        }
        live.applyBatch(liveData: newLiveData, metrics: newMetrics, errors: newErrors)
    }

    private static func merged(service: Service, liveEntry: ServiceLiveData) -> Service {
        var updated = service
        updated.status         = liveEntry.status
        updated.latencyMs      = liveEntry.latencyMs
        updated.httpStatusCode = liveEntry.httpStatusCode
        updated.lastChecked    = liveEntry.lastChecked
        return updated
    }
}
