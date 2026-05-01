import Foundation
import UserNotifications
import os

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

        AppLogger.refresh.debug("Background refresh started for \(services.count) service(s)")

        var newLiveData = live.liveData
        var newMetrics  = live.metrics
        var newErrors   = live.metricsError
        var pendingStoreUpdates: [Service] = []

        // Pre-filter: determine which services to check (synchronous, no I/O).
        var toCheck: [(Service, ServiceStatus)] = []
        for service in services {
            guard !Task.isCancelled else { break }
            if !network.canReachService(service) { continue }
            let previousStatus = live.liveData[service.id]?.status ?? service.status
            toCheck.append((service, previousStatus))
        }

        // Run all checks concurrently so a slow/timing-out service doesn't block others.
        // @MainActor is explicit here because BackgroundRefreshCoordinator has no `self`
        // for the compiler to infer isolation from — unlike HomeViewModel's task group.
        await withTaskGroup(of: Void.self) { group in
            for (service, previousStatus) in toCheck {
                group.addTask { @MainActor in
                    var liveEntry = ServiceLiveData(lastChecked: Date())

                    if service.serviceType.isCloudService {
                        let integration = IntegrationProvider.integration(for: service)
                        do {
                            var fetched = try await integration.fetchMetrics(service: service)
                            fetched = applyMetricOrder(fetched, serviceID: service.id)
                            liveEntry.status = fetched.isEmpty ? .degraded : .online
                            AppLogger.refresh.info("[BG] \(service.name, privacy: .public) (cloud) -> \(liveEntry.status.rawValue, privacy: .public)")
                            newLiveData[service.id] = liveEntry
                            newMetrics[service.id]  = fetched
                            newErrors.removeValue(forKey: service.id)
                            uptimeStore.record(serviceID: service.id, status: liveEntry.status)
                            pendingStoreUpdates.append(merged(service: service, liveEntry: liveEntry))
                            eventStore.recordTransition(previousStatus: previousStatus,
                                                        newStatus: liveEntry.status,
                                                        service: service)
                            // Check per-metric alert rules
                            if service.notificationsEnabled {
                                let alertStore = MetricAlertStore.shared
                                for metric in fetched where alertStore.shouldFire(metric: metric, serviceID: service.id) {
                                    await NotificationService.postMetricAlert(for: service, metric: metric)
                                }
                            }
                        } catch IntegrationError.transient(let retryAfter) {
                            AppLogger.refresh.info("[BG] \(service.name, privacy: .public) (cloud) rate-limited, retryAfter=\(retryAfter ?? 0)")
                            newErrors[service.id] = IntegrationError.transient(retryAfter: retryAfter).localizedDescription
                        } catch {
                            AppLogger.refresh.error("[BG] \(service.name, privacy: .public) (cloud) error: \(error.localizedDescription, privacy: .public)")
                            liveEntry.status = .degraded
                            newLiveData[service.id] = liveEntry
                            newMetrics[service.id]  = []
                            newErrors[service.id]   = error.localizedDescription
                            uptimeStore.record(serviceID: service.id, status: liveEntry.status)
                            pendingStoreUpdates.append(merged(service: service, liveEntry: liveEntry))
                        }
                        return
                    }

                    do {
                        let rawTimeout = UserDefaults.standard.double(forKey: "requestTimeoutSeconds")
                        let timeout = max(1, min(rawTimeout > 0 ? rawTimeout : 5, 60))
                        let result = try await PingService.shared.check(service, timeout: timeout)
                        liveEntry.latencyMs      = result.latencyMs
                        liveEntry.httpStatusCode = result.httpStatusCode
                        liveEntry.usingFailover  = result.usedFailover
                        let baseStatus: ServiceStatus = result.httpStatusCode.map {
                            (200..<400).contains($0) || $0 == 401 || $0 == 403 ? .online : .degraded
                        } ?? .online
                        if baseStatus == .online,
                           let threshold = service.latencyDegradedMs, result.latencyMs > threshold {
                            liveEntry.status = .degraded
                        } else {
                            liveEntry.status = baseStatus
                        }
                        AppLogger.refresh.info("[BG] \(service.name, privacy: .public) -> \(liveEntry.status.rawValue, privacy: .public) (\(Int(result.latencyMs))ms)")
                        await MainActor.run { LiveDataStore.shared.consecutiveFailures[service.id] = 0 }
                    } catch {
                        // If connectivity dropped entirely while the check was in flight,
                        // preserve last-known status.
                        if !network.isConnected { return }
                        // If the network probe says we're not on the local network, preserve
                        // last-known status instead of marking offline.
                        if service.isLocalNetwork && !network.canReachLocal { return }
                        // A cancelled error is transient (TCP reset, iOS killed the task) —
                        // not a genuine outage. Skip the update entirely.
                        if (error as? URLError)?.code == .cancelled {
                            AppLogger.refresh.info("[BG] \(service.name, privacy: .public) ping cancelled (transient), preserving previous status")
                            return
                        }
                        let failures = await MainActor.run {
                            let f = (LiveDataStore.shared.consecutiveFailures[service.id] ?? 0) + 1
                            LiveDataStore.shared.consecutiveFailures[service.id] = f
                            return f
                        }
                        let retryThreshold = UserDefaults.standard.integer(forKey: "retryCountBeforeOffline")
                        let threshold = retryThreshold > 0 ? retryThreshold : 1
                        if failures < threshold {
                            AppLogger.refresh.info("[BG] \(service.name, privacy: .public) failure \(failures)/\(threshold), not yet offline")
                            return
                        }
                        AppLogger.refresh.error("[BG] \(service.name, privacy: .public) ping failed: \(error.localizedDescription, privacy: .public)")
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
                        return
                    }

                    newLiveData[service.id] = liveEntry
                    historyStore.record(serviceID: service.id, status: liveEntry.status, latencyMs: liveEntry.latencyMs)
                    uptimeStore.record(serviceID: service.id, status: liveEntry.status)
                    pendingStoreUpdates.append(merged(service: service, liveEntry: liveEntry))
                    eventStore.recordTransition(previousStatus: previousStatus,
                                                newStatus: liveEntry.status,
                                                service: service)
                    let globalRecovery = UserDefaults.standard.object(forKey: "globalRecoveryNotificationsEnabled") as? Bool ?? true
                    if previousStatus == .offline && (liveEntry.status == .online || liveEntry.status == .degraded)
                       && service.notificationsEnabled && globalRecovery {
                        await NotificationService.postRecoveryAlert(for: service)
                    }

                    let integration = IntegrationProvider.integration(for: service)
                    do {
                        var fetched = try await integration.fetchMetrics(service: service)
                        if fetched.isEmpty && liveEntry.status != .offline {
                            updateResponseTime(in: &newMetrics, serviceID: service.id, latencyMs: liveEntry.latencyMs)
                        } else {
                            if let latency = liveEntry.latencyMs {
                                fetched.append(ServiceMetric(label: "Response Time", value: "\(Int(latency)) ms", icon: "clock", color: .secondary))
                            }
                            fetched = applyMetricOrder(fetched, serviceID: service.id)
                            newMetrics[service.id] = fetched
                        }
                        // Check per-metric alert rules
                        if service.notificationsEnabled {
                            let alertStore = MetricAlertStore.shared
                            for metric in (newMetrics[service.id] ?? []) where alertStore.shouldFire(metric: metric, serviceID: service.id) {
                                await NotificationService.postMetricAlert(for: service, metric: metric)
                            }
                        }
                        newErrors.removeValue(forKey: service.id)
                    } catch IntegrationError.transient(let retryAfter) {
                        newErrors[service.id] = IntegrationError.transient(retryAfter: retryAfter).localizedDescription
                    } catch {
                        updateResponseTime(in: &newMetrics, serviceID: service.id, latencyMs: liveEntry.latencyMs)
                        newErrors[service.id] = error.localizedDescription
                    }
                }
            }
        }

        // One publish for the persisted store, one publish for the live cache.
        if !pendingStoreUpdates.isEmpty {
            store.batchUpdate(pendingStoreUpdates)
        }
        live.applyBatch(liveData: newLiveData, metrics: newMetrics, errors: newErrors)
        AppLogger.refresh.debug("Background refresh complete — \(pendingStoreUpdates.count) service(s) updated")
    }

    private static func applyMetricOrder(_ fetched: [ServiceMetric], serviceID: UUID) -> [ServiceMetric] {
        guard let data = UserDefaults.standard.data(forKey: "hsm.metricOrder"),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data),
              let saved = dict[serviceID.uuidString], !saved.isEmpty else { return fetched }
        let indexed = Dictionary(uniqueKeysWithValues: fetched.map { ($0.label, $0) })
        let ordered = saved.compactMap { indexed[$0] }
        let remaining = fetched.filter { !saved.contains($0.label) }
        return ordered + remaining
    }

    private static func merged(service: Service, liveEntry: ServiceLiveData) -> Service {
        var updated = service
        updated.status         = liveEntry.status
        updated.latencyMs      = liveEntry.latencyMs
        updated.httpStatusCode = liveEntry.httpStatusCode
        updated.lastChecked    = liveEntry.lastChecked
        return updated
    }

    private static func updateResponseTime(in metricsDict: inout [UUID: [ServiceMetric]], serviceID: UUID, latencyMs: Double?) {
        guard var existing = metricsDict[serviceID] else { return }
        if let idx = existing.firstIndex(where: { $0.label == "Response Time" }) {
            if let latency = latencyMs {
                existing[idx] = ServiceMetric(label: "Response Time", value: "\(Int(latency)) ms", icon: "clock", color: .secondary)
            } else {
                existing.remove(at: idx)
            }
        } else if let latency = latencyMs {
            existing.append(ServiceMetric(label: "Response Time", value: "\(Int(latency)) ms", icon: "clock", color: .secondary))
        }
        metricsDict[serviceID] = existing
    }
}
