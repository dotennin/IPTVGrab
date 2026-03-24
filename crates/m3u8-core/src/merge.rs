use std::path::Path;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use tokio::process::Command;
use tracing::debug;

use crate::error::DownloadError;

fn map_ffmpeg_spawn_error(error: std::io::Error) -> DownloadError {
    if error.kind() == std::io::ErrorKind::NotFound {
        return DownloadError::Merge(format!("ffmpeg not found: {error}"));
    }
    DownloadError::Merge(format!("Failed to spawn ffmpeg: {error}"))
}

/// Merge MPEG-TS segments into an MP4 using ffmpeg concat demuxer.
/// Yields progress percentage (0–98) via the provided callback.
/// If `cancelled` becomes true while ffmpeg is running, ffmpeg is killed and
/// `DownloadError::Cancelled` is returned.
pub async fn merge_ts<F>(
    tmpdir: &Path,
    total: usize,
    output_path: &Path,
    total_secs: f64,
    mut progress_cb: F,
    cancelled: Arc<AtomicBool>,
) -> Result<(), DownloadError>
where
    F: FnMut(u8),
{
    let list_file = tmpdir.join("concat.txt");
    let mut list_content = String::new();
    for i in 0..total {
        let seg = tmpdir.join(format!("seg_{i:06}.ts"));
        if seg.exists() {
            let seg = std::fs::canonicalize(&seg).unwrap_or(seg);
            list_content.push_str(&format!("file '{}'\n", seg.display()));
        }
    }
    tokio::fs::write(&list_file, list_content).await?;

    let proc = Command::new("ffmpeg")
        .args([
            "-y",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            list_file.to_str().unwrap(),
            "-c",
            "copy",
            "-movflags",
            "+faststart",
            output_path.to_str().unwrap(),
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(map_ffmpeg_spawn_error)?;

    wait_ffmpeg(proc, total_secs, &mut progress_cb, cancelled).await
}

/// Merge CMAF/fMP4 segments: binary concat init+fragments, then re-mux with ffmpeg.
pub async fn merge_cmaf<F>(
    tmpdir: &Path,
    total: usize,
    init_data: &[u8],
    seg_ext: &str,
    output_path: &Path,
    audio_tmpdir: Option<&Path>,
    audio_total: usize,
    total_secs: f64,
    mut progress_cb: F,
    cancelled: Arc<AtomicBool>,
) -> Result<(), DownloadError>
where
    F: FnMut(u8),
{
    // Binary concat video: init + segments
    let raw_video = tmpdir.join("merged_raw.mp4");
    {
        let mut buf = init_data.to_vec();
        for i in 0..total {
            let seg = tmpdir.join(format!("seg_{i:06}{seg_ext}"));
            if seg.exists() {
                buf.extend_from_slice(&tokio::fs::read(&seg).await?);
            }
        }
        tokio::fs::write(&raw_video, &buf).await?;
    }

    let has_audio = audio_tmpdir.is_some() && audio_total > 0;
    let raw_audio = audio_tmpdir.map(|d| d.join("merged_audio.mp4"));

    if let (Some(ref raw_audio_path), Some(audio_dir)) = (&raw_audio, audio_tmpdir) {
        let audio_init = audio_dir.join("init.mp4");
        let mut buf: Vec<u8> = if audio_init.exists() {
            tokio::fs::read(&audio_init).await?
        } else {
            vec![]
        };
        for i in 0..audio_total {
            let seg = audio_dir.join(format!("seg_{i:06}{seg_ext}"));
            if seg.exists() {
                buf.extend_from_slice(&tokio::fs::read(&seg).await?);
            }
        }
        tokio::fs::write(raw_audio_path, &buf).await?;
    }

    let mut cmd = Command::new("ffmpeg");
    cmd.arg("-y").arg("-i").arg(raw_video.to_str().unwrap());

    if has_audio {
        if let Some(ref raw_audio_path) = raw_audio {
            cmd.arg("-i")
                .arg(raw_audio_path.to_str().unwrap())
                .args(["-map", "0:v", "-map", "1:a"]);
        }
    }

    cmd.args(["-c", "copy", "-movflags", "+faststart"])
        .arg(output_path.to_str().unwrap())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped());

    let proc = cmd.spawn().map_err(map_ffmpeg_spawn_error)?;

    wait_ffmpeg(proc, total_secs, &mut progress_cb, cancelled).await
}

async fn wait_ffmpeg<F>(
    mut child: tokio::process::Child,
    total_secs: f64,
    progress_cb: &mut F,
    cancelled: Arc<AtomicBool>,
) -> Result<(), DownloadError>
where
    F: FnMut(u8),
{
    use tokio::io::{AsyncBufReadExt, BufReader};

    let stderr = child.stderr.take().unwrap();
    let mut lines = BufReader::new(stderr).lines();

    let time_re = regex_lite::Regex::new(r"time=(\d+):(\d+):([\d.]+)").unwrap();

    loop {
        // Check cancel flag on each line — kill ffmpeg if cancelled
        if cancelled.load(Ordering::SeqCst) {
            let _ = child.kill().await;
            let _ = child.wait().await;
            return Err(DownloadError::Cancelled);
        }

        match lines.next_line().await.unwrap_or(None) {
            None => break,
            Some(line) => {
                debug!("ffmpeg: {}", line);
                if total_secs > 0.0 {
                    if let Some(caps) = time_re.captures(&line) {
                        let h: f64 = caps[1].parse().unwrap_or(0.0);
                        let m: f64 = caps[2].parse().unwrap_or(0.0);
                        let s: f64 = caps[3].parse().unwrap_or(0.0);
                        let done = h * 3600.0 + m * 60.0 + s;
                        let pct = ((done / total_secs) * 100.0).min(98.0) as u8;
                        progress_cb(pct);
                    }
                }
            }
        }
    }

    // Final cancel check before waiting for exit
    if cancelled.load(Ordering::SeqCst) {
        let _ = child.kill().await;
        let _ = child.wait().await;
        return Err(DownloadError::Cancelled);
    }

    let status = child
        .wait()
        .await
        .map_err(|e| DownloadError::Merge(e.to_string()))?;

    if !status.success() {
        // ffmpeg exits with 254 when it receives SIGTERM — treat as cancellation
        if status.code() == Some(254) && cancelled.load(Ordering::SeqCst) {
            return Err(DownloadError::Cancelled);
        }
        return Err(DownloadError::Merge(format!(
            "ffmpeg exited with code {:?}",
            status.code()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffmpeg_spawn_error_reports_missing_binary_clearly() {
        let error = std::io::Error::new(std::io::ErrorKind::NotFound, "No such file or directory");
        let mapped = map_ffmpeg_spawn_error(error).to_string();

        assert!(mapped.contains("ffmpeg not found"));
        assert!(mapped.contains("No such file or directory"));
    }
}
