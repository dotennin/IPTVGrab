use serde_json::json;
use uuid::Uuid;

#[tokio::test]
async fn clip_interrupted_allows_clip_when_segments_exist() {
    let tmpdir = std::env::temp_dir()
        .join(format!("m3u8-server-test-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&tmpdir).unwrap();

    let segdir = tmpdir.join("segments");
    std::fs::create_dir_all(&segdir).unwrap();
    std::fs::write(segdir.join("seg1.ts"), b"dummy").unwrap();
    std::fs::write(segdir.join("seg2.ts"), b"dummy").unwrap();

    let task_id = Uuid::new_v4().to_string();
    let task = json!({
        "id": task_id.clone(),
        "url": "https://example.com/stream.m3u8",
        "status": "interrupted",
        "progress": 0,
        "total": 0,
        "downloaded": 0,
        "failed": 0,
        "speed_mbps": 0.0,
        "bytes_downloaded": 0,
        "output": serde_json::Value::Null,
        "size": 0,
        "error": serde_json::Value::Null,
        "created_at": 1700000000.0,
        "req_headers": serde_json::Map::new(),
        "output_name": serde_json::Value::Null,
        "quality": "best",
        "concurrency": 8,
        "tmpdir": segdir.to_string_lossy().to_string(),
        "is_cmaf": serde_json::Value::Null,
        "seg_ext": serde_json::Value::Null,
        "target_duration": serde_json::Value::Null,
        "duration_sec": serde_json::Value::Null,
        "recorded_segments": serde_json::Value::Null,
        "elapsed_sec": serde_json::Value::Null,
        "task_type": serde_json::Value::Null
    });

    let mut map = serde_json::Map::new();
    map.insert(task_id.clone(), task);

    std::fs::write(tmpdir.join("tasks.json"), serde_json::to_string_pretty(&map).unwrap()).unwrap();

    let server = server::start_embedded_server(server::EmbeddedServerConfig::local_device(tmpdir.clone()))
        .await
        .unwrap();

    let client = reqwest::Client::new();
    let res = client
        .post(format!("{}/api/tasks/{}/clip", server.base_url(), task_id))
        .json(&json!({"start": 0.5, "end": 1.5}))
        .send()
        .await
        .unwrap();

    assert!(res.status().is_success());
    let body = res.json::<serde_json::Value>().await.unwrap();
    assert!(body["clip_task_id"].is_string());
    assert!(body["filename"].is_string());

    server.stop().await.unwrap();
    let _ = std::fs::remove_dir_all(&tmpdir);
}
