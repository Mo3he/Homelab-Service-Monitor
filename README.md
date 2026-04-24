# Peekr

A native iOS/iPadOS/macOS app for monitoring your self-hosted homelab services and cloud API quotas. Built with SwiftUI, no external dependencies.

## Features

### Monitoring
- HTTP/HTTPS/TCP health checks with live latency
- 29 built-in integrations with live metrics fetched from each service's API
- Latency sparkline and 30-check history per service
- Uptime percentage over 24h, 7 days, and 30 days
- Status event log across all services

### Self-hosted services
Home Assistant, AdGuard Home, Grafana, Portainer, Jellyfin, Plex, Sonarr, Radarr, Prowlarr, Overseerr, Proxmox, TrueNAS, Traefik, Unifi Controller, Pi-hole, Nextcloud, Vaultwarden, Immich, Paperless-ngx, Frigate, ntfy, qBittorrent, OpenWrt, Glances, Nginx Proxy Manager, GitHub, and Generic (any HTTP endpoint)

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
- Background refresh every 15 minutes
- Offline and recovery alerts per service (toggle per service)
- Time-sensitive interruption level for offline alerts

### Organization
- Group services into custom sections
- Search and filter by status
- Reorder services and metrics by drag
- Per-metric hide/show (long-press any metric row in the detail view)

### Platform
- iPhone: tab bar layout
- iPad: three-column NavigationSplitView (services | detail | event log)
- Mac (Catalyst): full app + menu bar status indicator
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
  App/              - Entry point, background refresh, onboarding gate
  Models/           - Service, ServiceType, ServiceStatus, UptimeStore, StatusHistory
  Views/            - All SwiftUI views (iPhone, iPad, macOS, onboarding)
  ViewModels/       - HomeViewModel
  Services/         - PingService, ServiceStore, NetworkMonitor, KeychainHelper,
                      NotificationService, UptimeReportGenerator
    Integrations/   - One file per service type integration
  AppIntents/       - Siri Shortcuts / App Intents

PeekrWidget/        - WidgetKit extension (overview + configurable service widget)
project.yml         - XcodeGen spec (source of truth for the Xcode project)
Peekr/PrivacyInfo.xcprivacy - Privacy manifest
```

## Adding a New Integration

1. Add a case to `ServiceType.swift` with `displayName`, `icon`, `defaultPort`, `authMode`, etc.
2. Create `YourIntegration.swift` in `Services/Integrations/` conforming to `ServiceIntegration`
3. Register it in `IntegrationProvider.integration(for:)` in `ServiceIntegration.swift`

## License

MIT
