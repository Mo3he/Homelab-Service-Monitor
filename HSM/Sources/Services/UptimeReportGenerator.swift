import Foundation

/// Generates a self-contained HTML uptime report from UptimeStore data.
@MainActor
enum UptimeReportGenerator {
    static func generate(services: [Service]) -> Data {
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        var rows = ""
        for service in services {
            let u24 = UptimeStore.shared.uptimePercent(for: service.id, days: 1)
            let u7  = UptimeStore.shared.uptimePercent(for: service.id, days: 7)
            let u30 = UptimeStore.shared.uptimePercent(for: service.id, days: 30)
            let statusColor = colorFor(service.status)
            let u24str  = u24.map { String(format: "%.1f%%", $0) } ?? "--"
            let u7str   = u7.map  { String(format: "%.1f%%", $0) } ?? "--"
            let u30str  = u30.map { String(format: "%.1f%%", $0) } ?? "--"
            let latency = service.latencyMs.map { String(format: "%.0f ms", $0) } ?? "--"
            rows += """
            <tr>
              <td><span class="dot" style="background:\(statusColor)"></span>\(esc(service.name))</td>
              <td>\(esc(service.displayURL))</td>
              <td>\(esc(service.status.label))</td>
              <td class="mono">\(latency)</td>
              <td class="mono">\(u24str)</td>
              <td class="mono">\(u7str)</td>
              <td class="mono">\(u30str)</td>
            </tr>
            """
        }

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>HSM Status Report</title>
        <style>
          body { font-family: -apple-system, sans-serif; background: #f5f5f7; color: #1d1d1f; margin: 0; padding: 20px; }
          h1 { font-size: 1.5rem; margin-bottom: 4px; }
          p.sub { color: #6e6e73; font-size: .9rem; margin-bottom: 24px; }
          table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,.08); }
          th { text-align: left; padding: 12px 16px; background: #f5f5f7; font-size: .78rem; color: #6e6e73; text-transform: uppercase; letter-spacing: .05em; }
          td { padding: 12px 16px; border-top: 1px solid #f0f0f0; font-size: .9rem; }
          .mono { font-variant-numeric: tabular-nums; }
          .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; vertical-align: middle; }
          @media (prefers-color-scheme: dark) {
            body { background: #000; color: #f5f5f7; }
            table { background: #1c1c1e; box-shadow: none; }
            th { background: #2c2c2e; color: #8e8e93; }
            td { border-top-color: #2c2c2e; }
          }
        </style>
        </head>
        <body>
        <h1>HSM Status Report</h1>
        <p class="sub">Generated \(esc(dateStr)) &bull; \(services.count) service(s)</p>
        <table>
        <thead>
          <tr>
            <th>Service</th><th>URL</th><th>Status</th><th>Latency</th>
            <th>24h Uptime</th><th>7d Uptime</th><th>30d Uptime</th>
          </tr>
        </thead>
        <tbody>
        \(rows)
        </tbody>
        </table>
        </body>
        </html>
        """
        return Data(html.utf8)
    }

    private static func colorFor(_ status: ServiceStatus) -> String {
        switch status {
        case .online:   return "#30d158"
        case .offline:  return "#ff453a"
        case .degraded: return "#ff9f0a"
        default:        return "#8e8e93"
        }
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
