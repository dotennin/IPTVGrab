import { apiFetch } from './api';
import { esc, formatBytes, formatDuration, toast } from './utils';
import { Modal } from './bootstrap-shim';
import type { Task } from './types';

export let currentRequest: { url: string; headers: Record<string, string> } = { url: '', headers: {} };
export const taskSockets: Record<string, { ws: WebSocket; stop: () => void }> = {};

document.getElementById('concurrency')?.addEventListener('input', (e) => {
  const val = document.getElementById('concurrencyVal');
  if (val) val.textContent = (e.target as HTMLInputElement).value;
});

let currentCategory = 'all';
let currentSort: { field: string; dir: 'asc' | 'desc' } = { field: 'created_at', dir: 'desc' };
const SORT_DEFAULTS: Record<string, 'asc' | 'desc'> = { created_at: 'desc', filename: 'asc', size: 'desc' };
const ACTIVE_STATUSES   = ['downloading', 'recording', 'merging', 'stopping'];
const WAITING_STATUSES  = ['queued'];
const FINISHED_STATUSES = ['completed', 'failed', 'cancelled', 'interrupted'];

function updateTaskCount(): void {
  const cards = document.querySelectorAll('.task-card');
  let all = 0, active = 0, waiting = 0, finished = 0;
  cards.forEach((c) => {
    all++;
    const s = (c as HTMLElement).dataset.taskStatus || '';
    if      (ACTIVE_STATUSES.includes(s))   active++;
    else if (WAITING_STATUSES.includes(s))  waiting++;
    else if (FINISHED_STATUSES.includes(s)) finished++;
  });
  const taskCountBadge   = document.getElementById('taskCountBadge');
  const catCountAll      = document.getElementById('catCount-all');
  const catCountActive   = document.getElementById('catCount-active');
  const catCountQueued   = document.getElementById('catCount-queued');
  const catCountFinished = document.getElementById('catCount-finished');
  if (taskCountBadge)   taskCountBadge.textContent   = String(all);
  if (catCountAll)      catCountAll.textContent     = String(all);
  if (catCountActive)   catCountActive.textContent  = String(active);
  if (catCountQueued)   catCountQueued.textContent  = String(waiting);
  if (catCountFinished) catCountFinished.textContent = String(finished);
}

function applyCategoryFilter(): void {
  document.querySelectorAll('.task-card').forEach((card) => {
    const el = card as HTMLElement;
    const s = el.dataset.taskStatus || '';
    let show = false;
    switch (currentCategory) {
      case 'all':      show = true; break;
      case 'active':   show = ACTIVE_STATUSES.includes(s); break;
      case 'queued':   show = WAITING_STATUSES.includes(s); break;
      case 'finished': show = FINISHED_STATUSES.includes(s); break;
    }
    el.style.display = show ? '' : 'none';
  });
  const hasVisible = [...document.querySelectorAll('.task-card')].some(
    (c) => (c as HTMLElement).style.display !== 'none',
  );
  const ph = document.getElementById('tasksPlaceholder');
  if (ph) ph.style.display = hasVisible ? 'none' : '';
}

function applySortOrder(): void {
  const list = document.getElementById('downloadsList');
  if (!list) return;
  const cards = [...list.querySelectorAll('.task-card')] as HTMLElement[];
  const { field, dir } = currentSort;
  const sortedCards = [...cards].sort((a, b) => {
    let va: string | number, vb: string | number;
    if (field === 'created_at') {
      va = parseFloat(a.dataset.createdAt || '0') || 0;
      vb = parseFloat(b.dataset.createdAt || '0') || 0;
    } else if (field === 'size') {
      va = parseInt(a.dataset.size || '0') || 0;
      vb = parseInt(b.dataset.size || '0') || 0;
    } else {
      va = (a.dataset.filename || '').toLowerCase();
      vb = (b.dataset.filename || '').toLowerCase();
    }
    if (va < vb) return dir === 'asc' ? -1 : 1;
    if (va > vb) return dir === 'asc' ? 1 : -1;
    return 0;
  });
  if (!sortedCards.some((card, idx) => card !== cards[idx])) return;

  const fragment = document.createDocumentFragment();
  sortedCards.forEach((card) => fragment.appendChild(card));
  list.appendChild(fragment);
}

export function addTaskCard(taskId: string, url: string): void {
  const list = document.getElementById('downloadsList');
  if (!list) return;

  const card = document.createElement('div');
  card.className = 'task-card';
  card.id = `task-${taskId}`;
  card.dataset.taskStatus = 'queued';
  card.dataset.createdAt  = (Date.now() / 1000).toString();
  card.dataset.size       = '0';
  card.dataset.filename   = '';
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
    <div class="d-flex justify-content-between align-items-center task-bottom-row">
      <small class="task-info text-muted">Preparing...</small>
      <div class="d-flex gap-2 align-items-center flex-wrap">
        <button class="btn btn-sm btn-outline-info task-preview d-none" title="Preview downloaded segments">
          <i class="fas fa-play-circle me-1"></i>Preview
        </button>
        <button class="btn btn-sm btn-outline-warning task-clip d-none" title="Clip video segment">
          <i class="fas fa-cut me-1"></i>Clip
        </button>
        <div class="d-flex gap-1 task-recording-extras d-none"></div>
        <button class="btn btn-sm btn-outline-secondary task-pause d-none" data-id="${taskId}" title="Pause — keep segments for later resume">
          <i class="fas fa-pause"></i> Pause
        </button>
        <button class="btn btn-sm btn-outline-danger task-action" data-id="${taskId}">
          <i class="fas fa-times"></i> Cancel
        </button>
      </div>
    </div>`;

  list.appendChild(card);
  card.querySelector('.task-action')?.addEventListener('click', () => cancelTask(taskId));
  card.querySelector('.task-pause')?.addEventListener('click', () => pauseTask(taskId));
  applyCategoryFilter();
  applySortOrder();
  updateTaskCount();
}

const STATUS_MAP: Record<string, { text: string; cls: string }> = {
  queued:      { text: 'Queued',      cls: 'bg-secondary' },
  downloading: { text: 'Downloading', cls: 'bg-primary'   },
  recording:   { text: 'Recording',   cls: 'bg-danger'    },
  stopping:    { text: 'Merging',     cls: 'bg-info'      },
  merging:     { text: 'Merging',     cls: 'bg-info'      },
  completed:   { text: 'Completed',   cls: 'bg-success'   },
  failed:      { text: 'Failed',      cls: 'bg-danger'    },
  cancelled:   { text: 'Cancelled',   cls: 'bg-secondary' },
  interrupted: { text: 'Interrupted', cls: 'bg-warning'   },
  paused:      { text: 'Paused',      cls: 'bg-warning'   },
};

export function updateTaskCard(taskId: string, task: Task): void {
  const card = document.getElementById(`task-${taskId}`) as HTMLElement | null;
  if (!card) return;
  const prevStatus   = card.dataset.taskStatus || '';
  const prevCreatedAt = card.dataset.createdAt || '';
  const prevSize     = card.dataset.size || '';
  const prevFilename = card.dataset.filename || '';

  const { text, cls } = STATUS_MAP[task.status] || { text: task.status, cls: 'bg-secondary' };
  const statusEl = card.querySelector('.task-status') as HTMLElement | null;
  if (statusEl) {
    statusEl.className = `badge ${cls} flex-shrink-0 task-status`;
    statusEl.textContent = text;
  }

  if (task.status !== 'recording') {
    const extras = card.querySelector('.task-recording-extras') as HTMLElement | null;
    if (extras) {
      extras.classList.add('d-none');
      delete extras.dataset.populated;
    }
  }

  const filenameEl = card.querySelector('.task-filename') as HTMLElement | null;
  if (filenameEl) {
    let fname = task.output || null;
    if (!fname && task.output_name) {
      fname = task.output_name.endsWith('.mp4') ? task.output_name : task.output_name + '.mp4';
    }
    if (fname) {
      filenameEl.textContent = '📄 ' + fname;
      filenameEl.classList.remove('d-none');
    } else {
      filenameEl.classList.add('d-none');
    }
  }

  const bar = card.querySelector('.task-bar') as HTMLElement | null;
  if (bar) {
    if (task.status === 'recording') {
      bar.style.width = '100%';
      bar.className = 'progress-bar task-bar bg-danger progress-bar-striped progress-bar-animated';
    } else if (task.status === 'stopping') {
      bar.style.width = '100%';
      bar.className = 'progress-bar task-bar bg-info progress-bar-striped progress-bar-animated';
    } else {
      bar.style.width = `${task.progress || 0}%`;
      bar.className = `progress-bar task-bar${task.status === 'failed' ? ' bg-danger' : ''}`;
    }
  }

  const info = card.querySelector('.task-info') as HTMLElement | null;
  if (info) {
    const infoStatus = info.dataset.status || '';
    if (task.status === 'recording') {
      if (infoStatus !== 'recording' || !info.querySelector('.task-recording-time')) {
        info.className = 'task-info small';
        info.innerHTML = `
          <span class="text-danger fw-semibold">
            <i class="fas fa-circle fa-beat me-1" style="font-size:.6em"></i><span class="task-recording-time"></span>
          </span>
          <span class="task-recording-segments ms-2"></span>
          <span class="task-recording-bytes ms-2"></span>
          <span class="task-recording-speed ms-2 text-muted"></span>`;
        info.dataset.status = 'recording';
      }
      const elapsed = task.elapsed_sec || 0;
      const mm = String(Math.floor(elapsed / 60)).padStart(2, '0');
      const ss = String(elapsed % 60).padStart(2, '0');
      const rtEl = info.querySelector('.task-recording-time');
      if (rtEl) rtEl.textContent = `${mm}:${ss}`;
      const rsEl = info.querySelector('.task-recording-segments');
      if (rsEl) rsEl.textContent = `${task.recorded_segments || 0} segs`;
      const rbEl = info.querySelector('.task-recording-bytes');
      if (rbEl) rbEl.textContent = formatBytes(task.bytes_downloaded);
      const rspEl = info.querySelector('.task-recording-speed');
      if (rspEl) rspEl.textContent = `${task.speed_mbps || 0} MB/s`;
    } else if (task.status === 'downloading') {
      if (infoStatus !== 'downloading' || !info.querySelector('.task-download-progress')) {
        info.className = 'task-info small';
        info.innerHTML = `
          <span class="task-download-progress"></span>
          <span class="task-download-speed ms-2 text-primary"></span>
          <span class="task-download-bytes ms-2"></span>`;
        info.dataset.status = 'downloading';
      }
      const dpEl = info.querySelector('.task-download-progress');
      if (dpEl) dpEl.textContent = `${task.downloaded || 0} / ${task.total || 0} segs`;
      const dsEl = info.querySelector('.task-download-speed');
      if (dsEl) dsEl.textContent = `${task.speed_mbps || 0} MB/s`;
      const dbEl = info.querySelector('.task-download-bytes');
      if (dbEl) dbEl.textContent = formatBytes(task.bytes_downloaded);
    } else if (infoStatus !== task.status) {
      info.dataset.status = task.status;
      if (task.status === 'stopping') {
        info.innerHTML = '<i class="fas fa-cog fa-spin me-1"></i>Merging recorded segments...';
        info.className = 'task-info small text-info';
      } else if (task.status === 'merging') {
        info.innerHTML = '<i class="fas fa-cog fa-spin me-1"></i>Merging segments...';
        info.className = 'task-info small text-info';
      } else if (task.status === 'completed' && task.output) {
        const sizeStr = task.size ? ` (${formatBytes(task.size)})` : '';
        info.innerHTML = `
          <a href="/downloads/${esc(task.output)}" download
             class="btn btn-sm btn-success">
            <i class="fas fa-download me-1"></i>${esc(task.output)}${sizeStr}
          </a>
          ${task.duration_sec ? `<span class="ms-2 text-muted small">${task.duration_sec}s elapsed</span>` : ''}
          <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="window.restartTask('${taskId}')">
            <i class="fas fa-redo me-1"></i>Restart
          </button>`;
      } else if (task.status === 'failed') {
        info.innerHTML = `
          <div class="task-error text-danger" title="Click to expand/collapse" onclick="this.classList.toggle('expanded')">Error: ${esc(task.error || 'Unknown error')}</div>
          <div class="mt-1">
            <button class="btn btn-link btn-sm p-0 text-warning" onclick="window.resumeTask('${taskId}')">
              <i class="fas fa-play me-1"></i>Resume
            </button>
            <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="window.restartTask('${taskId}')">
              <i class="fas fa-sync me-1"></i>Restart
            </button>
          </div>`;
        info.className = 'task-info small';
      } else if (task.status === 'cancelled') {
        info.innerHTML = `<span class="text-muted">Cancelled</span>
          <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="window.restartTask('${taskId}')">
            <i class="fas fa-redo me-1"></i>Restart
          </button>`;
        info.className = 'task-info small';
      } else if (task.status === 'interrupted') {
        info.innerHTML = `<span class="text-warning"><i class="fas fa-exclamation-triangle me-1"></i>Interrupted</span>
          <button class="btn btn-link btn-sm p-0 ms-2 text-warning" onclick="window.resumeTask('${taskId}')">
            <i class="fas fa-redo me-1"></i>Resume
          </button>
          <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="window.restartTask('${taskId}')">
            <i class="fas fa-sync me-1"></i>Restart
          </button>`;
        info.className = 'task-info small';
      } else if (task.status === 'paused') {
        const segs  = task.downloaded || task.recorded_segments || 0;
        const total = task.total || 0;
        const pct   = total > 0 ? ` (${task.progress || 0}%)` : '';
        info.innerHTML = `
          <span class="text-warning"><i class="fas fa-pause me-1"></i>Paused${pct}${segs ? ` — ${segs}${total ? '/' + total : ''} segs saved` : ''}</span>
          <button class="btn btn-link btn-sm p-0 ms-2 text-warning" onclick="window.resumeTask('${taskId}')">
            <i class="fas fa-play me-1"></i>Resume
          </button>
          <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="window.restartTask('${taskId}')">
            <i class="fas fa-sync me-1"></i>Restart
          </button>`;
        info.className = 'task-info small';
      } else {
        info.className = 'task-info small text-muted';
        info.textContent = 'Preparing...';
      }
    }
  }

  const previewBtn = card.querySelector('.task-preview') as HTMLElement | null;
  if (previewBtn) {
    const canLive   = !!(task.tmpdir && ((task.downloaded ?? 0) >= 5 || (task.recorded_segments ?? 0) >= 5));
    const canDirect = task.status === 'completed' && !!task.output;
    if (canLive || canDirect) {
      previewBtn.classList.remove('d-none');
      if (canDirect) {
        previewBtn.dataset.outputUrl = `/downloads/${task.output}`;
      } else {
        delete previewBtn.dataset.outputUrl;
      }
      if (!previewBtn.dataset.listenerAdded) {
        previewBtn.dataset.listenerAdded = '1';
        previewBtn.addEventListener('click', () => {
          if (previewBtn.dataset.outputUrl) {
            openPreviewDirect(previewBtn.dataset.outputUrl, taskId);
          } else {
            openPreview(taskId);
          }
        });
      }
    }
  }

  const clipBtn = card.querySelector('.task-clip') as HTMLElement | null;
  if (clipBtn) {
    const canLive   = !!(task.tmpdir && ((task.downloaded ?? 0) >= 5 || (task.recorded_segments ?? 0) >= 5));
    const canDirect = task.status === 'completed' && !!task.output;
    if (canLive || canDirect) {
      clipBtn.classList.remove('d-none');
      if (canDirect) {
        clipBtn.dataset.outputUrl = `/downloads/${task.output}`;
      } else {
        delete clipBtn.dataset.outputUrl;
      }
      if (!clipBtn.dataset.listenerAdded) {
        clipBtn.dataset.listenerAdded = '1';
        clipBtn.addEventListener('click', () => {
          openClipMode(taskId, clipBtn.dataset.outputUrl || null);
        });
      }
    }
  }

  const pauseBtn = card.querySelector('.task-pause') as HTMLElement | null;
  if (pauseBtn) {
    const pausable = ['downloading', 'recording', 'queued'].includes(task.status);
    pauseBtn.classList.toggle('d-none', !pausable);
  }

  if (task.status === 'recording') {
    const btn = card.querySelector('.task-action') as HTMLElement | null;
    if (btn && btn.dataset.mode !== 'stop') {
      btn.innerHTML = '<i class="fas fa-stop me-1"></i>Stop';
      btn.className = 'btn btn-sm btn-danger task-action';
      btn.dataset.mode = 'stop';
    }
    const extras = card.querySelector('.task-recording-extras') as HTMLElement | null;
    if (extras && !extras.dataset.populated) {
      extras.classList.remove('d-none');
      extras.innerHTML = `
        <button class="btn btn-sm btn-outline-warning"
                title="Delete all recorded segments and start fresh"
                onclick="window.restartRecording('${taskId}')">
          <i class="fas fa-redo me-1"></i>Restart
        </button>
        <button class="btn btn-sm btn-outline-info"
                title="Keep &amp; merge current segments, then start a new recording"
                onclick="window.forkRecording('${taskId}')">
          <i class="fas fa-code-branch me-1"></i>Stop &amp; New
        </button>`;
      extras.dataset.populated = '1';
    }
  } else if (task.status === 'stopping') {
    const btn = card.querySelector('.task-action') as HTMLButtonElement | null;
    if (btn) {
      btn.disabled = true;
      btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Merging';
      btn.className = 'btn btn-sm btn-secondary task-action';
    }
  } else if (['completed', 'failed', 'cancelled', 'interrupted', 'paused'].includes(task.status)) {
    const btn = card.querySelector('.task-action') as HTMLElement | null;
    if (btn && btn.dataset.mode !== 'trash') {
      btn.innerHTML = '<i class="fas fa-trash"></i>';
      btn.className = 'btn btn-sm btn-outline-secondary task-action';
      btn.dataset.mode = 'trash';
      (btn as HTMLButtonElement).disabled = false;
      const newBtn = btn.cloneNode(true) as HTMLElement;
      btn.replaceWith(newBtn);
      newBtn.addEventListener('click', async () => {
        await apiFetch(`/api/tasks/${taskId}`, { method: 'DELETE' }).catch(() => {});
        card.remove();
        applyCategoryFilter();
        updateTaskCount();
      });
    }
  }

  card.dataset.taskStatus = task.status;
  if (task.created_at) card.dataset.createdAt = String(task.created_at);
  card.dataset.size = task.size ? String(task.size) : '0';
  const _fn = task.output || (task.output_name
    ? (task.output_name.endsWith('.mp4') ? task.output_name : task.output_name + '.mp4')
    : '');
  card.dataset.filename = _fn;

  const sortKeyChanged =
    (currentSort.field === 'created_at' && prevCreatedAt !== (card.dataset.createdAt || '')) ||
    (currentSort.field === 'size' && prevSize !== card.dataset.size) ||
    (currentSort.field === 'filename' && prevFilename !== card.dataset.filename);
  const statusChanged = prevStatus !== task.status;

  if (statusChanged) applyCategoryFilter();
  if (sortKeyChanged) applySortOrder();
  if (statusChanged) updateTaskCount();
}

const _TERMINAL_STATUSES = ['completed', 'failed', 'cancelled', 'interrupted'];

export function startPolling(taskId: string): void {
  if (taskSockets[taskId]) return;

  let stopped = false;
  let reconnectDelay = 1000;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  function connect(): void {
    if (stopped) return;
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${proto}//${location.host}/ws/tasks/${taskId}`);

    ws.onopen = () => { reconnectDelay = 1000; };

    ws.onmessage = (event) => {
      let task: Task & { type?: string };
      try { task = JSON.parse(event.data as string); } catch { return; }
      if (task.type === 'ping') return;
      updateTaskCard(taskId, task);
      if (_TERMINAL_STATUSES.includes(task.status)) {
        stopped = true;
        taskSockets[taskId]?.ws?.close();
        delete taskSockets[taskId];
        if (task.status === 'completed')
          toast(`${task.output} — completed`, 'success');
        else if (task.status === 'failed')
          toast(`Failed: ${task.error}`, 'danger');
      }
    };

    ws.onclose = () => {
      if (stopped) return;
      const card = document.getElementById(`task-${taskId}`);
      if (!card) { stopped = true; delete taskSockets[taskId]; return; }
      const badge = card.querySelector('.task-status')?.textContent?.toLowerCase() ?? '';
      if (_TERMINAL_STATUSES.some((s) => badge.includes(s))) {
        stopped = true; delete taskSockets[taskId]; return;
      }
      reconnectTimer = setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 30000);
    };

    ws.onerror = () => ws.close();

    taskSockets[taskId] = {
      ws,
      stop() {
        stopped = true;
        if (reconnectTimer) clearTimeout(reconnectTimer);
        ws.close();
        delete taskSockets[taskId];
      },
    };
  }

  connect();
}

export function stopPolling(taskId: string): void {
  taskSockets[taskId]?.stop();
}

export async function cancelTask(taskId: string): Promise<void> {
  let data: { status?: string } = {};
  try {
    const res = await apiFetch(`/api/tasks/${taskId}`, { method: 'DELETE' });
    data = await res.json();
  } catch { /* ignore */ }

  if (data.status === 'stopping') return;

  stopPolling(taskId);
  const card = document.getElementById(`task-${taskId}`) as HTMLElement | null;
  if (card) {
    const statusEl = card.querySelector('.task-status') as HTMLElement | null;
    if (statusEl) {
      statusEl.textContent = 'Cancelled';
      statusEl.className = 'badge bg-secondary flex-shrink-0 task-status';
    }
    card.dataset.taskStatus = 'cancelled';
    const info = card.querySelector('.task-info') as HTMLElement | null;
    if (info) {
      info.className = 'task-info small';
      delete info.dataset.status;
      info.innerHTML = `<span class="text-muted">Cancelled</span>
        <button class="btn btn-link btn-sm p-0 ms-2 text-info" onclick="window.restartTask('${taskId}')">
          <i class="fas fa-redo me-1"></i>Restart
        </button>`;
    }
    const btn = card.querySelector('.task-action') as HTMLElement | null;
    if (btn) {
      btn.innerHTML = '<i class="fas fa-trash"></i>';
      btn.className = 'btn btn-sm btn-outline-secondary task-action';
      btn.dataset.mode = 'trash';
      const newBtn = btn.cloneNode(true) as HTMLElement;
      btn.replaceWith(newBtn);
      newBtn.addEventListener('click', async () => {
        await apiFetch(`/api/tasks/${taskId}`, { method: 'DELETE' }).catch(() => {});
        card.remove();
        applyCategoryFilter();
        updateTaskCount();
      });
    }
    applyCategoryFilter();
    updateTaskCount();
  }
}

document.getElementById('clearCompletedBtn')?.addEventListener('click', async () => {
  const toRemove = Array.from(document.querySelectorAll('.task-card')).filter((card) => {
    const s = (card as HTMLElement).dataset.taskStatus;
    return s === 'failed' || s === 'cancelled' || s === 'interrupted';
  });
  for (const card of toRemove) {
    const taskId = card.id.replace('task-', '');
    await apiFetch(`/api/tasks/${taskId}`, { method: 'DELETE' }).catch(() => {});
    card.remove();
  }
  applyCategoryFilter();
  updateTaskCount();
});

document.querySelectorAll('.dl-cat').forEach((cat) => {
  cat.addEventListener('click', () => {
    currentCategory = (cat as HTMLElement).dataset.cat || 'all';
    document.querySelectorAll('.dl-cat').forEach((c) => c.classList.remove('active'));
    cat.classList.add('active');
    applyCategoryFilter();
    updateTaskCount();
  });
});

document.querySelectorAll('.sort-btn').forEach((btn) => {
  btn.addEventListener('click', () => {
    const field = (btn as HTMLElement).dataset.field || 'created_at';
    if (currentSort.field === field) {
      currentSort.dir = currentSort.dir === 'asc' ? 'desc' : 'asc';
    } else {
      currentSort.field = field;
      currentSort.dir = SORT_DEFAULTS[field] ?? 'desc';
    }
    document.querySelectorAll('.sort-btn').forEach((b) => {
      b.classList.remove('active');
      const icon = b.querySelector('.sort-dir-icon');
      if (icon) icon.className = 'fas fa-arrow-down sort-dir-icon ms-1 d-none';
    });
    btn.classList.add('active');
    const icon = btn.querySelector('.sort-dir-icon');
    if (icon) {
      icon.className = `fas ${currentSort.dir === 'asc' ? 'fa-arrow-up' : 'fa-arrow-down'} sort-dir-icon ms-1`;
    }
    applySortOrder();
  });
});

async function pauseTask(taskId: string): Promise<void> {
  try {
    const res = await apiFetch(`/api/tasks/${taskId}/pause`, { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Pause failed');
    toast('Download paused — segments preserved', 'warning');
  } catch (e) {
    toast((e as Error).message, 'danger');
  }
}

export async function resumeTask(taskId: string): Promise<void> {
  try {
    const res = await apiFetch(`/api/tasks/${taskId}/resume`, { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Resume failed');
    const card = document.getElementById(`task-${taskId}`) as HTMLElement | null;
    if (card) {
      const statusEl = card.querySelector('.task-status') as HTMLElement | null;
      if (statusEl) {
        statusEl.textContent = 'Queued';
        statusEl.className = 'badge bg-secondary flex-shrink-0 task-status';
      }
      const info = card.querySelector('.task-info') as HTMLElement | null;
      if (info) {
        info.className = 'task-info small text-muted';
        info.textContent = 'Preparing...';
        delete info.dataset.status;
      }
      card.dataset.taskStatus = 'queued';
      const btn = card.querySelector('.task-action') as HTMLElement | null;
      if (btn) {
        btn.innerHTML = '<i class="fas fa-times"></i> Cancel';
        btn.className = 'btn btn-sm btn-outline-danger task-action';
        btn.dataset.mode = '';
        (btn as HTMLButtonElement).disabled = false;
        const newBtn = btn.cloneNode(true) as HTMLElement;
        btn.replaceWith(newBtn);
        newBtn.addEventListener('click', () => cancelTask(taskId));
      }
      applyCategoryFilter();
      updateTaskCount();
    }
    startPolling(taskId);
    toast('Resume started', 'info');
  } catch (e) {
    toast((e as Error).message, 'danger');
  }
}

export async function restartTask(taskId: string): Promise<void> {
  try {
    const res = await apiFetch(`/api/tasks/${taskId}/restart`, { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Restart failed');
    const card = document.getElementById(`task-${taskId}`) as HTMLElement | null;
    if (card) {
      const statusEl = card.querySelector('.task-status') as HTMLElement | null;
      if (statusEl) {
        statusEl.textContent = 'Queued';
        statusEl.className = 'badge bg-secondary flex-shrink-0 task-status';
      }
      const info = card.querySelector('.task-info') as HTMLElement | null;
      if (info) {
        info.className = 'task-info small text-muted';
        info.textContent = 'Preparing...';
        delete info.dataset.status;
      }
      card.dataset.taskStatus = 'queued';
      const bar = card.querySelector('.task-bar') as HTMLElement | null;
      if (bar) { bar.style.width = '0%'; bar.textContent = ''; }
      const btn = card.querySelector('.task-action') as HTMLElement | null;
      if (btn) {
        btn.innerHTML = '<i class="fas fa-times"></i> Cancel';
        btn.className = 'btn btn-sm btn-outline-danger task-action';
        btn.dataset.mode = '';
        (btn as HTMLButtonElement).disabled = false;
        const newBtn = btn.cloneNode(true) as HTMLElement;
        btn.replaceWith(newBtn);
        newBtn.addEventListener('click', () => cancelTask(taskId));
      }
      applyCategoryFilter();
      updateTaskCount();
    }
    startPolling(taskId);
    toast('Download restarted', 'info');
  } catch (e) {
    toast((e as Error).message, 'danger');
  }
}

let _restartRecordingTaskId: string | null = null;
let _restartRecordingModal: Modal | null = null;

export function restartRecording(taskId: string): void {
  _restartRecordingTaskId = taskId;
  if (!_restartRecordingModal) {
    const el = document.getElementById('confirmRestartRecordingModal');
    if (el) _restartRecordingModal = new Modal(el);
  }
  _restartRecordingModal?.show();
}

document.getElementById('confirmRestartRecordingBtn')?.addEventListener('click', async () => {
  _restartRecordingModal?.hide();
  const taskId = _restartRecordingTaskId;
  if (!taskId) return;
  try {
    const res = await apiFetch(`/api/tasks/${taskId}/recording-restart`, { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Restart failed');
    stopPolling(taskId);
    document.getElementById(`task-${taskId}`)?.remove();
    addTaskCard(data.new_task_id, data.url);
    startPolling(data.new_task_id);
    toast('Recording restarted', 'info');
  } catch (e) {
    toast((e as Error).message, 'danger');
  }
});

export async function forkRecording(taskId: string): Promise<void> {
  try {
    const res = await apiFetch(`/api/tasks/${taskId}/fork`, { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Fork failed');
    addTaskCard(data.new_task_id, data.url);
    startPolling(data.new_task_id);
    toast('New recording started', 'info');
  } catch (e) {
    toast((e as Error).message, 'danger');
  }
}

// Expose functions called via inline onclick attributes
(window as unknown as Record<string, unknown>).resumeTask = resumeTask;
(window as unknown as Record<string, unknown>).restartTask = restartTask;
(window as unknown as Record<string, unknown>).restartRecording = restartRecording;
(window as unknown as Record<string, unknown>).forkRecording = forkRecording;

// openPreview / openPreviewDirect / openClipMode are defined in player.ts and exposed there
function openPreview(taskId: string): void {
  (window as unknown as Record<string, Function>).openPreview?.(taskId);
}
function openPreviewDirect(url: string, taskId: string | null): void {
  (window as unknown as Record<string, Function>).openPreviewDirect?.(url, taskId);
}
function openClipMode(taskId: string, outputUrl: string | null): void {
  (window as unknown as Record<string, Function>).openClipMode?.(taskId, outputUrl);
}
