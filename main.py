import asyncio
import json
import re
import shutil
import time
import uuid
from pathlib import Path
from typing import Optional

from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from downloader import M3U8Downloader, parse_curl_command

app = FastAPI(title="M3U8 Downloader")

DOWNLOADS_DIR = Path("downloads")
DOWNLOADS_DIR.mkdir(exist_ok=True)
TASKS_FILE = DOWNLOADS_DIR / "tasks.json"

# ── Task persistence ─────────────────────────────────────────────────────────

def load_tasks() -> dict:
    if TASKS_FILE.exists():
        try:
            data = json.loads(TASKS_FILE.read_text())
        except Exception:
            return {}
        active = {"downloading", "recording", "queued", "merging", "stopping"}
        for t in data.values():
            if t.get("status") in active:
                t["status"] = "interrupted"
            tmpdir = t.get("tmpdir")
            if tmpdir and not Path(tmpdir).exists():
                t["tmpdir"] = None
        return data
    return {}


def save_tasks():
    try:
        TASKS_FILE.write_text(json.dumps(tasks, indent=2, default=str))
    except Exception:
        pass


# In-memory registries
tasks: dict = load_tasks()
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
        # Stored for resume capability
        "req_headers": req.headers,
        "output_name": req.output_name,
        "quality": req.quality,
        "concurrency": req.concurrency,
    }
    save_tasks()
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
    task = tasks[task_id]
    dl = downloaders.get(task_id)
    current_status = task.get("status")

    if current_status == "recording" and dl:
        tasks[task_id]["status"] = "stopping"
        dl.stop_recording()
        save_tasks()
        return {"status": "stopping"}

    if current_status not in ("completed", "failed", "cancelled", "interrupted"):
        tasks[task_id]["status"] = "cancelled"
        if dl:
            dl.cancel()

    _cleanup_tmpdir(task_id)
    save_tasks()
    return {"status": tasks[task_id]["status"]}


@app.post("/api/tasks/{task_id}/resume")
async def resume_task(task_id: str, bg: BackgroundTasks):
    if task_id not in tasks:
        raise HTTPException(404, "Task not found")
    task = tasks[task_id]
    if task.get("status") not in ("interrupted", "failed"):
        raise HTTPException(400, "Task is not resumable")
    req = DownloadRequest(
        url=task["url"],
        headers=task.get("req_headers") or {},
        output_name=task.get("output_name"),
        quality=task.get("quality", "best"),
        concurrency=task.get("concurrency", 8),
    )
    tasks[task_id].update({"status": "queued", "error": None, "progress": 0})
    save_tasks()
    bg.add_task(_run_download, task_id, req)
    return {"task_id": task_id, "status": "queued"}


@app.get("/api/tasks/{task_id}/preview.m3u8")
async def preview_playlist(task_id: str):
    task = tasks.get(task_id)
    if not task:
        raise HTTPException(404, "Task not found")
    tmpdir = task.get("tmpdir")
    if not tmpdir or not Path(tmpdir).exists():
        raise HTTPException(404, "No preview available yet")
    tmpdir_path = Path(tmpdir)
    seg_ext = task.get("seg_ext", ".ts")
    is_cmaf = task.get("is_cmaf", False)
    target_dur = int(task.get("target_duration") or 6)
    seg_files = sorted(tmpdir_path.glob(f"seg_*{seg_ext}"))
    if not seg_files:
        raise HTTPException(404, "No segments available yet")
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:3",
        f"#EXT-X-TARGETDURATION:{target_dur}",
        "#EXT-X-MEDIA-SEQUENCE:0",
    ]
    if is_cmaf:
        init_file = tmpdir_path / "init.mp4"
        if init_file.exists():
            lines.append(f'#EXT-X-MAP:URI="/api/tasks/{task_id}/seg/init.mp4"')
    for seg_file in seg_files:
        lines.append(f"#EXTINF:{target_dur}.000,")
        lines.append(f"/api/tasks/{task_id}/seg/{seg_file.name}")
    lines.append("#EXT-X-ENDLIST")
    return Response("\n".join(lines), media_type="application/vnd.apple.mpegurl")


@app.get("/api/tasks/{task_id}/seg/{filename}")
async def serve_segment(task_id: str, filename: str):
    task = tasks.get(task_id)
    if not task or not task.get("tmpdir"):
        raise HTTPException(404, "Task or tmpdir not found")
    if not (re.match(r"^seg_\d{6}\.(ts|m4s|mp4)$", filename) or filename == "init.mp4"):
        raise HTTPException(403, "Invalid filename")
    seg_path = Path(task["tmpdir"]) / filename
    if not seg_path.exists():
        raise HTTPException(404, "Segment not found")
    media_type = "video/mp2t" if filename.endswith(".ts") else "video/mp4"
    return FileResponse(seg_path, media_type=media_type)


@app.get("/downloads/{filename}")
async def serve_file(filename: str):
    path = DOWNLOADS_DIR / filename
    if not path.exists():
        raise HTTPException(404, "File not found")
    return FileResponse(path, filename=filename)


# ── Helpers ─────────────────────────────────────────────────────────────────

def _cleanup_tmpdir(task_id: str):
    tmpdir = tasks.get(task_id, {}).get("tmpdir")
    if tmpdir:
        p = Path(tmpdir)
        if p.exists():
            shutil.rmtree(p, ignore_errors=True)
        tasks[task_id]["tmpdir"] = None


# ── Background task runner ───────────────────────────────────────────────────

async def _run_download(task_id: str, req: DownloadRequest):
    dl = M3U8Downloader(
        req.url,
        req.headers,
        output_dir=DOWNLOADS_DIR,
        output_name=req.output_name,
        quality=req.quality,
        concurrency=req.concurrency,
        task_id=task_id,
    )
    downloaders[task_id] = dl
    try:
        prev_status = tasks[task_id].get("status")
        async for progress in dl.download():
            current_status = tasks[task_id].get("status")
            if current_status == "cancelled":
                dl.cancel()
                _cleanup_tmpdir(task_id)
                save_tasks()
                return
            tasks[task_id].update(progress)
            new_status = tasks[task_id].get("status")
            if new_status != prev_status:
                save_tasks()
                prev_status = new_status
        final_status = tasks[task_id].get("status")
        if final_status == "completed":
            _cleanup_tmpdir(task_id)
            save_tasks()
    except Exception as e:
        tasks[task_id].update({"status": "failed", "error": str(e)})
        save_tasks()
    finally:
        downloaders.pop(task_id, None)


# ── Static files (must be last) ───────────────────────────────────────────────

app.mount("/", StaticFiles(directory="static", html=True), name="static")
