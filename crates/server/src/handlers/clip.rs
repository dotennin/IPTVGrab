use std::collections::HashMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use uuid::Uuid;

use crate::handlers::tasks::cleanup_tmpdir;
use crate::state::AppState;
use crate::types::{ClipRequest, LocalMergeCompleteRequest, Task};

fn fmt_hms(secs: f64) -> String {
    let total = secs as u64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    if h > 0 {
        format!("{h:02}h{m:02}m{s:02}s")
    } else {
        format!("{m:02}m{s:02}s")
    }
}

fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

/// Broadcast the current state of `task_id` to all WebSocket subscribers.
async fn broadcast_task(state: &AppState, task_id: &str) {
    let json = {
        let tasks = state.tasks.read().await;
        tasks.get(task_id).and_then(|t| serde_json::to_string(t).ok())
    };
    if let Some(j) = json {
        let subs = state.ws_subs.lock().await;
        if let Some(list) = subs.get(task_id) {
            for sender in list {
                let _ = sender.try_send(j.clone());
            }
        }
    }
}

pub(crate) async fn clip_task(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
    Json(body): Json<ClipRequest>,
) -> impl IntoResponse {
    if body.start < 0.0 || body.end <= body.start || (body.end - body.start) < 0.5 {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Invalid clip range (end must be ≥ start + 0.5 s)"})),
        )
            .into_response();
    }
    let source_task = {
        let tasks = state.tasks.read().await;
        match tasks.get(&task_id).cloned() {
            None => {
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({"detail":"Not found"})),
                )
                    .into_response()
            }
            Some(t) => t,
        }
    };
    let duration = body.end - body.start;
    let suffix = format!("{}-{}", fmt_hms(body.start), fmt_hms(body.end));

    let downloads_dir =
        std::fs::canonicalize(&state.downloads_dir).unwrap_or_else(|_| state.downloads_dir.clone());

    // ── Build the ffmpeg command (must happen synchronously so we can capture
    //    tmpdir contents before they change) ─────────────────────────────────
    let (clip_name, ffmpeg_args): (String, Vec<String>) = if source_task.status == "completed" {
        let output = match &source_task.output {
            Some(o) => o.clone(),
            None => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail":"No output file"})),
                )
                    .into_response()
            }
        };
        let input_path = downloads_dir.join(&output);
        if !input_path.exists() {
            return (
                StatusCode::NOT_FOUND,
                Json(serde_json::json!({"detail":"Output file not found"})),
            )
                .into_response();
        }
        let stem = Path::new(&output)
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let clip_name = format!("{stem}_clip_{suffix}.mp4");
        let clip_path = downloads_dir.join(&clip_name);
        let args = vec![
            "-y".into(),
            "-ss".into(), body.start.to_string(),
            "-i".into(), input_path.to_string_lossy().to_string(),
            "-t".into(), duration.to_string(),
            "-map".into(), "0".into(),
            "-avoid_negative_ts".into(), "make_zero".into(),
            "-c".into(), "copy".into(),
            clip_path.to_string_lossy().to_string(),
        ];
        (clip_name, args)
    } else {
        // In-progress task (downloading / recording / stopping / merging)
        let tmpdir = match source_task.tmpdir.as_deref().filter(|d| Path::new(d).exists()) {
            Some(d) => std::path::PathBuf::from(d),
            None => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"detail":"Task cannot be clipped in its current state"})),
                )
                    .into_response()
            }
        };
        if !matches!(
            source_task.status.as_str(),
            "downloading" | "recording" | "stopping" | "merging" | "interrupted"
        ) {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"detail":"Task cannot be clipped in its current state"})),
            )
                .into_response();
        }
        let stem = source_task
            .output_name
            .as_deref()
            .unwrap_or(&task_id[..8.min(task_id.len())])
            .trim_end_matches(".mp4")
            .to_string();
        let clip_name = format!("{stem}_clip_{suffix}.mp4");
        let is_cmaf = source_task.is_cmaf.unwrap_or(false);
        let seg_ext = source_task
            .seg_ext
            .as_deref()
            .unwrap_or(".ts")
            .trim_start_matches('.')
            .to_string();
        let clip_path = downloads_dir.join(&clip_name);
        let clip_path_str = clip_path.to_string_lossy().to_string();

        let args = if is_cmaf {
            let mut seg_files: Vec<_> = std::fs::read_dir(&tmpdir)
                .into_iter()
                .flatten()
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().and_then(|e| e.to_str()) == Some(&seg_ext as &str))
                .collect();
            seg_files.sort();
            if seg_files.is_empty() {
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({"detail":"No segments available yet"})),
                )
                    .into_response();
            }
            let raw_path = tmpdir.join("clip_raw.mp4");
            let init_file = tmpdir.join("init.mp4");
            if let Ok(mut f) = std::fs::File::create(&raw_path) {
                use std::io::Write;
                if init_file.exists() {
                    let _ = f.write_all(&std::fs::read(&init_file).unwrap_or_default());
                }
                for sf in &seg_files {
                    let _ = f.write_all(&std::fs::read(sf).unwrap_or_default());
                }
            }

            // Check for separate audio rendition in tmpdir/audio/
            let audio_dir = tmpdir.join("audio");
            let raw_audio_path: Option<std::path::PathBuf> = if audio_dir.is_dir() {
                let mut audio_segs: Vec<_> = std::fs::read_dir(&audio_dir)
                    .into_iter()
                    .flatten()
                    .filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| p.extension().and_then(|e| e.to_str()) == Some(&seg_ext as &str))
                    .collect();
                audio_segs.sort();
                if !audio_segs.is_empty() {
                    let p = tmpdir.join("clip_raw_audio.mp4");
                    if let Ok(mut f) = std::fs::File::create(&p) {
                        use std::io::Write;
                        let audio_init = audio_dir.join("init.mp4");
                        if audio_init.exists() {
                            let _ = f.write_all(&std::fs::read(&audio_init).unwrap_or_default());
                        }
                        for sf in &audio_segs {
                            let _ = f.write_all(&std::fs::read(sf).unwrap_or_default());
                        }
                    }
                    Some(p)
                } else {
                    None
                }
            } else {
                None
            };

            let mut args: Vec<String> = vec![
                "-y".into(),
                "-ss".into(), body.start.to_string(),
                "-i".into(), raw_path.to_string_lossy().to_string(),
            ];
            if let Some(ref ap) = raw_audio_path {
                args.extend([
                    "-i".into(), ap.to_string_lossy().to_string(),
                    "-map".into(), "0:v".into(),
                    "-map".into(), "1:a".into(),
                ]);
            } else {
                args.extend(["-map".into(), "0".into()]);
            }
            args.extend([
                "-t".into(), duration.to_string(),
                "-avoid_negative_ts".into(), "make_zero".into(),
                "-c".into(), "copy".into(),
                clip_path_str,
            ]);
            args
        } else {
            let mut seg_files: Vec<_> = std::fs::read_dir(&tmpdir)
                .into_iter()
                .flatten()
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("ts"))
                .collect();
            seg_files.sort();
            if seg_files.is_empty() {
                return (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({"detail":"No segments available yet"})),
                )
                    .into_response();
            }
            let list_file = tmpdir.join("clip_concat.txt");
            let list_content: String = seg_files
                .iter()
                .map(|p| {
                    let abs = std::fs::canonicalize(p).unwrap_or_else(|_| p.clone());
                    format!("file '{}'\n", abs.display())
                })
                .collect();
            let _ = std::fs::write(&list_file, &list_content);

            // Check for separate audio rendition in tmpdir/audio/
            let audio_dir = tmpdir.join("audio");
            let audio_list_file: Option<std::path::PathBuf> = if audio_dir.is_dir() {
                let mut audio_segs: Vec<_> = std::fs::read_dir(&audio_dir)
                    .into_iter()
                    .flatten()
                    .filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("ts"))
                    .collect();
                audio_segs.sort();
                if !audio_segs.is_empty() {
                    let lf = tmpdir.join("clip_audio_concat.txt");
                    let lc: String = audio_segs
                        .iter()
                        .map(|p| {
                            let abs = std::fs::canonicalize(p).unwrap_or_else(|_| p.clone());
                            format!("file '{}'\n", abs.display())
                        })
                        .collect();
                    let _ = std::fs::write(&lf, &lc);
                    Some(lf)
                } else {
                    None
                }
            } else {
                None
            };

            let mut args: Vec<String> = vec![
                "-y".into(),
                "-f".into(), "concat".into(),
                "-safe".into(), "0".into(),
                "-i".into(), list_file.to_string_lossy().to_string(),
            ];
            if let Some(ref alf) = audio_list_file {
                args.extend([
                    "-f".into(), "concat".into(),
                    "-safe".into(), "0".into(),
                    "-i".into(), alf.to_string_lossy().to_string(),
                ]);
            }
            args.extend([
                "-ss".into(), body.start.to_string(),
                "-t".into(), duration.to_string(),
            ]);
            if audio_list_file.is_some() {
                args.extend(["-map".into(), "0:v".into(), "-map".into(), "1:a".into()]);
            } else {
                args.extend(["-map".into(), "0".into()]);
            }
            args.extend([
                "-avoid_negative_ts".into(), "make_zero".into(),
                "-c".into(), "copy".into(),
                clip_path_str,
            ]);
            args
        };
        (clip_name, args)
    };

    // ── Create a clip task entry ─────────────────────────────────────────────
    let clip_task_id = Uuid::new_v4().to_string();
    let clip_label = format!("✂ {clip_name}");
    let clip_task = Task {
        id: clip_task_id.clone(),
        url: clip_label,
        status: "clipping".into(),
        task_type: Some("clip".into()),
        progress: 0,
        total: 0,
        downloaded: 0,
        failed: 0,
        speed_mbps: 0.0,
        bytes_downloaded: 0,
        output: None,
        size: 0,
        error: None,
        created_at: now_secs(),
        req_headers: HashMap::new(),
        output_name: Some(clip_name.clone()),
        quality: String::new(),
        concurrency: 1,
        tmpdir: None,
        is_cmaf: None,
        seg_ext: None,
        target_duration: None,
        duration_sec: Some(duration),
        recorded_segments: None,
        elapsed_sec: None,
    };
    {
        let mut tasks = state.tasks.write().await;
        tasks.insert(clip_task_id.clone(), clip_task);
    }
    state.save_tasks().await;
    broadcast_task(&state, &clip_task_id).await;

    // ── Spawn ffmpeg in background ───────────────────────────────────────────
    let state_bg = state.clone();
    let clip_task_id_bg = clip_task_id.clone();
    let clip_name_bg = clip_name.clone();
    tokio::spawn(async move {
        let result = tokio::process::Command::new("ffmpeg")
            .args(&ffmpeg_args)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await;

        let (new_status, error, size) = match result {
            Ok(s) if s.success() => {
                let sz = ffmpeg_args
                    .last()
                    .and_then(|p| std::fs::metadata(p).ok())
                    .map(|m| m.len())
                    .unwrap_or(0);
                ("completed".to_string(), None, sz)
            }
            Ok(s) => (
                "failed".to_string(),
                Some(format!("ffmpeg exited with code {}", s.code().unwrap_or(-1))),
                0,
            ),
            Err(e) => ("failed".to_string(), Some(format!("ffmpeg not found: {e}")), 0),
        };

        {
            let mut tasks = state_bg.tasks.write().await;
            if let Some(t) = tasks.get_mut(&clip_task_id_bg) {
                t.status = new_status;
                t.progress = 100;
                t.error = error;
                if t.status == "completed" {
                    t.output = Some(clip_name_bg);
                    t.size = size;
                }
            }
        }
        state_bg.save_tasks().await;
        broadcast_task(&state_bg, &clip_task_id_bg).await;
    });

    Json(serde_json::json!({
        "clip_task_id": clip_task_id,
        "filename": clip_name,
    }))
    .into_response()
}

pub(crate) async fn complete_local_merge(
    State(state): State<AppState>,
    AxumPath(task_id): AxumPath<String>,
    Json(body): Json<LocalMergeCompleteRequest>,
) -> impl IntoResponse {
    if body.filename.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Filename is required"})),
        )
            .into_response();
    }

    let output_path = state.downloads_dir.join(&body.filename);
    if !output_path.exists() {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Merged output file not found"})),
        )
            .into_response();
    }

    let mut tasks = state.tasks.write().await;
    let Some(task) = tasks.get_mut(&task_id) else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"detail":"Not found"})),
        )
            .into_response();
    };

    task.status = "completed".into();
    task.progress = 100;
    task.output = Some(body.filename.clone());
    task.size = body.size;
    task.duration_sec = body.duration_sec;
    task.error = None;
    drop(tasks);

    cleanup_tmpdir(&state, &task_id).await;
    state.save_tasks().await;

    Json(serde_json::json!({
        "status": "completed",
        "filename": body.filename,
    }))
    .into_response()
}
