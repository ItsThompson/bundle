# macOS App

## Overview

A native Swift menubar application providing capture (screenshot, note, link), retrieval (grid with tag filtering and search), and settings (auth, hotkey config). Runs as a menubar-only app with no Dock presence.

Canonical source: `apps/macos/Sources/App/`

## Component Layout

| Directory | Responsibility |
|-----------|----------------|
| `App/` | Entry point (`BundleApp.swift`), lifecycle (`AppDelegate.swift`) |
| `Capture/` | Capture palette, screenshot region selection, note editor, link input, post-capture thumbnail |
| `Retrieval/` | Retrieval panel, artifact grid, tile rendering, tag filter bar, search bar, detail views |
| `Hotkey/` | Global hotkey manager (CGEvent tap, key recording) |
| `Networking/` | APIClient (URLSession + auth refresh), AuthService, ArtifactUploadService, SyncService, SearchService |
| `Storage/` | LocalDatabase (SQLite3), KeychainManager |
| `Settings/` | Settings panel, auth views, hotkey config view, account management |
| `Models/` | Domain models (Artifact, AuthModels) |

## App Lifecycle

1. `BundleApp` (SwiftUI `@main`) creates a `MenuBarExtra` with Capture, Artifacts, Settings, and Quit options
2. `AppDelegate` sets activation policy to `.accessory` (no Dock icon)
3. Requests Accessibility, Input Monitoring, and Screen Recording permissions
4. Opens local SQLite database
5. Registers global hotkey (default: ⌘⇧B)
6. Restores auth session from Keychain

## Capture Flow

1. Hotkey pressed → `CapturePalette` shown (floating NSPanel)
2. User selects type via keyboard (1/2/3) or arrow keys + enter
3. Capture handler runs (screenshot region selection / note editor / link input)
4. Artifact inserted into SQLite with local UUID, status `pending`
5. Post-capture thumbnail shown (5s auto-dismiss, interactive: copy, add note)
6. Upload fires asynchronously; on success, local UUID replaced with backend UUID

## Retrieval Panel

- Floating NSPanel showing artifacts in a grid layout
- Data source: local SQLite (instant load, works offline)
- Tag filter bar: horizontal scrollable pills with counts
- Search bar: delegates to backend hybrid search
- Artifact detail views: zoomable screenshots, rendered markdown, link browser open
- SyncService starts on panel open, stops on panel close

## Sync Service

Defined in `apps/macos/Sources/App/Networking/SyncService.swift`.

- Polls every 5 seconds while active
- Initial sync: paginated full download with progress indicator
- Delta sync: `updated_since` parameter for incremental updates
- Exponential backoff on failures (5s → 10s → 20s → ... cap 5min)
- Retries uploading pending local artifacts each cycle

## Global Hotkey

Defined in `apps/macos/Sources/App/Hotkey/HotkeyManager.swift`.

- Uses CGEvent tap at session level
- Default combo: ⌘⇧B (configurable via settings)
- Key recording mode for custom shortcuts
- Conflict detection against common macOS shortcuts
- Persisted in UserDefaults
- Auto-re-enables tap on system timeout/disable events

## Window Management

All floating panels use `NSPanel` with `nonactivatingPanel` style:
- Don't steal focus from the current app
- Compatible with tiling window managers (AeroSpace)
- Post-capture thumbnail overlay: positioned at bottom-right, sized to content, never tiled
