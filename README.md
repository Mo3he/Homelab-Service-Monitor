# Homelab Service Monitor

A native iOS/iPadOS/macOS app for monitoring your self-hosted homelab services and cloud API quotas. Built with SwiftUI, no external dependencies.

## Features

### Monitoring
- HTTP/HTTPS/TCP health checks with live latency
- 30 built-in integrations with live metrics fetched from each service's API
- Latency sparkline and 30-check history per service
- Uptime percentage over 24h, 7 days, and 30 days
- Status event log across all services

### Self-hosted services
Home Assistant, AdGuard Home, Grafana, Portainer, Jellyfin, Plex, Sonarr, Radarr, Prowlarr, Overseerr, Proxmox, TrueNAS, UGREEN NAS (UGOS Pro), Traefik, Unifi Controller, Pi-hole, Nextcloud, Vaultwarden, Immich, Paperless-ngx, Frigate, ntfy, qBittorrent, OpenWrt, Glances, Nginx Proxy Manager, and Generic (any HTTP endpoint)

UGREEN NAS handles the UGOS Pro auth flow end-to-end: username + password + a one-time 2FA code on first setup, then a cached trust token reused for subsequent logins so the OTP isn't needed again.

### Cloud API services
Dedicated monitoring for cloud APIs that don't require a host or port - just an API key:

- **GitHub** - repository stats (stars, forks, open issues), Actions CI status per workflow, API rate limit
- **Anthropic Claude** - available models, API connectivity check
- **GitHub Copilot** - subscription plan, suggestion/acceptance stats, API rate limit

Cloud services skip the TCP/HTTP ping entirely and derive their status from whether the API call succeeds.

### Smart network handling
- Automatically pauses local-only services when you're off your home network
- Uses a concurrent TCP probe, not WiFi SSID (no location permission needed)
- Per-service check intervals (30s to 15 min, independent of the global setting)

### Widgets
- **Overview widget** (small + medium + lock screen) — overall status summary; medium shows a configurable per-service list
- **Service widget** (small + medium + lock screen) — pin any service to a widget and see its live status and metrics
- **Monitor widget** (large) — up to 4 configurable services, each showing live status and up to 6 key metrics
- All widgets read live data from a shared App Group container and reload automatically when the app refreshes metrics

### Notifications
- Background refresh every 15 minutes (interval configurable in Settings)
- Offline and recovery alerts per service (toggle per service)
- Time-sensitive interruption level for offline alerts
- **Per-metric alert rules** — tap the bell on any metric in the detail view to set a rule:
  - *When flagged* — fires when the metric enters its alert state
  - *When value changes* — fires whenever the metric's string value changes
  - *Custom threshold* — fires when the extracted numeric value crosses an above/below limit (e.g. CPU temp > 80°C, free space < 10 GB)
- **Summary notifications** — schedule recurring summaries that bundle the latest metrics from one or more services. Daily at a specific time, or every N hours. Total alert count is reflected as the badge.

### Organization
- Group services into custom sections
- Search and filter by status
- Reorder services and metrics by drag
- Per-metric hide/show (long-press any metric row in the detail view)

### Platform
- iPhone: tab bar layout
- iPad: three-column NavigationSplitView (services | detail | event log)
- Mac (Catalyst): full app with menu bar status indicator
- Onboarding flow on first launch

### Data
- Credentials stored securely in the system Keychain with iCloud Keychain sync enabled, so API keys and passwords are available across your own devices without ever leaving Apple's secure enclave
- iCloud KV sync for the service list across devices
- Export services as JSON
- Export uptime report as a self-contained HTML file
- Import services from JSON

### Developer
- Siri Shortcuts integration: "Refresh Homelab Service Monitor", "Is [service] online in Homelab Service Monitor"
- Privacy manifest (PrivacyInfo.xcprivacy) declaring all required-reason API usage
- Export compliance declared (ITSAppUsesNonExemptEncryption = false)

## Requirements

- iOS 17+ / iPadOS 17+ / macOS 14+ (via Catalyst)
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting Started

```bash
# Install XcodeGen if you don't have it
brew install xcodegen

# Clone and generate the project
git clone https://github.com/Mo3he/Homelab-Service-Monitor.git
cd Homelab-Service-Monitor
xcodegen generate --spec project.yml

# Open in Xcode
open HSM.xcodeproj
```

Build and run on a simulator or device. The widget extension is the `HSMWidget` scheme.

## Project Structure

```
HSM/Sources/
  App/              - Entry point, background refresh registration, notification routing
  Models/           - Service, ServiceType, ServiceStatus, UptimeStore, StatusHistory,
                      MetricAlertStore, MetricHistoryStore, MetricSummarySchedule
  Views/            - All SwiftUI views (iPhone, iPad, macOS, onboarding,
                      metric alert config, notification schedules, settings)
  ViewModels/       - HomeViewModel, LiveDataStore (in-memory live status/metrics cache)
  Services/         - PingService, ServiceStore, NetworkMonitor, KeychainHelper,
                      NotificationService, SummaryNotificationManager,
                      BackgroundRefreshCoordinator, StatusEventStore,
                      InsecureTrust, UptimeReportGenerator
    Integrations/   - One file per service type integration
  AppIntents/       - Siri Shortcuts / App Intents

HSMWidget/        - WidgetKit extension (Overview, Service, and Monitor widgets)
project.yml         - XcodeGen spec (source of truth for the Xcode project)
HSM/PrivacyInfo.xcprivacy - Privacy manifest
```

## Adding a New Integration

1. Add a case to `ServiceType.swift` with `displayName`, `icon`, `defaultPort`, `authMode`, etc.
2. Create `YourIntegration.swift` in `Services/Integrations/` conforming to `ServiceIntegration`
3. Register it in `IntegrationProvider.integration(for:)` in `ServiceIntegration.swift`

## Roadmap

### Upcoming Integrations
- **Synology NAS** - DSM REST API, session-based auth, metrics: DSM version/uptime, volume/pool health, CPU + RAM utilization, disk SMART status

## License

MIT
