# GitHub Copilot Instructions — IPTVGrab

## Project overview

Rust rewrite of a Python/FastAPI HLS/M3U8 downloader. Includes:
- **Web server** (`crates/server`) — full REST API + WebSocket, serves browser UI
- **Core library** (`crates/m3u8-core`) — download engine shared by server + mobile
- **Mobile FFI** (`crates/mobile-ffi`) — C ABI bridge used by the Flutter on-device app

## Build & run

```bash
# Run server (dev)
RUST_LOG=info cargo run -p server

# Build release binary
cargo build --release -p server
./target/release/m3u8-server

# Check all crates compile
cargo check

# Run API tests (requires server running or starts one automatically)
./tests/test_api.sh

# Run tests against specific server
BASE=http://192.168.1.32:8765 ./tests/test_api.sh
```

Environment variables for server:
```bash
PORT=8765          # default
HOST=0.0.0.0       # default (all interfaces, mobile-accessible)
DOWNLOADS_DIR=./downloads
STATIC_DIR=./static          # symlink → ../m3u8-downloader/static
AUTH_PASSWORD=secret         # omit to disable auth
RUST_LOG=info
```

## Architecture

```
crates/
  m3u8-core/      ← Download engine (shared between server + mobile)
    src/
      downloader.rs    ← Downloader struct, VOD/live loops, parse_curl_command()
      parser.rs        ← M3U8 parse, quality selection, key prefetch
      aes.rs           ← AES-128-CBC decrypt (RustCrypto)
      merge.rs         ← ffmpeg concat/CMAF merge (async subprocess)
      types.rs         ← DownloadConfig, ProgressEvent, StreamInfo, Quality
      error.rs         ← DownloadError enum

  server/
    src/main.rs  ← Everything: AppState, all handlers, routes (~1500 lines)

  mobile-ffi/
    src/lib.rs   ← exported C ABI for starting/stopping/querying the embedded localhost server

static/           ← Symlink → ../m3u8-downloader/static (Bootstrap 5 dark UI)
downloads/        ← Output MP4 files + tasks.json, playlists.json, merged_config.json
```

## Server: key conventions

### AppState
```rust
struct AppState {
    tasks:         Arc<RwLock<HashMap<String, Task>>>,
    downloaders:   Arc<RwLock<HashMap<String, Arc<Downloader>>>>,
    downloads_dir: PathBuf,
    auth_password: Option<String>,
    sessions:      Arc<RwLock<HashSet<String>>>,
    playlists:     Arc<RwLock<HashMap<String, SavedPlaylist>>>,
    merged_config: Arc<RwLock<MergedConfig>>,
    health_cache:  Arc<RwLock<HashMap<String, HealthEntry>>>,
    health_state:  Arc<RwLock<HealthState>>,
    ws_subs:       Arc<tokio::sync::Mutex<HashMap<String, Vec<mpsc::Sender<String>>>>>,
}
```
- **Always clone `AppState`** before passing to async tasks (it's `Clone` via `Arc`).
- **Save after every mutation**: `state.save_tasks().await`, `state.save_playlists().await`, etc.
- All persistence files live in `downloads_dir/`.

### Task state machine
```
queued → downloading (VOD) → merging → completed
       → recording (live) → merging → completed
                           ↓
                        cancelled / failed / interrupted
```
`interrupted` = was active when server restarted (set by `load_tasks()`).

### Task progress: ProgressEvent updates
`m3u8-core::Downloader::download()` is an async fn that takes an `mpsc::Sender<ProgressEvent>`.
In `run_download`, we read from the receiver and call `apply_event()` to update the `Task` struct. After each update, broadcast to WS subscribers.

### All-playlists merged config
`MergedConfig.groups` is the canonical source for ordering, enabled state, and custom items. `build_merged_view()` reconstructs it from `playlists` (sourced channels) + existing `merged_config` (user customizations). Call it when:
- A playlist is added/refreshed
- `GET /api/all-playlists` is requested with no saved config

### Health check
Background tokio task: GET each channel URL with 8s timeout, 50 concurrent, `danger_accept_invalid_certs(true)`. Treats any HTTP status < 400 as "ok", network errors as "dead". Results stored in `health_cache` (persisted to `health_cache.json`). `HealthState.running` is true while in progress.

### Cancel during merge
When `cancel()` is called while ffmpeg is running in merge phase, ffmpeg receives SIGTERM and exits with code 254 (its standard signal exit). `run_download` checks both `DownloadError::Cancelled` AND `dl.is_cancelled()` before marking a task as "failed", preventing "Failed: ffmpeg error 254" from showing for user-initiated cancellations.

### WebSocket task streaming
`/ws/tasks/:id` upgrades to WebSocket via `axum::extract::ws::WebSocketUpgrade`.
- Sends current task JSON immediately
- If terminal status, closes right away
- Otherwise, subscribes to `ws_subs[task_id]` channel, relays messages
- Sends `{"type":"ping"}` keepalive every 25s
- `run_download` publishes updated task JSON to all subscribers after each state change

## Complete API surface

### Auth
| Method | Path | Description |
|--------|------|-------------|
| GET | /api/auth/status | `{"auth_required": bool}` |
| POST | /api/login | `{"password"}` → sets `session` cookie |
| POST | /api/logout | Clears session cookie |

### Tasks
| Method | Path | Description |
|--------|------|-------------|
| GET | /api/tasks | List all tasks |
| POST | /api/download | Start download (`{url, headers, quality, concurrency, output_name}`) |
| GET | /api/tasks/:id | Get task |
| DELETE | /api/tasks/:id | Cancel task |
| POST | /api/tasks/:id/resume | Resume interrupted task |
| POST | /api/tasks/:id/recording-restart | Cancel recording + start fresh |
| POST | /api/tasks/:id/fork | Stop recording (merge) + start fresh |
| POST | /api/tasks/:id/clip | Trim task video to time range (`{start, end}` seconds) → `{filename}` |
| GET | /api/tasks/:id/preview.m3u8 | HLS preview playlist |
| GET | /api/tasks/:id/seg/:filename | Serve segment file |
| WS | /ws/tasks/:id | Stream task updates |

### Parse
| Method | Path | Description |
|--------|------|-------------|
| POST | /api/parse | Parse M3U8 URL or cURL command → StreamInfo |

### Downloads
| Method | Path | Description |
|--------|------|-------------|
| GET | /downloads/:filename | Serve completed MP4 |

### Playlists (IPTV)
| Method | Path | Description |
|--------|------|-------------|
| GET | /api/playlists | List playlists (no channels) |
| POST | /api/playlists | Add playlist (body: `{name, url?, raw?}`) |
| GET | /api/playlists/:id | Get playlist with channels |
| PATCH | /api/playlists/:id | Edit name/url |
| DELETE | /api/playlists/:id | Delete playlist |
| POST | /api/playlists/:id/refresh | Re-fetch URL, update channels |
| GET | /api/channels | Flat list of all channels across playlists |

### All-Playlists (merged editor)
| Method | Path | Description |
|--------|------|-------------|
| GET | /api/all-playlists | Merged group+channel tree |
| PUT | /api/all-playlists | Save full merged config |
| POST | /api/all-playlists/refresh | Re-fetch all playlist URLs |
| GET | /api/all-playlists/export.m3u | Export enabled channels as M3U |
| POST | /api/all-playlists/groups | Add custom group |
| DELETE | /api/all-playlists/groups/:id | Delete custom group |
| POST | /api/all-playlists/channels | Add custom channel |
| PATCH | /api/all-playlists/channels/:id | Edit channel (enable/disable, rename, move) |
| DELETE | /api/all-playlists/channels/:id | Delete custom channel |

### Health Check
| Method | Path | Description |
|--------|------|-------------|
| GET | /api/health-check | `{running, total, done, started_at, cache}` |
| POST | /api/health-check | Trigger health check for all enabled channels |

## Code style conventions

- **Error responses**: `(StatusCode::NOT_FOUND, Json(json!({"detail":"..."})))).into_response()`
- **IntoResponse**: All handlers returning multiple types must call `.into_response()` on every branch
- **Locking**: Never hold a write lock across an await. Scope locks with `{ let mut g = ...; ... drop(g); }`
- **Persistence**: `save_*` methods are async, always `await` them
- **New routes**: Register in the `api` Router in `main()`, before `.layer(cors)`
- **Static files**: `ServeDir::new(&static_dir)` as `.fallback_service()` — must be last
- **No `unwrap()` in handlers**: Use `map_err(|e| e.to_string())?` or match on errors

## Testing workflow

After any code change:
```bash
# 1. Verify compilation
cargo check -p server

# 2. Kill any running server
lsof -ti:8765 | xargs kill 2>/dev/null; true

# 3. Run tests (auto-starts server)
cd /Users/dotennin-mac14/projects/m3u8-downloader-rs && ./tests/test_api.sh
```

## Mobile build commands

```bash
make setup          # Install cargo-ndk + uniffi-bindgen
make flutter-prepare # Build Rust native artifacts for Flutter
make apk             # Flutter Android APK
make ipa-debug       # Flutter debugging IPA for local device install
make server         # Release server binary
```

## Dependencies (key)
- `axum 0.7` with features: `macros`, `ws`
- `tower-http 0.5` with features: `fs`, `cors`, `set-header`
- `tokio 1` with feature: `full`
- `reqwest 0.12` with features: `rustls-tls`, `stream`, `json`, `gzip`
- `uniffi 0.28` with feature: `tokio`
- `m3u8-rs 6`
- `aes 0.8` + `cbc 0.1` + `cipher 0.4` (RustCrypto)

## Coding style
- Using `Flutter`, `Rust` skills for best practices in Rust API design, error handling, async patterns, and FFI for mobile integration.
- Adding comments and documentation for clarity, especially around complex async flows and shared state management in the server.
- Adding unit tests for core library functions (e.g. M3U8 parsing, AES decryption) and integration tests for server API endpoints.
