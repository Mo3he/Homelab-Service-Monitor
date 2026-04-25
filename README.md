# Peekr

A native iOS/iPadOS/macOS app for monitoring your self-hosted homelab services and cloud API quotas. Built with SwiftUI, no external dependencies.

## Features

### Monitoring
- HTTP/HTTPS/TCP health checks with live latency
- 30 built-in integrations with live metrics fetched from each service's API
- Latency sparkline and 30-check history per service
- Uptime percentage over 24h, 7 days, and 30 days
- Status event log across all services

### Self-hosted services
Home Assistant, AdGuard Home, Grafana, Portainer, Jellyfin, Plex, Sonarr, Radarr, Prowlarr, Overseerr, Proxmox, TrueNAS, UGREEN NAS (UGOS Pro), Traefik, Unifi Controller, Pi-hole, Nextcloud, Vaultwarden, Immich, Paperless-ngx, Frigate, ntfy, qBittorrent, OpenWrt, Glances, Nginx Proxy Manager, GitHub, and Generic (any HTTP endpoint)

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
- Home screen: small (overall status) and medium (status breakdown)
- Lock screen: circular and rectangular
- Configurable widget: pin any service to a widget and see its live status
- Widget reads from a shared App Group container - always up to date

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
- Mac (Catalyst): full app
- Mac (native macOS target): menu bar status indicator (requires a separate native macOS target; not available under Catalyst since `MenuBarExtra` is macOS-only)
- Onboarding flow on first launch

### Data
- Credentials stored securely in the system Keychain (never in UserDefaults or iCloud)
- iCloud KV sync for the service list across devices (requires paid Apple Developer account)
- Export services as JSON
- Export uptime report as a self-contained HTML file
- Import services from JSON

### Developer
- Siri Shortcuts integration: "Refresh Peekr", "Is [service] online in Peekr"
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
git clone https://github.com/Mo3he/Peekr.git
cd Peekr
xcodegen generate --spec project.yml

# Open in Xcode
open Peekr.xcodeproj
```

Build and run on a simulator or device. The widget extension is the `PeekrWidget` scheme.

## Project Structure

```
Peekr/Sources/
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

PeekrWidget/        - WidgetKit extension (overview + configurable service widget)
project.yml         - XcodeGen spec (source of truth for the Xcode project)
Peekr/PrivacyInfo.xcprivacy - Privacy manifest
```

Code paths gated by `// PAID_ACCOUNT:` comments (iCloud KV sync, App Group container, entitlement files in `project.yml`) are kept in-tree but commented out — they require an active Apple Developer Program subscription. Until the account is upgraded, the app uses `UserDefaults.standard` and ships per-device only.

## Adding a New Integration

1. Add a case to `ServiceType.swift` with `displayName`, `icon`, `defaultPort`, `authMode`, etc.
2. Create `YourIntegration.swift` in `Services/Integrations/` conforming to `ServiceIntegration`
3. Register it in `IntegrationProvider.integration(for:)` in `ServiceIntegration.swift`

## License

MIT
