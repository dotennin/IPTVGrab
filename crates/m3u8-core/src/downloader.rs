use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use m3u8_rs::{KeyMethod, MediaPlaylist, Playlist};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use tokio::sync::{mpsc, Semaphore};
use tracing::warn;
use uuid::Uuid;

use crate::aes::decrypt_aes128;
use crate::error::DownloadError;
use crate::merge::{merge_cmaf, merge_ts};
use crate::parser::{
    fetch_bytes_retry, fetch_text_retry, find_audio_playlist, is_cmaf, parse_playlist,
    pick_quality, prefetch_keys, resolve,
};
use crate::types::*;

// ── Downloader ────────────────────────────────────────────────────────────────

pub struct Downloader {
    config: DownloadConfig,
    cancelled: Arc<AtomicBool>,
    stop_recording: Arc<AtomicBool>, // stop live + merge (vs cancel which discards)
    paused: Arc<AtomicBool>,         // pause without merging or discarding segments
}

impl Downloader {
    pub fn new(config: DownloadConfig) -> Self {
        Self {
            config,
            cancelled: Arc::new(AtomicBool::new(false)),
            stop_recording: Arc::new(AtomicBool::new(false)),
            paused: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn stop(&self) {
        self.stop_recording.store(true, Ordering::SeqCst);
    }

    /// Pause: stop downloading segments without merging or discarding them.
    pub fn pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
        // Reuse cancelled flag so in-flight segment spawns stop acquiring new work.
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    fn should_stop_live(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst) || self.stop_recording.load(Ordering::SeqCst)
    }

    // ── Build reqwest Client with custom headers ──────────────────────────────

    fn make_client(&self) -> Result<reqwest::Client, DownloadError> {
        let mut headers = HeaderMap::new();
        for (k, v) in &self.config.headers {
            if let (Ok(name), Ok(value)) = (k.parse::<HeaderName>(), HeaderValue::from_str(v)) {
                headers.insert(name, value);
            }
        }
        reqwest::ClientBuilder::new()
            .default_headers(headers)
            .danger_accept_invalid_certs(true)
            .build()
            .map_err(|e| DownloadError::Network(e.to_string()))
    }

    // ── Parse M3U8 metadata (no download) ─────────────────────────────────────

    pub async fn parse(&self) -> Result<StreamInfo, DownloadError> {
        let client = self.make_client()?;
        let content = fetch_text_retry(&client, &self.config.url, self.config.retry).await?;
        let playlist = parse_playlist(&content)?;
        Ok(crate::parser::playlist_to_info(
            &playlist,
            &content,
            &self.config.url,
        ))
    }

    // ── Main download entry point ─────────────────────────────────────────────

    pub async fn download(&self, tx: mpsc::Sender<ProgressEvent>) -> Result<(), DownloadError> {
        let tmpdir = self
            .config
            .output_dir
            .join(".cache")
            .join(&self.config.task_id);
        tokio::fs::create_dir_all(&tmpdir).await?;

        let result = self.run_download(&tx, &tmpdir).await;

        // tmpdir is kept for preview/resume — caller is responsible for cleanup
        match result {
            Ok(_) => Ok(()),
            Err(DownloadError::Paused) => {
                let _ = tx.send(ProgressEvent::Paused).await;
                Err(DownloadError::Paused)
            }
            Err(DownloadError::Cancelled) => {
                let _ = tx.send(ProgressEvent::Cancelled).await;
                Err(DownloadError::Cancelled)
            }
            Err(e) => {
                let _ = tx
                    .send(ProgressEvent::Failed {
                        error: e.to_string(),
                    })
                    .await;
                Err(e)
            }
        }
    }

    async fn run_download(
        &self,
        tx: &mpsc::Sender<ProgressEvent>,
        tmpdir: &Path,
    ) -> Result<(), DownloadError> {
        let client = self.make_client()?;
        let content = fetch_text_retry(&client, &self.config.url, self.config.retry).await?;
        let top_playlist = parse_playlist(&content)?;

        // If master, pick quality variant
        let (media_playlist, base_url) = match &top_playlist {
            Playlist::MasterPlaylist(master) => {
                let chosen_url =
                    pick_quality(master, &content, &self.config.quality, &self.config.url);
                let media_content =
                    fetch_text_retry(&client, &chosen_url, self.config.retry).await?;
                let media_pl = match parse_playlist(&media_content)? {
                    Playlist::MediaPlaylist(m) => m,
                    _ => return Err(DownloadError::Parse("Expected media playlist".into())),
                };
                (media_pl, chosen_url)
            }
            Playlist::MediaPlaylist(m) => (m.clone(), self.config.url.clone()),
        };

        let cmaf = is_cmaf(&media_playlist);
        let seg_ext = if cmaf { ".m4s" } else { ".ts" };
        let target_dur = media_playlist.target_duration as f64;
        let is_live = !media_playlist.end_list;

        // Find audio rendition from master (if applicable)
        let audio_url: Option<String> = if let Playlist::MasterPlaylist(master) = &top_playlist {
            find_audio_playlist(master, &content, &base_url, &self.config.url)
        } else {
            None
        };

        // Pre-fetch AES keys
        let mut keys_cache: HashMap<String, Vec<u8>> = prefetch_keys(
            &client,
            &media_playlist.segments,
            &base_url,
            self.config.retry,
        )
        .await;

        // Download CMAF init segment
        let init_data = self
            .fetch_init_segment(&client, &media_playlist, &base_url, tmpdir, cmaf)
            .await?;

        // Setup audio directory
        let audio_tmpdir: Option<PathBuf> = if cmaf && audio_url.is_some() {
            let d = tmpdir.join("audio");
            tokio::fs::create_dir_all(&d).await?;
            Some(d)
        } else {
            None
        };

        let start = Instant::now();

        if is_live {
            self.download_live(
                &client,
                &tx,
                tmpdir,
                &audio_tmpdir,
                audio_url.as_deref(),
                media_playlist,
                &base_url,
                cmaf,
                seg_ext,
                target_dur,
                &mut keys_cache,
                init_data,
                start,
            )
            .await?;
        } else {
            // Fetch initial audio playlist for VOD
            let audio_vod_pl =
                if let (Some(ref audio_dir), Some(ref aurl)) = (&audio_tmpdir, &audio_url) {
                    self.fetch_audio_init(&client, aurl, audio_dir, &base_url)
                        .await
                        .ok()
                } else {
                    None
                };

            self.download_vod(
                &client,
                &tx,
                tmpdir,
                &audio_tmpdir,
                audio_vod_pl.as_ref(),
                audio_url.as_deref(),
                &media_playlist,
                &base_url,
                cmaf,
                seg_ext,
                target_dur,
                &mut keys_cache,
                init_data.clone(),
                start,
            )
            .await?;
        }

        Ok(())
    }

    // ── VOD Download ──────────────────────────────────────────────────────────

    async fn download_vod(
        &self,
        client: &reqwest::Client,
        tx: &mpsc::Sender<ProgressEvent>,
        tmpdir: &Path,
        audio_tmpdir: &Option<PathBuf>,
        audio_pl: Option<&m3u8_rs::MediaPlaylist>,
        audio_url: Option<&str>,
        media_pl: &MediaPlaylist,
        base_url: &str,
        cmaf: bool,
        seg_ext: &str,
        target_dur: f64,
        keys_cache: &mut HashMap<String, Vec<u8>>,
        init_data: Vec<u8>,
        start: Instant,
    ) -> Result<(), DownloadError> {
        let segments = &media_pl.segments;
        let total = segments.len();

        let semaphore = Arc::new(Semaphore::new(self.config.concurrency));
        let bytes_dl = Arc::new(AtomicU64::new(0));
        let downloaded = Arc::new(AtomicU64::new(0));
        let failed_count = Arc::new(AtomicU64::new(0));
        let cancelled = self.cancelled.clone();

        // Check for already-downloaded segments (resume) — must happen before
        // emitting the initial progress event so the UI shows correct totals.
        for i in 0..total {
            let seg_path = tmpdir.join(format!("seg_{i:06}{seg_ext}"));
            if seg_path.exists() {
                let sz = tokio::fs::metadata(&seg_path)
                    .await
                    .map(|m| m.len())
                    .unwrap_or(0);
                if sz > 0 {
                    bytes_dl.fetch_add(sz, Ordering::Relaxed);
                    downloaded.fetch_add(1, Ordering::Relaxed);
                }
            }
        }

        let base_dl = downloaded.load(Ordering::Relaxed) as usize;
        let base_bytes = bytes_dl.load(Ordering::Relaxed);
        let base_progress = if total > 0 {
            ((base_dl as f64 / total as f64) * 100.0) as u8
        } else {
            0
        };
        let _ = tx
            .send(ProgressEvent::Downloading {
                total,
                downloaded: base_dl,
                failed: 0,
                progress: base_progress,
                speed_mbps: 0.0,
                bytes_downloaded: base_bytes,
                tmpdir: tmpdir.to_string_lossy().to_string(),
                is_cmaf: cmaf,
                seg_ext: seg_ext.to_string(),
                target_duration: target_dur,
            })
            .await;

        // Spawn all segment download tasks
        let mut handles = Vec::with_capacity(total);
        for (i, seg) in segments.iter().enumerate() {
            let seg_path = tmpdir.join(format!("seg_{i:06}{seg_ext}"));
            let seg_url = resolve(&seg.uri, base_url);
            let key_info = seg.key.clone();
            let keys_clone: HashMap<String, Vec<u8>> = keys_cache.clone();
            let base_url_owned = base_url.to_string();
            let client_clone = client.clone();
            let sem = semaphore.clone();
            let bytes_ref = bytes_dl.clone();
            let dl_ref = downloaded.clone();
            let fail_ref = failed_count.clone();
            let cancel_ref = cancelled.clone();
            let retry = self.config.retry;

            handles.push(tokio::spawn(async move {
                if cancel_ref.load(Ordering::SeqCst) {
                    return;
                }
                // Resume: skip existing
                if seg_path.exists() {
                    let sz = tokio::fs::metadata(&seg_path)
                        .await
                        .map(|m| m.len())
                        .unwrap_or(0);
                    if sz > 0 {
                        return; // already counted above
                    }
                }
                let _permit = sem.acquire().await.unwrap();
                match fetch_bytes_retry(&client_clone, &seg_url, retry).await {
                    Ok(mut data) => {
                        // AES-128 decrypt if needed
                        if let Some(key) = &key_info {
                            if key.method == KeyMethod::AES128 {
                                if let Some(key_uri) = &key.uri {
                                    let ku = resolve(key_uri, &base_url_owned);
                                    if let Some(key_bytes) = keys_clone.get(&ku) {
                                        match decrypt_aes128(&data, key_bytes, key.iv.as_deref()) {
                                            Ok(dec) => data = dec,
                                            Err(e) => {
                                                warn!("AES decrypt failed for {seg_url}: {e}");
                                                fail_ref.fetch_add(1, Ordering::Relaxed);
                                                return;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        let len = data.len() as u64;
                        if let Err(e) = write_atomic(&seg_path, &data).await {
                            warn!("Write failed for {seg_url}: {e}");
                            fail_ref.fetch_add(1, Ordering::Relaxed);
                        } else {
                            bytes_ref.fetch_add(len, Ordering::Relaxed);
                            dl_ref.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                    Err(e) => {
                        warn!("Download failed for {seg_url}: {e}");
                        fail_ref.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }));
        }

        // Audio VOD tasks
        let audio_total = audio_pl.map(|pl| pl.segments.len()).unwrap_or(0);
        let mut audio_handles = Vec::with_capacity(audio_total);
        if let (Some(ref audio_dir), Some(apl)) = (audio_tmpdir, audio_pl) {
            for (i, seg) in apl.segments.iter().enumerate() {
                let seg_path = audio_dir.join(format!("seg_{i:06}{seg_ext}"));
                let seg_url = resolve(&seg.uri, audio_url.unwrap_or(base_url));
                let client_clone = client.clone();
                let sem = semaphore.clone();
                let bytes_ref = bytes_dl.clone();
                let cancel_ref = cancelled.clone();
                let retry = self.config.retry;

                audio_handles.push(tokio::spawn(async move {
                    if cancel_ref.load(Ordering::SeqCst) {
                        return;
                    }
                    if seg_path.exists()
                        && tokio::fs::metadata(&seg_path)
                            .await
                            .map(|m| m.len())
                            .unwrap_or(0)
                            > 0
                    {
                        return;
                    }
                    let _permit = sem.acquire().await.unwrap();
                    if let Ok(data) = fetch_bytes_retry(&client_clone, &seg_url, retry).await {
                        let len = data.len() as u64;
                        if write_atomic(&seg_path, &data).await.is_ok() {
                            bytes_ref.fetch_add(len, Ordering::Relaxed);
                        }
                    }
                }));
            }
        }

        // Progress-reporting loop
        loop {
            let done = downloaded.load(Ordering::Relaxed) as usize;
            let failed = failed_count.load(Ordering::Relaxed) as usize;
            let bytes = bytes_dl.load(Ordering::Relaxed);
            let elapsed = start.elapsed().as_secs_f64();
            // Speed is based on newly downloaded bytes only (excludes resumed base).
            let new_bytes = bytes.saturating_sub(base_bytes);
            let speed = if elapsed > 0.0 {
                new_bytes as f64 / elapsed / 1_048_576.0
            } else {
                0.0
            };
            let progress = if total > 0 {
                ((done as f64 / total as f64) * 100.0) as u8
            } else {
                0
            };

            let _ = tx
                .send(ProgressEvent::Downloading {
                    total,
                    downloaded: done,
                    failed,
                    progress,
                    speed_mbps: (speed * 100.0).round() / 100.0,
                    bytes_downloaded: bytes,
                    tmpdir: tmpdir.to_string_lossy().to_string(),
                    is_cmaf: cmaf,
                    seg_ext: seg_ext.to_string(),
                    target_duration: target_dur,
                })
                .await;

            if (done + failed >= total) || self.is_cancelled() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        }

        // Await all handles
        for h in handles {
            let _ = h.await;
        }
        for h in audio_handles {
            let _ = h.await;
        }

        if self.is_paused() {
            return Err(DownloadError::Paused);
        }

        if self.is_cancelled() {
            let _ = tx.send(ProgressEvent::Cancelled).await;
            return Err(DownloadError::Cancelled);
        }

        let failed = failed_count.load(Ordering::Relaxed) as usize;
        let max_failures = (total / 10).max(1);
        if failed > max_failures {
            return Err(DownloadError::Other(format!(
                "Too many segments failed ({failed}/{total})"
            )));
        }

        // Merge
        self.merge_phase(
            tx,
            tmpdir,
            audio_tmpdir,
            total,
            audio_total,
            cmaf,
            seg_ext,
            &init_data,
            target_dur,
            start,
        )
        .await
    }

    // ── Live Recording ────────────────────────────────────────────────────────

    async fn download_live(
        &self,
        client: &reqwest::Client,
        tx: &mpsc::Sender<ProgressEvent>,
        tmpdir: &Path,
        audio_tmpdir: &Option<PathBuf>,
        audio_url: Option<&str>,
        mut current_pl: MediaPlaylist,
        base_url: &str,
        cmaf: bool,
        seg_ext: &str,
        target_dur: f64,
        keys_cache: &mut HashMap<String, Vec<u8>>,
        init_data: Vec<u8>,
        start: Instant,
    ) -> Result<(), DownloadError> {
        let semaphore = Arc::new(Semaphore::new(self.config.concurrency));
        let cancelled = self.cancelled.clone();
        let stop_recording = self.stop_recording.clone();

        // Resume: count existing segments and sum their bytes so the progress
        // display continues from where the previous session left off.
        let existing: Vec<_> = {
            let mut v: Vec<_> = tmpdir
                .read_dir()
                .ok()
                .into_iter()
                .flatten()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with("seg_"))
                .collect();
            v.sort_by_key(|e| e.file_name());
            v
        };
        let mut seg_idx: usize = existing.len();
        let base_bytes: u64 = existing
            .iter()
            .map(|e| std::fs::metadata(e.path()).map(|m| m.len()).unwrap_or(0))
            .sum();
        let bytes_dl = Arc::new(AtomicU64::new(base_bytes));

        let mut audio_seg_idx: usize = if let Some(ref ad) = audio_tmpdir {
            ad.read_dir()
                .ok()
                .into_iter()
                .flatten()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with("seg_"))
                .count()
        } else {
            0
        };

        let mut seen_uris: HashSet<String> = HashSet::new();
        let mut audio_seen_uris: HashSet<String> = HashSet::new();
        let mut current_audio_pl: Option<MediaPlaylist> = None;
        if let (Some(audio_dir), Some(aurl)) = (audio_tmpdir.as_ref(), audio_url) {
            if let Ok(audio_pl) = self
                .fetch_audio_init(client, aurl, audio_dir, base_url)
                .await
            {
                current_audio_pl = Some(audio_pl);
            }
        }

        let poll_interval = (current_pl.target_duration as f64 / 2.0).max(1.0);
        let base_elapsed = self.config.base_elapsed_sec;

        let _ = tx
            .send(ProgressEvent::Recording {
                recorded_segments: seg_idx,
                bytes_downloaded: base_bytes,
                speed_mbps: 0.0,
                elapsed_sec: base_elapsed,
                tmpdir: tmpdir.to_string_lossy().to_string(),
                is_cmaf: cmaf,
                seg_ext: seg_ext.to_string(),
                target_duration: target_dur,
            })
            .await;

        loop {
            if self.should_stop_live() {
                break;
            }

            // New video segments this poll
            let new_segs: Vec<_> = current_pl
                .segments
                .iter()
                .filter(|s| !seen_uris.contains(&s.uri))
                .cloned()
                .collect();

            // Pre-fetch AES keys
            let fresh_keys = prefetch_keys(client, &new_segs, base_url, self.config.retry).await;
            keys_cache.extend(fresh_keys);

            let mut batch: Vec<(usize, m3u8_rs::MediaSegment)> = Vec::new();
            for seg in new_segs {
                seen_uris.insert(seg.uri.clone());
                batch.push((seg_idx, seg));
                seg_idx += 1;
            }

            // Download video batch
            if !batch.is_empty() {
                let handles: Vec<_> = batch
                    .into_iter()
                    .map(|(idx, seg)| {
                        let seg_path = tmpdir.join(format!("seg_{idx:06}{seg_ext}"));
                        let seg_url = resolve(&seg.uri, base_url);
                        let key_info = seg.key.clone();
                        let keys_clone = keys_cache.clone();
                        let base_url_owned = base_url.to_string();
                        let client_clone = client.clone();
                        let sem = semaphore.clone();
                        let bytes_ref = bytes_dl.clone();
                        let cancel_ref = cancelled.clone();
                        let stop_ref = stop_recording.clone();
                        let retry = self.config.retry;

                        tokio::spawn(async move {
                            if cancel_ref.load(Ordering::SeqCst) || stop_ref.load(Ordering::SeqCst)
                            {
                                return;
                            }
                            let _permit = sem.acquire().await.unwrap();
                            if let Ok(mut data) =
                                fetch_bytes_retry(&client_clone, &seg_url, retry).await
                            {
                                if let Some(key) = &key_info {
                                    if key.method == KeyMethod::AES128 {
                                        if let Some(ku_raw) = &key.uri {
                                            let ku = resolve(ku_raw, &base_url_owned);
                                            if let Some(kb) = keys_clone.get(&ku) {
                                                if let Ok(dec) =
                                                    decrypt_aes128(&data, kb, key.iv.as_deref())
                                                {
                                                    data = dec;
                                                }
                                            }
                                        }
                                    }
                                }
                                let len = data.len() as u64;
                                if write_atomic(&seg_path, &data).await.is_ok() {
                                    bytes_ref.fetch_add(len, Ordering::Relaxed);
                                }
                            }
                        })
                    })
                    .collect();

                futures::future::join_all(handles).await;
            }

            // Download audio batch
            if let (Some(ref audio_dir), Some(ref apl)) = (audio_tmpdir, &current_audio_pl) {
                let new_audio: Vec<_> = apl
                    .segments
                    .iter()
                    .filter(|s| !audio_seen_uris.contains(&s.uri))
                    .cloned()
                    .collect();
                let audio_base = audio_url.unwrap_or(base_url);
                let mut audio_batch: Vec<(usize, m3u8_rs::MediaSegment)> = Vec::new();
                for seg in new_audio {
                    audio_seen_uris.insert(seg.uri.clone());
                    audio_batch.push((audio_seg_idx, seg));
                    audio_seg_idx += 1;
                }
                if !audio_batch.is_empty() {
                    let handles: Vec<_> = audio_batch
                        .into_iter()
                        .map(|(idx, seg)| {
                            let seg_path = audio_dir.join(format!("seg_{idx:06}{seg_ext}"));
                            let seg_url = resolve(&seg.uri, audio_base);
                            let client_clone = client.clone();
                            let sem = semaphore.clone();
                            let bytes_ref = bytes_dl.clone();
                            let cancel_ref = cancelled.clone();
                            let stop_ref = stop_recording.clone();
                            let retry = self.config.retry;
                            tokio::spawn(async move {
                                if cancel_ref.load(Ordering::SeqCst)
                                    || stop_ref.load(Ordering::SeqCst)
                                {
                                    return;
                                }
                                let _permit = sem.acquire().await.unwrap();
                                if let Ok(data) =
                                    fetch_bytes_retry(&client_clone, &seg_url, retry).await
                                {
                                    let len = data.len() as u64;
                                    if write_atomic(&seg_path, &data).await.is_ok() {
                                        bytes_ref.fetch_add(len, Ordering::Relaxed);
                                    }
                                }
                            })
                        })
                        .collect();
                    futures::future::join_all(handles).await;
                }
            }

            // Emit progress
            let bytes = bytes_dl.load(Ordering::Relaxed);
            let elapsed = start.elapsed().as_secs_f64();
            // Speed based on new bytes only; elapsed is cumulative across resume sessions.
            let new_bytes = bytes.saturating_sub(base_bytes);
            let speed = if elapsed > 0.0 {
                new_bytes as f64 / elapsed / 1_048_576.0
            } else {
                0.0
            };
            let _ = tx
                .send(ProgressEvent::Recording {
                    recorded_segments: seg_idx,
                    bytes_downloaded: bytes,
                    speed_mbps: (speed * 100.0).round() / 100.0,
                    elapsed_sec: base_elapsed + elapsed as u64,
                    tmpdir: tmpdir.to_string_lossy().to_string(),
                    is_cmaf: cmaf,
                    seg_ext: seg_ext.to_string(),
                    target_duration: target_dur,
                })
                .await;

            if current_pl.end_list {
                break;
            }

            // Interruptible poll sleep
            let deadline =
                tokio::time::Instant::now() + std::time::Duration::from_secs_f64(poll_interval);
            loop {
                if self.should_stop_live() {
                    break;
                }
                let now = tokio::time::Instant::now();
                if now >= deadline {
                    break;
                }
                let remaining = deadline - now;
                tokio::time::sleep(remaining.min(std::time::Duration::from_millis(300))).await;
            }

            if self.should_stop_live() {
                break;
            }

            // Re-fetch video playlist
            if let Ok(text) = fetch_text_retry(client, base_url, self.config.retry).await {
                if let Ok(Playlist::MediaPlaylist(pl)) = parse_playlist(&text) {
                    current_pl = pl;
                }
            }

            // Re-fetch audio playlist
            if let (Some(audio_dir), Some(aurl)) = (audio_tmpdir.as_ref(), audio_url) {
                if let Ok(audio_pl) = self
                    .fetch_audio_init(client, aurl, audio_dir, base_url)
                    .await
                {
                    current_audio_pl = Some(audio_pl);
                }
            }
        }

        // Paused = stop without merging or discarding
        if self.is_paused() {
            return Err(DownloadError::Paused);
        }

        // Cancelled without stop = discard
        if self.cancelled.load(Ordering::SeqCst) && !self.stop_recording.load(Ordering::SeqCst) {
            let _ = tx.send(ProgressEvent::Cancelled).await;
            return Err(DownloadError::Cancelled);
        }

        let total = seg_idx;
        let audio_total = audio_seg_idx;
        self.merge_phase(
            tx,
            tmpdir,
            audio_tmpdir,
            total,
            audio_total,
            cmaf,
            seg_ext,
            &init_data,
            target_dur,
            start,
        )
        .await
    }

    // ── Shared merge phase ─────────────────────────────────────────────────────

    async fn merge_phase(
        &self,
        tx: &mpsc::Sender<ProgressEvent>,
        tmpdir: &Path,
        audio_tmpdir: &Option<PathBuf>,
        total: usize,
        audio_total: usize,
        cmaf: bool,
        seg_ext: &str,
        init_data: &[u8],
        target_dur: f64,
        start: Instant,
    ) -> Result<(), DownloadError> {
        let _ = tx.send(ProgressEvent::Merging { progress: 0 }).await;

        let output_name = self
            .config
            .output_name
            .clone()
            .unwrap_or_else(|| format!("video_{}", chrono::Utc::now().timestamp()));
        let output_name = if output_name.ends_with(".mp4") {
            output_name
        } else {
            format!("{output_name}.mp4")
        };
        tokio::fs::create_dir_all(&self.config.output_dir).await?;
        let output_path = self.config.output_dir.join(&output_name);
        let total_secs = total as f64 * target_dur;

        let tx_clone = tx.clone();
        let progress_cb = move |pct: u8| {
            let _ = tx_clone.try_send(ProgressEvent::Merging { progress: pct });
        };

        if cmaf {
            merge_cmaf(
                tmpdir,
                total,
                init_data,
                seg_ext,
                &output_path,
                audio_tmpdir.as_deref(),
                audio_total,
                total_secs,
                progress_cb,
                self.cancelled.clone(),
            )
            .await
        } else {
            merge_ts(
                tmpdir,
                total,
                &output_path,
                total_secs,
                progress_cb,
                self.cancelled.clone(),
            )
            .await
        }
        .map_err(|e| {
            // If paused during merge, surface Paused (not Cancelled).
            if self.is_paused() {
                let tx = tx.clone();
                tokio::spawn(async move {
                    let _ = tx.send(ProgressEvent::Paused).await;
                });
                return DownloadError::Paused;
            }
            // If merge was cancelled, send the Cancelled event so the task transitions cleanly
            if matches!(e, DownloadError::Cancelled) || self.is_cancelled() {
                let tx = tx.clone();
                tokio::spawn(async move {
                    let _ = tx.send(ProgressEvent::Cancelled).await;
                });
                return DownloadError::Cancelled;
            }
            e
        })?;

        let size = tokio::fs::metadata(&output_path)
            .await
            .map(|m| m.len())
            .unwrap_or(0);

        let _ = tx
            .send(ProgressEvent::Completed {
                output: output_name,
                size,
                duration_sec: start.elapsed().as_secs_f64(),
            })
            .await;

        Ok(())
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    async fn fetch_init_segment(
        &self,
        client: &reqwest::Client,
        media_pl: &MediaPlaylist,
        base_url: &str,
        tmpdir: &Path,
        cmaf: bool,
    ) -> Result<Vec<u8>, DownloadError> {
        if !cmaf {
            return Ok(vec![]);
        }
        let init_disk = tmpdir.join("init.mp4");
        for seg in &media_pl.segments {
            if let Some(map) = &seg.map {
                let init_url = resolve(&map.uri, base_url);
                // Reuse cached init if available
                if init_disk.exists()
                    && tokio::fs::metadata(&init_disk)
                        .await
                        .map(|m| m.len())
                        .unwrap_or(0)
                        > 0
                {
                    return Ok(tokio::fs::read(&init_disk).await?);
                }
                let data = fetch_bytes_retry(client, &init_url, self.config.retry).await?;
                write_atomic(&init_disk, &data).await?;
                return Ok(data);
            }
        }
        Ok(vec![])
    }

    async fn fetch_audio_init(
        &self,
        client: &reqwest::Client,
        audio_url: &str,
        audio_dir: &Path,
        _base_url: &str,
    ) -> Result<m3u8_rs::MediaPlaylist, DownloadError> {
        let content = fetch_text_retry(client, audio_url, self.config.retry).await?;
        let apl = match parse_playlist(&content)? {
            Playlist::MediaPlaylist(m) => m,
            _ => {
                return Err(DownloadError::Parse(
                    "Expected media playlist for audio".into(),
                ))
            }
        };
        let init_disk = audio_dir.join("init.mp4");
        if !init_disk.exists()
            || tokio::fs::metadata(&init_disk)
                .await
                .map(|m| m.len())
                .unwrap_or(0)
                == 0
        {
            for seg in &apl.segments {
                if let Some(map) = &seg.map {
                    let url = resolve(&map.uri, audio_url);
                    if let Ok(data) = fetch_bytes_retry(client, &url, self.config.retry).await {
                        let _ = write_atomic(&init_disk, &data).await;
                        break;
                    }
                }
            }
        }
        Ok(apl)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stop_recording_does_not_mark_cancelled() {
        let dl = Downloader::new(DownloadConfig::default());
        dl.stop();

        assert!(!dl.is_cancelled());
        assert!(dl.should_stop_live());
    }

    #[test]
    fn cancel_marks_cancelled() {
        let dl = Downloader::new(DownloadConfig::default());
        dl.cancel();

        assert!(dl.is_cancelled());
        assert!(dl.should_stop_live());
    }
}

// ── Atomic write helper ────────────────────────────────────────────────────────

async fn write_atomic(path: &Path, data: &[u8]) -> Result<(), DownloadError> {
    let tmp = path.with_file_name(format!(
        ".{}.{}.part",
        path.file_name().unwrap_or_default().to_string_lossy(),
        Uuid::new_v4().simple()
    ));
    tokio::fs::write(&tmp, data).await?;
    tokio::fs::rename(&tmp, path).await?;
    Ok(())
}
