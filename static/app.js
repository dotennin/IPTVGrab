/* globals Bootstrap */
"use strict";

// ── State ────────────────────────────────────────────────────────────────────
let currentRequest = { url: "", headers: {} };
let currentStreamInfo = null;
const pollingTimers = {};

// ── Auth helpers ─────────────────────────────────────────────────────────────
async function apiFetch(url, options = {}) {
  const res = await fetch(url, options);
  if (res.status === 401) {
    window.location.replace("/login");
    // Return a never-resolving promise to stop further execution
    return new Promise(() => {});
  }
  return res;
}

async function initAuth() {
  try {
    const res = await fetch("/api/auth/status");
    if (!res.ok) return;
    const data = await res.json();
    if (data.auth_required) {
      const btn = document.getElementById("logoutBtn");
      if (btn) btn.classList.remove("d-none");
    }
  } catch {
    // ignore
  }
}

document.getElementById("logoutBtn")?.addEventListener("click", async () => {
  await fetch("/api/logout", { method: "POST" }).catch(() => {});
  window.location.replace("/login");
});

initAuth();

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

// ── Tab: toggle common output settings visibility ────────────────────────────
document.getElementById("playlist-tab").addEventListener("shown.bs.tab", () => {
  document.getElementById("outputSettingsRow").classList.add("d-none");
  document.getElementById("parseBtnGroup").classList.add("d-none");
  document.getElementById("streamInfoPanel").classList.add("d-none");
  document.getElementById("channelGridPanel").classList.remove("d-none");
});

["url-tab", "curl-tab"].forEach((id) => {
  document.getElementById(id).addEventListener("shown.bs.tab", () => {
    document.getElementById("outputSettingsRow").classList.remove("d-none");
    document.getElementById("parseBtnGroup").classList.remove("d-none");
    document.getElementById("streamInfoPanel").classList.remove("d-none");
    document.getElementById("channelGridPanel").classList.add("d-none");
  });
});

// ── Header rows ───────────────────────────────────────────────────────────────
function addHeaderRow(key = "", val = "") {
  const list = document.getElementById("headersList");
  const row = document.createElement("div");
  row.className = "input-group input-group-sm mb-2 header-row";
  row.innerHTML = `
    <input type="text" class="form-control header-key font-mono" placeholder="Header name" value="${esc(key)}" />
    <input type="text" class="form-control header-val font-mono" placeholder="Value" value="${esc(val)}" />
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
      toast("Please paste a cURL command", "danger");
      return;
    }
  } else {
    url = document.getElementById("urlInput").value.trim();
    if (!url) {
      toast("Please enter an M3U8 URL", "danger");
      return;
    }
    headers = collectHeaders();
  }

  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Parsing...';

  try {
    const res = await apiFetch("/api/parse", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, headers, curl_command: curlCommand }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Parse failed");

    currentRequest = { url: data.url, headers: data.headers || headers };
    currentStreamInfo = data;

    // Auto-fill URL tab
    document.getElementById("urlInput").value = data.url || "";
    if (data.headers) populateHeaders(data.headers);

    showStreamInfo(data);
    toast("Parsed successfully", "success");
  } catch (e) {
    toast(e.message, "danger");
    showError(e.message);
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-search me-1"></i>Parse stream';
  }
});

// ── Stream info panel ─────────────────────────────────────────────────────────
function resetStreamInfo() {
  document.getElementById("streamTypeBadge").innerHTML = "";
  document.getElementById("streamInfoBody").innerHTML = `
    <div class="text-center text-muted py-5" id="streamPlaceholder">
      <i class="fas fa-play-circle fa-3x mb-3 d-block opacity-25"></i>
      <p class="mb-0">Stream info will appear here after parsing</p>
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
    badge.innerHTML = `<span class="badge bg-info">Master playlist</span>`;
    let html = `<p class="text-muted small mb-3">
      <i class="fas fa-layer-group me-1"></i>${info.streams.length} quality option(s). Select a stream to download:
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
          ${i === 0 ? '<span class="badge bg-success">Best</span>' : ""}
        </label>`;
    });

    body.innerHTML = html + downloadButton();
  } else {
    const isLive = info.is_live === true;
    badge.innerHTML = isLive
      ? `<span class="badge bg-danger live-badge"><i class="fas fa-circle me-1" style="font-size:.6em"></i>LIVE</span>`
      : `<span class="badge bg-success">Media playlist</span>`;
    body.innerHTML = `
      <dl class="stat-grid mb-3">
        ${isLive
          ? `<dt>Status</dt><dd><span class="text-danger fw-semibold">Live — records until stopped</span></dd>`
          : `<dt>Segments</dt><dd>${info.segments}</dd>
             <dt>Duration</dt><dd>${formatDuration(info.duration)}</dd>`
        }
        <dt>Encryption</dt>
        <dd>${
          info.encrypted
            ? '<span class="badge bg-warning text-dark">AES-128</span>'
            : '<span class="text-muted">None</span>'
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
  body.querySelector("#watchStreamBtn")?.addEventListener("click", () => {
    if (!currentRequest.url) return;
    const label = document.getElementById("outputName")?.value.trim() || currentRequest.url.split("/").pop().split("?")[0] || "Watch";
    openHLSPlayer(currentRequest.url, label);
  });
}

function downloadButton(isLive = false) {
  const startBtn = isLive
    ? `<button class="btn btn-danger" id="startDownloadBtn" type="button">
         <i class="fas fa-circle me-2"></i>Start recording
       </button>`
    : `<button class="btn btn-success" id="startDownloadBtn" type="button">
         <i class="fas fa-download me-2"></i>Start download
       </button>`;

  return `<div class="mt-3 pt-3 border-top">
    <div class="d-flex align-items-center gap-2 flex-wrap">
      ${startBtn}
      <button class="btn btn-outline-info" id="watchStreamBtn" type="button">
        <i class="fas fa-play me-1"></i>Watch
      </button>
    </div>
    ${isLive ? `<p class="text-muted small mt-2 mb-0"><i class="fas fa-info-circle me-1"></i>Merges to MP4 automatically when stopped</p>` : ""}
  </div>`;
}

// ── Start download ────────────────────────────────────────────────────────────
async function startDownload() {
  if (!currentRequest.url) {
    toast("Parse a stream first", "danger");
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
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-2"></i>Submitting...';

  try {
    const res = await apiFetch("/api/download", {
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
    toast("Download task added", "info");
  } catch (e) {
    toast(e.message, "danger");
  } finally {
    btn.disabled = false;
    const isLive = currentStreamInfo?.is_live === true;
    btn.innerHTML = isLive
      ? '<i class="fas fa-circle me-2"></i>Start recording'
      : '<i class="fas fa-download me-2"></i>Start download';
  }
}

// ── Download task state ───────────────────────────────────────────────────────
let currentCategory = "all";
let currentSort = { field: "created_at", dir: "desc" };
const SORT_DEFAULTS = { created_at: "desc", filename: "asc", size: "desc" };
const ACTIVE_STATUSES   = ["downloading", "recording", "merging", "stopping"];
const WAITING_STATUSES  = ["queued"];
const FINISHED_STATUSES = ["completed", "failed", "cancelled", "interrupted"];

// ── Task cards ────────────────────────────────────────────────────────────────
function updateTaskCount() {
  const cards = document.querySelectorAll(".task-card");
  let all = 0, active = 0, waiting = 0, finished = 0;
  cards.forEach(c => {
    all++;
    const s = c.dataset.taskStatus || "";
    if      (ACTIVE_STATUSES.includes(s))   active++;
    else if (WAITING_STATUSES.includes(s))  waiting++;
    else if (FINISHED_STATUSES.includes(s)) finished++;
  });
  document.getElementById("taskCountBadge").textContent   = all;
  document.getElementById("catCount-all").textContent     = all;
  document.getElementById("catCount-active").textContent  = active;
  document.getElementById("catCount-queued").textContent  = waiting;
  document.getElementById("catCount-finished").textContent = finished;
}

function applyCategoryFilter() {
  document.querySelectorAll(".task-card").forEach(card => {
    const s = card.dataset.taskStatus || "";
    let show = false;
    switch (currentCategory) {
      case "all":      show = true; break;
      case "active":   show = ACTIVE_STATUSES.includes(s); break;
      case "queued":   show = WAITING_STATUSES.includes(s); break;
      case "finished": show = FINISHED_STATUSES.includes(s); break;
    }
    card.style.display = show ? "" : "none";
  });
  const hasVisible = [...document.querySelectorAll(".task-card")].some(c => c.style.display !== "none");
  document.getElementById("tasksPlaceholder").style.display = hasVisible ? "none" : "";
}

function applySortOrder() {
  const list = document.getElementById("downloadsList");
  const cards = [...list.querySelectorAll(".task-card")];
  const { field, dir } = currentSort;
  const sortedCards = [...cards].sort((a, b) => {
    let va, vb;
    if (field === "created_at") {
      va = parseFloat(a.dataset.createdAt) || 0;
      vb = parseFloat(b.dataset.createdAt) || 0;
    } else if (field === "size") {
      va = parseInt(a.dataset.size) || 0;
      vb = parseInt(b.dataset.size) || 0;
    } else {
      va = (a.dataset.filename || "").toLowerCase();
      vb = (b.dataset.filename || "").toLowerCase();
    }
    if (va < vb) return dir === "asc" ? -1 : 1;
    if (va > vb) return dir === "asc" ? 1 : -1;
    return 0;
  });
  if (!sortedCards.some((card, idx) => card !== cards[idx])) return;

  const fragment = document.createDocumentFragment();
  sortedCards.forEach(card => fragment.appendChild(card));
  list.appendChild(fragment);
}

function addTaskCard(taskId, url) {
  const list = document.getElementById("downloadsList");

  const card = document.createElement("div");
  card.className = "task-card";
  card.id = `task-${taskId}`;
  card.dataset.taskStatus = "queued";
  card.dataset.createdAt  = (Date.now() / 1000).toString();
  card.dataset.size       = "0";
  card.dataset.filename   = "";
  card.innerHTML = `
    <div class="d-flex justify-content-between align-items-start mb-2 gap-2">
      <div class="flex-grow-1 overflow-hidden">
        <div class="task-url text-truncate">${esc(url)}</div>
        <div class="task-filename text-muted small text-truncate d-none"></div>
      </div>
      <span class="badge bg-secondary flex-shrink-0 task-status">Queued</span>
    </div>
    <div class="progress mb-2">
      <div class="progress-bar task-bar" role="progressbar" style="width:0%"></div>
    </div>
    <div class="d-flex justify-content-between align-items-center">
      <small class="task-info text-muted">Preparing...</small>
      <div class="d-flex gap-2 align-items-center">
        <button class="btn btn-sm btn-outline-info task-preview d-none" title="Preview downloaded segments">
          <i class="fas fa-play-circle me-1"></i>Preview
        </button>
        <div class="d-flex gap-1 task-recording-extras d-none"></div>
        <button class="btn btn-sm btn-outline-danger task-action" data-id="${taskId}">
          <i class="fas fa-times"></i> Cancel
        </button>
      </div>
    </div>`;

  list.appendChild(card);
  card.querySelector(".task-action").addEventListener("click", () => cancelTask(taskId));
  applyCategoryFilter();
  applySortOrder();
  updateTaskCount();
}

const STATUS_MAP = {
  queued:      { text: "Queued",      cls: "bg-secondary" },
  downloading: { text: "Downloading", cls: "bg-primary"   },
  recording:   { text: "Recording",   cls: "bg-danger"    },
  stopping:    { text: "Merging",     cls: "bg-info"      },
  merging:     { text: "Merging",     cls: "bg-info"      },
  completed:   { text: "Completed",   cls: "bg-success"   },
  failed:      { text: "Failed",      cls: "bg-danger"    },
  cancelled:   { text: "Cancelled",   cls: "bg-secondary" },
  interrupted: { text: "Interrupted", cls: "bg-warning"   },
};

function updateTaskCard(taskId, task) {
  const card = document.getElementById(`task-${taskId}`);
  if (!card) return;
  const prevStatus = card.dataset.taskStatus || "";
  const prevCreatedAt = card.dataset.createdAt || "";
  const prevSize = card.dataset.size || "";
  const prevFilename = card.dataset.filename || "";

  const { text, cls } = STATUS_MAP[task.status] || { text: task.status, cls: "bg-secondary" };
  card.querySelector(".task-status").className = `badge ${cls} flex-shrink-0 task-status`;
  card.querySelector(".task-status").textContent = text;

  // Hide recording-only extra buttons when not recording
  if (task.status !== "recording") {
    const extras = card.querySelector(".task-recording-extras");
    if (extras) {
      extras.classList.add("d-none");
      extras.removeAttribute("data-populated");
    }
  }

  // ── Filename label (show expected name during download, actual name when done) ──
  const filenameEl = card.querySelector(".task-filename");
  if (filenameEl) {
    let fname = task.output || null;
    if (!fname && task.output_name) {
      fname = task.output_name.endsWith(".mp4") ? task.output_name : task.output_name + ".mp4";
    }
    if (fname) {
      filenameEl.textContent = "📄 " + fname;
      filenameEl.classList.remove("d-none");
    } else {
      filenameEl.classList.add("d-none");
    }
  }

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
  const infoStatus = info.dataset.status || "";

  if (task.status === "recording") {
    if (infoStatus !== "recording" || !info.querySelector(".task-recording-time")) {
      info.className = "task-info small";
      info.innerHTML = `
        <span class="text-danger fw-semibold">
          <i class="fas fa-circle fa-beat me-1" style="font-size:.6em"></i><span class="task-recording-time"></span>
        </span>
        <span class="task-recording-segments ms-2"></span>
        <span class="task-recording-bytes ms-2"></span>
        <span class="task-recording-speed ms-2 text-muted"></span>`;
      info.dataset.status = "recording";
    }
    const elapsed = task.elapsed_sec || 0;
    const mm = String(Math.floor(elapsed / 60)).padStart(2, "0");
    const ss = String(elapsed % 60).padStart(2, "0");
    info.querySelector(".task-recording-time").textContent = `${mm}:${ss}`;
    info.querySelector(".task-recording-segments").textContent = `${task.recorded_segments || 0} segs`;
    info.querySelector(".task-recording-bytes").textContent = formatBytes(task.bytes_downloaded);
    info.querySelector(".task-recording-speed").textContent = `${task.speed_mbps || 0} MB/s`;
  } else if (task.status === "downloading") {
    if (infoStatus !== "downloading" || !info.querySelector(".task-download-progress")) {
      info.className = "task-info small";
      info.innerHTML = `
        <span class="task-download-progress"></span>
        <span class="task-download-speed ms-2 text-primary"></span>
        <span class="task-download-bytes ms-2"></span>`;
      info.dataset.status = "downloading";
    }
    info.querySelector(".task-download-progress").textContent = `${task.downloaded || 0} / ${task.total || 0} segs`;
    info.querySelector(".task-download-speed").textContent = `${task.speed_mbps || 0} MB/s`;
    info.querySelector(".task-download-bytes").textContent = formatBytes(task.bytes_downloaded);
  } else if (infoStatus !== task.status) {
    info.dataset.status = task.status;
    if (task.status === "stopping") {
      info.innerHTML = '<i class="fas fa-cog fa-spin me-1"></i>Merging recorded segments...';
      info.className = "task-info small text-info";
    } else if (task.status === "merging") {
      info.innerHTML = '<i class="fas fa-cog fa-spin me-1"></i>Merging segments...';
      info.className = "task-info small text-info";
    } else if (task.status === "completed" && task.output) {
      const sizeStr = task.size ? ` (${formatBytes(task.size)})` : "";
      info.innerHTML = `
        <a href="/downloads/${esc(task.output)}" download
           class="btn btn-sm btn-success">
          <i class="fas fa-download me-1"></i>${esc(task.output)}${sizeStr}
        </a>
        ${task.duration_sec ? `<span class="ms-2 text-muted small">${task.duration_sec}s elapsed</span>` : ""}
        <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="restartTask('${taskId}')">
          <i class="fas fa-redo me-1"></i>Restart
        </button>`;
    } else if (task.status === "failed") {
      info.innerHTML = `
        <div class="task-error text-danger" title="Click to expand/collapse" onclick="this.classList.toggle('expanded')">Error: ${esc(task.error || "Unknown error")}</div>
        <div class="mt-1">
          <button class="btn btn-link btn-sm p-0 text-warning" onclick="resumeTask('${taskId}')">
            <i class="fas fa-play me-1"></i>Resume
          </button>
          <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="restartTask('${taskId}')">
            <i class="fas fa-sync me-1"></i>Restart
          </button>
        </div>`;
      info.className = "task-info small";
    } else if (task.status === "cancelled") {
      info.innerHTML = `<span class="text-muted">Cancelled</span>
        <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="restartTask('${taskId}')">
          <i class="fas fa-redo me-1"></i>Restart
        </button>`;
      info.className = "task-info small";
    } else if (task.status === "interrupted") {
      info.innerHTML = `<span class="text-warning"><i class="fas fa-exclamation-triangle me-1"></i>Interrupted</span>
        <button class="btn btn-link btn-sm p-0 ms-2 text-warning" onclick="resumeTask('${taskId}')">
          <i class="fas fa-redo me-1"></i>Resume
        </button>
        <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="restartTask('${taskId}')">
          <i class="fas fa-sync me-1"></i>Restart
        </button>`;
      info.className = "task-info small";
    } else {
      info.className = "task-info small text-muted";
      info.textContent = "Preparing...";
    }
  }

  // ── Preview button ────────────────────────────────────────────────────────
  const previewBtn = card.querySelector(".task-preview");
  if (previewBtn) {
    const canLive = task.tmpdir && (task.downloaded >= 5 || task.recorded_segments >= 5);
    const canDirect = task.status === "completed" && task.output;
    if (canLive || canDirect) {
      previewBtn.classList.remove("d-none");
      // Keep data-output-url in sync so click handler always uses latest value
      if (canDirect) {
        previewBtn.dataset.outputUrl = `/downloads/${task.output}`;
      } else {
        delete previewBtn.dataset.outputUrl;
      }
      if (!previewBtn.dataset.listenerAdded) {
        previewBtn.dataset.listenerAdded = "1";
        previewBtn.addEventListener("click", () => {
          if (previewBtn.dataset.outputUrl) {
            openPreviewDirect(previewBtn.dataset.outputUrl);
          } else {
            openPreview(taskId);
          }
        });
      }
    }
  }

  // ── Action button state ───────────────────────────────────────────────────
  if (task.status === "recording") {
    const btn = card.querySelector(".task-action");
    if (btn && btn.dataset.mode !== "stop") {
      btn.innerHTML = '<i class="fas fa-stop me-1"></i>Stop';
      btn.className = "btn btn-sm btn-danger task-action";
      btn.dataset.mode = "stop";
    }
    const extras = card.querySelector(".task-recording-extras");
    if (extras && !extras.dataset.populated) {
      extras.classList.remove("d-none");
      extras.innerHTML = `
        <button class="btn btn-sm btn-outline-warning"
                title="Delete all recorded segments and start fresh"
                onclick="restartRecording('${taskId}')">
          <i class="fas fa-redo me-1"></i>Restart
        </button>
        <button class="btn btn-sm btn-outline-info"
                title="Keep &amp; merge current segments, then start a new recording"
                onclick="forkRecording('${taskId}')">
          <i class="fas fa-code-branch me-1"></i>Stop &amp; New
        </button>`;
      extras.dataset.populated = "1";
    }
  } else if (task.status === "stopping") {
    const btn = card.querySelector(".task-action");
    if (btn) {
      btn.disabled = true;
      btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Merging';
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
        await apiFetch(`/api/tasks/${taskId}`, { method: "DELETE" }).catch(() => {});
        card.remove();
        applyCategoryFilter();
        updateTaskCount();
      });
    }
  }

  // Sync data attributes for category filtering and sorting
  card.dataset.taskStatus = task.status;
  if (task.created_at) card.dataset.createdAt = String(task.created_at);
  card.dataset.size = task.size ? String(task.size) : "0";
  const _fn = task.output || (task.output_name
    ? (task.output_name.endsWith(".mp4") ? task.output_name : task.output_name + ".mp4")
    : "");
  card.dataset.filename = _fn;

  const sortKeyChanged =
    (currentSort.field === "created_at" && prevCreatedAt !== (card.dataset.createdAt || "")) ||
    (currentSort.field === "size" && prevSize !== card.dataset.size) ||
    (currentSort.field === "filename" && prevFilename !== card.dataset.filename);
  const statusChanged = prevStatus !== task.status;

  if (statusChanged) applyCategoryFilter();
  if (sortKeyChanged) applySortOrder();
  if (statusChanged) updateTaskCount();
}

// ── Polling ───────────────────────────────────────────────────────────────────
function startPolling(taskId) {
  if (pollingTimers[taskId]) return;
  let inFlight = false;
  pollingTimers[taskId] = setInterval(async () => {
    if (inFlight) return;
    inFlight = true;
    try {
      const res = await apiFetch(`/api/tasks/${taskId}`);
      if (!res.ok) { stopPolling(taskId); return; }
      const task = await res.json();
      updateTaskCard(taskId, task);
      if (["completed", "failed", "cancelled", "interrupted"].includes(task.status)) {
        stopPolling(taskId);
        if (task.status === "completed")
          toast(`${task.output} — completed`, "success");
        else if (task.status === "failed")
          toast(`Failed: ${task.error}`, "danger");
      }
    } catch (_) { /* network hiccup – keep polling */ }
    finally { inFlight = false; }
  }, 600);
}

function stopPolling(taskId) {
  clearInterval(pollingTimers[taskId]);
  delete pollingTimers[taskId];
}

async function cancelTask(taskId) {
  let data = {};
  try {
    const res = await apiFetch(`/api/tasks/${taskId}`, { method: "DELETE" });
    data = await res.json();
  } catch (_) {}

  if (data.status === "stopping") {
    // Live stream: server is merging — keep polling to completion
    return;
  }

  stopPolling(taskId);
  const card = document.getElementById(`task-${taskId}`);
  if (card) {
    card.querySelector(".task-status").textContent = "Cancelled";
    card.querySelector(".task-status").className = "badge bg-secondary flex-shrink-0 task-status";
    card.dataset.taskStatus = "cancelled";
    const info = card.querySelector(".task-info");
    if (info) {
      info.className = "task-info small";
      delete info.dataset.status;
      info.innerHTML = `<span class="text-muted">Cancelled</span>
        <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="restartTask('${taskId}')">
          <i class="fas fa-redo me-1"></i>Restart
        </button>`;
    }
    const btn = card.querySelector(".task-action");
    btn.innerHTML = '<i class="fas fa-trash"></i>';
    btn.className = "btn btn-sm btn-outline-secondary task-action";
    btn.dataset.mode = "trash";
    btn.replaceWith(btn.cloneNode(true));
    card.querySelector(".task-action").addEventListener("click", async () => {
      await apiFetch(`/api/tasks/${taskId}`, { method: "DELETE" }).catch(() => {});
      card.remove();
      applyCategoryFilter();
      updateTaskCount();
    });
    applyCategoryFilter();
    updateTaskCount();
  }
}

// ── Clear failed (completed tasks are preserved) ──────────────────────────────
document.getElementById("clearCompletedBtn").addEventListener("click", async () => {
  const toRemove = Array.from(document.querySelectorAll(".task-card")).filter(card => {
    const s = card.dataset.taskStatus;
    return s === "failed" || s === "cancelled" || s === "interrupted";
  });
  for (const card of toRemove) {
    const taskId = card.id.replace("task-", "");
    await apiFetch(`/api/tasks/${taskId}`, { method: "DELETE" }).catch(() => {});
    card.remove();
  }
  applyCategoryFilter();
  updateTaskCount();
});

// ── Category sidebar ──────────────────────────────────────────────────────────
document.querySelectorAll(".dl-cat").forEach(cat => {
  cat.addEventListener("click", () => {
    currentCategory = cat.dataset.cat;
    document.querySelectorAll(".dl-cat").forEach(c => c.classList.remove("active"));
    cat.classList.add("active");
    applyCategoryFilter();
    updateTaskCount();
  });
});

// ── Sort controls ─────────────────────────────────────────────────────────────
document.querySelectorAll(".sort-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    const field = btn.dataset.field;
    if (currentSort.field === field) {
      currentSort.dir = currentSort.dir === "asc" ? "desc" : "asc";
    } else {
      currentSort.field = field;
      currentSort.dir = SORT_DEFAULTS[field];
    }
    // Update button UI: deactivate all, hide all direction icons
    document.querySelectorAll(".sort-btn").forEach(b => {
      b.classList.remove("active");
      const icon = b.querySelector(".sort-dir-icon");
      if (icon) icon.className = "fas fa-arrow-down sort-dir-icon ms-1 d-none";
    });
    btn.classList.add("active");
    const icon = btn.querySelector(".sort-dir-icon");
    if (icon) {
      icon.className = `fas ${currentSort.dir === "asc" ? "fa-arrow-up" : "fa-arrow-down"} sort-dir-icon ms-1`;
    }
    applySortOrder();
  });
});

// ── Resume task ────────────────────────────────────────────────────────────────
async function resumeTask(taskId) {
  try {
    const res = await apiFetch(`/api/tasks/${taskId}/resume`, { method: "POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Resume failed");
    // Reset card to queued state
    const card = document.getElementById(`task-${taskId}`);
    if (card) {
      card.querySelector(".task-status").textContent = "Queued";
      card.querySelector(".task-status").className = "badge bg-secondary flex-shrink-0 task-status";
      const info = card.querySelector(".task-info");
      info.className = "task-info small text-muted";
      info.textContent = "Preparing...";
      delete info.dataset.status;
      card.dataset.taskStatus = "queued";
      const btn = card.querySelector(".task-action");
      btn.innerHTML = '<i class="fas fa-times"></i> Cancel';
      btn.className = "btn btn-sm btn-outline-danger task-action";
      btn.dataset.mode = "";
      btn.disabled = false;
      btn.replaceWith(btn.cloneNode(true));
      card.querySelector(".task-action").addEventListener("click", () => cancelTask(taskId));
      applyCategoryFilter();
      updateTaskCount();
    }
    startPolling(taskId);
    toast("Resume started", "info");
  } catch (e) {
    toast(e.message, "danger");
  }
}

// ── Restart task (re-download from scratch) ────────────────────────────────────
async function restartTask(taskId) {
  try {
    const res = await apiFetch(`/api/tasks/${taskId}/restart`, { method: "POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Restart failed");
    const card = document.getElementById(`task-${taskId}`);
    if (card) {
      card.querySelector(".task-status").textContent = "Queued";
      card.querySelector(".task-status").className = "badge bg-secondary flex-shrink-0 task-status";
      const info = card.querySelector(".task-info");
      info.className = "task-info small text-muted";
      info.textContent = "Preparing...";
      delete info.dataset.status;
      card.dataset.taskStatus = "queued";
      const bar = card.querySelector(".task-bar");
      if (bar) { bar.style.width = "0%"; bar.textContent = ""; }
      const btn = card.querySelector(".task-action");
      btn.innerHTML = '<i class="fas fa-times"></i> Cancel';
      btn.className = "btn btn-sm btn-outline-danger task-action";
      btn.dataset.mode = "";
      btn.disabled = false;
      btn.replaceWith(btn.cloneNode(true));
      card.querySelector(".task-action").addEventListener("click", () => cancelTask(taskId));
      applyCategoryFilter();
      updateTaskCount();
    }
    startPolling(taskId);
    toast("Download restarted", "info");
  } catch (e) {
    toast(e.message, "danger");
  }
}

// ── Restart live recording (discard segments, start fresh) ────────────────────
let _restartRecordingTaskId = null;
let _restartRecordingModal = null;

function restartRecording(taskId) {
  _restartRecordingTaskId = taskId;
  if (!_restartRecordingModal) {
    _restartRecordingModal = new bootstrap.Modal(
      document.getElementById("confirmRestartRecordingModal")
    );
  }
  _restartRecordingModal.show();
}

document.getElementById("confirmRestartRecordingBtn").addEventListener("click", async () => {
  _restartRecordingModal.hide();
  const taskId = _restartRecordingTaskId;
  if (!taskId) return;
  try {
    const res = await apiFetch(`/api/tasks/${taskId}/recording-restart`, { method: "POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Restart failed");
    stopPolling(taskId);
    const oldCard = document.getElementById(`task-${taskId}`);
    if (oldCard) oldCard.remove();
    addTaskCard(data.new_task_id, data.url);
    startPolling(data.new_task_id);
    toast("Recording restarted", "info");
  } catch (e) {
    toast(e.message, "danger");
  }
});

// ── Fork live recording (merge current, start new in parallel) ────────────────
async function forkRecording(taskId) {
  try {
    const res = await apiFetch(`/api/tasks/${taskId}/fork`, { method: "POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Fork failed");
    // Old card stays — polling will pick up the stopping → merging → completed transition
    addTaskCard(data.new_task_id, data.url);
    startPolling(data.new_task_id);
    toast("New recording started", "info");
  } catch (e) {
    toast(e.message, "danger");
  }
}

// ── Preview / Watch player (hls.js) ──────────────────────────────────────────
let hlsInstance = null;
const previewModalEl = document.getElementById("previewModal");
const previewViewportEl = document.getElementById("previewViewport");
const previewVideo = document.getElementById("previewVideo");
const previewTitleEl = document.getElementById("previewModalTitle");
const previewModal = bootstrap.Modal.getOrCreateInstance(previewModalEl);
const PREVIEW_IDLE_DELAY_MS = 1800;
let previewIdleTimer = null;

function isPreviewVisible() {
  return previewModalEl.classList.contains("show");
}

function setPreviewTitle(title) {
  if (previewTitleEl) {
    previewTitleEl.innerHTML = `<i class="fas fa-play-circle me-2 text-primary"></i>${title}`;
  }
}

function clearPreviewIdleTimer() {
  if (previewIdleTimer !== null) {
    window.clearTimeout(previewIdleTimer);
    previewIdleTimer = null;
  }
}

function resetPreviewChrome() {
  clearPreviewIdleTimer();
  previewVideo.controls = true;
  previewViewportEl.classList.remove("preview-idle");
}

function hidePreviewChrome() {
  if (!isPreviewVisible() || previewVideo.paused || previewVideo.ended) return;
  previewVideo.controls = false;
  previewViewportEl.classList.add("preview-idle");
}

function schedulePreviewChromeHide() {
  clearPreviewIdleTimer();
  if (!isPreviewVisible() || previewVideo.paused || previewVideo.ended) return;
  previewIdleTimer = window.setTimeout(() => {
    hidePreviewChrome();
  }, PREVIEW_IDLE_DELAY_MS);
}

function handlePreviewActivity() {
  if (!isPreviewVisible()) return;
  resetPreviewChrome();
  schedulePreviewChromeHide();
}

function isPreviewFullscreen() {
  return document.fullscreenElement === previewViewportEl
    || document.fullscreenElement === previewVideo
    || (!!document.fullscreenElement && previewViewportEl.contains(document.fullscreenElement))
    || previewVideo.webkitDisplayingFullscreen === true;
}

async function enterPreviewFullscreen() {
  if (previewViewportEl.requestFullscreen) {
    try {
      await previewViewportEl.requestFullscreen();
    } catch (error) {
      toast("Unable to enter fullscreen", "danger");
    }
    return;
  }

  if (previewViewportEl.webkitRequestFullscreen) {
    previewViewportEl.webkitRequestFullscreen();
    return;
  }

  if (previewVideo.requestFullscreen) {
    try {
      await previewVideo.requestFullscreen();
    } catch (error) {
      toast("Unable to enter fullscreen", "danger");
    }
    return;
  }

  if (previewVideo.webkitEnterFullscreen) {
    previewVideo.webkitEnterFullscreen();
    return;
  }

  toast("Fullscreen is not supported in this browser", "danger");
}

async function exitPreviewFullscreen() {
  if (document.fullscreenElement && document.exitFullscreen) {
    try {
      await document.exitFullscreen();
    } catch (error) {
      toast("Unable to exit fullscreen", "danger");
    }
    return;
  }

  if (document.webkitFullscreenElement && document.webkitExitFullscreen) {
    document.webkitExitFullscreen();
    return;
  }

  if (previewVideo.webkitDisplayingFullscreen === true && previewVideo.webkitExitFullscreen) {
    previewVideo.webkitExitFullscreen();
  }
}

async function togglePreviewFullscreen() {
  if (isPreviewFullscreen()) {
    await exitPreviewFullscreen();
    return;
  }

  await enterPreviewFullscreen();
}

async function closePreviewModal() {
  if (isPreviewFullscreen()) {
    await exitPreviewFullscreen();
  }
  previewModal.hide();
}

previewModalEl.addEventListener("shown.bs.modal", () => {
  resetPreviewChrome();
  previewVideo.focus();
  schedulePreviewChromeHide();
});

document.addEventListener("keydown", (event) => {
  if (!isPreviewVisible() || event.altKey || event.ctrlKey || event.metaKey) return;

  handlePreviewActivity();

  if (event.key === "Escape") {
    event.preventDefault();
    event.stopImmediatePropagation();
    void closePreviewModal();
    return;
  }

  if (!event.repeat && (event.key === "f" || event.key === "F")) {
    event.preventDefault();
    void togglePreviewFullscreen();
  }
});

["mousemove", "pointerdown", "touchstart"].forEach((eventName) => {
  previewViewportEl.addEventListener(eventName, handlePreviewActivity);
});

previewVideo.addEventListener("play", schedulePreviewChromeHide);
previewVideo.addEventListener("pause", resetPreviewChrome);
previewVideo.addEventListener("ended", resetPreviewChrome);
document.addEventListener("fullscreenchange", handlePreviewActivity);
document.addEventListener("webkitfullscreenchange", handlePreviewActivity);
previewVideo.addEventListener("webkitbeginfullscreen", handlePreviewActivity);
previewVideo.addEventListener("webkitendfullscreen", handlePreviewActivity);

function openHLSPlayer(url, title = "") {
  setPreviewTitle(title ? esc(title) : "Watch");
  if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
  previewVideo.pause();
  previewVideo.removeAttribute("src");
  if (typeof Hls !== "undefined" && Hls.isSupported()) {
    hlsInstance = new Hls({ enableWorker: false });
    hlsInstance.loadSource(url);
    hlsInstance.attachMedia(previewVideo);
    hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => previewVideo.play().catch(() => {}));
    hlsInstance.on(Hls.Events.ERROR, (_evt, data) => {
      if (data.fatal) toast("Stream error: " + (data.details || "unknown"), "danger");
    });
  } else if (previewVideo.canPlayType("application/vnd.apple.mpegurl")) {
    previewVideo.src = url;
    previewVideo.play().catch(() => {});
  } else {
    toast("HLS playback not supported in this browser", "danger");
    return;
  }
  previewModal.show();
}

function openPreviewDirect(url) {
  setPreviewTitle("Preview");
  if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
  previewVideo.pause();
  previewVideo.src = url;
  previewModal.show();
  previewVideo.play().catch(() => {});
}

function openPreview(taskId) {
  setPreviewTitle("Preview");
  if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
  previewVideo.pause();
  previewVideo.removeAttribute("src");

  const src = `/api/tasks/${taskId}/preview.m3u8`;
  if (typeof Hls !== "undefined" && Hls.isSupported()) {
    hlsInstance = new Hls({ enableWorker: false });
    hlsInstance.loadSource(src);
    hlsInstance.attachMedia(previewVideo);
    hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => previewVideo.play().catch(() => {}));
  } else if (previewVideo.canPlayType("application/vnd.apple.mpegurl")) {
    previewVideo.src = src;
    previewVideo.play().catch(() => {});
  } else {
    toast("HLS preview requires Chrome with hls.js loaded", "danger");
    return;
  }
  previewModal.show();
}

previewModalEl.addEventListener("hidden.bs.modal", () => {
  setPreviewTitle("Preview");
  resetPreviewChrome();
  if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
  previewVideo.pause();
  previewVideo.removeAttribute("src");
  previewVideo.load();
});

// ── Load existing tasks on page load ─────────────────────────────────────────
(async () => {
  try {
    const res = await apiFetch("/api/tasks");
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

// ── IPTV Playlists ────────────────────────────────────────────────────────────

let currentPlaylist = null;
let allChannels = [];

async function loadPlaylists({ autoSelect = false } = {}) {
  try {
    const res = await apiFetch("/api/playlists");
    if (!res.ok) return;
    const list = await res.json();
    const sel = document.getElementById("playlistSelect");
    const prev = sel.value;
    sel.innerHTML = '<option value="">＋ Add playlist…</option>';
    if (list.length > 0) {
      const totalChannels = list.reduce((sum, pl) => sum + (pl.channel_count || 0), 0);
      const allOpt = document.createElement("option");
      allOpt.value = "__all__";
      allOpt.textContent = `All Playlists (${totalChannels})`;
      sel.appendChild(allOpt);
    }
    for (const pl of list) {
      const opt = document.createElement("option");
      opt.value = pl.id;
      opt.textContent = `${pl.name} (${pl.channel_count})`;
      sel.appendChild(opt);
    }
    if (prev && [...sel.options].some((o) => o.value === prev)) {
      sel.value = prev;
    } else if (autoSelect && list.length > 0 && !currentPlaylist) {
      sel.value = "__all__";
      await selectPlaylist("__all__");
    }
  } catch (_) {}
}

function _populateGroupFilter(channels) {
  const gSel = document.getElementById("groupFilter");
  gSel.innerHTML = "";
  const allOpt = document.createElement("option");
  allOpt.value = "";
  allOpt.textContent = "All groups";
  gSel.appendChild(allOpt);
  const groups = [...new Set(channels.map((c) => c.group).filter(Boolean))].sort();
  for (const g of groups) {
    const opt = document.createElement("option");
    opt.value = g;
    opt.textContent = g;
    gSel.appendChild(opt);
  }
}

async function selectPlaylist(id) {
  const filterBar = document.getElementById("channelFilterBar");
  const countBadge = document.getElementById("channelCountBadge");
  const refreshBtn = document.getElementById("refreshPlaylistBtn");
  const deleteBtn = document.getElementById("deletePlaylistBtn");

  if (!id) {
    currentPlaylist = null;
    allChannels = [];
    renderChannels([]);
    filterBar.classList.add("d-none");
    countBadge.textContent = "0";
    refreshBtn.disabled = true;
    document.getElementById("editPlaylistBtn").disabled = true;
    document.getElementById("editAllPlaylistsBtn").classList.add("d-none");
    document.getElementById("refreshAllPlaylistsBtn").classList.add("d-none");
    deleteBtn.disabled = true;
    return;
  }

  // "All Playlists" mode: use merged config (respects ordering, enabled state)
  if (id === "__all__") {
    try {
      const res = await apiFetch("/api/all-playlists");
      if (!res.ok) throw new Error("Failed to load channels");
      const data = await res.json();
      currentPlaylist = null;
      // Flatten enabled groups/channels for the grid view
      allChannels = [];
      for (const g of data.groups || []) {
        if (!g.enabled) continue;
        for (const ch of g.channels || []) {
          if (!ch.enabled) continue;
          allChannels.push({ ...ch, playlist_name: ch.source_playlist_name || "" });
        }
      }
      _populateGroupFilter(allChannels);
      document.getElementById("channelSearch").value = "";
      filterBar.classList.remove("d-none");
      countBadge.textContent = allChannels.length;
      refreshBtn.disabled = true;
      document.getElementById("editPlaylistBtn").disabled = true;
      deleteBtn.disabled = true;
      document.getElementById("editAllPlaylistsBtn").classList.remove("d-none");
      document.getElementById("refreshAllPlaylistsBtn").classList.remove("d-none");
      renderChannels(allChannels);
    } catch (e) {
      toast(e.message, "danger");
    }
    return;
  }

  try {
    const res = await apiFetch(`/api/playlists/${id}`);
    if (!res.ok) throw new Error("Failed to load playlist");
    currentPlaylist = await res.json();
    allChannels = currentPlaylist.channels || [];
    _populateGroupFilter(allChannels);
    document.getElementById("channelSearch").value = "";
    filterBar.classList.remove("d-none");
    countBadge.textContent = allChannels.length;
    refreshBtn.disabled = !currentPlaylist.url;
    document.getElementById("editPlaylistBtn").disabled = false;
    document.getElementById("editAllPlaylistsBtn").classList.add("d-none");
    document.getElementById("refreshAllPlaylistsBtn").classList.add("d-none");
    deleteBtn.disabled = false;
    renderChannels(allChannels);
  } catch (e) {
    toast(e.message, "danger");
  }
}

function getFilteredChannels() {
  const search = document.getElementById("channelSearch").value.toLowerCase();
  const group = document.getElementById("groupFilter").value;
  return allChannels.filter((ch) => {
    const matchSearch =
      !search ||
      (ch.name || "").toLowerCase().includes(search) ||
      (ch.group || "").toLowerCase().includes(search) ||
      (ch.playlist_name || "").toLowerCase().includes(search);
    const matchGroup = !group || ch.group === group;
    return matchSearch && matchGroup;
  });
}

function renderChannels(channels) {
  const grid = document.getElementById("channelGrid");
  const placeholder = document.getElementById("channelPlaceholder");
  // channelPlaceholder is a SIBLING of channelGrid — NOT inside it.
  // Setting grid.innerHTML never removes it from the DOM, fixing the crash.

  const filterCountEl = document.getElementById("channelFilterCount");
  if (filterCountEl) {
    filterCountEl.textContent =
      allChannels.length > 0 && channels.length !== allChannels.length
        ? `${channels.length} / ${allChannels.length}`
        : channels.length
        ? `${channels.length} channels`
        : "";
  }

  if (!channels.length) {
    grid.innerHTML = "";
    placeholder.classList.remove("d-none");
    return;
  }
  placeholder.classList.add("d-none");

  grid.innerHTML = channels
    .map(
      (ch, i) => `
    <div class="channel-card">
      <div class="channel-logo-wrap">
        ${
          ch.tvg_logo
            ? `<img src="${esc(ch.tvg_logo)}" class="channel-logo" alt=""
                 onerror="this.style.display='none';this.nextElementSibling.style.display='flex'" />
               <div class="channel-logo-fallback" style="display:none"><i class="fas fa-tv"></i></div>`
            : `<div class="channel-logo-fallback"><i class="fas fa-tv"></i></div>`
        }
      </div>
      <div class="channel-name" title="${esc(ch.name)}">${esc(ch.name || ch.url)}</div>
      ${ch.group ? `<div class="channel-group">${esc(ch.group)}</div>` : ""}
      ${ch.playlist_name ? `<div class="channel-playlist-tag" title="${esc(ch.playlist_name)}">${esc(ch.playlist_name)}</div>` : ""}
      <div class="channel-actions">
        <button class="btn btn-sm btn-primary channel-dl-btn" data-ch-idx="${i}" title="Download">
          <i class="fas fa-download"></i>
        </button>
        <button class="btn btn-sm btn-outline-info channel-watch-btn" data-ch-idx="${i}" title="Watch online">
          <i class="fas fa-play"></i>
        </button>
      </div>
    </div>`
    )
    .join("");

  // Bind download and watch buttons
  grid.querySelectorAll(".channel-dl-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const idx = parseInt(btn.dataset.chIdx, 10);
      downloadChannel(channels[idx]);
    });
  });
  grid.querySelectorAll(".channel-watch-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const idx = parseInt(btn.dataset.chIdx, 10);
      watchChannel(channels[idx]);
    });
  });
}

async function downloadChannel(ch) {
  try {
    const res = await apiFetch("/api/download", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: ch.url, output_name: ch.name || null, quality: "best", concurrency: 8 }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Failed to start download");

    const taskRes = await apiFetch(`/api/tasks/${data.task_id}`);
    if (taskRes.ok) {
      const task = await taskRes.json();
      addTaskCard(task.id, task.url || "");
      updateTaskCard(task.id, task);
      startPolling(task.id);
    }
    document.getElementById("downloadsList").scrollIntoView({ behavior: "smooth" });
    toast(`Started: ${ch.name || ch.url}`, "success");
  } catch (e) {
    toast(e.message, "danger");
  }
}

function watchChannel(ch) {
  openHLSPlayer(ch.url, ch.name || ch.url);
}

// ── Playlist event listeners ──────────────────────────────────────────────────

// When the select already shows "" (no playlists) clicking won't fire "change"
// because the value hasn't changed. Use mousedown to intercept that case.
document.getElementById("playlistSelect").addEventListener("mousedown", (e) => {
  const sel = document.getElementById("playlistSelect");
  if (sel.value === "") {
    e.preventDefault();
    new bootstrap.Modal(document.getElementById("addPlaylistModal")).show();
  }
});

document.getElementById("playlistSelect").addEventListener("change", (e) => {
  if (e.target.value === "") {
    // Restore previous selection (specific playlist or "__all__"), then open add modal
    const sel = document.getElementById("playlistSelect");
    sel.value = currentPlaylist?.id || (allChannels.length ? "__all__" : "");
    new bootstrap.Modal(document.getElementById("addPlaylistModal")).show();
    return;
  }
  selectPlaylist(e.target.value);
});

document.getElementById("channelSearch").addEventListener("input", () => {
  renderChannels(getFilteredChannels());
});

document.getElementById("groupFilter").addEventListener("change", () => {
  renderChannels(getFilteredChannels());
});

document.getElementById("refreshPlaylistBtn").addEventListener("click", async () => {
  if (!currentPlaylist) return;
  const btn = document.getElementById("refreshPlaylistBtn");
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i>';
  try {
    const res = await apiFetch(`/api/playlists/${currentPlaylist.id}/refresh`, { method: "POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Refresh failed");
    await selectPlaylist(currentPlaylist.id);
    await loadPlaylists();
    toast(`Refreshed: ${data.channel_count} channels`, "success");
  } catch (e) {
    toast(e.message, "danger");
  } finally {
    btn.disabled = !currentPlaylist?.url;
    btn.innerHTML = '<i class="fas fa-sync-alt"></i>';
  }
});

document.getElementById("editPlaylistBtn").addEventListener("click", () => {
  if (!currentPlaylist) return;
  document.getElementById("editPlaylistName").value = currentPlaylist.name || "";
  document.getElementById("editPlaylistUrl").value = currentPlaylist.url || "";
  new bootstrap.Modal(document.getElementById("editPlaylistModal")).show();
});

document.getElementById("saveEditPlaylistBtn").addEventListener("click", async () => {
  if (!currentPlaylist) return;
  const name = document.getElementById("editPlaylistName").value.trim();
  const url = document.getElementById("editPlaylistUrl").value.trim();
  if (!name) {
    toast("Playlist name cannot be empty", "danger");
    return;
  }
  const btn = document.getElementById("saveEditPlaylistBtn");
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Saving...';
  try {
    const res = await apiFetch(`/api/playlists/${currentPlaylist.id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, url }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Edit failed");
    bootstrap.Modal.getInstance(document.getElementById("editPlaylistModal")).hide();
    await loadPlaylists();
    await selectPlaylist(currentPlaylist.id);
    toast("Playlist updated", "success");
  } catch (e) {
    toast(e.message, "danger");
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-save me-1"></i>Save';
  }
});

document.getElementById("deletePlaylistBtn").addEventListener("click", async () => {
  if (!currentPlaylist) return;
  if (!confirm(`Delete playlist "${currentPlaylist.name}"?`)) return;
  const deletedId = currentPlaylist.id;
  try {
    const res = await apiFetch(`/api/playlists/${deletedId}`, { method: "DELETE" });
    if (!res.ok) throw new Error("Delete failed");
    currentPlaylist = null;
    allChannels = [];
    // Refresh dropdown first, then reset the panel — no page reload needed
    await loadPlaylists();
    document.getElementById("playlistSelect").value = "";
    await selectPlaylist("");
    toast("Playlist deleted", "success");
  } catch (e) {
    toast(e.message, "danger");
  }
});

document.getElementById("savePlaylistBtn").addEventListener("click", async () => {
  const name = document.getElementById("newPlaylistName").value.trim();
  const url = document.getElementById("newPlaylistUrl").value.trim();
  const text = document.getElementById("newPlaylistText").value.trim();

  if (!url && !text) {
    toast("Please provide a playlist URL or paste playlist content", "danger");
    return;
  }

  const btn = document.getElementById("savePlaylistBtn");
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Loading...';
  try {
    const res = await apiFetch("/api/playlists", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, url, text }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Failed to add playlist");

    bootstrap.Modal.getInstance(document.getElementById("addPlaylistModal")).hide();
    document.getElementById("newPlaylistName").value = "";
    document.getElementById("newPlaylistUrl").value = "";
    document.getElementById("newPlaylistText").value = "";

    await loadPlaylists();
    document.getElementById("playlistSelect").value = data.id;
    await selectPlaylist(data.id);
    toast(`Playlist added: ${data.channel_count} channels`, "success");
  } catch (e) {
    toast(e.message, "danger");
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-save me-1"></i>Save';
  }
});

// ── All Playlists Editor ──────────────────────────────────────────────────────

let editorGroups = [];
let editorSelectedGroupId = null;
let groupSortable = null;
let channelSortable = null;
let editorDirty = false;

function openAllPlaylistsEditor() {
  editorDirty = false;
  apiFetch("/api/all-playlists")
    .then((r) => r.json())
    .then((data) => {
      editorGroups = data.groups || [];
      editorSelectedGroupId = null;
      renderEditorGroups();
      renderEditorChannels();
      new bootstrap.Modal(document.getElementById("allPlaylistsEditorModal")).show();
    })
    .catch((e) => toast(e.message, "danger"));
}

function renderEditorGroups() {
  const list = document.getElementById("editorGroupList");
  list.innerHTML = editorGroups
    .map(
      (g) => `
    <div class="editor-group-item${g.id === editorSelectedGroupId ? " active" : ""}${g.enabled ? "" : " disabled-item"}"
         data-group-id="${g.id}">
      <span class="drag-handle"><i class="fas fa-grip-vertical"></i></span>
      <span class="editor-item-name" title="${esc(g.name)}">${esc(g.name)}</span>
      <span class="editor-item-badge badge ${g.custom ? "bg-info" : "bg-secondary"}">${g.channels?.length || 0}</span>
      <span class="editor-item-actions">
        <div class="form-check form-switch mb-0">
          <input class="form-check-input editor-group-toggle" type="checkbox" ${g.enabled ? "checked" : ""} data-gid="${g.id}" title="${g.enabled ? "Enabled" : "Disabled"}">
        </div>
        <button class="btn btn-outline-danger btn-xs editor-delete-group-btn" data-gid="${g.id}" ${g.custom ? "" : "disabled"} title="${g.custom ? "Delete group" : "Source groups cannot be deleted"}">
          <i class="fas fa-trash-alt"></i>
        </button>
      </span>
    </div>`
    )
    .join("");

  // Click to select group
  list.querySelectorAll(".editor-group-item").forEach((el) => {
    el.addEventListener("click", (e) => {
      if (e.target.closest(".editor-item-actions")) return;
      editorSelectedGroupId = el.dataset.groupId;
      renderEditorGroups();
      renderEditorChannels();
    });
  });

  // Toggle group enabled
  list.querySelectorAll(".editor-group-toggle").forEach((cb) => {
    cb.addEventListener("change", (e) => {
      e.stopPropagation();
      const g = editorGroups.find((g) => g.id === cb.dataset.gid);
      if (g) {
        g.enabled = cb.checked;
        editorDirty = true;
        renderEditorGroups();
      }
    });
  });

  // Delete custom group
  list.querySelectorAll(".editor-delete-group-btn:not([disabled])").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const gid = btn.dataset.gid;
      const g = editorGroups.find((g) => g.id === gid);
      if (!g?.custom) return;
      if (!confirm(`Delete custom group "${g.name}" and all its channels?`)) return;
      editorGroups = editorGroups.filter((g) => g.id !== gid);
      if (editorSelectedGroupId === gid) editorSelectedGroupId = null;
      editorDirty = true;
      renderEditorGroups();
      renderEditorChannels();
    });
  });

  // Init Sortable for groups
  if (groupSortable) groupSortable.destroy();
  groupSortable = new Sortable(list, {
    handle: ".drag-handle",
    animation: 150,
    ghostClass: "sortable-ghost",
    chosenClass: "sortable-chosen",
    onEnd: () => {
      const newOrder = [...list.querySelectorAll(".editor-group-item")].map((el) => el.dataset.groupId);
      const reordered = newOrder.map((id) => editorGroups.find((g) => g.id === id)).filter(Boolean);
      editorGroups = reordered;
      editorDirty = true;
    },
  });
}

function renderEditorChannels() {
  const list = document.getElementById("editorChannelList");
  const placeholder = document.getElementById("editorChannelPlaceholder");
  const addBtn = document.getElementById("editorAddChannelBtn");
  const countEl = document.getElementById("editorChannelCount");
  const nameEl = document.getElementById("editorSelectedGroupName");

  const group = editorGroups.find((g) => g.id === editorSelectedGroupId);
  if (!group) {
    list.classList.add("d-none");
    placeholder.classList.remove("d-none");
    addBtn.classList.add("d-none");
    countEl.textContent = "0";
    nameEl.textContent = "";
    return;
  }

  placeholder.classList.add("d-none");
  list.classList.remove("d-none");
  addBtn.classList.remove("d-none");
  countEl.textContent = group.channels?.length || 0;
  nameEl.textContent = `— ${group.name}`;

  const channels = group.channels || [];
  list.innerHTML = channels
    .map(
      (ch, i) => `
    <div class="editor-channel-item${ch.enabled ? "" : " disabled-item"}" data-ch-id="${ch.id}" data-ch-idx="${i}">
      <span class="drag-handle"><i class="fas fa-grip-vertical"></i></span>
      ${
        ch.tvg_logo
          ? `<img src="${esc(ch.tvg_logo)}" class="ch-logo" alt="" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">`
          : ""
      }
      <div class="ch-logo-fallback" ${ch.tvg_logo ? 'style="display:none"' : ""}><i class="fas fa-tv"></i></div>
      <div class="flex-grow-1" style="min-width:0">
        <div class="editor-item-name" title="${esc(ch.name)}">${esc(ch.name || ch.url)}</div>
        <div class="editor-channel-url" title="${esc(ch.url)}">${esc(ch.url)}</div>
        ${ch.source_playlist_name ? `<div class="editor-channel-source">${esc(ch.source_playlist_name)}</div>` : ""}
      </div>
      <span class="editor-item-actions">
        <div class="form-check form-switch mb-0">
          <input class="form-check-input editor-ch-toggle" type="checkbox" ${ch.enabled ? "checked" : ""} data-chid="${ch.id}">
        </div>
        ${ch.custom ? `<button class="btn btn-outline-secondary btn-xs editor-edit-ch-btn" data-chid="${ch.id}" title="Edit"><i class="fas fa-pencil-alt"></i></button>` : ""}
        <button class="btn btn-outline-danger btn-xs editor-delete-ch-btn" data-chid="${ch.id}" ${ch.custom ? "" : "disabled"} title="${ch.custom ? "Delete" : "Source channels cannot be deleted"}">
          <i class="fas fa-trash-alt"></i>
        </button>
      </span>
    </div>`
    )
    .join("");

  // Toggle channel enabled
  list.querySelectorAll(".editor-ch-toggle").forEach((cb) => {
    cb.addEventListener("change", (e) => {
      e.stopPropagation();
      const ch = channels.find((c) => c.id === cb.dataset.chid);
      if (ch) {
        ch.enabled = cb.checked;
        editorDirty = true;
        renderEditorChannels();
      }
    });
  });

  // Edit custom channel
  list.querySelectorAll(".editor-edit-ch-btn").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const ch = channels.find((c) => c.id === btn.dataset.chid);
      if (!ch) return;
      document.getElementById("editChannelNameInput").value = ch.name || "";
      document.getElementById("editChannelUrlInput").value = ch.url || "";
      document.getElementById("editChannelLogoInput").value = ch.tvg_logo || "";
      document.getElementById("editChannelIdInput").value = ch.id;
      new bootstrap.Modal(document.getElementById("editChannelModal")).show();
    });
  });

  // Delete custom channel
  list.querySelectorAll(".editor-delete-ch-btn:not([disabled])").forEach((btn) => {
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const chid = btn.dataset.chid;
      const ch = channels.find((c) => c.id === chid);
      if (!ch?.custom) return;
      group.channels = channels.filter((c) => c.id !== chid);
      editorDirty = true;
      renderEditorChannels();
    });
  });

  // Init Sortable for channels
  if (channelSortable) channelSortable.destroy();
  channelSortable = new Sortable(list, {
    handle: ".drag-handle",
    animation: 150,
    ghostClass: "sortable-ghost",
    chosenClass: "sortable-chosen",
    onEnd: () => {
      const newOrder = [...list.querySelectorAll(".editor-channel-item")].map((el) => el.dataset.chId);
      group.channels = newOrder.map((id) => channels.find((c) => c.id === id)).filter(Boolean);
      editorDirty = true;
    },
  });
}

// Edit All Playlists button
document.getElementById("editAllPlaylistsBtn").addEventListener("click", openAllPlaylistsEditor);

// Refresh All Playlists button (from toolbar, outside editor)
document.getElementById("refreshAllPlaylistsBtn").addEventListener("click", async () => {
  const btn = document.getElementById("refreshAllPlaylistsBtn");
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i>';
  try {
    const res = await apiFetch("/api/all-playlists/refresh", { method: "POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Refresh failed");
    await loadPlaylists();
    await selectPlaylist("__all__");
    let msg = `Refreshed: ${data.total_channels} channels`;
    if (data.errors?.length) msg += ` (${data.errors.length} error(s))`;
    toast(msg, "success");
  } catch (e) {
    toast(e.message, "danger");
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-sync-alt"></i>';
  }
});

// Save editor changes
document.getElementById("editorSaveBtn").addEventListener("click", async () => {
  const btn = document.getElementById("editorSaveBtn");
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Saving...';
  try {
    const res = await apiFetch("/api/all-playlists", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ groups: editorGroups }),
    });
    if (!res.ok) {
      const data = await res.json();
      throw new Error(data.detail || "Save failed");
    }
    editorDirty = false;
    bootstrap.Modal.getInstance(document.getElementById("allPlaylistsEditorModal")).hide();
    toast("All Playlists config saved", "success");
    // Refresh the main channel view
    await selectPlaylist("__all__");
  } catch (e) {
    toast(e.message, "danger");
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-save me-1"></i>Save Changes';
  }
});

// Refresh all (from inside editor)
document.getElementById("editorRefreshAllBtn").addEventListener("click", async () => {
  const btn = document.getElementById("editorRefreshAllBtn");
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Refreshing...';
  try {
    const res = await apiFetch("/api/all-playlists/refresh", { method: "POST" });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Refresh failed");
    // Reload editor data
    const res2 = await apiFetch("/api/all-playlists");
    const data2 = await res2.json();
    editorGroups = data2.groups || [];
    // Try to keep the same group selected
    if (editorSelectedGroupId && !editorGroups.find((g) => g.id === editorSelectedGroupId)) {
      editorSelectedGroupId = null;
    }
    renderEditorGroups();
    renderEditorChannels();
    editorDirty = false;
    let msg = `Refreshed: ${data.total_channels} channels`;
    if (data.errors?.length) msg += ` (${data.errors.length} error(s))`;
    toast(msg, "success");
  } catch (e) {
    toast(e.message, "danger");
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-sync-alt me-1"></i>Refresh All';
  }
});

// Add custom group
document.getElementById("editorAddGroupBtn").addEventListener("click", () => {
  document.getElementById("newGroupNameInput").value = "";
  new bootstrap.Modal(document.getElementById("addGroupModal")).show();
});

document.getElementById("confirmAddGroupBtn").addEventListener("click", () => {
  const name = document.getElementById("newGroupNameInput").value.trim();
  if (!name) { toast("Group name is required", "danger"); return; }
  if (editorGroups.some((g) => g.name === name)) { toast("Group already exists", "danger"); return; }
  editorGroups.push({
    id: "g_" + Math.random().toString(36).slice(2, 10),
    name,
    enabled: true,
    custom: true,
    channels: [],
  });
  editorDirty = true;
  bootstrap.Modal.getInstance(document.getElementById("addGroupModal")).hide();
  renderEditorGroups();
});

// Add custom channel
document.getElementById("editorAddChannelBtn").addEventListener("click", () => {
  document.getElementById("newChannelNameInput").value = "";
  document.getElementById("newChannelUrlInput").value = "";
  document.getElementById("newChannelLogoInput").value = "";
  new bootstrap.Modal(document.getElementById("addChannelModal")).show();
});

document.getElementById("confirmAddChannelBtn").addEventListener("click", () => {
  const name = document.getElementById("newChannelNameInput").value.trim();
  const url = document.getElementById("newChannelUrlInput").value.trim();
  const logo = document.getElementById("newChannelLogoInput").value.trim();
  if (!name || !url) { toast("Name and URL are required", "danger"); return; }
  const group = editorGroups.find((g) => g.id === editorSelectedGroupId);
  if (!group) { toast("No group selected", "danger"); return; }
  if (!group.channels) group.channels = [];
  group.channels.push({
    id: "cc_" + Math.random().toString(36).slice(2, 10),
    name,
    url,
    tvg_id: "",
    tvg_name: "",
    tvg_logo: logo,
    group: group.name,
    enabled: true,
    custom: true,
    source_playlist_id: null,
    source_playlist_name: null,
  });
  editorDirty = true;
  bootstrap.Modal.getInstance(document.getElementById("addChannelModal")).hide();
  renderEditorChannels();
});

// Confirm edit channel
document.getElementById("confirmEditChannelBtn").addEventListener("click", () => {
  const chId = document.getElementById("editChannelIdInput").value;
  const name = document.getElementById("editChannelNameInput").value.trim();
  const url = document.getElementById("editChannelUrlInput").value.trim();
  const logo = document.getElementById("editChannelLogoInput").value.trim();
  if (!name || !url) { toast("Name and URL are required", "danger"); return; }
  for (const g of editorGroups) {
    const ch = (g.channels || []).find((c) => c.id === chId);
    if (ch && ch.custom) {
      ch.name = name;
      ch.url = url;
      ch.tvg_logo = logo;
      editorDirty = true;
      break;
    }
  }
  bootstrap.Modal.getInstance(document.getElementById("editChannelModal")).hide();
  renderEditorChannels();
});

// Warn before closing editor with unsaved changes
document.getElementById("allPlaylistsEditorModal").addEventListener("hide.bs.modal", (e) => {
  if (editorDirty) {
    if (!confirm("You have unsaved changes. Close without saving?")) {
      e.preventDefault();
    }
  }
});

// Load playlists on page load (auto-select first if available)
loadPlaylists({ autoSelect: true });
