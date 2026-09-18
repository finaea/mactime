<p align="center">
  <img src="assets/icon.png" width="140" alt="MacTime icon">
</p>

<h1 align="center">MacTime</h1>

<p align="center">
  Screenshot timeline + app/browser activity tracking for macOS.<br>
  A minimal tracking solution like Manictime designed for Mac.
</p>

<p align="center">
  <img src="assets/screenshot.jpg" alt="MacTime Day tab">
</p>

## What it does

- **Screenshots** — captures every display on an interval (default 15s) via
  ScreenCaptureKit, full image + thumbnail per display, into per-day folders.
  Auto-prunes past the retention window (default 14 days). Skips capture while
  the screen is locked or you're idle. Show just the display that held the
  focused window, or every display side by side.
- **Activity tracking** — samples the frontmost app + focused window title every
  3s and collapses them into spans. Idle ("Away") spans are backdated to when
  input actually stopped; sleep is backfilled on wake as its own span kind.
  macOS maintenance dark wakes are recorded as sleep rather than inflating Away.
- **Browser URLs** — records the active tab URL when a browser is frontmost.
  Safari/Chrome via Apple Events, Firefox via the accessibility tree.
- **Day tab** — screenshot strip aligned to the clock, Status/Apps timeline with
  drag-to-select, zoomable via the overview bar, details list and day summary.
  Hovering the timeline previews the nearest capture; the docked viewer follows
  your hover in realtime and zooms/pans.
- **Statistics tab** — From/To range with presets (week, month, YTD, all time…)
  and four charts: Day duration, Top Applications, Top Computer Usage, and an
  attendance calendar heatmap.
- **Menu bar app** — starts quietly in the menu bar with no window and no dock
  icon; the tray icon opens the window, closing it keeps tracking. Optional
  start at login.

## What it doesn't do

MacTime is a pure record of what was on your screen and how long you spent in
each app. It is **not** a productivity suite — there is no tagging, no marking
or labelling of time ranges, no todo list, no Pomodoro timer, no note taking,
no projects/clients, no timesheets or invoicing. Nothing to fill in, nothing to
maintain: it just runs and answers "what was I doing at 3pm, and where did the
day go?".

## Install

Download the latest `MacTime-<version>-macos-arm64.dmg` from
[**Releases**](https://github.com/finaea/mactime/releases/latest), drag MacTime
to Applications, and **right-click → Open** on first launch (the build is
self-signed, not notarized — macOS will complain once).

Requires macOS 15+ on Apple silicon.

On first run, grant the permissions it asks for:

| Permission | Used for | Without it |
|---|---|---|
| Screen Recording | screenshots | no captures |
| Accessibility | window titles (and Firefox URLs) | app names only |
| Automation (per browser) | Safari/Chrome tab URLs | titles only |

## Day tab controls

| Input | Effect |
|---|---|
| Drag on timeline | select a time range (details/summary filter to it) |
| Scroll on timeline | pan the zoomed view (up = back in time) |
| Pinch on timeline | zoom around the cursor |
| Drag on overview bar | select a zoom window; drag inside to pan, edges to resize |
| Scroll / pinch on overview bar | zoom in/out |
| Double-click overview bar | reset to the full day |
| Hover the timeline | preview the nearest capture (position configurable in Settings) |
| `Space` | open the docked screenshot viewer (live) · press again to freeze/unfreeze |
| Click a thumbnail | open the viewer frozen on that capture |
| Scroll / pinch in the viewer | zoom the screenshot (1×–8×) |
| Drag in the viewer | pan while zoomed · double-click to reset to fit |
| `Esc` / ✕ | close the viewer |
| Click the date | calendar popover for jumping to any day |

The viewer is on `Space` rather than an F-key because keyboards whose firmware
owns the F-row as media keys never deliver `F12` to an app at all.

## Data

Everything lives in `~/Library/Application Support/MacTime/`:
SQLite database (`MacTime.db`: activity spans + screenshot index) and
`Screenshots/yyyy-MM-dd/` image folders. Nothing leaves the machine.

### Encryption at rest

Screenshots, window titles and browser URLs are encrypted with AES-256-GCM
before they reach the disk. `~/Library/Application Support/` is not covered by
macOS privacy protection, while Screen Recording is — so anything running as you
can read that folder with no prompt at all. Encrypted, all it gets is
ciphertext. The capture files keep their `.jpg` names but are no longer images,
which is why Finder can't preview them.

Deliberately left in the clear: span start/end, the app's bundle ID, and whether
a span was active, idle or sleep, so the statistics stay one SQL query each. The
trade, stated plainly: someone reading the database still learns which apps you
used when. They learn nothing about what was on the screen, what the windows
were called, or which pages were open.

**The key is in your login keychain and nowhere else.** It is stored
`WhenUnlockedThisDeviceOnly`, which is macOS's way of keeping it out of iCloud
Keychain and out of any backup that could restore it onto another machine. That
is the intended posture, and it has one consequence worth meeting here rather
than on the day:

> **Copying `~/Library/Application Support/MacTime/` to a new Mac leaves you an
> unreadable archive, by design.** The data travels; the key does not.

MacTime detects that instead of quietly starting over. A small `key-check` file
next to the database records that the store was sealed under *some* key, so a
launch that cannot reach that key stops recording and says so, rather than
minting a fresh key on top of history it can no longer read. Two ways out:

- **Bring the key back** — restore the login keychain the data was sealed under
  and everything opens again. This is the only way to read existing captures.
- **Or start over** — Settings ▸ Delete data ▸ Everything. That clears the
  `key-check` interlock along with the data, and the next launch opens a new
  encrypted store. The keychain item itself is left alone: MacTime carries on
  with the key it already has, or makes one if that has gone too.

There is no recovery path that doesn't involve the key. That is what makes the
encryption worth anything, and it is the trade for the folder no longer being
readable by everything else on your Mac.

### Deleting

Settings → Delete data erases a single day, a date range, or everything —
screenshots and activity history together, files as well as rows, and the
database is compacted afterwards so the deleted rows aren't left readable in
its free pages. Deleting the folder in Finder still works, but it leaves the
database pointing at captures that are gone.

Day folders are named `yyyy-MM-dd` in a fixed Gregorian, Latin-digit spelling
regardless of your region. Retention and deletion both work off capture
timestamps rather than those names — before 1.1 the folder names followed the
system region, and comparing them meant retention could stop pruning entirely
on a machine whose calendar or numbering system changed. Folders written under
the old spelling are still read, and their day column is corrected on first
launch.

## Building from source

Swift 6.1+, macOS 15 SDK.

```bash
swift build                      # compile          (needs Xcode — see below)
tools/typecheck.sh               # type-check everything, SwiftUI included
tools/run-tests.sh               # checks for the date math and the store (Tests/)
tools/bundle-macos.sh            # build + assemble publish/MacTime.app + sign
swift tools/make-icons.swift     # regenerate icns + dmg artwork
tools/make-dmg.sh                # package the dmg
```

**Compiling needs Xcode, not just the Command Line Tools.** SwiftUI's `@State`
is a macro, and the `SwiftUIMacros` plugin that expands it ships with Xcode —
it is not in the Command Line Tools (verified absent on CLT 27.0.0). Without it
every `@State` fails before the type checker reads any of your code, so
`swift build`, `swift test` and `tools/bundle-macos.sh` all fail with hundreds
of errors that have nothing to do with the change you just made.

The two scripts work regardless, and on a CLT-only machine they are the whole
verification story:

- `tools/typecheck.sh` type-checks the entire app, SwiftUI views included, by
  swapping `@State` for an equivalent property wrapper in a throwaway copy of
  the tree (`State()` is the only macro this app uses). It catches real type
  errors in `UI/*.swift` and reports them against the real source paths. It
  type-checks only — it doesn't produce a binary.
- `tools/run-tests.sh` compiles the checks in `Tests/` into a plain executable
  rather than a SwiftPM test target, for the same reason: `swift test` would
  build the app target and hit the same wall. It can only take SwiftUI-free
  sources, which is why the date math, day-key rules and store live in files
  that import at most AppKit.

Signing: run `tools/make-dev-identity.sh` once (on the machine, not over ssh)
to create a stable self-signed identity — otherwise builds are ad-hoc signed
and macOS drops the TCC permission grants on every rebuild. The bundle script
picks the identity up automatically.

## Layout

```
Sources/MacTime/
├── Trackers/    ActivityService, ScreenshotService, BrowserService, IdleMonitor, AX, PowerState
├── Store/       sqlite3 wrapper + queries (spans, screenshots, day stats)
├── UI/          DayView (timeline/viewer/zoom), StatsView (4 charts), Settings
└── Support/     settings, formatters, app colors, image cache
tools/           typecheck, tests, bundle, dmg, icon generation, signing identity
```

## License

MIT — see [LICENSE](LICENSE).
