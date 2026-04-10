use std::path::Path;

use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};

use crate::handlers::tasks::cleanup_tmpdir;
use crate::state::AppState;
use crate::types::{ClipRequest, LocalMergeCompleteRequest};

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
    let task = {
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

    if task.status == "completed" {
        let output = match &task.output {
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
        let status = tokio::process::Command::new("ffmpeg")
            .args([
                "-y",
                "-ss",
                &body.start.to_string(),
                "-i",
                &input_path.to_string_lossy(),
                "-t",
                &duration.to_string(),
                "-c",
                "copy",
                clip_path.to_str().unwrap_or(""),
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .await;
        return match status {
            Ok(s) if s.success() => {
                Json(serde_json::json!({"filename": clip_name})).into_response()
            }
            Ok(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"detail": "ffmpeg clip failed"})),
            )
                .into_response(),
            Err(e) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"detail": format!("ffmpeg not found: {e}")})),
            )
                .into_response(),
        };
    }

    let tmpdir = match task.tmpdir.as_deref().filter(|d| Path::new(d).exists()) {
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
        task.status.as_str(),
        "downloading" | "recording" | "stopping" | "merging"
    ) {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"detail":"Task cannot be clipped in its current state"})),
        )
            .into_response();
    }
    let stem = task
        .output_name
        .as_deref()
        .unwrap_or(&task_id[..8.min(task_id.len())])
        .trim_end_matches(".mp4")
        .to_string();
    let clip_name = format!("{stem}_clip_{suffix}.mp4");
    let is_cmaf = task.is_cmaf.unwrap_or(false);
    let seg_ext = task
        .seg_ext
        .as_deref()
        .unwrap_or(".ts")
        .trim_start_matches('.')
        .to_string();

    let clip_path = downloads_dir.join(&clip_name);
    let clip_path_str = clip_path.to_string_lossy().to_string();

    let child = if is_cmaf {
        let mut seg_files: Vec<_> = std::fs::read_dir(&tmpdir)
            .into_iter()
            .flatten()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some(&seg_ext))
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
        tokio::process::Command::new("ffmpeg")
            .args([
                "-y",
                "-ss",
                &body.start.to_string(),
                "-i",
                &raw_path.to_string_lossy(),
                "-t",
                &duration.to_string(),
            ])
            .args(["-c", "copy", clip_path_str.as_str()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
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
        let _ = tokio::fs::write(&list_file, list_content).await;
        tokio::process::Command::new("ffmpeg")
            .args([
                "-y",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                &list_file.to_string_lossy(),
                "-ss",
                &body.start.to_string(),
                "-t",
                &duration.to_string(),
            ])
            .args(["-c", "copy", clip_path_str.as_str()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
    };
    match child {
        Ok(mut proc) => match proc.wait().await {
            Ok(s) if s.success() => {
                Json(serde_json::json!({"filename": clip_name})).into_response()
            }
            Ok(_) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"detail": "ffmpeg clip failed"})),
            )
                .into_response(),
            Err(e) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"detail": format!("{e}")})),
            )
                .into_response(),
        },
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"detail": format!("ffmpeg not found: {e}")})),
        )
            .into_response(),
    }
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
