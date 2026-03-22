import asyncio
import hashlib
import json
import os
import re
import secrets
import shutil
import time
import uuid
from pathlib import Path
from typing import Optional

import aiohttp
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
PLAYLISTS_FILE = DOWNLOADS_DIR / "playlists.json"
MERGED_FILE = DOWNLOADS_DIR / "merged_config.json"
HEALTH_FILE = DOWNLOADS_DIR / "health_cache.json"

_HEALTH_CONCURRENCY = 15
_HEALTH_TIMEOUT = 8

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


# ── Playlist persistence ──────────────────────────────────────────────────────

def load_playlists() -> dict:
    if PLAYLISTS_FILE.exists():
        try:
            return json.loads(PLAYLISTS_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_playlists():
    try:
        PLAYLISTS_FILE.write_text(json.dumps(playlists, indent=2, default=str))
    except Exception:
        pass


playlists: dict = load_playlists()


# ── Merged "All Playlists" config ─────────────────────────────────────────────

def _channel_id(playlist_id: str, url: str) -> str:
    """Stable ID for a sourced channel based on playlist + URL."""
    return hashlib.md5(f"{playlist_id}:{url}".encode()).hexdigest()[:12]


def load_merged_config() -> dict:
    if MERGED_FILE.exists():
        try:
            return json.loads(MERGED_FILE.read_text())
        except Exception:
            return {"groups": []}
    return {"groups": []}


def save_merged_config():
    try:
        MERGED_FILE.write_text(json.dumps(merged_config, indent=2, default=str))
    except Exception:
        pass


merged_config: dict = load_merged_config()


# ── Health check ──────────────────────────────────────────────────────────────

def load_health_cache() -> dict:
    if HEALTH_FILE.exists():
        try:
            return json.loads(HEALTH_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_health_cache():
    try:
        HEALTH_FILE.write_text(json.dumps(health_cache, indent=2))
    except Exception:
        pass


health_cache: dict = load_health_cache()  # {url: {"status": "ok"|"dead", "checked_at": float}}
health_check_state: dict = {"running": False, "total": 0, "done": 0, "started_at": 0.0}
_health_gen: int = 0
_health_task: Optional[asyncio.Task] = None


async def _run_health_check(urls: list, gen: int):
    global health_check_state
    deduped = list(dict.fromkeys(u for u in urls if u and u.startswith(("http://", "https://"))))
    if not deduped:
        if _health_gen == gen:
            health_check_state["running"] = False
        return
    health_check_state.update({"running": True, "total": len(deduped), "done": 0, "started_at": time.time()})
    sem = asyncio.Semaphore(_HEALTH_CONCURRENCY)

    async def check_one(session: aiohttp.ClientSession, url: str):
        async with sem:
            try:
                async with session.get(url, allow_redirects=True, ssl=False) as resp:
                    st = "ok" if resp.status < 400 else "dead"
            except Exception:
                st = "dead"
            health_cache[url] = {"status": st, "checked_at": time.time()}
            health_check_state["done"] += 1

    try:
        timeout = aiohttp.ClientTimeout(total=_HEALTH_TIMEOUT)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            await asyncio.gather(*[check_one(session, url) for url in deduped])
    except (asyncio.CancelledError, Exception):
        pass
    finally:
        if _health_gen == gen:
            health_check_state["running"] = False
        save_health_cache()


def _trigger_health_check(urls: list):
    global _health_task, _health_gen
    _health_gen += 1
    gen = _health_gen
    if _health_task and not _health_task.done():
        _health_task.cancel()
    _health_task = asyncio.create_task(_run_health_check(urls, gen))


def build_merged_view() -> list:
    """Build the full merged group+channel tree from all playlists + config.

    Returns a list of group dicts, each with an ordered list of channels.
    Preserves user customizations (order, enabled state, custom items).
    """
    # Collect all sourced channels, grouped
    sourced: dict = {}  # group_name -> list of channel dicts
    for pl in playlists.values():
        pl_id = pl["id"]
        for ch in pl.get("channels", []):
            g = ch.get("group") or "Ungrouped"
            cid = _channel_id(pl_id, ch["url"])
            entry = {
                "id": cid,
                "name": ch.get("name", ""),
                "url": ch.get("url", ""),
                "tvg_id": ch.get("tvg_id", ""),
                "tvg_name": ch.get("tvg_name", ""),
                "tvg_logo": ch.get("tvg_logo", ""),
                "group": g,
                "enabled": True,
                "custom": False,
                "source_playlist_id": pl_id,
                "source_playlist_name": pl.get("name", ""),
            }
            sourced.setdefault(g, []).append(entry)

    existing_groups = merged_config.get("groups", [])
    if not existing_groups:
        # First build: create groups from sourced data
        groups = []
        for g_name, channels in sorted(sourced.items()):
            groups.append({
                "id": "g_" + hashlib.md5(g_name.encode()).hexdigest()[:8],
                "name": g_name,
                "enabled": True,
                "custom": False,
                "channels": channels,
            })
        return groups

    # Merge with existing config
    existing_group_names = {g["name"] for g in existing_groups}

    result = []
    for eg in existing_groups:
        g_name = eg["name"]
        new_group = {
            "id": eg.get("id", "g_" + hashlib.md5(g_name.encode()).hexdigest()[:8]),
            "name": g_name,
            "enabled": eg.get("enabled", True),
            "custom": eg.get("custom", False),
            "channels": [],
        }

        # Build channel map from sourced data for this group
        sourced_for_group = {ch["id"]: ch for ch in sourced.get(g_name, [])}

        # Keep existing channel order, update metadata from source
        for ech in eg.get("channels", []):
            if ech.get("custom"):
                new_group["channels"].append(ech)
            elif ech["id"] in sourced_for_group:
                updated = sourced_for_group.pop(ech["id"])
                updated["enabled"] = ech.get("enabled", True)
                new_group["channels"].append(updated)
            # else: channel was removed from source, drop it

        # Append new sourced channels not in existing config
        for ch in sourced_for_group.values():
            new_group["channels"].append(ch)

        result.append(new_group)

    # Append brand-new groups from sources
    for g_name, channels in sorted(sourced.items()):
        if g_name not in existing_group_names:
            result.append({
                "id": "g_" + hashlib.md5(g_name.encode()).hexdigest()[:8],
                "name": g_name,
                "enabled": True,
                "custom": False,
                "channels": channels,
            })

    return result


def parse_m3u_playlist(text: str) -> list:
    """Parse IPTV M3U playlist into a list of channel dicts.

    Handles the standard IPTV #EXTINF format:
        #EXTINF:-1 tvg-id="..." tvg-name="..." tvg-logo="..." group-title="...",Display Name
        http://stream-url
    """
    channels = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.upper().startswith("#EXTINF:"):
            channel: dict = {"name": "", "url": "", "tvg_id": "", "tvg_name": "", "tvg_logo": "", "group": ""}
            comma_pos = line.rfind(",")
            attr_part = line[8:comma_pos] if comma_pos != -1 else line[8:]
            if comma_pos != -1:
                channel["name"] = line[comma_pos + 1:].strip()
            for attr, key in [("tvg-id", "tvg_id"), ("tvg-name", "tvg_name"),
                               ("tvg-logo", "tvg_logo"), ("group-title", "group")]:
                m = re.search(rf'{attr}="([^"]*)"', attr_part, re.IGNORECASE)
                if m:
                    channel[key] = m.group(1)
            if not channel["name"] and channel["tvg_name"]:
                channel["name"] = channel["tvg_name"]
            # Find next URL line
            i += 1
            while i < len(lines):
                url_line = lines[i].strip()
                if url_line and not url_line.startswith("#"):
                    channel["url"] = url_line
                    if channel["name"] or channel["url"]:
                        channels.append(channel)
                    break
                i += 1
        i += 1
    return channels


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


class AddPlaylistRequest(BaseModel):
    name: str = ""
    url: str = ""
    text: str = ""  # raw M3U text (alternative to URL)


class EditPlaylistRequest(BaseModel):
    name: str = ""
    url: str = ""


class AddCustomGroupRequest(BaseModel):
    name: str


class AddCustomChannelRequest(BaseModel):
    name: str
    url: str
    group_id: str
    tvg_logo: str = ""


class EditChannelRequest(BaseModel):
    name: Optional[str] = None
    url: Optional[str] = None
    tvg_logo: Optional[str] = None
    group_id: Optional[str] = None
    enabled: Optional[bool] = None


class SaveMergedConfigRequest(BaseModel):
    groups: list  # full group+channel tree from frontend


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


_PREVIEW_NO_CACHE_HEADERS = {"Cache-Control": "no-cache, no-store, must-revalidate"}
_PREVIEW_TERMINAL_STATUSES = {
    "stopping",
    "merging",
    "completed",
    "failed",
    "cancelled",
    "interrupted",
}


def _get_preview_context(task_id: str) -> tuple[dict, Path, str, bool, int]:
    task = tasks.get(task_id)
    if not task:
        raise HTTPException(404, "Task not found")
    tmpdir = task.get("tmpdir")
    if not tmpdir or not Path(tmpdir).exists():
        raise HTTPException(404, "No preview available yet")
    return (
        task,
        Path(tmpdir),
        task.get("seg_ext", ".ts"),
        task.get("is_cmaf", False),
        int(task.get("target_duration") or 6),
    )


def _preview_segment_prefix(directory: Path, seg_ext: str) -> list[Path]:
    seg_files: list[Path] = []
    idx = 0
    while True:
        seg_path = directory / f"seg_{idx:06d}{seg_ext}"
        if not seg_path.exists():
            break
        if seg_path.stat().st_size <= 0:
            break
        seg_files.append(seg_path)
        idx += 1
    return seg_files


def _preview_is_terminal(task: dict) -> bool:
    return task.get("status") in _PREVIEW_TERMINAL_STATUSES


def _preview_media_response(
    seg_files: list[Path],
    target_dur: int,
    is_terminal: bool,
    segment_base_url: str,
    map_uri: Optional[str] = None,
) -> Response:
    if not seg_files:
        raise HTTPException(404, "No segments available yet")
    lines = [
        "#EXTM3U",
        f"#EXT-X-VERSION:{7 if map_uri else 3}",
        f"#EXT-X-TARGETDURATION:{target_dur}",
        "#EXT-X-MEDIA-SEQUENCE:0",
    ]
    if not is_terminal:
        lines.append("#EXT-X-PLAYLIST-TYPE:EVENT")
    if map_uri:
        lines.append(f'#EXT-X-MAP:URI="{map_uri}"')
    for seg_file in seg_files:
        lines.append(f"#EXTINF:{target_dur:.3f},")
        lines.append(f"{segment_base_url}/{seg_file.name}")
    if is_terminal:
        lines.append("#EXT-X-ENDLIST")
    return Response(
        "\n".join(lines),
        media_type="application/vnd.apple.mpegurl",
        headers=_PREVIEW_NO_CACHE_HEADERS,
    )


@app.get("/api/tasks/{task_id}/preview.m3u8")
async def preview_playlist(task_id: str):
    task, tmpdir_path, seg_ext, is_cmaf, target_dur = _get_preview_context(task_id)
    video_seg_files = _preview_segment_prefix(tmpdir_path, seg_ext)
    if not video_seg_files:
        raise HTTPException(404, "No segments available yet")

    if is_cmaf and not (tmpdir_path / "init.mp4").exists():
        raise HTTPException(404, "Preview init segment not ready yet")

    audio_dir = tmpdir_path / "audio"
    audio_init_file = audio_dir / "init.mp4"
    audio_seg_files = (
        _preview_segment_prefix(audio_dir, seg_ext)
        if audio_dir.exists() and audio_init_file.exists()
        else []
    )
    if audio_seg_files and min(len(video_seg_files), len(audio_seg_files)) > 0:
        lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            f'#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="/api/tasks/{task_id}/preview/audio.m3u8"',
            '#EXT-X-STREAM-INF:BANDWIDTH=1600000,AUDIO="audio",CLOSED-CAPTIONS=NONE',
            f"/api/tasks/{task_id}/preview/video.m3u8",
        ]
        return Response(
            "\n".join(lines),
            media_type="application/vnd.apple.mpegurl",
            headers=_PREVIEW_NO_CACHE_HEADERS,
        )

    return _preview_media_response(
        video_seg_files,
        target_dur,
        _preview_is_terminal(task),
        f"/api/tasks/{task_id}/seg",
        map_uri=f"/api/tasks/{task_id}/seg/init.mp4" if is_cmaf else None,
    )


@app.get("/api/tasks/{task_id}/preview/video.m3u8")
async def preview_video_playlist(task_id: str):
    task, tmpdir_path, seg_ext, is_cmaf, target_dur = _get_preview_context(task_id)
    video_seg_files = _preview_segment_prefix(tmpdir_path, seg_ext)
    if is_cmaf and not (tmpdir_path / "init.mp4").exists():
        raise HTTPException(404, "Preview init segment not ready yet")

    audio_dir = tmpdir_path / "audio"
    audio_init_file = audio_dir / "init.mp4"
    if audio_dir.exists() and audio_init_file.exists():
        audio_seg_files = _preview_segment_prefix(audio_dir, seg_ext)
        if audio_seg_files:
            video_seg_files = video_seg_files[: min(len(video_seg_files), len(audio_seg_files))]

    return _preview_media_response(
        video_seg_files,
        target_dur,
        _preview_is_terminal(task),
        f"/api/tasks/{task_id}/seg",
        map_uri=f"/api/tasks/{task_id}/seg/init.mp4" if is_cmaf else None,
    )


@app.get("/api/tasks/{task_id}/preview/audio.m3u8")
async def preview_audio_playlist(task_id: str):
    task, tmpdir_path, seg_ext, _is_cmaf, target_dur = _get_preview_context(task_id)
    audio_dir = tmpdir_path / "audio"
    audio_init_file = audio_dir / "init.mp4"
    if not audio_dir.exists() or not audio_init_file.exists():
        raise HTTPException(404, "No preview audio available yet")

    audio_seg_files = _preview_segment_prefix(audio_dir, seg_ext)
    video_seg_files = _preview_segment_prefix(tmpdir_path, seg_ext)
    if video_seg_files:
        audio_seg_files = audio_seg_files[: min(len(audio_seg_files), len(video_seg_files))]

    return _preview_media_response(
        audio_seg_files,
        target_dur,
        _preview_is_terminal(task),
        f"/api/tasks/{task_id}/audio-seg",
        map_uri=f"/api/tasks/{task_id}/audio-seg/init.mp4",
    )


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


@app.get("/api/tasks/{task_id}/audio-seg/{filename}")
async def serve_audio_segment(task_id: str, filename: str):
    task = tasks.get(task_id)
    if not task or not task.get("tmpdir"):
        raise HTTPException(404, "Task or tmpdir not found")
    if not (re.match(r"^seg_\d{6}\.(ts|m4s|mp4)$", filename) or filename == "init.mp4"):
        raise HTTPException(403, "Invalid filename")
    seg_path = Path(task["tmpdir"]) / "audio" / filename
    if not seg_path.exists():
        raise HTTPException(404, "Audio segment not found")
    media_type = "audio/mp2t" if filename.endswith(".ts") else "audio/mp4"
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


# ── Playlist routes ───────────────────────────────────────────────────────────

@app.get("/api/playlists")
async def list_playlists():
    result = [{k: v for k, v in pl.items() if k != "channels"} for pl in playlists.values()]
    return sorted(result, key=lambda p: p.get("created_at", 0), reverse=True)


@app.post("/api/playlists")
async def add_playlist(req: AddPlaylistRequest):
    if not req.url and not req.text:
        raise HTTPException(400, "URL or playlist text is required")

    raw_text = req.text
    source_url = req.url.strip()

    if source_url and not raw_text:
        try:
            timeout = aiohttp.ClientTimeout(total=30)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(source_url) as resp:
                    if resp.status != 200:
                        raise HTTPException(400, f"Failed to fetch playlist: HTTP {resp.status}")
                    raw_text = await resp.text(errors="replace")
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(400, f"Failed to fetch playlist: {e}")

    channels = parse_m3u_playlist(raw_text)
    if not channels:
        raise HTTPException(400, "No channels found in playlist")

    pl_id = str(uuid.uuid4())
    auto_name = source_url.split("/")[-1].split("?")[0] if source_url else "Playlist"
    name = req.name.strip() or auto_name or "Playlist"
    playlists[pl_id] = {
        "id": pl_id,
        "name": name,
        "url": source_url,
        "channel_count": len(channels),
        "channels": channels,
        "created_at": time.time(),
        "updated_at": time.time(),
    }
    save_playlists()
    _trigger_health_check([ch["url"] for ch in channels if ch.get("url")])
    return {"id": pl_id, "channel_count": len(channels)}


@app.get("/api/playlists/{pl_id}")
async def get_playlist(pl_id: str):
    if pl_id not in playlists:
        raise HTTPException(404, "Playlist not found")
    return playlists[pl_id]


@app.delete("/api/playlists/{pl_id}")
async def delete_playlist(pl_id: str):
    if pl_id not in playlists:
        raise HTTPException(404, "Playlist not found")
    del playlists[pl_id]
    save_playlists()
    return {"ok": True}


@app.patch("/api/playlists/{pl_id}")
async def edit_playlist(pl_id: str, req: EditPlaylistRequest):
    if pl_id not in playlists:
        raise HTTPException(404, "Playlist not found")
    if req.name.strip():
        playlists[pl_id]["name"] = req.name.strip()
    playlists[pl_id]["url"] = req.url.strip()
    save_playlists()
    return {"ok": True, "name": playlists[pl_id]["name"], "url": playlists[pl_id]["url"]}


@app.post("/api/playlists/{pl_id}/refresh")
async def refresh_playlist(pl_id: str):
    if pl_id not in playlists:
        raise HTTPException(404, "Playlist not found")
    pl = playlists[pl_id]
    if not pl.get("url"):
        raise HTTPException(400, "Playlist has no URL to refresh from")
    try:
        timeout = aiohttp.ClientTimeout(total=30)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(pl["url"]) as resp:
                if resp.status != 200:
                    raise HTTPException(400, f"Failed to fetch playlist: HTTP {resp.status}")
                raw_text = await resp.text(errors="replace")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(400, f"Failed to fetch playlist: {e}")

    channels = parse_m3u_playlist(raw_text)
    if not channels:
        raise HTTPException(400, "No channels found in refreshed playlist")

    playlists[pl_id]["channels"] = channels
    playlists[pl_id]["channel_count"] = len(channels)
    playlists[pl_id]["updated_at"] = time.time()
    save_playlists()
    _trigger_health_check([ch["url"] for ch in channels if ch.get("url")])
    return {"channel_count": len(channels)}


@app.get("/api/channels")
async def list_all_channels():
    result = []
    for pl in playlists.values():
        for ch in pl.get("channels", []):
            result.append({**ch, "playlist_id": pl["id"], "playlist_name": pl["name"]})
    return result


# ── All Playlists (merged editor) routes ──────────────────────────────────────

@app.get("/api/all-playlists")
async def get_all_playlists():
    """Return merged group+channel tree with user customizations applied."""
    groups = build_merged_view()
    # Persist on first access so subsequent calls use saved ordering
    if not merged_config.get("groups"):
        merged_config["groups"] = groups
        save_merged_config()
    return {"groups": groups}


@app.put("/api/all-playlists")
async def save_all_playlists(req: SaveMergedConfigRequest):
    """Save the full merged config (reorder, enable/disable) from frontend."""
    merged_config["groups"] = req.groups
    save_merged_config()
    return {"ok": True}


@app.post("/api/all-playlists/groups")
async def add_custom_group(req: AddCustomGroupRequest):
    name = req.name.strip()
    if not name:
        raise HTTPException(400, "Group name is required")
    groups = merged_config.get("groups") or build_merged_view()
    for g in groups:
        if g["name"] == name:
            raise HTTPException(400, f"Group '{name}' already exists")
    new_group = {
        "id": "g_" + uuid.uuid4().hex[:8],
        "name": name,
        "enabled": True,
        "custom": True,
        "channels": [],
    }
    groups.append(new_group)
    merged_config["groups"] = groups
    save_merged_config()
    return new_group


@app.delete("/api/all-playlists/groups/{group_id}")
async def delete_custom_group(group_id: str):
    groups = merged_config.get("groups", [])
    for i, g in enumerate(groups):
        if g["id"] == group_id:
            if not g.get("custom"):
                raise HTTPException(400, "Only custom groups can be deleted")
            groups.pop(i)
            merged_config["groups"] = groups
            save_merged_config()
            return {"ok": True}
    raise HTTPException(404, "Group not found")


@app.post("/api/all-playlists/channels")
async def add_custom_channel(req: AddCustomChannelRequest):
    if not req.name.strip() or not req.url.strip():
        raise HTTPException(400, "Channel name and URL are required")
    groups = merged_config.get("groups") or build_merged_view()
    target_group = None
    for g in groups:
        if g["id"] == req.group_id:
            target_group = g
            break
    if not target_group:
        raise HTTPException(404, "Group not found")
    new_channel = {
        "id": "cc_" + uuid.uuid4().hex[:8],
        "name": req.name.strip(),
        "url": req.url.strip(),
        "tvg_id": "",
        "tvg_name": "",
        "tvg_logo": req.tvg_logo.strip(),
        "group": target_group["name"],
        "enabled": True,
        "custom": True,
        "source_playlist_id": None,
        "source_playlist_name": None,
    }
    target_group["channels"].append(new_channel)
    merged_config["groups"] = groups
    save_merged_config()
    return new_channel


@app.patch("/api/all-playlists/channels/{channel_id}")
async def edit_channel(channel_id: str, req: EditChannelRequest):
    groups = merged_config.get("groups", [])
    for g in groups:
        for ch in g.get("channels", []):
            if ch["id"] == channel_id:
                if req.enabled is not None:
                    ch["enabled"] = req.enabled
                if ch.get("custom"):
                    if req.name is not None:
                        ch["name"] = req.name.strip()
                    if req.url is not None:
                        ch["url"] = req.url.strip()
                    if req.tvg_logo is not None:
                        ch["tvg_logo"] = req.tvg_logo.strip()
                    if req.group_id is not None:
                        # Move to different group
                        for tg in groups:
                            if tg["id"] == req.group_id:
                                ch["group"] = tg["name"]
                                g["channels"].remove(ch)
                                tg["channels"].append(ch)
                                break
                merged_config["groups"] = groups
                save_merged_config()
                return ch
    raise HTTPException(404, "Channel not found")


@app.delete("/api/all-playlists/channels/{channel_id}")
async def delete_custom_channel(channel_id: str):
    groups = merged_config.get("groups", [])
    for g in groups:
        for i, ch in enumerate(g.get("channels", [])):
            if ch["id"] == channel_id:
                if not ch.get("custom"):
                    raise HTTPException(400, "Only custom channels can be deleted")
                g["channels"].pop(i)
                merged_config["groups"] = groups
                save_merged_config()
                return {"ok": True}
    raise HTTPException(404, "Channel not found")


@app.post("/api/all-playlists/refresh")
async def refresh_all_playlists():
    """Re-fetch all source playlist URLs and smart-merge with existing config."""
    errors = []
    for pl_id, pl in list(playlists.items()):
        url = pl.get("url")
        if not url:
            continue
        try:
            timeout = aiohttp.ClientTimeout(total=30)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(url) as resp:
                    if resp.status != 200:
                        errors.append(f"{pl.get('name', pl_id)}: HTTP {resp.status}")
                        continue
                    raw_text = await resp.text(errors="replace")
            channels = parse_m3u_playlist(raw_text)
            if channels:
                playlists[pl_id]["channels"] = channels
                playlists[pl_id]["channel_count"] = len(channels)
                playlists[pl_id]["updated_at"] = time.time()
        except Exception as e:
            errors.append(f"{pl.get('name', pl_id)}: {e}")
    save_playlists()

    # Rebuild merged view (preserves custom items, disabled state, ordering)
    merged_config["groups"] = build_merged_view()
    save_merged_config()

    all_urls = [ch["url"] for g in merged_config["groups"] for ch in g.get("channels", []) if ch.get("url")]
    _trigger_health_check(all_urls)

    total = sum(pl.get("channel_count", 0) for pl in playlists.values())
    return {"ok": True, "total_channels": total, "errors": errors}


@app.get("/api/all-playlists/export.m3u")
async def export_m3u():
    """Export enabled channels as M3U playlist."""
    groups = merged_config.get("groups") or build_merged_view()
    lines = ["#EXTM3U"]
    for g in groups:
        if not g.get("enabled", True):
            continue
        for ch in g.get("channels", []):
            if not ch.get("enabled", True):
                continue
            attrs = f'tvg-id="{ch.get("tvg_id", "")}" tvg-name="{ch.get("tvg_name", "") or ch.get("name", "")}" tvg-logo="{ch.get("tvg_logo", "")}" group-title="{g["name"]}"'
            lines.append(f'#EXTINF:-1 {attrs},{ch.get("name", "")}')
            lines.append(ch.get("url", ""))
    content = "\n".join(lines) + "\n"
    return Response(content=content, media_type="text/plain; charset=utf-8")


# ── Health check routes ───────────────────────────────────────────────────────

@app.get("/api/health-check")
async def get_health_status():
    return {
        "running": health_check_state["running"],
        "total": health_check_state["total"],
        "done": health_check_state["done"],
        "started_at": health_check_state["started_at"],
        "cache": health_cache,
    }


@app.post("/api/health-check")
async def trigger_health_check_route():
    """Manually trigger health check for all enabled channels."""
    groups = merged_config.get("groups") or build_merged_view()
    urls = [ch["url"] for g in groups for ch in g.get("channels", []) if ch.get("url")]
    _trigger_health_check(urls)
    return {"ok": True, "total": len(set(urls))}


# ── Static files (must be last) ───────────────────────────────────────────────

app.mount("/", StaticFiles(directory="static", html=True), name="static")
