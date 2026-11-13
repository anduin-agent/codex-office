# Codex Office

English · [简体中文](README.zh-CN.md)

Codex Office is a macOS menu bar app that shows local Codex chats in a two-floor 3D office. It reads session logs and desktop metadata directly from your Mac. The app does its work locally and does not need a separate service, account, or API key.

Download the DMG from [GitHub Releases](https://github.com/anduin-agent/codex-office/releases/latest), open it, and drag Codex Office into Applications. The app supports macOS 12 or later on Apple silicon and macOS 13 or later on Intel. It runs without Python, Apple Command Line Tools, or `zstd`.

Building from source requires Apple Command Line Tools with the macOS 26 SDK or later.

```sh
make mac-office
open "build/Codex Office.app"
```

Click the menu bar icon to open the office. Click it again or click outside the panel to close it. The 3D scene pauses while hidden. Click a workstation to see its status, or double-click to open the Codex chat. When a session log reports a cumulative token count, the workstation details display that count.

The menu bar shows the number of running main chats. When chats are waiting for confirmation, that status and count take priority. In Office Settings, choose today's tokens, token speed, or remaining plan quota to show alongside the counts. The menu bar robot walks at a pace set by usage in the last minute and stops when idle. Office robots type and blink while their chats are running. When the local Codex desktop reports a pending approval or question, the robot stops typing, looks up, and shows a waiting label. Both animations respect macOS Reduce Motion. Open the Usage panel to see recent usage by chat, a 30-day chart, and totals for the readable local logs.

Use the Office and Usage tabs below the token summary to switch views. Hover over a bar for the date, tokens and estimated API cost. Select a bar to see its daily chat ranking. Usage is calculated on this Mac from Codex session logs and archives. A built-in Zstandard decoder reads compressed archives. Usage shows the current quota windows from the latest logged allowance, with the 5-hour window above the weekly window when both are available. The menu bar quota shows the longest active window.

The weekly and five-hour quota rows show local tokens recorded since the start of each cycle. Capacity is extrapolated from the local token count and the quota percentage at the same time. The estimate reflects the current usage mix. Incomplete data, usage below 5%, and exhausted quotas show the observed count alone. The five-hour row appears when the local log has an active window.

Choose **Usage details** to open a resizable window with date, project and model filters. Select a session to see the tokens attributed to each model in the selected range. The app reads Codex logs and session metadata through its Swift collector. It needs no Python process or local web service. A separate personal dashboard can continue collecting from the same Codex logs while retaining its own historical database and other sources.

Usage rankings sort by the combined tokens of each main chat, its subagents, and any linked automatic reviews. Expand a group to see each session's own usage, or collapse all groups at once. Reviews with no verified parent appear together under Unassigned automatic reviews.

The summary includes today's estimated API cost. The Usage tab totals all readable local history, while the chart and peak day cover the last 30 days. Select a day to see input and output tokens and the share of recorded input tokens served from cache. The amounts beside token counts are API list-price equivalents in USD. Actual charges may differ.

When local logs report weekly or 5-hour quotas, Usage shows the local usage and estimated capacity of the current and last recorded cycle for each window. The previous cycle's token count stops at reset. Its capacity uses the last usable snapshot for the same account: local tokens through that snapshot divided by the usage percentage at that time (at least 5%, below 100%). Each estimate has a ±15% tolerance; overlapping ranges are considered close, while separated ranges suggest a possible decrease or increase. No comparison is made with insufficient data or different recorded plans. Models, tasks, and usage on other devices can affect the estimate.

Estimates use [OpenAI's standard API rates](https://developers.openai.com/api/docs/pricing) in USD and indicate partial coverage when some tokens cannot be priced. The app ships with a local rate table and checks the public pricing page at most once per local day while the panel is open. It keeps the last usable rates if the refresh fails.

Git workspaces appear as projects. Use the settings button in the panel or “Settings…” in the right-click menu to edit project aliases, the coordination section, and chat assignments. The coordination section is blank on a fresh install. Changes are saved in `~/Library/Application Support/Codex Office/office.json`. Manual collaboration links and acknowledgements stay in the app’s macOS preferences.

To add a project alias, select a folder registered in local Codex or click **Browse…** to choose another folder, then enter the name to show in Office.

Office Settings lists sections from the local Codex sidebar. Show all sections or select which ones appear in the office, including chats without a section. The menu bar counts and usage totals cover local chats across all sections.

Choose Simplified Chinese, English, or Follow system under Office settings → Language. Language changes take effect when selected, and settings save automatically. Settings also shows the version and the short Git revision when built from a checkout. Launch at Login is available on macOS 13 and later. Earlier versions can add the app manually in Login Items. The office shows today’s usage and the token rate side by side. The Usage panel shows the quota reset time and a countdown in minutes.

For release builds, set `OFFICE_RELEASE_REPO=owner/repo` to a public GitHub repository and publish a stable release tagged like `v1.2.3` with the DMG attached. Check for Updates queries the latest stable release on demand and offers to open its release page. Development builds leave the release channel unconfigured by default.

Automatic coordination comes from successful local Codex task dispatches. When an event confirms a file change in another project, that project briefly lights up and the chat’s character stays at its own desk.

The collector uses `CODEX_HOME` when it is set and otherwise reads `~/.codex`. You can also point an instance at another Codex directory.

```sh
open -na "build/Codex Office.app" --args -officeCodexHome "$HOME/path/to/codex-home"
```

To import an earlier Office settings JSON file, run this command once before saving settings in the new app. It copies project aliases, the coordination section, and chat assignments. If an Office settings file already exists, the import leaves it intact.

```sh
"build/Codex Office.app/Contents/MacOS/CodexOffice" --import-settings "/path/to/previous-office-settings.json"
```

`make mac-office` builds the AppKit shell, WebKit scene, and Swift collector into `build/Codex Office.app`. When rebuilding an existing installation, set `OFFICE_BUNDLE_ID` to the existing bundle identifier to keep the app’s preferences. `make test` uses Python 3 on the development machine to create fixtures and verifies the Swift collector’s activity, usage, coordination, waiting status, and settings migration. `make test-ui` checks settings read and write through the WebKit bridge in an offscreen AppKit panel. It uses temporary data and never takes focus or shows a window.

## License

Codex Office is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may use, modify, and share the original or modified software free of charge for noncommercial purposes under its terms. When distributing source code or a built app, retain the original author's copyright notice and include the license text or its official URL. Commercial use and paid distribution require separate permission from the copyright holder.

The bundled [Zstandard decoder](mac-office/Collector/Zstd/LICENSE) remains under its BSD license.
