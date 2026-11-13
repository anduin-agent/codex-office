# Codex Office

English · [简体中文](README.zh-CN.md)

Codex Office is a macOS menu bar app for keeping track of local Codex chats. See which chats are working or waiting for you, then switch to **Usage** to see where your tokens went. The app reads Codex logs and desktop metadata on your Mac and needs no separate server or API key.

[Download for macOS](https://github.com/anduin-agent/codex-office/releases/latest)

Open the DMG, drag **Codex Office** into Applications, then open it. Click the robot in the menu bar to open the panel.

- **Apple silicon:** macOS 12 or later. **Intel:** macOS 13 or later.
- The v0.1.0 app uses an ad hoc signature and has not been notarized by Apple. macOS may block the first launch.
- The installed app does not need Python, Apple Command Line Tools, or `zstd`.

### If macOS blocks the first launch

Use these steps if macOS says it can't verify the developer or check the app for malicious software. Make sure you downloaded the DMG from this project's GitHub Release and that its SHA-256 matches `SHA256SUMS.txt`.

1. Try opening **Codex Office** from Applications and dismiss the warning.
2. Go to **System Settings → Privacy & Security**, then scroll to **Security**. On macOS 12, use **System Preferences → Security & Privacy → General**.
3. Click **Open Anyway** next to Codex Office and confirm in the dialog. Authenticate if macOS asks.

[Apple's guide to opening apps safely](https://support.apple.com/en-us/102445)

## Office

- **See what needs you.** Running chats have animated workstations. When Codex Desktop reports a pending approval or question, the robot stops typing, looks up, and shows a waiting label. Double-click its workstation to open the chat.
- **Track subagents.** The scene shows subagents in relation to their parent chat. Use the local Codex sidebar sections to choose which chats appear in the office.
- **Read the menu bar at a glance.** It shows the running chat count, or the waiting count when someone needs a response. Choose one metric to show alongside it: today's tokens, tokens per minute, or remaining plan quota. The robot's pace follows the last minute of usage.
- **Follow cross-project work.** Set a coordination section to see successful dispatches detected in local Codex logs. You can also choose the chats yourself and record their acknowledgments. Manual recording saves the relationship locally and does not start a Codex task.

## Usage

- **Check today's activity or look back.** The panel shows today's tokens, the current rate, and today's estimated API cost. Usage adds a 30-day chart, the peak day, and totals from all readable local logs. Hover over a bar for the date, tokens, and estimated cost. Click it for the daily ranking and the input, output, and cache breakdown.
- **See which chats used the most.** Rankings combine each main chat with its subagents and linked automatic reviews. Expand a group to see its sessions. Reviews without a verified parent are grouped under **Unassigned automatic reviews**.
- **Drill down.** Open **Usage details** to filter by date, project, or model and inspect a session's token and model breakdown.
- **Compare quota cycles.** When the local logs contain weekly or 5-hour quota records, the panel shows the remaining percentage, reset time, and countdown. It compares estimated token capacity for the current and last recorded cycle when both have enough data.
- **Check live account quota.** Enable **Live account quota** in Office Settings to query OpenAI through your installed Codex while the Usage tab is visible or the menu bar shows quota. The Usage tab shows the source and reading time. If the query fails, Office shows local quota only when it can match it to the current account.

API cost figures are USD equivalents based on [OpenAI's standard API prices](https://developers.openai.com/api/docs/pricing). They are separate from subscription charges. The app includes a rate table and checks for price updates at most once per local day while the panel is open. It marks estimates that cover only part of the recorded usage.

Quota capacity uses local tokens through a recorded snapshot divided by its used percentage. The snapshot must show at least 5% and less than 100% used. The previous cycle's token count stops at reset. Each estimate gets a ±15% tolerance: overlapping ranges are shown as close, and separated ranges are marked as a possible increase or decrease. The model and task mix and usage on other devices can affect the comparison.

## Settings and data

Settings save as you change them. Choose Simplified Chinese, English, or the system language, add project aliases, and choose which sidebar sections to show. Launch at Login is available from macOS 13. **Check for Updates** looks for a newer stable version and offers to open its GitHub release page.

Codex Office reads session logs, compressed archives, and the Codex desktop database locally. Its settings are stored in `~/Library/Application Support/Codex Office/office.json`. Manually recorded collaboration and acknowledgments stay in the app's macOS preferences.

## Build from source

Building from source requires Apple Command Line Tools with the macOS 26 SDK or later.

```sh
make mac-office
open "build/Codex Office.app"
```

To enable **Check for Updates** in a release build, set `OFFICE_RELEASE_REPO=owner/repo` and publish a stable GitHub release with a version tag such as `v0.1.0`.

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
