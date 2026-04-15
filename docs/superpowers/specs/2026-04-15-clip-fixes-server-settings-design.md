# Clip Bug Fixes + Server-Side Settings

**Date:** 2026-04-15

---

## Issue 1 — Clip Task Card Not Appearing Without Refresh

**Root cause:** `startPolling(clip_task_id)` only updates an *existing* DOM card via
`updateTaskCard`. The clip task card is never created (`addTaskCard` is never called), so
WebSocket updates for the clip task are silently discarded.

**Fix:** In `player.ts`, after receiving `{clip_task_id, filename}`, call
`addTaskCard(d.clip_task_id, `✂ ${d.filename}`)` before `startPolling(d.clip_task_id)`.

---

## Issue 2 — No Audio in Clip from In-Progress Download

**Root cause:** The TS concat ffmpeg command uses output-side seeking (`-ss` AFTER `-i`)
combined with `-c copy`. When seeking past the exact start of a TS segment boundary with
stream-copy mode, the audio stream's first packet may have a negative relative timestamp,
causing ffmpeg to silently drop the entire audio stream.

**Fix in `clip.rs`:** Add two ffmpeg flags to the TS concat command (and the CMAF concat):
- `-avoid_negative_ts make_zero` — normalises timestamps after seeking so audio isn't dropped
- `-map 0` — explicitly include all streams (video + audio) from the input

Also apply `-map 0` to the single-file (completed task) clip command.

---

## Issue 3+4 — Server-Side Settings

### Motivation

Currently the only frontend setting (`useProxy`) is stored in `localStorage`. The user wants:
- All settings persisted in a server-side JSON file (`settings.json`)
- A new `healthOnlyFilter` setting (default `true`) added to the Settings modal
- All future settings to live on the server — one source of truth shared across browsers

### Architecture

**Backend (Rust):**

```
AppSettings {
    use_proxy:           bool  // default: true
    health_only_filter:  bool  // default: true
}
```

- Stored in `{downloads_dir}/settings.json`
- `AppState.app_settings: Arc<RwLock<AppSettings>>`
- `GET  /api/settings` → returns current `AppSettings` as JSON
- `PATCH /api/settings` → accepts `{ use_proxy?, health_only_filter? }`, merges, saves, returns updated settings
- Loaded at startup alongside `tasks.json`, `playlists.json`, etc.

**Frontend (TypeScript):**

- `types.ts` `Settings`: add `healthOnlyFilter: boolean`
- `settings.ts`: replace `localStorage` with `GET /api/settings` (load) and `PATCH /api/settings` (save)
- `health.ts`: `healthOnlyFilter` initial value sourced from `settings.healthOnlyFilter` after settings load
- `ui.ts` Settings modal init: populate both `settingUseProxy` and `settingHealthOnly` from loaded settings; PATCH on change
- `index.html` Settings modal: add **Active channels only** row with `id="settingHealthOnly"` toggle

### Settings Modal New Row

```
Section: Channels
  ┌─────────────────────────────────────────────┬────────┐
  │ Show active channels only by default         │  [●]  │
  │ When viewing a playlist, hide channels that  │       │
  │ did not pass the health check.               │       │
  └─────────────────────────────────────────────┴────────┘
```

### API Contract

```
GET /api/settings
→ 200 { "use_proxy": true, "health_only_filter": true }

PATCH /api/settings
← { "use_proxy": false }
→ 200 { "use_proxy": false, "health_only_filter": true }
```

### Startup Synchronisation

`ui.ts` page-load initialiser (`initSettingsModal`) is already synchronous — it reads from
the `settings` module which must be loaded first. Because network fetch is async, the
strategy is:

1. `settings.ts` exports `loadSettings(): Promise<void>` — fetches `/api/settings`, falls
   back to defaults on error.
2. `ui.ts` top-level IIFE calls `await loadSettings()` before any UI that reads settings.
3. `health.ts` `healthOnlyFilter` is initialised lazily: `getHealthOnlyFilter()` reads from
   `settings.healthOnlyFilter`.

---

## Files Changed

| File | Change |
|------|--------|
| `frontend/src/player.ts` | `addTaskCard` before `startPolling` for clip task |
| `crates/server/src/handlers/clip.rs` | Add `-map 0` + `-avoid_negative_ts make_zero` |
| `crates/server/src/types.rs` | Add `AppSettings` struct |
| `crates/server/src/state.rs` | Add `app_settings: Arc<RwLock<AppSettings>>` field |
| `crates/server/src/persistence.rs` | Add `load_app_settings`, `save_app_settings` helpers |
| `crates/server/src/handlers/settings.rs` | New file: `get_settings`, `patch_settings` handlers |
| `crates/server/src/handlers/mod.rs` | Declare `pub(crate) mod settings` |
| `crates/server/src/router.rs` | Register `/api/settings` routes |
| `frontend/src/types.ts` | Add `healthOnlyFilter: boolean` to `Settings` |
| `frontend/src/settings.ts` | Replace `localStorage` with server API |
| `frontend/src/health.ts` | Read `healthOnlyFilter` from settings |
| `frontend/src/ui.ts` | Async settings init, sync `settingHealthOnly` checkbox |
| `frontend/index.html` | Add `settingHealthOnly` toggle row in settings modal |
