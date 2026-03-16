import asyncio
import time
import uuid
from pathlib import Path
from typing import Optional

from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from downloader import M3U8Downloader, parse_curl_command

app = FastAPI(title="M3U8 Downloader")

DOWNLOADS_DIR = Path("downloads")
DOWNLOADS_DIR.mkdir(exist_ok=True)

# In-memory task registry (task_id -> task dict)
tasks: dict = {}
# Keep downloader references to support cancellation
downloaders: dict = {}


# ── Pydantic models ─────────────────────────────────────────────────────────

class ParseRequest(BaseModel):
    url: str = ""
    headers: dict = {}
    curl_command: str = ""


class DownloadRequest(BaseModel):
    url: str
    headers: dict = {}
    output_name: Optional[str] = None
    quality: str = "best"
    concurrency: int = 8


# ── API routes ───────────────────────────────────────────────────────────────

@app.post("/api/parse")
async def parse_stream(req: ParseRequest):
    url = req.url
    headers = req.headers

    if req.curl_command.strip():
        parsed_url, parsed_headers = parse_curl_command(req.curl_command)
        url = parsed_url or url
        if parsed_headers:
            headers = parsed_headers

    if not url:
        raise HTTPException(400, "URL is required")

    try:
        dl = M3U8Downloader(url, headers)
        info = await dl.parse()
        info["url"] = url
        info["headers"] = headers
        return info
    except Exception as e:
        raise HTTPException(400, f"Failed to parse stream: {e}")


@app.post("/api/download")
async def start_download(req: DownloadRequest, bg: BackgroundTasks):
    task_id = str(uuid.uuid4())
    tasks[task_id] = {
        "id": task_id,
        "url": req.url,
        "status": "queued",
        "progress": 0,
        "total": 0,
        "downloaded": 0,
        "failed": 0,
        "speed_mbps": 0.0,
        "bytes_downloaded": 0,
        "output": None,
        "size": 0,
        "error": None,
        "created_at": time.time(),
    }
    bg.add_task(_run_download, task_id, req)
    return {"task_id": task_id}


@app.get("/api/tasks")
async def list_tasks():
    return sorted(tasks.values(), key=lambda t: t.get("created_at", 0), reverse=True)


@app.get("/api/tasks/{task_id}")
async def get_task(task_id: str):
    if task_id not in tasks:
        raise HTTPException(404, "Task not found")
    return tasks[task_id]


@app.delete("/api/tasks/{task_id}")
async def cancel_task(task_id: str):
    if task_id not in tasks:
        raise HTTPException(404, "Task not found")
    dl = downloaders.get(task_id)
    if tasks[task_id].get("status") == "recording" and dl:
        # Live stream: stop polling and merge recorded segments
        tasks[task_id]["status"] = "stopping"
        dl.stop_recording()
        return {"status": "stopping"}
    else:
        tasks[task_id]["status"] = "cancelled"
        if dl:
            dl.cancel()
        return {"status": "cancelled"}


@app.get("/downloads/{filename}")
async def serve_file(filename: str):
    path = DOWNLOADS_DIR / filename
    if not path.exists():
        raise HTTPException(404, "File not found")
    return FileResponse(path, filename=filename)


# ── Background task runner ───────────────────────────────────────────────────

async def _run_download(task_id: str, req: DownloadRequest):
    dl = M3U8Downloader(
        req.url,
        req.headers,
        output_dir=DOWNLOADS_DIR,
        output_name=req.output_name,
        quality=req.quality,
        concurrency=req.concurrency,
    )
    downloaders[task_id] = dl
    try:
        async for progress in dl.download():
            status = tasks[task_id].get("status")
            if status == "cancelled":
                dl.cancel()
                return
            # "stopping" = live stop+merge in progress — let it run through
            tasks[task_id].update(progress)
    except Exception as e:
        tasks[task_id].update({"status": "failed", "error": str(e)})
    finally:
        downloaders.pop(task_id, None)


# ── Static files (must be last) ───────────────────────────────────────────────

app.mount("/", StaticFiles(directory="static", html=True), name="static")
