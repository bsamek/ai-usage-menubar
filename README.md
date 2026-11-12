# AI Usage

A small native macOS menu-bar app showing today's estimated AI API cost. Click
the total to see each harness and its models, costs, token counts, and a forecast
of today's final spend. The menu-bar number stays spend so far.

- Refreshes every 30 seconds, on wake, or with **Refresh now**.
- Forecasts the final daily total at today's workday pace using fixed **9 AM–6 PM
  hours in your Mac's local timezone**. Work hours are not editable; any previously
  saved custom hours are ignored.
- Shows the breakdown in a single native popover, without a separate window background.
- Keeps the last successful report after an error and marks it with `!`.
- Reads local AI usage histories. Includes every source ccusage detects, not
  just three hard-coded ones.
- Bundles ccusage **20.0.45** as a native executable. Bun/Node are not needed at
  runtime, and refreshing never checks npm or installs a package.
- Uses ccusage's normal pricing lookup and user configuration. It may fetch
  public pricing data; it does not call provider billing APIs.
- Costs are estimates, not invoices. Only this machine's saved history is counted.
  Usage generally appears when a response is saved, not token-by-token.

## Daily forecast

`Projected today = spend so far × full workday duration ÷ elapsed workday duration`.
For example, $6 spent by noon projects $18 over the fixed 9 AM–6 PM day.

- Waits until 9:30 AM (30 minutes after the workday starts) to avoid an unstable
  early estimate.
- At/after 6 PM, projects the recorded total, assuming no further spend today.
  Hours apply every day, including weekends.
- Includes all of today's recorded usage, including before work hours. Overnight
  activity can inflate the forecast; bursty usage and long unsaved responses can
  make it inaccurate. This is a pace estimate, not a billing prediction.
- Uses local calendar boundaries, including daylight-saving transitions. Each
  ccusage request explicitly selects today's local date and timezone, overriding
  any different timezone in ccusage configuration. A request crossing a date or
  timezone change is discarded and retried on the next refresh.
- A failed refresh keeps the same-day forecast at the last successful report's
  observation time and labels it cached; it does not silently reduce the rate
  while waiting for data. A previous-date or previous-timezone forecast is hidden.
  The old spend total remains visible, marked stale with `!`.
- Reuses ccusage's existing daily totals without new billing calls, log parsers,
  or stored usage samples. No work-hours preferences are read or saved.

## Build and install

Requires macOS 13+, Swift 6+ (Command Line Tools are enough), and Bun for the build.

```sh
swift run AIUsageChecks
./scripts/build-app.sh --install
open "$HOME/Applications/AI Usage.app"
```

The app has no Dock icon. Click its **$…** menu-bar item to open it or quit.
It is ad-hoc signed for local use, not notarized for distribution.

To start it automatically, add **AI Usage.app** under **System Settings →
General → Login Items & Extensions → Open at Login**. Installation does not
enable this automatically.

## Verify without UI

```sh
"$HOME/Applications/AI Usage.app/Contents/MacOS/AIUsageMenuBar" --check
"$HOME/Applications/AI Usage.app/Contents/MacOS/AIUsageMenuBar" --check-layout
```

`--check` prints spend so far, the forecast, and fixed local work hours.
`--check-layout` also measures the dropdown offscreen: short and long lists,
warm-up, projected, ended, empty, cached, previous-date, and changed-timezone
states. It checks that legacy custom hours are ignored and failed refreshes retain
cached data, without changing saved preferences. It does not open a window or take
a screenshot.

For `swift run` development, set `AI_USAGE_CCUSAGE` to the absolute path of a
native ccusage executable. The subprocess runs from your home directory so
project-local ccusage settings do not accidentally change the global total.

## Update ccusage

Change the pinned version in `Tools/package.json` and `Resources/Info.plist`,
rebuild, quit the running app, then open the installed copy. `Tools/bun.lock`
records the build dependency versions. The app does not auto-update itself.
