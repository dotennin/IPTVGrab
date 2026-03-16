# M3U8 Downloader

A web-based M3U8/HLS stream downloader with a browser UI. Paste an M3U8 URL (or a `curl` command), choose quality, and download the stream as a merged video file.

## Features

- Parse M3U8 playlists and select quality variants
- Accept raw URLs or pasted `curl` commands (with headers)
- Concurrent segment downloading with configurable concurrency
- Real-time progress tracking with speed reporting
- Cancel in-flight downloads
- Serve completed files directly from the browser

## Requirements

- Python 3.9+
- Dependencies listed in `requirements.txt`

## Setup

```bash
pip install -r requirements.txt
```

## Usage

```bash
python run.py          # starts on port 8765
python run.py 9000     # starts on a custom port
```

Then open `http://localhost:8765` in your browser.

## API

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/parse` | Parse an M3U8 URL or curl command |
| `POST` | `/api/download` | Start a download task |
| `GET` | `/api/tasks` | List all tasks |
| `GET` | `/api/tasks/{id}` | Get task status |
| `DELETE` | `/api/tasks/{id}` | Cancel a task |
| `GET` | `/downloads/{filename}` | Download a completed file |

### POST /api/parse

```json
{
  "url": "https://example.com/stream.m3u8",
  "headers": {},
  "curl_command": ""
}
```

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

## Project Structure

```
.
├── main.py          # FastAPI app and API routes
├── downloader.py    # M3U8Downloader class and curl parser
├── run.py           # Server entry point
├── static/          # Frontend (HTML, CSS, JS)
├── downloads/       # Downloaded files (auto-created)
└── requirements.txt
```
