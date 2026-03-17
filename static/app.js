/* globals Bootstrap */
"use strict";

// ── State ────────────────────────────────────────────────────────────────────
let currentRequest = { url: "", headers: {} };
let currentStreamInfo = null;
const pollingTimers = {};

// ── Utilities ────────────────────────────────────────────────────────────────
function esc(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatBytes(bytes) {
  if (!bytes) return "0 B";
  const k = 1024;
  const units = ["B", "KB", "MB", "GB"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return (bytes / Math.pow(k, i)).toFixed(1) + " " + units[i];
}

function formatDuration(sec) {
  if (!sec) return "--";
  const m = Math.floor(sec / 60);
  const s = Math.round(sec % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

function toast(msg, type = "success") {
  const id = "t" + Date.now();
  const colors = { success: "bg-success", danger: "bg-danger", info: "bg-primary" };
  const html = `
    <div id="${id}" class="toast align-items-center text-white border-0 ${colors[type] || ""}"
         role="alert" data-bs-delay="3500">
      <div class="d-flex">
        <div class="toast-body">${esc(msg)}</div>
        <button type="button" class="btn-close btn-close-white me-2 m-auto"
                data-bs-dismiss="toast"></button>
      </div>
    </div>`;
  document.getElementById("toastContainer").insertAdjacentHTML("beforeend", html);
  const el = document.getElementById(id);
  new bootstrap.Toast(el).show();
  el.addEventListener("hidden.bs.toast", () => el.remove());
}

// ── Concurrency slider ────────────────────────────────────────────────────────
document.getElementById("concurrency").addEventListener("input", (e) => {
  document.getElementById("concurrencyVal").textContent = e.target.value;
});

// ── Header rows ───────────────────────────────────────────────────────────────
function addHeaderRow(key = "", val = "") {
  const list = document.getElementById("headersList");
  const row = document.createElement("div");
  row.className = "input-group input-group-sm mb-2 header-row";
  row.innerHTML = `
    <input type="text" class="form-control header-key font-mono" placeholder="Header 名称" value="${esc(key)}" />
    <input type="text" class="form-control header-val font-mono" placeholder="值" value="${esc(val)}" />
    <button class="btn btn-outline-danger" type="button" tabindex="-1"
            onclick="this.closest('.header-row').remove()">
      <i class="fas fa-times"></i>
    </button>`;
  list.appendChild(row);
}

document.getElementById("addHeaderBtn").addEventListener("click", () => addHeaderRow());

function collectHeaders() {
  const h = {};
  document.querySelectorAll(".header-row").forEach((row) => {
    const k = row.querySelector(".header-key").value.trim();
    const v = row.querySelector(".header-val").value.trim();
    if (k) h[k] = v;
  });
  return h;
}

function populateHeaders(headers) {
  document.getElementById("headersList").innerHTML = "";
  Object.entries(headers).forEach(([k, v]) => addHeaderRow(k, v));
}

// ── Parse button ──────────────────────────────────────────────────────────────
document.getElementById("parseBtn").addEventListener("click", async () => {
  const btn = document.getElementById("parseBtn");
  const curlActive = document.getElementById("curl-tab").classList.contains("active");

  let url = "";
  let headers = {};
  let curlCommand = "";

  if (curlActive) {
    curlCommand = document.getElementById("curlInput").value.trim();
    if (!curlCommand) {
      toast("请粘贴 cURL 命令", "danger");
      return;
    }
  } else {
    url = document.getElementById("urlInput").value.trim();
    if (!url) {
      toast("请输入 M3U8 URL", "danger");
      return;
    }
    headers = collectHeaders();
  }

  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>解析中...';

  try {
    const res = await fetch("/api/parse", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, headers, curl_command: curlCommand }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "解析失败");

    currentRequest = { url: data.url, headers: data.headers || headers };
    currentStreamInfo = data;

    // Auto-fill URL tab
    document.getElementById("urlInput").value = data.url || "";
    if (data.headers) populateHeaders(data.headers);

    showStreamInfo(data);
    document.getElementById("clearInfoBtn").classList.remove("d-none");
    toast("解析成功", "success");
  } catch (e) {
    toast(e.message, "danger");
    showError(e.message);
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-search me-1"></i>解析流';
  }
});

document.getElementById("clearInfoBtn").addEventListener("click", () => {
  currentStreamInfo = null;
  resetStreamInfo();
  document.getElementById("clearInfoBtn").classList.add("d-none");
});

// ── Stream info panel ─────────────────────────────────────────────────────────
function resetStreamInfo() {
  document.getElementById("streamTypeBadge").innerHTML = "";
  document.getElementById("streamInfoBody").innerHTML = `
    <div class="text-center text-muted py-5" id="streamPlaceholder">
      <i class="fas fa-play-circle fa-3x mb-3 d-block opacity-25"></i>
      <p class="mb-0">解析 M3U8 后在此显示流信息</p>
    </div>`;
}

function showError(msg) {
  document.getElementById("streamInfoBody").innerHTML = `
    <div class="alert alert-danger mb-0">
      <i class="fas fa-exclamation-triangle me-2"></i>${esc(msg)}
    </div>`;
}

function showStreamInfo(info) {
  const badge = document.getElementById("streamTypeBadge");
  const body = document.getElementById("streamInfoBody");

  if (info.type === "master") {
    badge.innerHTML = `<span class="badge bg-info">主播放列表</span>`;
    let html = `<p class="text-muted small mb-3">
      <i class="fas fa-layer-group me-1"></i>包含 ${info.streams.length} 个质量选项，请选择下载画质：
    </p>`;

    info.streams.forEach((s, i) => {
      const checked = i === 0 ? "checked" : "";
      html += `
        <label class="quality-option d-flex align-items-center gap-3 w-100">
          <input type="radio" name="quality" value="${i}" ${checked} class="flex-shrink-0" />
          <div class="flex-grow-1">
            <div class="fw-semibold">${esc(s.label)}</div>
            <div class="text-muted small">
              ${s.resolution ? `${esc(s.resolution)} · ` : ""}
              ${Math.round(s.bandwidth / 1000)} kbps
              ${s.codecs ? ` · ${esc(s.codecs)}` : ""}
            </div>
          </div>
          ${i === 0 ? '<span class="badge bg-success">最高画质</span>' : ""}
        </label>`;
    });

    body.innerHTML = html + downloadButton();
  } else {
    const isLive = info.is_live === true;
    badge.innerHTML = isLive
      ? `<span class="badge bg-danger live-badge"><i class="fas fa-circle me-1" style="font-size:.6em"></i>LIVE</span>`
      : `<span class="badge bg-success">媒体播放列表</span>`;
    body.innerHTML = `
      <dl class="stat-grid mb-3">
        ${isLive
          ? `<dt>直播状态</dt><dd><span class="text-danger fw-semibold">持续录制，直到手动停止</span></dd>`
          : `<dt>片段数量</dt><dd>${info.segments} 个</dd>
             <dt>视频时长</dt><dd>${formatDuration(info.duration)}</dd>`
        }
        <dt>AES 加密</dt>
        <dd>${
          info.encrypted
            ? '<span class="badge bg-warning text-dark">AES-128</span>'
            : '<span class="text-muted">无</span>'
        }</dd>
      </dl>` + downloadButton(isLive);
  }

  body.querySelectorAll(".quality-option").forEach((label) => {
    label.addEventListener("click", () => {
      const radio = label.querySelector("input[type=radio]");
      if (radio) radio.checked = true;
    });
  });

  body.querySelector("#startDownloadBtn")?.addEventListener("click", startDownload);
}

function downloadButton(isLive = false) {
  return isLive
    ? `<div class="mt-3 pt-3 border-top">
         <button class="btn btn-danger px-4" id="startDownloadBtn" type="button">
           <i class="fas fa-circle me-2"></i>开始录制
         </button>
         <span class="ms-3 text-muted small">停止录制后自动合并为 MP4</span>
       </div>`
    : `<div class="mt-3 pt-3 border-top">
         <button class="btn btn-success px-4" id="startDownloadBtn" type="button">
           <i class="fas fa-download me-2"></i>开始下载
         </button>
       </div>`;
}

// ── Start download ────────────────────────────────────────────────────────────
async function startDownload() {
  if (!currentRequest.url) {
    toast("请先解析流", "danger");
    return;
  }

  const outputName = document.getElementById("outputName").value.trim() || null;
  const concurrency = parseInt(document.getElementById("concurrency").value, 10);

  let quality = "best";
  if (currentStreamInfo?.type === "master") {
    const sel = document.querySelector('input[name="quality"]:checked');
    if (sel) quality = sel.value;
  }

  const btn = document.getElementById("startDownloadBtn");
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-2"></i>提交中...';

  try {
    const res = await fetch("/api/download", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        url: currentRequest.url,
        headers: currentRequest.headers,
        output_name: outputName,
        quality,
        concurrency,
      }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Failed to start download");

    addTaskCard(data.task_id, currentRequest.url);
    startPolling(data.task_id);
    toast("下载任务已添加", "info");
  } catch (e) {
    toast(e.message, "danger");
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-download me-2"></i>开始下载';
  }
}

// ── Task cards ────────────────────────────────────────────────────────────────
function updateTaskCount() {
  const n = document.querySelectorAll(".task-card").length;
  document.getElementById("taskCountBadge").textContent = n;
  document.getElementById("tasksPlaceholder").style.display = n ? "none" : "";
}

function addTaskCard(taskId, url) {
  const list = document.getElementById("downloadsList");
  document.getElementById("tasksPlaceholder").style.display = "none";

  const card = document.createElement("div");
  card.className = "task-card";
  card.id = `task-${taskId}`;
  card.innerHTML = `
    <div class="d-flex justify-content-between align-items-start mb-2 gap-2">
      <div class="task-url flex-grow-1">${esc(url)}</div>
      <span class="badge bg-secondary flex-shrink-0 task-status">等待中</span>
    </div>
    <div class="progress mb-2">
      <div class="progress-bar task-bar" role="progressbar" style="width:0%"></div>
    </div>
    <div class="d-flex justify-content-between align-items-center">
      <small class="task-info text-muted">正在准备...</small>
      <div class="d-flex gap-2 align-items-center">
        <button class="btn btn-sm btn-outline-info task-preview d-none" title="预览已下载片段">
          <i class="fas fa-play-circle me-1"></i>预览
        </button>
        <button class="btn btn-sm btn-outline-danger task-action" data-id="${taskId}">
          <i class="fas fa-times"></i> 取消
        </button>
      </div>
    </div>`;

  list.insertBefore(card, list.firstChild);
  card.querySelector(".task-action").addEventListener("click", () => cancelTask(taskId));
  updateTaskCount();
}

const STATUS_MAP = {
  queued:      { text: "等待中",  cls: "bg-secondary" },
  downloading: { text: "下载中",  cls: "bg-primary"   },
  recording:   { text: "录制中",  cls: "bg-danger"    },
  stopping:    { text: "合并中",  cls: "bg-info"      },
  merging:     { text: "合并中",  cls: "bg-info"      },
  completed:   { text: "已完成",  cls: "bg-success"   },
  failed:      { text: "失败",    cls: "bg-danger"    },
  cancelled:   { text: "已取消",  cls: "bg-secondary" },
  interrupted: { text: "已中断",  cls: "bg-warning"   },
};

function updateTaskCard(taskId, task) {
  const card = document.getElementById(`task-${taskId}`);
  if (!card) return;

  const { text, cls } = STATUS_MAP[task.status] || { text: task.status, cls: "bg-secondary" };
  card.querySelector(".task-status").className = `badge ${cls} flex-shrink-0 task-status`;
  card.querySelector(".task-status").textContent = text;

  const bar = card.querySelector(".task-bar");
  if (task.status === "recording") {
    bar.style.width = "100%";
    bar.className = "progress-bar task-bar bg-danger progress-bar-striped progress-bar-animated";
  } else if (task.status === "stopping") {
    bar.style.width = "100%";
    bar.className = "progress-bar task-bar bg-info progress-bar-striped progress-bar-animated";
  } else {
    bar.style.width = `${task.progress || 0}%`;
    bar.className = `progress-bar task-bar${task.status === "failed" ? " bg-danger" : ""}`;
  }

  const info = card.querySelector(".task-info");

  if (task.status === "recording") {
    const elapsed = task.elapsed_sec || 0;
    const mm = String(Math.floor(elapsed / 60)).padStart(2, "0");
    const ss = String(elapsed % 60).padStart(2, "0");
    info.innerHTML = `
      <span class="text-danger fw-semibold">
        <i class="fas fa-circle fa-beat me-1" style="font-size:.6em"></i>${mm}:${ss}
      </span>
      <span class="ms-2">${task.recorded_segments || 0} 片段</span>
      <span class="ms-2">${formatBytes(task.bytes_downloaded)}</span>
      <span class="ms-2 text-muted">${task.speed_mbps || 0} MB/s</span>`;
    info.className = "task-info small";
  } else if (task.status === "downloading") {
    info.innerHTML = `
      <span>${task.downloaded || 0} / ${task.total || 0} 片段</span>
      <span class="ms-2 text-primary">${task.speed_mbps || 0} MB/s</span>
      <span class="ms-2">${formatBytes(task.bytes_downloaded)}</span>`;
    info.className = "task-info small";
  } else if (task.status === "stopping") {
    info.innerHTML = '<i class="fas fa-cog fa-spin me-1"></i>正在合并已录制的片段...';
    info.className = "task-info small text-info";
  } else if (task.status === "merging") {
    info.innerHTML = '<i class="fas fa-cog fa-spin me-1"></i>正在合并视频片段...';
    info.className = "task-info small text-info";
  } else if (task.status === "completed" && task.output) {
    const sizeStr = task.size ? ` (${formatBytes(task.size)})` : "";
    info.innerHTML = `
      <a href="/downloads/${esc(task.output)}" download
         class="btn btn-sm btn-success">
        <i class="fas fa-download me-1"></i>${esc(task.output)}${sizeStr}
      </a>
      ${task.duration_sec ? `<span class="ms-2 text-muted small">耗时 ${task.duration_sec}s</span>` : ""}
      <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="restartTask('${taskId}')">
        <i class="fas fa-redo me-1"></i>重新下载
      </button>`;
  } else if (task.status === "failed") {
    info.innerHTML = `<span class="text-danger">错误: ${esc(task.error || "未知错误")}</span>
      <button class="btn btn-link btn-sm p-0 ms-2 text-warning" onclick="resumeTask('${taskId}')">
        <i class="fas fa-play me-1"></i>断点续传
      </button>
      <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="restartTask('${taskId}')">
        <i class="fas fa-sync me-1"></i>重新下载
      </button>`;
    info.className = "task-info small";
  } else if (task.status === "cancelled") {
    info.innerHTML = `<span class="text-muted">已取消</span>
      <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="restartTask('${taskId}')">
        <i class="fas fa-redo me-1"></i>重新下载
      </button>`;
    info.className = "task-info small";
  } else if (task.status === "interrupted") {
    info.innerHTML = `<span class="text-warning"><i class="fas fa-exclamation-triangle me-1"></i>服务中断</span>
      <button class="btn btn-link btn-sm p-0 ms-2 text-warning" onclick="resumeTask('${taskId}')">
        <i class="fas fa-redo me-1"></i>断点续传
      </button>
      <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="restartTask('${taskId}')">
        <i class="fas fa-sync me-1"></i>重新下载
      </button>`;
    info.className = "task-info small";
  }

  // ── Preview button: show when enough segments are available ──────────────
  const previewBtn = card.querySelector(".task-preview");
  if (previewBtn && task.tmpdir && (task.downloaded >= 5 || task.recorded_segments >= 5)) {
    previewBtn.classList.remove("d-none");
    if (!previewBtn.dataset.listenerAdded) {
      previewBtn.dataset.listenerAdded = "1";
      previewBtn.addEventListener("click", () => openPreview(taskId));
    }
  }

  // ── Action button state ───────────────────────────────────────────────────
  if (task.status === "recording") {
    const btn = card.querySelector(".task-action");
    if (btn && btn.dataset.mode !== "stop") {
      btn.innerHTML = '<i class="fas fa-stop me-1"></i>停止录制';
      btn.className = "btn btn-sm btn-danger task-action";
      btn.dataset.mode = "stop";
    }
  } else if (task.status === "stopping") {
    const btn = card.querySelector(".task-action");
    if (btn) {
      btn.disabled = true;
      btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>合并中';
      btn.className = "btn btn-sm btn-secondary task-action";
    }
  } else if (["completed", "failed", "cancelled", "interrupted"].includes(task.status)) {
    const btn = card.querySelector(".task-action");
    if (btn && btn.dataset.mode !== "trash") {
      btn.innerHTML = '<i class="fas fa-trash"></i>';
      btn.className = "btn btn-sm btn-outline-secondary task-action";
      btn.dataset.mode = "trash";
      btn.disabled = false;
      btn.replaceWith(btn.cloneNode(true));
      card.querySelector(".task-action").addEventListener("click", async () => {
        await fetch(`/api/tasks/${taskId}`, { method: "DELETE" }).catch(() => {});
        card.remove();
        updateTaskCount();
      });
    }
  }
}

// ── Polling ───────────────────────────────────────────────────────────────────
function startPolling(taskId) {
  pollingTimers[taskId] = setInterval(async () => {
    try {
      const res = await fetch(`/api/tasks/${taskId}`);
      if (!res.ok) { stopPolling(taskId); return; }
      const task = await res.json();
      updateTaskCard(taskId, task);
      if (["completed", "failed", "cancelled", "interrupted"].includes(task.status)) {
        stopPolling(taskId);
        if (task.status === "completed")
          toast(`${task.output} 已完成`, "success");
        else if (task.status === "failed")
          toast(`失败: ${task.error}`, "danger");
      }
    } catch (_) { /* network hiccup – keep polling */ }
  }, 600);
}

function stopPolling(taskId) {
  clearInterval(pollingTimers[taskId]);
  delete pollingTimers[taskId];
}

async function cancelTask(taskId) {
  let data = {};
  try {
    const res = await fetch(`/api/tasks/${taskId}`, { method: "DELETE" });
    data = await res.json();
  } catch (_) {}

  if (data.status === "stopping") {
    // Live stream: server is merging — keep polling to completion
    return;
  }

  stopPolling(taskId);
  const card = document.getElementById(`task-${taskId}`);
  if (card) {
    card.querySelector(".task-status").textContent = "已取消";
    card.querySelector(".task-status").className = "badge bg-secondary flex-shrink-0 task-status";
    const btn = card.querySelector(".task-action");
    btn.innerHTML = '<i class="fas fa-trash"></i>';
    btn.className = "btn btn-sm btn-outline-secondary task-action";
    btn.dataset.mode = "trash";
    btn.replaceWith(btn.cloneNode(true));
    card.querySelector(".task-action").addEventListener("click", async () => {
      await fetch(`/api/tasks/${taskId}`, { method: "DELETE" }).catch(() => {});
      card.remove();
      updateTaskCount();
    });
  }
}

// ── Clear completed ───────────────────────────────────────────────────────────
document.getElementById("clearCompletedBtn").addEventListener("click", async () => {
  const terminalTexts = ["已完成", "失败", "已取消", "已中断"];
  const toRemove = Array.from(document.querySelectorAll(".task-card")).filter((card) => {
    const s = card.querySelector(".task-status")?.textContent;
    return terminalTexts.includes(s);
  });
  for (const card of toRemove) {
    const taskId = card.id.replace("task-", "");
    await fetch(`/api/tasks/${taskId}`, { method: "DELETE" }).catch(() => {});
    card.remove();
  }
  updateTaskCount();
});

// ── Resume task ────────────────────────────────────────────────────────────────
async function resumeTask(taskId) {
  try {
    const res = await fetch(`/api/tasks/${taskId}/resume`, { method: "POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "断点续传失败");
    // Reset card to queued state
    const card = document.getElementById(`task-${taskId}`);
    if (card) {
      card.querySelector(".task-status").textContent = "等待中";
      card.querySelector(".task-status").className = "badge bg-secondary flex-shrink-0 task-status";
      card.querySelector(".task-info").textContent = "正在准备...";
      const btn = card.querySelector(".task-action");
      btn.innerHTML = '<i class="fas fa-times"></i> 取消';
      btn.className = "btn btn-sm btn-outline-danger task-action";
      btn.dataset.mode = "";
      btn.disabled = false;
      btn.replaceWith(btn.cloneNode(true));
      card.querySelector(".task-action").addEventListener("click", () => cancelTask(taskId));
    }
    startPolling(taskId);
    toast("已开始断点续传", "info");
  } catch (e) {
    toast(e.message, "danger");
  }
}

// ── Restart task (re-download from scratch) ────────────────────────────────────
async function restartTask(taskId) {
  try {
    const res = await fetch(`/api/tasks/${taskId}/restart`, { method: "POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "重新下载失败");
    const card = document.getElementById(`task-${taskId}`);
    if (card) {
      card.querySelector(".task-status").textContent = "等待中";
      card.querySelector(".task-status").className = "badge bg-secondary flex-shrink-0 task-status";
      card.querySelector(".task-info").textContent = "正在准备...";
      const bar = card.querySelector(".task-bar");
      if (bar) { bar.style.width = "0%"; bar.textContent = ""; }
      const btn = card.querySelector(".task-action");
      btn.innerHTML = '<i class="fas fa-times"></i> 取消';
      btn.className = "btn btn-sm btn-outline-danger task-action";
      btn.dataset.mode = "";
      btn.disabled = false;
      btn.replaceWith(btn.cloneNode(true));
      card.querySelector(".task-action").addEventListener("click", () => cancelTask(taskId));
    }
    startPolling(taskId);
    toast("已开始重新下载", "info");
  } catch (e) {
    toast(e.message, "danger");
  }
}

// ── Preview player (hls.js) ───────────────────────────────────────────────────
let hlsInstance = null;

function openPreview(taskId) {
  const video = document.getElementById("previewVideo");
  if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
  video.pause();
  video.removeAttribute("src");

  const src = `/api/tasks/${taskId}/preview.m3u8`;
  if (typeof Hls !== "undefined" && Hls.isSupported()) {
    hlsInstance = new Hls({ enableWorker: false });
    hlsInstance.loadSource(src);
    hlsInstance.attachMedia(video);
    hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => video.play().catch(() => {}));
  } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
    video.src = src;
    video.play().catch(() => {});
  } else {
    toast("浏览器不支持 HLS 预览，请使用 Chrome 并确保页面加载了 hls.js", "danger");
    return;
  }
  new bootstrap.Modal(document.getElementById("previewModal")).show();
}

document.getElementById("previewModal").addEventListener("hidden.bs.modal", () => {
  const video = document.getElementById("previewVideo");
  if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
  video.pause();
  video.removeAttribute("src");
  video.load();
});

// ── Load existing tasks on page load ─────────────────────────────────────────
(async () => {
  try {
    const res = await fetch("/api/tasks");
    if (!res.ok) return;
    const taskList = await res.json();
    taskList.forEach((task) => {
      addTaskCard(task.id, task.url || "");
      updateTaskCard(task.id, task);
      if (["downloading", "queued", "merging", "recording", "stopping"].includes(task.status)) {
        startPolling(task.id);
      }
    });
  } catch (_) {}
})();
