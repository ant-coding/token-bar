# AGENTS.md

This file provides guidance to Codex when working with code in this repository.

## Commands

- `swift run -c release` - run the menu bar app.
- `swift run -c release TokenBar --print-today` - print today's token summary and exit.
- `swift run -c release TokenBar --period week` - print a selected period. Supported periods are `day`, `week`, and `month`; use `--offset -1` for prior weeks/months.
- `swift run -c release TokenBar --rebuild-cache` - rebuild the local usage cache and print cache stats.
- `swift build -c release` - build only.
- `zsh Scripts/build-app.sh` - produce a double-clickable `.build/release/TokenBar.app` bundle and a root `TokenBar.app` convenience copy. Generated app bundles are ignored by Git.

There are no tests or lint configuration in this repo.

Swift toolchain: `swift-tools-version: 6.0`, `.macOS(.v13)` minimum.

## Architecture

Single-file SwiftPM executable (`Sources/TokenBar/main.swift`). Most logic lives in one file; keep edits there unless splitting is clearly warranted.

Key areas:

1. `CodexUsageReader` and the cache parser read Codex JSONL usage under `~/.codex/sessions` and `~/.codex/archived_sessions`.
2. `ClaudeCodeUsageReader` and the cache parser read Claude Code JSONL usage under `~/.claude/projects`.
3. `UsageCacheManager` stores exact hourly rollups and per-file cursors in `~/Library/Application Support/local.tokenbar/usage-cache-v1.json`.
4. `AppConfigManager` stores provider path and theme settings in `~/Library/Application Support/local.tokenbar/config-v1.json`.
5. `UsageViewController`, `ProviderSettingsViewController`, and the AppKit view classes render the popover and settings window.
6. `AppDelegate` owns the status item, popover, settings window, in-memory snapshots, and 5-minute refresh timer.

## Token Event Rules

Codex JSONL:

- `session_meta` gives the `payload.originator`.
- `event_msg` with `payload.type == "token_count"` is the summable event.
- Use `payload.info.last_token_usage`, not running totals.
- Do not add `cached_input_tokens` on top of `input_tokens`; cached input is already included in input.

Claude Code JSONL:

- Assistant messages with `message.usage` carry token usage.
- Cache creation and cache read tokens are priced separately where present.
- Path-derived contributor identifiers should remain redacted or hashed before being persisted.

Timestamps can include or omit fractional seconds; use `parseISOTimestamp`.

## macOS Bundle Notes

`Bundle/Info.plist` sets `LSUIElement=true` so the app is menu-bar-only. The SwiftPM build produces a plain Mach-O binary; `Scripts/build-app.sh` wraps it in the `.app` layout Finder expects and ad-hoc signs it. Bundle id is `local.tokenbar`; version strings live in `Bundle/Info.plist`.

Do not commit generated `.build/`, `.app`, `.dSYM`, `.DS_Store`, or local assistant settings.
