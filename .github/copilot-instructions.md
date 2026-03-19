# Copilot Instructions

## Dev server

```bash
python3 run.py           # starts on http://localhost:8765 with --reload
python3 run.py 9000      # custom port
```

No build step. Frontend is plain HTML/JS/CSS served from `static/`. Changes to `static/` are reflected immediately; changes to Python files trigger auto-reload via uvicorn.

## Install dependencies

```bash
# macOS (Homebrew Python requires this flag)
pip3 install --break-system-packages -r requirements.txt
```

External runtime dependency: `ffmpeg` must be available on `$PATH` (used for final segment merge).

## Architecture

```
main.py          FastAPI app — API routes + background task runner
downloader.py    M3U8Downloader class + parse_curl_command()
static/
  index.html     Bootstrap 5 dark theme shell
  login.html     Login page (served by GET /login route)
  app.js         All frontend logic (no framework, no build)
  styles.css     Custom dark theme styles
downloads/       Output MP4 files (served via /downloads/<filename>)
```

**Request flow:**
1. User parses a stream → `POST /api/parse` → `M3U8Downloader.parse()` → returns stream metadata
2. User starts download → `POST /api/download` → FastAPI `BackgroundTasks` runs `_run_download()`
3. `_run_download()` consumes the async generator `M3U8Downloader.download()`, writing each yielded progress dict into the in-memory `tasks` dict
4. Frontend polls `GET /api/tasks/{id}` every 1 second to update the task card UI
5. Cancel → `DELETE /api/tasks/{id}` sets `tasks[id]["status"] = "cancelled"` and calls `dl.cancel()` which sets `self._cancel = True`

**Task status machine:**
`queued` → `downloading` (VOD) or `recording` (live) → `merging` → `completed` / `failed` / `cancelled`

## Key conventions

### Authentication
Controlled by the `AUTH_PASSWORD` environment variable. If unset, auth is fully disabled (all requests pass through).

- `GET /login` → serves `static/login.html` (explicit route; StaticFiles does not auto-map `/login` → `login.html`)
- `POST /api/login` → validates password, issues `session` cookie (HMAC token stored in `sessions: set`)
- `POST /api/logout` → removes token from `sessions`, deletes cookie
- `AuthMiddleware` runs before routes; always allows `/login`, `/api/login`, `/api/logout`, and static asset extensions (`.js`, `.css`, etc.)

**IP-based brute-force protection** (`_login_failures` dict):
- 5 consecutive wrong passwords → IP locked for 300 seconds (5 minutes)
- `_check_lock(ip)` returns `(is_locked, remaining_seconds)` and auto-clears expired locks
- `_record_failure(ip)` increments count and sets `lock_until` timestamp on the 5th failure
- Successful login clears `_login_failures[ip]`
- On 429 response, `login.html` shows a live countdown and disables the form until the lock expires

### Static files mount must be last
In `main.py`, `app.mount("/", StaticFiles(...))` **must remain the last statement**. If placed before any `@app.` route, the API routes become unreachable (FastAPI matches the mount first).

### `download()` is an async generator
`M3U8Downloader.download()` yields progress dicts throughout execution. Every dict is a partial update — callers do `tasks[id].update(progress)` to merge it into the task record. Never replace the task dict entirely.

### Two merge strategies based on stream format
`_detect_cmaf(segments)` checks for `#EXT-X-MAP` init sections or `.m4s`/`.mp4`/`.cmfv`/`.cmfa` URI extensions:
- **MPEG-TS** (`.ts`): ffmpeg `-f concat` on a `concat.txt` file list
- **CMAF/fMP4** (`.m4s`): binary concatenate `init_data + seg_000000.m4s + ...` → raw `.mp4`, then ffmpeg `-i raw.mp4 -c copy` to remux

Both paths share the same merge step after live/VOD download finishes.

### Live vs VOD branching
`is_live = not pl.is_endlist` in `download()`. Live streams enter a polling loop:
- `seen_uris` set prevents re-downloading segments across playlist refreshes
- Poll interval = `max(1.0, target_duration / 2)` seconds
- `seg_idx` is a global counter across all batches → sequential `seg_{idx:06d}` filenames → merge step is identical to VOD
- Loop exits on `self._cancel` or when a refreshed playlist has `is_endlist = True`

### Segment temp files
All segment files are written to `tempfile.mkdtemp(prefix="m3u8dl_")` as `seg_{idx:06d}.ts` or `seg_{idx:06d}.m4s`. The tmpdir is always removed in `finally` after merge (or on error/cancel).

### AES-128 decryption
Keys are fetched once and cached in `keys_cache: Dict[str, bytes]` (keyed by key URL). The IV defaults to 16 zero bytes if not specified in the M3U8 `#EXT-X-KEY` tag. Decryption uses `pycryptodome` (`from Crypto.Cipher import AES`).

### curl command parsing
`parse_curl_command()` in `downloader.py` strips `\\\n` line continuations before regex-matching. It handles both single- and double-quoted `-H` values. The frontend's `parseRawHeaders()` in `app.js` additionally skips HTTP request lines (`GET /path HTTP/1.1`) so users can paste directly from Chrome DevTools.

### Tasks are in-memory only
`tasks: dict` and `downloaders: dict` in `main.py` are module-level dicts. They are not persisted — all task history is lost on server restart.

### Frontend header input modes
The UI has two modes toggled by Bootstrap `btn-check` radio inputs (`#modeKV` / `#modeRaw`). Raw mode is the default. Switching modes calls `switchHeaderMode(isRaw)` which must use explicit `"block"/"none"` strings (not `""`) because Bootstrap sets inline `display` on the hidden input itself.
