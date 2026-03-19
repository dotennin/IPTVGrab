# M3U8 Downloader

A web-based HLS/M3U8 video downloader with a dark-theme browser UI.
Paste a URL or a raw `curl` command, choose quality, and download the stream as a merged MP4.

---

## Features

- **URL & cURL input** — paste a plain M3U8 URL or a full `curl` command copied from browser DevTools (with all headers)
- **Master playlist** — auto-lists quality variants; pick the resolution you want
- **Concurrent download** — configurable segment concurrency (1–32)
- **AES-128 decryption** — transparent key fetch + CBC decrypt per segment
- **CMAF / fMP4** — handles `#EXT-X-MAP` init segments; binary-concatenates + re-muxes via ffmpeg
- **Live stream recording** — polls playlist, deduplicates segments, records until stopped, then merges to MP4
- **Video preview** — in-browser HLS preview via hls.js after the first few segments are downloaded
- **Resume /** — interrupted downloads resume from the last segment on server restart
- **Task persistence** — task history survives server restarts (`tasks.json` inside the downloads dir)
- **Access control** — optional password protection; brute-force protection locks an IP for 5 minutes after 5 failed attempts

---

## UI Overview

### Login page `/login`

Shown only when the `AUTH_PASSWORD` environment variable is set.
Enter the access password to reach the main page.
After **5 consecutive wrong attempts** the originating IP is locked for **5 minutes**; a live countdown is displayed and the form is disabled until the lock expires.

---

### Main page `/`

Two-column layout with a task panel below.

#### Left panel — Input

Three tabs for different input methods:

| Tab | Purpose |
|-----|---------|
| **URL** | Enter a direct M3U8 URL. Add any number of custom request headers as key-value pairs. |
| **cURL command** | Paste the full `curl` command copied from Chrome DevTools → *Copy as cURL*. The URL and all headers are extracted automatically. Raw HTTP request header blocks (Chrome DevTools format) are also accepted. |
| **Batch download** | One URL per line. Prefix a line with `#title` to set the output filename for the next URL. Configure how many tasks run in parallel (1–10). |

Shared options below the tabs:

- **Output filename** — leave blank to auto-name with a Unix timestamp; output is always `.mp4`
- **Concurrency slider** — number of segments downloaded in parallel per task (1–32, default 8)
- **Parse stream** button — fetches and parses the M3U8, populating the right panel

#### Right panel — Stream info

Displays parse results. Content adapts to the detected stream type:

| Stream type | Displayed |
|-------------|-----------|
| **Master playlist** | All quality variants with resolution, bitrate, and codec. Select one, then click *Start download*. The highest quality is pre-selected. |
| **Media playlist (VOD)** | Segment count, total duration, encryption status. Click *Start download*. |
| **Live stream** | Red pulsing 🔴 **LIVE** badge at the top. Click *Start recording*; stop at any time and the recorded segments are merged automatically into an MP4. |

#### Bottom — Download tasks

Each task is displayed as a card. States and their UI:

| Status | Progress bar | Action button |
|--------|-------------|---------------|
| Queued | Gray | Cancel |
| Downloading | Blue — shows speed (MB/s), bytes downloaded, percent complete | Cancel |
| Recording (live) | Red animated stripes — shows segment count, speed, elapsed time (MM:SS) | Stop recording |
| Merging | Blue at 99% | — |
| Completed | Green 100% — shows file size and total time | Download MP4 |
| Failed | Red — shows error message | Delete / Retry |
| Cancelled | Gray | Delete |

While a task is **downloading or recording**, a **Preview** button opens a modal that plays the already-downloaded segments live in the browser (powered by hls.js). No need to wait for the full download to finish.

The **Clear completed** button in the panel header removes all terminal-state cards (completed, failed, cancelled) at once.

---

## Quick start (Python)

```bash
# 1. Install dependencies
pip install -r requirements.txt      # Python 3.9+ required

# 2. Start on default port 8765
python run.py

# 3. Custom port and download directory
python run.py --port 9000 --downloads-dir /mnt/videos

# 4. With password protection
AUTH_PASSWORD=secret python run.py

# 5. Development mode (auto-reload on code changes)
python run.py --dev
```

Open **http://localhost:8765** in your browser.

### CLI options

| Flag | Short | Default | Description |
|---|---|---|---|
| `--port` | `-p` | `8765` | TCP port |
| `--downloads-dir` | `-d` | `./downloads` | Where MP4 files are saved |
| `--host` | | `0.0.0.0` | Bind address |
| `--dev` | | off | Enable uvicorn `--reload` |

Environment variables `PORT`, `DOWNLOADS_DIR`, and `AUTH_PASSWORD` are also respected (CLI flags take precedence).

---

## Docker

### Build & run

```bash
# Build image
docker build -t m3u8-downloader .

# Run (downloads saved to ./downloads on your host)
docker run -d \
  -p 8765:8765 \
  -v "$(pwd)/downloads:/downloads" \
  --name m3u8dl \
  m3u8-downloader
```

### docker-compose (recommended)

```bash
docker compose up -d          # start in background
docker compose logs -f        # follow logs
docker compose down           # stop
```

The default `docker-compose.yml` mounts `./downloads` on the host to `/downloads` inside the container.
Edit the file to change the port or mount path:

```yaml
services:
  m3u8-downloader:
    build: .
    ports:
      - "8765:8765"        # change host port here
    volumes:
      - /your/path:/downloads   # change host path here
    environment:
      - DOWNLOADS_DIR=/downloads
```

### Environment variables (Docker)

| Variable | Default | Description |
|---|---|---|
| `DOWNLOADS_DIR` | `/downloads` | Path inside the container for MP4 output |
| `PORT` | `8765` | Port the server binds to |
| `AUTH_PASSWORD` | _(unset)_ | If set, enables password login at `/login` |

---

## Requirements

| Dependency | Notes |
|---|---|
| Python 3.9+ | 3.11+ recommended |
| ffmpeg | Must be on `$PATH`; used for segment merging |
| See `requirements.txt` | fastapi, uvicorn, aiohttp, m3u8, pycryptodome |

---

## API reference

| Method | Path | Description |
|---|---|---|
| `GET` | `/login` | Login page (when auth is enabled) |
| `POST` | `/api/login` | Submit password, receive session cookie |
| `POST` | `/api/logout` | Invalidate session |
| `GET` | `/api/auth/status` | Returns `{ "auth_required": bool }` |
| `POST` | `/api/parse` | Parse an M3U8 URL or curl command |
| `POST` | `/api/download` | Start a download / recording task |
| `GET` | `/api/tasks` | List all tasks (persisted across restarts) |
| `GET` | `/api/tasks/{id}` | Get task status & progress |
| `DELETE` | `/api/tasks/{id}` | Cancel active task, or delete terminal task |
| `POST` | `/api/tasks/{id}/resume` | Resume an interrupted or failed task |
| `GET` | `/api/tasks/{id}/preview.m3u8` | HLS playlist for in-progress preview |
| `GET` | `/api/tasks/{id}/seg/{filename}` | Serve an individual downloaded segment |
| `GET` | `/downloads/{filename}` | Download a completed MP4 file |

### POST /api/parse

```json
{
  "url": "https://example.com/stream.m3u8",
  "headers": { "referer": "https://example.com" },
  "curl_command": ""
}
```

Returns `{ "type": "master"|"media", "streams": [...] }` for master playlists, or
`{ "type": "media", "segments": N, "duration": 120.5, "encrypted": false, "is_live": false }` for media playlists.

### POST /api/download

```json
{
  "url": "https://example.com/stream.m3u8",
  "headers": {},
  "output_name": "my-video",
  "quality": "best",
  "concurrency": 8
}
```

`quality`: `"best"` (default) · `"worst"` · integer index into the variant list.

---

## Project structure

```
.
├── main.py            # FastAPI app, API routes, task registry, auth middleware
├── downloader.py      # M3U8Downloader class, curl parser
├── run.py             # CLI entry point (argparse → uvicorn)
├── static/
│   ├── index.html     # Main UI (Bootstrap 5 dark theme)
│   ├── login.html     # Login page (shown when AUTH_PASSWORD is set)
│   ├── app.js         # Frontend logic (polling, hls.js preview, auth)
│   └── styles.css
├── downloads/         # Default output dir (auto-created)
│   ├── tasks.json     # Persisted task history
│   └── .cache/        # Segment cache for resume & preview
├── Dockerfile
├── docker-compose.yml
└── requirements.txt
```

