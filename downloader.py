import re
import uuid
import asyncio
import aiohttp
import m3u8
import shutil
import time
from pathlib import Path
from urllib.parse import urljoin
from typing import AsyncGenerator, Dict, Any, Optional


def parse_curl_command(curl_cmd: str):
    """Parse a curl command string, return (url, headers) tuple."""
    curl_cmd = re.sub(r"\\\s*\n\s*", " ", curl_cmd)

    url = None
    headers = {}

    for pattern in [r"curl\s+'([^']+)'", r'curl\s+"([^"]+)"', r"curl\s+(\S+)"]:
        m = re.search(pattern, curl_cmd)
        if m:
            url = m.group(1)
            break

    for pattern in [r"-H\s+'([^']+)'", r'-H\s+"([^"]+)"']:
        for m in re.finditer(pattern, curl_cmd):
            h = m.group(1)
            if ":" in h:
                k, _, v = h.partition(":")
                headers[k.strip()] = v.strip()

    return url, headers


class M3U8Downloader:
    def __init__(
        self,
        url: str,
        headers: Dict[str, str] = None,
        output_dir=None,
        output_name: str = None,
        quality: str = "best",
        concurrency: int = 8,
        retry: int = 3,
        task_id: str = None,
    ):
        self.url = url
        self.headers = headers or {}
        self.output_dir = Path(output_dir) if output_dir else Path("downloads")
        self.output_name = output_name
        self.quality = quality
        self.concurrency = concurrency
        self.retry = retry
        self.task_id = task_id or str(uuid.uuid4())
        self._cancel = False
        self._stop = False  # stop live recording but still merge

    def cancel(self):
        self._cancel = True

    def stop_recording(self):
        """Signal live stream to stop polling and proceed to merge."""
        self._stop = True
        self._cancel = True

    def cleanup_cache(self):
        """Remove the deterministic cache directory for this task."""
        cache_dir = self.output_dir / ".cache" / self.task_id
        if cache_dir.exists():
            shutil.rmtree(cache_dir, ignore_errors=True)

    def _make_session(self):
        connector = aiohttp.TCPConnector(ssl=False, limit=self.concurrency * 4)
        timeout = aiohttp.ClientTimeout(total=60, connect=15)
        return aiohttp.ClientSession(
            headers=self.headers,
            connector=connector,
            timeout=timeout,
        )

    def _resolve(self, uri: str, base: str) -> str:
        if not uri:
            return uri
        if uri.startswith("http://") or uri.startswith("https://"):
            return uri
        return urljoin(base, uri)

    async def _fetch_bytes(self, session: aiohttp.ClientSession, url: str) -> bytes:
        for attempt in range(self.retry):
            try:
                async with session.get(url) as r:
                    r.raise_for_status()
                    return await r.read()
            except Exception as e:
                if attempt == self.retry - 1:
                    raise
                await asyncio.sleep(min(2 ** attempt, 8))

    async def _fetch_text(self, session: aiohttp.ClientSession, url: str) -> str:
        data = await self._fetch_bytes(session, url)
        return data.decode("utf-8", errors="replace")

    async def parse(self) -> Dict[str, Any]:
        """Fetch and parse M3U8, return stream metadata."""
        async with self._make_session() as session:
            content = await self._fetch_text(session, self.url)

        pl = m3u8.loads(content)

        if pl.is_variant:
            streams = []
            for p in pl.playlists:
                si = p.stream_info
                res = si.resolution
                streams.append(
                    {
                        "url": self._resolve(p.uri, self.url),
                        "bandwidth": si.bandwidth,
                        "resolution": f"{res[0]}x{res[1]}" if res else None,
                        "label": f"{res[1]}p" if res else f"{si.bandwidth // 1000}kbps",
                        "codecs": si.codecs or "",
                    }
                )
            streams.sort(key=lambda x: x["bandwidth"], reverse=True)
            return {"type": "master", "streams": streams}
        else:
            duration = sum(s.duration or 0 for s in pl.segments)
            encrypted = bool(
                pl.keys and any(k and k.method != "NONE" for k in pl.keys)
            )
            return {
                "type": "media",
                "segments": len(pl.segments),
                "duration": round(duration, 2),
                "encrypted": encrypted,
                "is_live": not pl.is_endlist,
            }

    async def download(self) -> AsyncGenerator[Dict[str, Any], None]:
        """Download the M3U8 stream, yielding progress dicts."""
        # Deterministic cache dir: survives server restarts for resume/preview
        tmpdir_path = self.output_dir / ".cache" / self.task_id
        tmpdir_path.mkdir(parents=True, exist_ok=True)
        try:
            async with self._make_session() as session:
                content = await self._fetch_text(session, self.url)
                pl = m3u8.loads(content)
                base_url = self.url

                master_pl = None
                if pl.is_variant:
                    master_pl = pl
                    chosen_url = self._pick_quality(pl)
                    content = await self._fetch_text(session, chosen_url)
                    pl = m3u8.loads(content)
                    base_url = chosen_url

                segments = pl.segments
                total = len(segments)

                is_live = not pl.is_endlist
                if total == 0 and not is_live:
                    yield {"status": "failed", "error": "No segments found in playlist"}
                    return

                # Detect separate audio rendition (demuxed CMAF streams carry
                # video-only fragments; audio lives in a separate EXT-X-MEDIA playlist)
                audio_url: Optional[str] = None
                audio_tmpdir: Optional[Path] = None
                audio_pl_initial = None
                if master_pl is not None:
                    audio_url = self._find_audio_playlist(master_pl)

                # ── Format detection ──────────────────────────────────────────
                # CMAF/fMP4 playlists carry an #EXT-X-MAP init segment and use
                # .m4s/.mp4 fragments.  MPEG-TS playlists use .ts segments.
                is_cmaf = self._detect_cmaf(segments)
                seg_ext = ".m4s" if is_cmaf else ".ts"

                # Pre-fetch AES-128 keys
                keys_cache: Dict[str, bytes] = {}
                for seg in segments:
                    if seg.key and seg.key.method == "AES-128" and seg.key.uri:
                        key_url = self._resolve(seg.key.uri, base_url)
                        if key_url not in keys_cache:
                            keys_cache[key_url] = await self._fetch_bytes(
                                session, key_url
                            )

                # Download CMAF init segment(s) (EXT-X-MAP)
                # Also save to disk so preview endpoint can serve it
                init_data_map: Dict[str, bytes] = {}
                if is_cmaf:
                    init_disk = tmpdir_path / "init.mp4"
                    for seg in segments:
                        init_sec = getattr(seg, "init_section", None)
                        if init_sec and getattr(init_sec, "uri", None):
                            init_url = self._resolve(init_sec.uri, base_url)
                            if init_url not in init_data_map:
                                try:
                                    if init_disk.exists() and init_disk.stat().st_size > 0:
                                        init_data_map[init_url] = init_disk.read_bytes()
                                    else:
                                        init_bytes = await self._fetch_bytes(session, init_url)
                                        init_data_map[init_url] = init_bytes
                                        init_disk.write_bytes(init_bytes)
                                except Exception:
                                    pass

                # Setup audio subdirectory and fetch audio init segment
                if is_cmaf and audio_url:
                    audio_tmpdir = tmpdir_path / "audio"
                    audio_tmpdir.mkdir(exist_ok=True)
                    try:
                        audio_content = await self._fetch_text(session, audio_url)
                        audio_pl_initial = m3u8.loads(audio_content)
                        audio_init_disk = audio_tmpdir / "init.mp4"
                        if not (audio_init_disk.exists() and audio_init_disk.stat().st_size > 0):
                            for seg in audio_pl_initial.segments:
                                init_sec = getattr(seg, "init_section", None)
                                if init_sec and getattr(init_sec, "uri", None):
                                    try:
                                        ai_url = self._resolve(init_sec.uri, audio_url)
                                        ai_bytes = await self._fetch_bytes(session, ai_url)
                                        audio_init_disk.write_bytes(ai_bytes)
                                    except Exception:
                                        pass
                                    break
                    except Exception:
                        audio_tmpdir = None
                        audio_url = None

                start_time = time.time()
                semaphore = asyncio.Semaphore(self.concurrency)
                bytes_downloaded = 0
                total_audio = 0  # populated by whichever branch runs

                # ── LIVE recording ────────────────────────────────────────────
                if is_live:
                    # Resume: start segment index from how many files already exist
                    # so that new segments are APPENDED after old ones, not overwritten.
                    existing_segs = sorted(tmpdir_path.glob(f"seg_*{seg_ext}"))
                    seg_idx = len(existing_segs)

                    seen_uris: set = set()
                    poll_interval = max(1.0, (pl.target_duration or 6) / 2)
                    current_pl = pl

                    # Audio live tracking (also resume-aware)
                    audio_seen_uris: set = set()
                    if audio_tmpdir:
                        existing_audio_segs = sorted(audio_tmpdir.glob(f"seg_*{seg_ext}"))
                        audio_seg_idx = len(existing_audio_segs)
                    else:
                        audio_seg_idx = 0
                    current_audio_pl = audio_pl_initial  # may be None

                    # Single coroutine reused across all batches
                    async def dl_live_one(idx: int, seg):
                        nonlocal bytes_downloaded
                        seg_path = tmpdir_path / f"seg_{idx:06d}{seg_ext}"
                        # Skip already-downloaded segments (e.g. on resume)
                        if seg_path.exists() and seg_path.stat().st_size > 0:
                            bytes_downloaded += seg_path.stat().st_size
                            return
                        seg_url = self._resolve(seg.uri, base_url)
                        async with semaphore:
                            try:
                                data = await self._fetch_bytes(session, seg_url)
                                if seg.key and seg.key.method == "AES-128":
                                    ku = self._resolve(seg.key.uri, base_url)
                                    k = keys_cache.get(ku)
                                    if k:
                                        data = self._decrypt_aes128(data, k, seg.key.iv)
                                seg_path.write_bytes(data)
                                bytes_downloaded += len(data)
                            except Exception:
                                pass

                    async def dl_audio_live_one(idx: int, seg):
                        nonlocal bytes_downloaded
                        if not audio_tmpdir or not audio_url:
                            return
                        seg_path = audio_tmpdir / f"seg_{idx:06d}{seg_ext}"
                        if seg_path.exists() and seg_path.stat().st_size > 0:
                            bytes_downloaded += seg_path.stat().st_size
                            return
                        au_url = self._resolve(seg.uri, audio_url)
                        async with semaphore:
                            try:
                                data = await self._fetch_bytes(session, au_url)
                                seg_path.write_bytes(data)
                                bytes_downloaded += len(data)
                            except Exception:
                                pass

                    yield {
                        "status": "recording",
                        "recorded_segments": seg_idx,
                        "bytes_downloaded": 0,
                        "speed_mbps": 0.0,
                        "elapsed_sec": 0,
                        "tmpdir": str(tmpdir_path),
                        "is_cmaf": is_cmaf,
                        "seg_ext": seg_ext,
                        "target_duration": pl.target_duration or 6,
                    }

                    while not self._cancel:
                        new_segs = [
                            s for s in current_pl.segments if s.uri not in seen_uris
                        ]

                        # Pre-fetch AES keys for new segments
                        for seg in new_segs:
                            if seg.key and seg.key.method == "AES-128" and seg.key.uri:
                                ku = self._resolve(seg.key.uri, base_url)
                                if ku not in keys_cache:
                                    try:
                                        keys_cache[ku] = await self._fetch_bytes(
                                            session, ku
                                        )
                                    except Exception:
                                        pass

                        # Assign indices and mark seen before download
                        batch = []
                        for seg in new_segs:
                            seen_uris.add(seg.uri)
                            batch.append((seg_idx, seg))
                            seg_idx += 1

                        if batch:
                            await asyncio.gather(
                                *[
                                    asyncio.create_task(dl_live_one(i, s))
                                    for i, s in batch
                                ],
                                return_exceptions=True,
                            )

                        # Download new audio segments in parallel
                        if audio_tmpdir and current_audio_pl:
                            new_audio_segs = [
                                s for s in current_audio_pl.segments
                                if s.uri not in audio_seen_uris
                            ]
                            audio_batch = []
                            for seg in new_audio_segs:
                                audio_seen_uris.add(seg.uri)
                                audio_batch.append((audio_seg_idx, seg))
                                audio_seg_idx += 1
                            if audio_batch:
                                await asyncio.gather(
                                    *[
                                        asyncio.create_task(dl_audio_live_one(i, s))
                                        for i, s in audio_batch
                                    ],
                                    return_exceptions=True,
                                )

                        elapsed = time.time() - start_time
                        yield {
                            "status": "recording",
                            "recorded_segments": seg_idx,
                            "bytes_downloaded": bytes_downloaded,
                            "speed_mbps": round(
                                bytes_downloaded / elapsed / 1024 / 1024, 2
                            )
                            if elapsed > 0
                            else 0.0,
                            "elapsed_sec": round(elapsed),
                        }

                        if current_pl.is_endlist:
                            break

                        # Interruptible sleep: check _cancel every 0.3 s so
                        # stop_recording() takes effect almost immediately.
                        deadline = asyncio.get_event_loop().time() + poll_interval
                        while not self._cancel:
                            remaining = deadline - asyncio.get_event_loop().time()
                            if remaining <= 0:
                                break
                            await asyncio.sleep(min(0.3, remaining))

                        if self._cancel:
                            break

                        # Re-fetch video playlist
                        try:
                            nc = await self._fetch_text(session, base_url)
                            current_pl = m3u8.loads(nc)
                            poll_interval = max(
                                1.0, (current_pl.target_duration or 6) / 2
                            )
                            # Pick up any new CMAF init segments
                            if is_cmaf:
                                for seg in current_pl.segments:
                                    init_sec = getattr(seg, "init_section", None)
                                    if init_sec and getattr(init_sec, "uri", None):
                                        iu = self._resolve(init_sec.uri, base_url)
                                        if iu not in init_data_map:
                                            try:
                                                init_data_map[iu] = (
                                                    await self._fetch_bytes(session, iu)
                                                )
                                            except Exception:
                                                pass
                        except Exception:
                            pass  # keep polling on transient errors

                        # Re-fetch audio playlist
                        if audio_tmpdir and audio_url:
                            try:
                                aac = await self._fetch_text(session, audio_url)
                                current_audio_pl = m3u8.loads(aac)
                                # Fetch new audio init if it changed
                                audio_init_disk = audio_tmpdir / "init.mp4"
                                if not (audio_init_disk.exists() and audio_init_disk.stat().st_size > 0):
                                    for seg in current_audio_pl.segments:
                                        init_sec = getattr(seg, "init_section", None)
                                        if init_sec and getattr(init_sec, "uri", None):
                                            try:
                                                ai_url = self._resolve(init_sec.uri, audio_url)
                                                ai_bytes = await self._fetch_bytes(session, ai_url)
                                                audio_init_disk.write_bytes(ai_bytes)
                                            except Exception:
                                                pass
                                            break
                            except Exception:
                                pass

                    # _stop = stop+merge (user clicked "停止录制")
                    # _cancel only (no _stop) = true cancel, discard segments
                    if self._cancel and not self._stop:
                        yield {"status": "cancelled"}
                        return

                    total = seg_idx  # for merge step below
                    total_audio = audio_seg_idx

                else:
                    # ── VOD download ──────────────────────────────────────────
                    yield {
                        "status": "downloading",
                        "total": total,
                        "downloaded": 0,
                        "progress": 0,
                        "tmpdir": str(tmpdir_path),
                        "is_cmaf": is_cmaf,
                        "seg_ext": seg_ext,
                        "target_duration": pl.target_duration or 6,
                    }

                    downloaded = 0
                    failed_count = 0

                    async def dl_one(idx: int, seg):
                        nonlocal downloaded, failed_count, bytes_downloaded
                        if self._cancel:
                            return
                        seg_path = tmpdir_path / f"seg_{idx:06d}{seg_ext}"
                        # Resume: skip already-downloaded segments
                        if seg_path.exists() and seg_path.stat().st_size > 0:
                            downloaded += 1
                            bytes_downloaded += seg_path.stat().st_size
                            return
                        seg_url = self._resolve(seg.uri, base_url)
                        async with semaphore:
                            try:
                                data = await self._fetch_bytes(session, seg_url)
                                if seg.key and seg.key.method == "AES-128":
                                    key_url = self._resolve(seg.key.uri, base_url)
                                    key = keys_cache.get(key_url)
                                    if key:
                                        data = self._decrypt_aes128(
                                            data, key, seg.key.iv
                                        )
                                seg_path.write_bytes(data)
                                downloaded += 1
                                bytes_downloaded += len(data)
                            except Exception:
                                failed_count += 1

                    all_tasks = [
                        asyncio.create_task(dl_one(i, s))
                        for i, s in enumerate(segments)
                    ]

                    # Audio download tasks (for demuxed CMAF streams)
                    audio_vod_total = 0
                    audio_vod_tasks = []
                    if audio_tmpdir and audio_pl_initial:
                        audio_vod_segs = audio_pl_initial.segments
                        audio_vod_total = len(audio_vod_segs)

                        async def dl_audio_one(idx: int, seg):
                            nonlocal bytes_downloaded
                            seg_path = audio_tmpdir / f"seg_{idx:06d}{seg_ext}"
                            if seg_path.exists() and seg_path.stat().st_size > 0:
                                bytes_downloaded += seg_path.stat().st_size
                                return
                            au_url = self._resolve(seg.uri, audio_url)
                            async with semaphore:
                                try:
                                    data = await self._fetch_bytes(session, au_url)
                                    seg_path.write_bytes(data)
                                    bytes_downloaded += len(data)
                                except Exception:
                                    pass

                        audio_vod_tasks = [
                            asyncio.create_task(dl_audio_one(i, s))
                            for i, s in enumerate(audio_vod_segs)
                        ]

                    while True:
                        done = sum(1 for t in all_tasks if t.done())
                        audio_done = sum(1 for t in audio_vod_tasks if t.done())
                        elapsed = time.time() - start_time
                        speed_mbps = (
                            (bytes_downloaded / elapsed / 1024 / 1024)
                            if elapsed > 0
                            else 0
                        )
                        yield {
                            "status": "downloading",
                            "total": total,
                            "downloaded": downloaded,
                            "failed": failed_count,
                            "progress": int(done / total * 100) if total > 0 else 0,
                            "speed_mbps": round(speed_mbps, 2),
                            "bytes_downloaded": bytes_downloaded,
                        }
                        if (done >= total and audio_done >= audio_vod_total) or self._cancel:
                            break
                        await asyncio.sleep(0.5)

                    await asyncio.gather(*all_tasks, *audio_vod_tasks, return_exceptions=True)

                    if self._cancel:
                        yield {"status": "cancelled"}
                        return

                    if failed_count > max(1, total * 0.1):
                        yield {
                            "status": "failed",
                            "error": f"Too many segments failed ({failed_count}/{total})",
                        }
                        return

                    total_audio = audio_vod_total

                # ── Merge (shared by live and VOD) ────────────────────────────
                yield {"status": "merging", "progress": 0}

                output_name = self.output_name or f"video_{int(time.time())}"
                if not output_name.endswith(".mp4"):
                    output_name += ".mp4"
                self.output_dir.mkdir(parents=True, exist_ok=True)
                output_path = self.output_dir / output_name

                total_secs = total * (pl.target_duration or 6)
                if is_cmaf:
                    init_data = next(iter(init_data_map.values()), b"")
                    async for pct in self._merge_cmaf(
                        tmpdir_path, total, init_data, seg_ext, output_path,
                        audio_tmpdir=audio_tmpdir,
                        audio_total=total_audio,
                        total_secs=total_secs,
                    ):
                        yield {"status": "merging", "progress": pct}
                else:
                    async for pct in self._merge(tmpdir_path, total, output_path, total_secs=total_secs):
                        yield {"status": "merging", "progress": pct}

                size = output_path.stat().st_size if output_path.exists() else 0
                yield {
                    "status": "completed",
                    "progress": 100,
                    "output": output_name,
                    "size": size,
                    "duration_sec": round(time.time() - start_time, 1),
                }

        except Exception as e:
            yield {"status": "failed", "error": str(e)}
        finally:
            pass  # cache dir is kept for preview and resume; caller cleans up

    def _pick_quality(self, pl) -> str:
        streams = sorted(
            pl.playlists, key=lambda p: p.stream_info.bandwidth, reverse=True
        )
        if not streams:
            return self.url
        if self.quality == "best":
            chosen = streams[0]
        elif self.quality == "worst":
            chosen = streams[-1]
        elif str(self.quality).isdigit():
            idx = int(self.quality)
            chosen = streams[min(idx, len(streams) - 1)]
        else:
            chosen = streams[0]
        return self._resolve(chosen.uri, self.url)

    def _find_audio_playlist(self, master_pl) -> Optional[str]:
        """Return the URI of the default audio rendition, or None.

        CMAF streams with demuxed audio have #EXT-X-MEDIA TYPE=AUDIO entries
        in the master playlist.  The video streams reference them via AUDIO=<group-id>.
        We pick the DEFAULT=YES (or first available) audio rendition URI.
        """
        # Collect audio group IDs referenced by any video stream
        audio_groups: set = set()
        for variant in master_pl.playlists:
            ag = getattr(variant.stream_info, "audio", None)
            if ag:
                audio_groups.add(ag)

        if not audio_groups:
            return None

        # Prefer DEFAULT=YES audio rendition
        for media in master_pl.media:
            if (
                getattr(media, "type", None) == "AUDIO"
                and media.group_id in audio_groups
                and getattr(media, "uri", None)
                and str(getattr(media, "default", "") or "").upper() == "YES"
            ):
                return self._resolve(media.uri, self.url)

        # Fallback: first audio rendition with a URI in a matching group
        for media in master_pl.media:
            if (
                getattr(media, "type", None) == "AUDIO"
                and media.group_id in audio_groups
                and getattr(media, "uri", None)
            ):
                return self._resolve(media.uri, self.url)

        return None

    def _detect_cmaf(self, segments) -> bool:
        """Return True if segments are CMAF/fMP4 (not MPEG-TS)."""
        if not segments:
            return False
        # EXT-X-MAP init section is definitive proof of fMP4
        if any(getattr(seg, "init_section", None) for seg in segments):
            return True
        # Fallback: check first segment URI extension
        uri = segments[0].uri.lower().split("?")[0]
        return uri.endswith((".m4s", ".cmfv", ".cmfa", ".mp4"))

    def _decrypt_aes128(self, data: bytes, key: bytes, iv_str: Optional[str]) -> bytes:
        from Crypto.Cipher import AES

        if iv_str:
            iv = bytes.fromhex(re.sub(r"^0[xX]", "", iv_str))
        else:
            iv = b"\x00" * 16
        cipher = AES.new(key[:16], AES.MODE_CBC, iv)
        return cipher.decrypt(data)

    async def _merge(self, tmpdir: Path, total: int, output_path: Path, total_secs: float = 0):
        """Async generator: merge MPEG-TS segments via ffmpeg, yielding progress (0–98)."""
        loop = asyncio.get_event_loop()
        list_file = tmpdir / "concat.txt"

        def _write_concat():
            with open(list_file, "w") as f:
                for i in range(total):
                    seg = tmpdir / f"seg_{i:06d}.ts"
                    if seg.exists():
                        f.write(f"file '{seg.absolute()}'\n")

        await loop.run_in_executor(None, _write_concat)

        cmd = [
            "ffmpeg", "-y",
            "-f", "concat", "-safe", "0",
            "-i", str(list_file),
            "-c", "copy",
            "-movflags", "+faststart",
            str(output_path),
        ]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        stderr_lines = []
        async for raw_line in proc.stderr:
            line = raw_line.decode(errors="replace")
            stderr_lines.append(line)
            if total_secs > 0:
                m = re.search(r"time=(\d+):(\d+):([\d.]+)", line)
                if m:
                    done = int(m[1]) * 3600 + int(m[2]) * 60 + float(m[3])
                    yield min(98, int(done / total_secs * 100))
        await proc.wait()
        if proc.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: {''.join(stderr_lines)[-500:]}")

    async def _merge_cmaf(
        self,
        tmpdir: Path,
        total: int,
        init_data: bytes,
        seg_ext: str,
        output_path: Path,
        audio_tmpdir: Optional[Path] = None,
        audio_total: int = 0,
        total_secs: float = 0,
    ):
        """
        Async generator: CMAF/fMP4 merge strategy, yielding progress (0–98).

          1. Binary-concatenate init + fragments in a thread pool so the event
             loop stays responsive for other API requests.
          2. Re-mux with ffmpeg; parse stderr for real-time progress updates.
        """
        loop = asyncio.get_event_loop()
        raw_path = tmpdir / "merged_raw.mp4"

        def _concat_video():
            with open(raw_path, "wb") as f:
                if init_data:
                    f.write(init_data)
                for i in range(total):
                    seg = tmpdir / f"seg_{i:06d}{seg_ext}"
                    if seg.exists():
                        f.write(seg.read_bytes())

        await loop.run_in_executor(None, _concat_video)

        has_audio = audio_tmpdir is not None and audio_total > 0
        if has_audio:
            audio_init_disk = audio_tmpdir / "init.mp4"
            raw_audio_path = audio_tmpdir / "merged_audio.mp4"

            def _concat_audio():
                with open(raw_audio_path, "wb") as f:
                    if audio_init_disk.exists():
                        f.write(audio_init_disk.read_bytes())
                    for i in range(audio_total):
                        seg = audio_tmpdir / f"seg_{i:06d}{seg_ext}"
                        if seg.exists():
                            f.write(seg.read_bytes())

            await loop.run_in_executor(None, _concat_audio)
            cmd = [
                "ffmpeg", "-y",
                "-i", str(raw_path),
                "-i", str(raw_audio_path),
                "-map", "0:v",
                "-map", "1:a",
                "-c", "copy",
                "-movflags", "+faststart",
                str(output_path),
            ]
        else:
            cmd = [
                "ffmpeg", "-y",
                "-i", str(raw_path),
                "-c", "copy",
                "-movflags", "+faststart",
                str(output_path),
            ]

        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        stderr_lines = []
        async for raw_line in proc.stderr:
            line = raw_line.decode(errors="replace")
            stderr_lines.append(line)
            if total_secs > 0:
                m = re.search(r"time=(\d+):(\d+):([\d.]+)", line)
                if m:
                    done = int(m[1]) * 3600 + int(m[2]) * 60 + float(m[3])
                    yield min(98, int(done / total_secs * 100))
        await proc.wait()
        if proc.returncode != 0:
            raise RuntimeError(f"ffmpeg re-mux failed: {''.join(stderr_lines)[-500:]}")
