# AI Usage

A small native macOS menu-bar app showing today's estimated AI API cost. Click
the total to see each harness and its models, costs, and token counts.

- Refreshes every 30 seconds, on wake, or with **Refresh now**.
- Keeps the last successful report after an error and marks it with `!`.
- Reads the same local histories as `aitoday` and `aimonitor`; those scripts are
  unchanged. Includes every source ccusage detects, not just three hard-coded ones.
- Bundles ccusage **20.0.45** as a native executable. Bun/Node are not needed at
  runtime, and refreshing never checks npm or installs a package.
- Uses ccusage's normal pricing lookup and user configuration. It may fetch
  public pricing data; it does not call provider billing APIs.
- Costs are estimates, not invoices. Only this machine's saved history is counted.
  Usage generally appears when a response is saved, not token-by-token.

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

`--check-layout` also measures the dropdown offscreen and checks that short
breakdowns fit their content, long lists scroll, and neither can collapse. It
does not open a window or take a screenshot.

For `swift run` development, set `AI_USAGE_CCUSAGE` to the absolute path of a
native ccusage executable. The subprocess runs from your home directory so
project-local ccusage settings do not accidentally change the global total.

## Update ccusage

Change the pinned version in `Tools/package.json` and `Resources/Info.plist`,
rebuild, quit the running app, then open the installed copy. `Tools/bun.lock`
records the build dependency versions. The app does not auto-update itself.
