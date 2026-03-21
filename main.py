import asyncio
import json
import os
import re
import secrets
import shutil
import time
import uuid
from pathlib import Path
from typing import Optional

from fastapi import BackgroundTasks, FastAPI, HTTPException, Request
from starlette.middleware.base import BaseHTTPMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from downloader import M3U8Downloader, parse_curl_command

app = FastAPI(title="M3U8 Downloader")

# ── Auth ─────────────────────────────────────────────────────────────────────

AUTH_PASSWORD = os.environ.get("AUTH_PASSWORD", "")
sessions: set = set()  # valid session tokens (in-memory)

_STATIC_EXTS = {".js", ".css", ".ico", ".png", ".svg", ".woff", ".woff2", ".ttf", ".map"}

# ── Login rate limiting ───────────────────────────────────────────────────────

_MAX_ATTEMPTS = 5
_LOCK_SECONDS = 300  # 5 minutes

# { ip: {"count": int, "lock_until": float} }
_login_failures: dict = {}


def _get_client_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _check_lock(ip: str) -> tuple[bool, int]:
    """Return (is_locked, remaining_seconds). Clears expired locks."""
    entry = _login_failures.get(ip)
    if not entry or entry["count"] < _MAX_ATTEMPTS:
        return False, 0
    remaining = int(entry["lock_until"] - time.time())
    if remaining <= 0:
        _login_failures.pop(ip, None)
        return False, 0
    return True, remaining


def _record_failure(ip: str) -> tuple[bool, int]:
    """Record a failed attempt. Returns (now_locked, remaining_seconds)."""
    entry = _login_failures.setdefault(ip, {"count": 0, "lock_until": 0.0})
    entry["count"] += 1
    if entry["count"] >= _MAX_ATTEMPTS:
        entry["lock_until"] = time.time() + _LOCK_SECONDS
        return True, _LOCK_SECONDS
    return False, 0


class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if not AUTH_PASSWORD:
            return await call_next(request)

        path = request.url.path

        # Always allow login page and login/logout API
        if path in ("/login", "/api/login", "/api/logout"):
            return await call_next(request)

        # Always allow static assets (needed by login page)
        if Path(path).suffix.lower() in _STATIC_EXTS:
            return await call_next(request)

        token = request.cookies.get("session")
        if token and token in sessions:
            return await call_next(request)

        if path.startswith("/api/"):
            return JSONResponse({"detail": "Unauthorized. Please log in."}, status_code=401)

        return RedirectResponse("/login")

# AuthMiddleware must be added before NoCacheStaticMiddleware
app.add_middleware(AuthMiddleware)

# Prevent browsers from caching JS/CSS so UI updates are always visible
class NoCacheStaticMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        path = request.url.path
        if path.endswith((".js", ".css")):
            response.headers["Cache-Control"] = "no-store"
        return response

app.add_middleware(NoCacheStaticMiddleware)

DOWNLOADS_DIR = Path(os.environ.get("DOWNLOADS_DIR", "downloads"))
DOWNLOADS_DIR.mkdir(parents=True, exist_ok=True)
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


class BatchRequest(BaseModel):
    batch_text: str
    headers: dict = {}
    quality: str = "best"
    task_parallelism: int = 3   # how many tasks download simultaneously
    concurrency: int = 4        # per-task segment concurrency


# ── Auth routes ──────────────────────────────────────────────────────────────

@app.get("/login")
async def login_page():
    return FileResponse("static/login.html")


class LoginRequest(BaseModel):
    password: str


@app.post("/api/login")
async def login(req: LoginRequest, request: Request, response: Response):
    if not AUTH_PASSWORD:
        return {"ok": True, "message": "auth disabled"}

    ip = _get_client_ip(request)

    # Check if already locked
    locked, remaining = _check_lock(ip)
    if locked:
        raise HTTPException(
            429, f"Too many attempts. Try again in {remaining} seconds"
        )

    if req.password != AUTH_PASSWORD:
        now_locked, lock_remaining = _record_failure(ip)
        entry = _login_failures.get(ip, {})
        if now_locked:
            raise HTTPException(
                429,
                f"Too many failed attempts. This IP is locked for {_LOCK_SECONDS // 60} minutes"
            )
        left = _MAX_ATTEMPTS - entry.get("count", 0)
        raise HTTPException(401, f"Incorrect password. {left} attempt(s) remaining")

    # Success — clear failure record and issue session
    _login_failures.pop(ip, None)
    token = secrets.token_hex(32)
    sessions.add(token)
    response.set_cookie("session", token, httponly=True, samesite="strict")
    return {"ok": True}


@app.post("/api/logout")
async def logout(request: Request, response: Response):
    token = request.cookies.get("session")
    if token:
        sessions.discard(token)
    response.delete_cookie("session")
    return {"ok": True}


@app.get("/api/auth/status")
async def auth_status():
    return {"auth_required": bool(AUTH_PASSWORD)}


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
    tasks[task_id] = _make_task_dict(task_id, req)
    save_tasks()
    bg.add_task(_run_download, task_id, req)
    return {"task_id": task_id}


def _parse_batch_text(text: str):
    """Parse batch text into [(title, url)] pairs.

    Supports two formats:
      1. Standard M3U:   #EXTINF:-1 group-title="x",Title Here
                         https://example.com/stream.m3u8
      2. Simple custom:  #optional title
                         https://example.com/stream.m3u8

    A URL without a preceding title line gets None (auto-generated name).
    """
    items = []
    current_title = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.upper().startswith("#EXTINF:"):
            # Standard M3U: title is everything after the last comma
            comma_pos = line.rfind(",")
            if comma_pos != -1:
                title = line[comma_pos + 1:].strip()
                current_title = title if title else None
        elif line.startswith("#"):
            # Simple custom: strip the leading #
            current_title = line[1:].strip() or None
        elif line.startswith(("http://", "https://")):
            items.append((current_title, line))
            current_title = None  # title consumed by this URL
    return items


@app.post("/api/batch")
async def batch_download(req: BatchRequest):
    """Parse a batch text block and start all downloads in parallel (up to task_parallelism)."""
    items = _parse_batch_text(req.batch_text)
    if not items:
        raise HTTPException(400, "No valid URLs found in batch text")

    task_ids = []
    now = time.time()
    sem = asyncio.Semaphore(req.task_parallelism)

    for idx, (title, url) in enumerate(items):
        task_id = str(uuid.uuid4())
        dl_req = DownloadRequest(
            url=url,
            headers=req.headers,
            output_name=title or None,
            quality=req.quality,
            concurrency=req.concurrency,
        )
        task_dict = _make_task_dict(task_id, dl_req)
        task_dict["created_at"] = now + idx * 0.001
        tasks[task_id] = task_dict
        task_ids.append((task_id, dl_req))

    save_tasks()

    async def run_with_sem(tid: str, r: DownloadRequest):
        async with sem:
            await _run_download(tid, r)

    for tid, r in task_ids:
        asyncio.create_task(run_with_sem(tid, r))

    return {"task_ids": [t for t, _ in task_ids], "count": len(task_ids)}


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
        # Active task: cancel it and keep in registry so _run_download can finish
        tasks[task_id]["status"] = "cancelled"
        if dl:
            dl.cancel()
        _cleanup_tmpdir(task_id)
        save_tasks()
        return {"status": "cancelled"}

    # Terminal task: fully remove from registry, tmpdir, and output file
    _cleanup_tmpdir(task_id)
    output = task.get("output")
    if output:
        out_path = DOWNLOADS_DIR / output
        if out_path.exists():
            out_path.unlink(missing_ok=True)
    del tasks[task_id]
    save_tasks()
    return {"status": "deleted"}


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


def _make_task_dict(task_id: str, req: DownloadRequest) -> dict:
    return {
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
        "req_headers": req.headers,
        "output_name": req.output_name,
        "quality": req.quality,
        "concurrency": req.concurrency,
    }


@app.post("/api/tasks/{task_id}/recording-restart")
async def recording_restart(task_id: str, bg: BackgroundTasks):
    """Cancel a live recording (discard segments) and immediately start a fresh one."""
    if task_id not in tasks:
        raise HTTPException(404, "Task not found")
    task = tasks[task_id]
    if task.get("status") != "recording":
        raise HTTPException(400, "Task is not currently recording")

    dl = downloaders.get(task_id)
    if dl:
        dl.cancel()
    _cleanup_tmpdir(task_id)
    tasks[task_id]["status"] = "cancelled"
    tasks[task_id]["_auto_delete"] = True  # _run_download will remove this entry on exit
    save_tasks()

    req = DownloadRequest(
        url=task["url"],
        headers=task.get("req_headers") or {},
        output_name=task.get("output_name"),
        quality=task.get("quality", "best"),
        concurrency=task.get("concurrency", 8),
    )
    new_task_id = str(uuid.uuid4())
    tasks[new_task_id] = _make_task_dict(new_task_id, req)
    save_tasks()
    bg.add_task(_run_download, new_task_id, req)
    return {"new_task_id": new_task_id, "url": req.url}


@app.post("/api/tasks/{task_id}/fork")
async def fork_recording(task_id: str, bg: BackgroundTasks):
    """Stop a live recording (keep & merge segments) and start a fresh recording."""
    if task_id not in tasks:
        raise HTTPException(404, "Task not found")
    task = tasks[task_id]
    if task.get("status") != "recording":
        raise HTTPException(400, "Task is not currently recording")

    dl = downloaders.get(task_id)
    if dl:
        dl.stop_recording()
    tasks[task_id]["status"] = "stopping"
    save_tasks()

    req = DownloadRequest(
        url=task["url"],
        headers=task.get("req_headers") or {},
        output_name=task.get("output_name"),
        quality=task.get("quality", "best"),
        concurrency=task.get("concurrency", 8),
    )
    new_task_id = str(uuid.uuid4())
    tasks[new_task_id] = _make_task_dict(new_task_id, req)
    save_tasks()
    bg.add_task(_run_download, new_task_id, req)
    return {"new_task_id": new_task_id, "url": req.url}


@app.post("/api/tasks/{task_id}/restart")
async def restart_task(task_id: str, bg: BackgroundTasks):
    """Re-download from scratch: clear cache + output file and re-run."""
    if task_id not in tasks:
        raise HTTPException(404, "Task not found")
    task = tasks[task_id]
    if task.get("status") not in ("completed", "failed", "cancelled", "interrupted"):
        raise HTTPException(400, "Task cannot be restarted in its current state")

    # Remove cached segments
    _cleanup_tmpdir(task_id)

    # Remove previously downloaded output file
    output = task.get("output")
    if output:
        out_path = DOWNLOADS_DIR / output
        if out_path.exists():
            try:
                out_path.unlink()
            except Exception:
                pass

    req = DownloadRequest(
        url=task["url"],
        headers=task.get("req_headers") or {},
        output_name=task.get("output_name"),
        quality=task.get("quality", "best"),
        concurrency=task.get("concurrency", 8),
    )
    tasks[task_id].update({
        "status": "queued",
        "progress": 0,
        "downloaded": 0,
        "failed": 0,
        "total": 0,
        "bytes_downloaded": 0,
        "speed_mbps": 0.0,
        "output": None,
        "size": 0,
        "error": None,
        "tmpdir": None,
    })
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
    task = tasks.get(task_id)
    if not task:
        return
    tmpdir = task.get("tmpdir")
    if tmpdir:
        p = Path(tmpdir)
        if p.exists():
            shutil.rmtree(p, ignore_errors=True)
        task["tmpdir"] = None


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
        if tasks.get(task_id, {}).get("_auto_delete"):
            del tasks[task_id]
            save_tasks()


# ── Static files (must be last) ───────────────────────────────────────────────

app.mount("/", StaticFiles(directory="static", html=True), name="static")
