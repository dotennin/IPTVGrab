# Async Clip API + Tasks Tab Redesign

**Date:** 2026-04-15

## Problem

1. **Cloudflare 524 timeout** — `POST /api/tasks/:id/clip` runs `ffmpeg` synchronously. Cloudflare
   drops connections after 100 s; large clips exceed this and return 524 to the client.

2. **"Active" filter checkbox bug** — `healthOnlyFilter` defaults to `true` and
   `selectPlaylist` sets `healthOnlyCheck.checked = true`, but then calls
   `renderChannels(allChannels)` directly (bypassing the filter). The checkbox appears
   checked while all channels are displayed — a visual/state mismatch.

---

## Solution 1: Async Clip

### Approach

Convert the clip handler from synchronous ffmpeg-wait to a background Tokio task:

1. Frontend calls `POST /api/tasks/:id/clip {start, end}`.
2. Server immediately creates a new `Task` (`task_type: "clip"`, `status: "clipping"`) and returns
   `{"clip_task_id": "<id>", "filename": "<planned-filename>"}`.
3. Server spawns a Tokio task that runs ffmpeg, then updates the task `status` to `"completed"` (with
   `output` set) or `"failed"`, saves tasks, and broadcasts the update via `ws_subs`.
4. Frontend closes the clip toolbar, shows a toast, and the new clip task card appears in the
   **Tasks** tab under the **Clipping** category.
5. The task card transitions to **Completed** when done and shows a Download button.

### New Task Fields

```rust
// types.rs
pub(crate) task_type: Option<String>,   // "download" | "clip"  (None = download)
```

### Status Lifecycle

```
clipping → completed   (ffmpeg exited 0)
         → failed      (ffmpeg error or not found)
```

### Tasks Tab Rename + Clipping Category

- Rename bottom-nav "Downloads" button to **"Tasks"**.
- Add **Clipping** sidebar category (filters `task_type == "clip"` OR `status == "clipping"`).
- `ACTIVE_STATUSES` gains `"clipping"` so the badge counter works.
- `STATUS_MAP` gains `clipping: { text: 'Clipping', cls: 'bg-warning' }`.

---

## Solution 2: Active Filter Bug Fix

**Root cause:** `selectPlaylist` calls `renderChannels(allChannels)` (unfiltered array), but also
sets `healthOnlyFilter = true` and checks the checkbox. The rendered list never respects the filter.

**Fix:**
- Default `healthOnlyFilter` to `false` (unchecked by default = show all channels).
- Remove the auto-set `setHealthOnlyFilter(true)` / `healthOnlyCheck.checked = true` from
  `selectPlaylist` (should be user-controlled, not reset on every navigation).
- Change both `renderChannels(allChannels)` calls in `selectPlaylist` to
  `renderChannels(getFilteredChannels())` so the current filter state is always applied.

---

## Files Changed

| File | Change |
|------|--------|
| `crates/server/src/types.rs` | Add `task_type: Option<String>` to `Task` |
| `crates/server/src/handlers/clip.rs` | Async clip — spawn tokio task, return immediately |
| `frontend/src/types.ts` | Add `task_type?: string` to `Task` |
| `frontend/index.html` | Rename nav tab; add Clipping sidebar category |
| `frontend/src/tasks.ts` | STATUS_MAP, ACTIVE_STATUSES, clip response, Clipping count |
| `frontend/src/player.ts` | clip handler: show toast + navigate to Tasks on submit |
| `frontend/src/health.ts` | `healthOnlyFilter = false` |
| `frontend/src/playlists.ts` | Remove auto-check; `renderChannels(getFilteredChannels())` |
