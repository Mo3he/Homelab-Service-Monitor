# App Store Snapshot Workflow

How we capture App Store screenshots for Peekr. Treat this as a runbook — pick up
mid-flow if a session ends before all shots are done.

## Current state (2026-04-25)

- `DemoMode.isEnabled = true` in [DemoMode.swift](../Peekr/Sources/App/DemoMode.swift). **Must flip to `false` before shipping.**
- Booted simulator: iPhone 17 Pro Max (renders at 1320×2868 = Apple's 6.9" requirement).
- 10 raw PNGs captured in `Screenshots/sim/` (`iphone-01-home.png` … `iphone-10-alerts.png`).
- Curated/named copies in `Screenshots/` (`01-…jpeg` … `08-…jpeg`) are the carry-over set; replace them from the sim PNGs once we're happy with the new captures.

## Why the sim PNGs can't be viewed in-session

Image attachments are capped at 2000px per side. The sim PNGs are 2868px tall.
Make a downsized review copy (see "Review thumbnails" below) — keep the originals
for App Store Connect.

## Capture loop

Bundle id: `com.mblieden.peekr`. Booted UDID lives in `xcrun simctl list devices booted`.

```sh
UDID=$(xcrun simctl list devices booted | awk -F'[()]' '/Booted/ {print $2; exit}')
BUNDLE=com.mblieden.peekr

# 1. Build & install (only when code changed)
xcodebuild -scheme Peekr -destination "id=$UDID" -configuration Debug build
APP=$(find ~/Library/Developer/Xcode/DerivedData -name Peekr.app -path "*Debug-iphonesimulator*" | head -1)
xcrun simctl install "$UDID" "$APP"

# 2. Launch into a specific demo screen
#    Screen names are the rawValues of DemoNavigator.Screen:
#    home | serviceDetail | systemHealth | metricDetail | metricAlertConfig
#    summaryNotifications | addService | settings | eventLog | metricAlertsList
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
xcrun simctl launch "$UDID" "$BUNDLE" -peekr.demoScreen home
sleep 2  # let the seed + render settle

# 3. Capture
xcrun simctl io "$UDID" screenshot "Screenshots/sim/iphone-01-home.png"
```

`DemoMode.seedIfNeeded()` runs at app launch and wipes prior demo state — relaunch
between shots so each screen sees a clean seed.

## Screen → filename mapping

| # | DemoNavigator.Screen     | sim/ file                   | final                                  |
|---|--------------------------|-----------------------------|----------------------------------------|
| 1 | `home`                   | `iphone-01-home.png`        | `01-Home-ServicesList.jpeg`            |
| 2 | `serviceDetail`          | `iphone-02-detail.png`      | `02-ServiceDetail-HomeAssistant.jpeg`  |
| 3 | `systemHealth`           | `iphone-03-health.png`      | `03-OverallHealth.jpeg`                |
| 4 | `metricDetail`           | `iphone-04-metric.png`      | `04-MetricDetail-CPU.jpeg`             |
| 5 | `metricAlertConfig`      | `iphone-05-alertcfg.png`    | `06-MetricAlertConfig.jpeg`            |
| 6 | `summaryNotifications`   | `iphone-06-summary.png`     | `05-SummaryNotifications.jpeg`         |
| 7 | `addService`             | `iphone-07-add.png`         | `07-AddService.jpeg`                   |
| 8 | `settings`               | `iphone-08-settings.png`    | `08-Settings.jpeg`                     |
| 9 | `eventLog`               | `iphone-09-log.png`         | `09-StatusLog.jpeg`                    |
| 10| `metricAlertsList`       | `iphone-10-alerts.png`      | `10-MetricAlerts.jpeg`                 |

## Review thumbnails (so Claude can view them in-session)

```sh
mkdir -p Screenshots/sim/review
for f in Screenshots/sim/*.png; do
  sips -Z 1800 "$f" --out "Screenshots/sim/review/$(basename "$f")" >/dev/null
done
```

`-Z 1800` keeps the longest side ≤ 1800px (under the 2000 limit) and preserves
aspect ratio. Throwaway folder; never commit.

## Promote sim → final

When a shot looks right, encode JPEG into `Screenshots/` with the curated name
(see table). High-quality JPEG keeps repo size sane while remaining App-Store
acceptable.

```sh
sips -s format jpeg -s formatOptions 90 \
  Screenshots/sim/iphone-01-home.png \
  --out Screenshots/01-Home-ServicesList.jpeg
```

## Mac (Catalyst) capture

No `simctl` on Mac. Launch the built `.app` directly, capture the window via `screencapture -l <windowID> -o` (no shadow), then pad to 2880×1800 with `sips --padToHeightWidth`.

```sh
APP="$(find ~/Library/Developer/Xcode/DerivedData/Peekr-* -name Peekr.app -path '*Debug-maccatalyst*' -not -path '*Index.noindex*' | head -1)"
OUT=/path/to/Screenshots/sim-mac
mkdir -p "$OUT"

get_win_id() {
  swift -e '
import CoreGraphics
let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as! [[String:Any]]
for w in wins { if let o = w["kCGWindowOwnerName"] as? String, o.contains("Peekr") { print(w["kCGWindowNumber"]!); break } }
' 2>/dev/null
}

pkill -f "MacOS/Peekr" 2>/dev/null; sleep 1
open "$APP" --args -peekr.demoScreen home
sleep 4
WID=$(get_win_id)
screencapture -l "$WID" -o "$OUT/raw.png"
sips --padToHeightWidth 1800 2880 --padColor F2F2F7 "$OUT/raw.png" --out "$OUT/mac-01-home.png"
rm "$OUT/raw.png"
```

Repeat for each screen using the same screen names as the iPhone loop. Window padding color `F2F2F7` matches the Mac Catalyst grouped background.



App Store Connect requires screenshots for **each device class** the app declares.
Peekr supports iPhone, iPad, and Mac (Catalyst).

Re-run the capture loop on each simulator below. Same DemoMode/DemoNavigator wiring,
just a different `UDID`. Flip `DemoMode.isEnabled` back to `true` for the run, then
back to `false` before committing.

| Device class           | Simulator              | Required dims | Folder                  |
|------------------------|------------------------|---------------|-------------------------|
| iPhone 6.9" ✅ done    | iPhone 17 Pro Max      | 1320 × 2868   | `sim/` (current)        |
| iPad 13" ✅ done       | iPad Pro 13" (M5)      | 2064 × 2752   | `sim-ipad/`             |
| Mac (Catalyst) ✅ done | n/a — capture from app | 2880 × 1800   | `sim-mac/`              |

For iPad, change the booted device and adjust the `UDID` line; everything else
works as-is. Mac Catalyst can't be driven by `simctl` — launch the app on the Mac
desktop with the same `-peekr.demoScreen` arg via `open -a Peekr.app --args -peekr.demoScreen home`
and screenshot the window with `screencapture -l$(window-id) ...` or `Cmd+Shift+4 → Space → click`.

Once captured, follow the same `sips` promote step into named JPEGs but with a
device-class suffix, e.g. `01-Home-ServicesList-iPad.jpeg`.

## Pre-ship checklist

- [ ] All required final JPEGs present in `Screenshots/` (iPhone ✅, iPad TODO, Mac TODO)
- [ ] `DemoMode.isEnabled = false`
- [ ] `Screenshots/sim*/` not committed (in `.gitignore`)
- [ ] App built in Release with demo path verified gone (no seed at launch)
