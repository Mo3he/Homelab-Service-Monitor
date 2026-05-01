import Foundation

/// Demo mode for App Store screenshots. Seeds realistic fake data into every store and
/// short-circuits the refresh loop so the simulator (which can't reach real homelab services)
/// shows a fully-populated app.
///
/// Toggle `isEnabled` to false to ship; the call sites are guarded so it costs nothing at runtime.
@MainActor
enum DemoMode {
    static let isEnabled = false

    private static var didSeed = false

    static func seedIfNeeded() {
        guard isEnabled, !didSeed else { return }
        didSeed = true

        // Skip the onboarding sheet
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")

        // Wipe persisted demo state from prior launches so we don't accumulate orphan
        // alert rules / metric history under stale UUIDs.
        UserDefaults.standard.removeObject(forKey: "hsm.metricAlertRules2")
        UserDefaults.standard.removeObject(forKey: "hsm.metricHistory")
        UserDefaults.standard.removeObject(forKey: "hsm.metricLastValues")
        UserDefaults.standard.removeObject(forKey: "hsm.metricLastAlertState")
        UserDefaults.standard.removeObject(forKey: "hsm.statusEvents")

        let services = makeServices()
        ServiceStore.shared.replaceForDemo(services)

        let live = LiveDataStore.shared
        let history = StatusHistoryStore.shared
        let uptime = UptimeStore.shared
        let events = StatusEventStore.shared
        let metricHistory = MetricHistoryStore.shared

        let now = Date()
        for service in services {
            let snapshot = liveSnapshot(for: service, now: now)
            live.setLive(snapshot.live, for: service.id)
            live.setMetrics(snapshot.metrics, for: service.id)

            // Sparkline history (30 points)
            for (idx, ms) in latencySeries(for: service).enumerated() {
                history.recordDemo(serviceID: service.id,
                                   status: .online,
                                   latencyMs: ms,
                                   timestamp: now.addingTimeInterval(Double(idx - 30) * 60))
            }

            // Uptime (50 points across the last 30 days, all online)
            for i in 0..<50 {
                let t = now.addingTimeInterval(-Double(i) * 30 * 24 * 3600 / 50)
                uptime.recordDemo(serviceID: service.id, status: .online, timestamp: t)
            }

            // Per-metric history so the "Recent readings" list is populated
            for metric in snapshot.metrics {
                metricHistory.recordDemo(serviceID: service.id, label: metric.label,
                                         value: metric.value, isAlert: metric.isAlert,
                                         values: demoMetricSeries(for: service, metric: metric))
            }
        }

        // Status events for the Log tab — varied across services and times.
        let homeAssistant = services[0]
        let ugreen        = services[1]
        let openwrt       = services[3]
        let adguard       = services[4]
        let jellyfin      = services[5]
        let demoEvents: [(Service, ServiceStatus, ServiceStatus, TimeInterval)] = [
            (homeAssistant, .offline, .online,    -3600),                  // 1h ago, recovery
            (ugreen,        .degraded, .online,   -7000),                  // ~1h56m ago
            (ugreen,        .online, .degraded,   -7200),                  // 2h ago
            (jellyfin,      .degraded, .online,   -5 * 3600),              // 5h ago
            (adguard,       .degraded, .online,   -8 * 3600),              // 8h ago
            (adguard,       .online, .degraded,   -(8 * 3600 + 720)),      // 8h12m ago
            (openwrt,       .degraded, .online,   -(24 * 3600 - 120)),     // 23h58m ago
            (openwrt,       .online, .degraded,   -(24 * 3600)),           // 1d ago
        ]
        for (svc, old, new, dt) in demoEvents {
            events.appendDemo(StatusEvent(serviceID: svc.id, serviceName: svc.name,
                                          oldStatus: old, newStatus: new,
                                          timestamp: now.addingTimeInterval(dt)))
        }

        // Summary notification schedules. Write directly to UserDefaults so we don't
        // trigger rescheduleAll → requestAuthorization, which would block the UI with a prompt.
        let schedules: [MetricSummarySchedule] = [
            MetricSummarySchedule(
                name: "Home Assistant",
                serviceIDs: [homeAssistant.id],
                serviceNames: [homeAssistant.name],
                metricLabels: [],
                scheduleType: .daily(hour: 9, minute: 0),
                isEnabled: true
            ),
            MetricSummarySchedule(
                name: "NAS Health",
                serviceIDs: [ugreen.id],
                serviceNames: [ugreen.name],
                metricLabels: [],
                scheduleType: .daily(hour: 7, minute: 30),
                isEnabled: true
            ),
            MetricSummarySchedule(
                name: "Network",
                serviceIDs: [openwrt.id, adguard.id],
                serviceNames: [openwrt.name, adguard.name],
                metricLabels: [],
                scheduleType: .interval(hours: 6),
                isEnabled: true
            ),
        ]
        if let data = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(data, forKey: "hsm.summarySchedules")
        }

        // Metric alert rules — two per service so each section has multiple entries.
        MetricAlertStore.shared.setRule(.whenAlert,
                                        serviceID: homeAssistant.id,
                                        label: "Updates available")
        MetricAlertStore.shared.setRule(.whenValueChanges,
                                        serviceID: homeAssistant.id,
                                        label: "Sensors")
        var cpuTempRule = MetricAlertStore.Rule(kind: .threshold)
        cpuTempRule.thresholdAbove = 70
        MetricAlertStore.shared.setRule(cpuTempRule,
                                        serviceID: ugreen.id,
                                        label: "CPU temp")
        var volumeRule = MetricAlertStore.Rule(kind: .threshold)
        volumeRule.thresholdBelow = 100
        MetricAlertStore.shared.setRule(volumeRule,
                                        serviceID: ugreen.id,
                                        label: "Volume 1 free")
    }

    /// Returns a 10-point varied series for metrics where flat-line demo data looks fake
    /// (e.g. the Glances CPU "Recent readings" list shown in the App Store screenshots).
    /// `nil` falls back to repeating the live value 10 times.
    private static func demoMetricSeries(for service: Service, metric: ServiceMetric) -> [String]? {
        switch (service.serviceType, metric.label) {
        case (.glances, "CPU"):
            return ["3.2%", "3.4%", "5.1%", "4.7%", "8.9%", "3.0%", "3.3%", "6.2%", "3.1%", "3.2%"]
        default:
            return nil
        }
    }

    // MARK: - Services

    private static func makeServices() -> [Service] {
        // Deterministic UUIDs so MetricAlertStore/MetricHistoryStore stay consistent across launches
        func uuid(_ n: Int) -> UUID {
            UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
        }
        let homeAssistant: Service = {
            var s = Service(id: uuid(1), name: "Home Assistant", host: "192.168.2.2", port: 8123,
                            scheme: .http, apiKey: "demo")
            s.serviceType = .homeAssistant
            return s
        }()
        let ugreen: Service = {
            var s = Service(id: uuid(2), name: "UGREEN NAS", host: "192.168.2.9", port: 9443,
                            scheme: .https, username: "demo", password: "demo")
            s.serviceType = .ugreenNas
            return s
        }()
        let github: Service = {
            var s = Service(id: uuid(3), name: "Event Engine", host: "api.github.com", port: 443,
                            scheme: .https, apiKey: "demo", username: "homelab-user/event-engine")
            s.serviceType = .github
            return s
        }()
        let openwrt: Service = {
            var s = Service(id: uuid(4), name: "OpenWrt", host: "192.168.0.1", port: 80,
                            scheme: .http, username: "root", password: "demo")
            s.serviceType = .openWrt
            return s
        }()
        let adguard: Service = {
            var s = Service(id: uuid(5), name: "AdGuard Home", host: "192.168.2.2", port: 80,
                            scheme: .http, username: "admin", password: "demo")
            s.serviceType = .adGuard
            return s
        }()
        let jellyfin: Service = {
            var s = Service(id: uuid(6), name: "Jellyfin", host: "192.168.2.2", port: 8096,
                            scheme: .http, apiKey: "demo")
            s.serviceType = .jellyfin
            return s
        }()
        let grafana: Service = {
            var s = Service(id: uuid(7), name: "Grafana", host: "192.168.2.2", port: 3000,
                            scheme: .http, apiKey: "demo")
            s.serviceType = .grafana
            return s
        }()
        let glances: Service = {
            var s = Service(id: uuid(8), name: "Glances", host: "192.168.2.2", port: 61208,
                            scheme: .http)
            s.serviceType = .glances
            return s
        }()
        return [homeAssistant, ugreen, github, openwrt, adguard, jellyfin, grafana, glances]
    }

    // MARK: - Live snapshot per service

    private struct LiveSnapshot {
        let live: ServiceLiveData
        let metrics: [ServiceMetric]
    }

    private static func liveSnapshot(for service: Service, now: Date) -> LiveSnapshot {
        switch service.serviceType {
        case .homeAssistant:
            return LiveSnapshot(
                live: ServiceLiveData(status: .online, latencyMs: 19, httpStatusCode: 200,
                                      lastChecked: now.addingTimeInterval(-2)),
                metrics: [
                    ServiceMetric(label: "Updates available", value: "1", icon: "arrow.down.circle",
                                  color: .orange, isAlert: true),
                    ServiceMetric(label: "Entities", value: "1485", icon: "square.grid.2x2"),
                    ServiceMetric(label: "Lights", value: "12 on / 60 total", icon: "lightbulb.fill",
                                  color: .yellow),
                    ServiceMetric(label: "Automations", value: "45 on / 154 total",
                                  icon: "wand.and.stars", color: .yellow),
                    ServiceMetric(label: "Switches", value: "3 on / 18 total", icon: "switch.2"),
                    ServiceMetric(label: "Sensors", value: "412", icon: "sensor.fill"),
                ]
            )
        case .ugreenNas:
            return LiveSnapshot(
                live: ServiceLiveData(status: .online, latencyMs: 18, httpStatusCode: 200,
                                      lastChecked: now.addingTimeInterval(-50)),
                metrics: [
                    ServiceMetric(label: "CPU temp", value: "53°C", icon: "thermometer.medium",
                                  color: .green),
                    ServiceMetric(label: "Memory", value: "8.6 GB", icon: "memorychip", color: .green),
                    ServiceMetric(label: "Volume 1 free", value: "216.7 GB", icon: "internaldrive",
                                  color: .green),
                    ServiceMetric(label: "Volume 2 free", value: "4.8 TB", icon: "externaldrive",
                                  color: .green),
                    ServiceMetric(label: "Uptime", value: "12d 4h", icon: "clock"),
                    ServiceMetric(label: "Firmware", value: "Up to date", icon: "checkmark.seal",
                                  color: .green),
                ]
            )
        case .github:
            return LiveSnapshot(
                live: ServiceLiveData(status: .online, latencyMs: nil, httpStatusCode: 200,
                                      lastChecked: now.addingTimeInterval(-171)),
                metrics: [
                    ServiceMetric(label: "Stars", value: "5", icon: "star.fill", color: .yellow),
                    ServiceMetric(label: "Forks", value: "0", icon: "tuningfork"),
                    ServiceMetric(label: "Open issues", value: "0", icon: "exclamationmark.circle"),
                    ServiceMetric(label: "Watchers", value: "0", icon: "eye"),
                    ServiceMetric(label: "CI", value: "Passing", icon: "checkmark.seal.fill",
                                  color: .green),
                    ServiceMetric(label: "Rate limit", value: "5000 / 5000",
                                  icon: "speedometer", color: .green),
                ]
            )
        case .openWrt:
            return LiveSnapshot(
                live: ServiceLiveData(status: .online, latencyMs: 4, httpStatusCode: 200,
                                      lastChecked: now.addingTimeInterval(-51)),
                metrics: [
                    ServiceMetric(label: "Uptime", value: "20d 23h", icon: "clock"),
                    ServiceMetric(label: "Load avg", value: "0.00", icon: "gauge.medium",
                                  color: .green),
                    ServiceMetric(label: "Memory", value: "60 MB / 243 MB", icon: "memorychip",
                                  color: .green),
                    ServiceMetric(label: "Hostname", value: "EdgeRouter", icon: "wifi.router"),
                    ServiceMetric(label: "Kernel", value: "5.15.150", icon: "cpu"),
                ]
            )
        case .adGuard:
            return LiveSnapshot(
                live: ServiceLiveData(status: .online, latencyMs: 12, httpStatusCode: 200,
                                      lastChecked: now.addingTimeInterval(-51)),
                metrics: [
                    ServiceMetric(label: "Queries today", value: "148.4K", icon: "globe"),
                    ServiceMetric(label: "Blocked", value: "9.7K (6.6%)", icon: "shield.fill",
                                  color: .green),
                    ServiceMetric(label: "Avg processing", value: "8.0 ms", icon: "stopwatch",
                                  color: .green),
                    ServiceMetric(label: "Filter rules", value: "126.4K", icon: "list.bullet"),
                ]
            )
        case .jellyfin:
            return LiveSnapshot(
                live: ServiceLiveData(status: .online, latencyMs: 13, httpStatusCode: 200,
                                      lastChecked: now.addingTimeInterval(-51)),
                metrics: [
                    ServiceMetric(label: "Active streams", value: "1", icon: "play.circle.fill",
                                  color: .green),
                    ServiceMetric(label: "Movies", value: "847", icon: "film"),
                    ServiceMetric(label: "Episodes", value: "12,486", icon: "tv"),
                    ServiceMetric(label: "Version", value: "10.10.7", icon: "info.circle"),
                ]
            )
        case .grafana:
            return LiveSnapshot(
                live: ServiceLiveData(status: .online, latencyMs: 20, httpStatusCode: 200,
                                      lastChecked: now.addingTimeInterval(-51)),
                metrics: [
                    ServiceMetric(label: "Database", value: "Healthy", icon: "checkmark.circle.fill",
                                  color: .green),
                    ServiceMetric(label: "Version", value: "11.4.0", icon: "info.circle"),
                    ServiceMetric(label: "Dashboards", value: "27", icon: "square.grid.3x3.fill"),
                    ServiceMetric(label: "Data sources", value: "4", icon: "cylinder.split.1x2"),
                ]
            )
        case .glances:
            return LiveSnapshot(
                live: ServiceLiveData(status: .online, latencyMs: 4, httpStatusCode: 200,
                                      lastChecked: now.addingTimeInterval(-21)),
                metrics: [
                    ServiceMetric(label: "CPU", value: "3.2%", icon: "cpu", color: .green),
                    ServiceMetric(label: "Memory", value: "31.4%", icon: "memorychip", color: .green),
                    ServiceMetric(label: "Disk /", value: "62%", icon: "internaldrive"),
                    ServiceMetric(label: "Load 1m", value: "0.18", icon: "gauge.medium", color: .green),
                ]
            )
        default:
            return LiveSnapshot(
                live: ServiceLiveData(status: .online, latencyMs: 25, httpStatusCode: 200,
                                      lastChecked: now),
                metrics: []
            )
        }
    }

    private static func latencySeries(for service: Service) -> [Double] {
        let base: Double = service.serviceType == .openWrt ? 4
                         : service.serviceType == .glances ? 4
                         : service.serviceType == .adGuard ? 12
                         : service.serviceType == .jellyfin ? 13
                         : service.serviceType == .ugreenNas ? 18
                         : service.serviceType == .homeAssistant ? 19
                         : service.serviceType == .grafana ? 20
                         : 25
        // Mostly stable with a few spikes
        let pattern: [Double] = [0, 1, -1, 2, 0, 1, 0, 12, 0, -1,
                                 8, 0, 0, 1, 18, 2, 0, 0, 1, 0,
                                 -1, 1, 0, 14, 0, -1, 0, 1, 0, 0]
        return pattern.map { max(1, base + $0) }
    }
}
