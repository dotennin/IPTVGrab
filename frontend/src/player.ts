import Hls from 'hls.js';
import mpegts from 'mpegts.js';
import Plyr from 'plyr';
import 'plyr/dist/plyr.css';
import { apiFetch } from './api';
import { upsertHealthEntry } from './health';
import { esc, formatDuration, toast } from './utils';
import { settings } from './settings';
import { Modal } from './bootstrap-shim';
import { addTaskCard, startPolling, currentRequest } from './tasks';
import type { StreamInfo, Channel } from './types';

export let currentStreamInfo: StreamInfo | null = null;
let _currentPreviewHealthUrl: string | null = null;
let _reportedPreviewInvalid = false;



// ── TV D-pad channel switching ────────────────────────────────────────────────
let _channelList: Channel[] = [];
let _channelIndex = -1;
/** Call this when opening a channel so ArrowUp/Down can zap through the list. */
export function setChannelContext(channels: Channel[], index: number): void {
  _channelList = channels;
  _channelIndex = index;
}

/** Trigger the channel OSD if a channel context is active. */
export function showChOsd(): void {
  if (_channelList.length > 0) _showChOsd();
}

let _chOsdTimer: ReturnType<typeof setTimeout> | null = null;

// ── Stream info panel ─────────────────────────────────────────────────────────
function resetStreamInfo(): void {
  const badge = document.getElementById('streamTypeBadge');
  const body  = document.getElementById('streamInfoBody');
  if (badge) badge.innerHTML = '';
  if (body)  body.innerHTML = `
    <div class="text-center text-muted py-5" id="streamPlaceholder">
      <i class="fas fa-play-circle fa-3x mb-3 d-block opacity-25"></i>
      <p class="mb-0">Stream info will appear here after parsing</p>
    </div>`;
}
void resetStreamInfo;

function showError(msg: string): void {
  const body = document.getElementById('streamInfoBody');
  if (body) body.innerHTML = `
    <div class="alert alert-danger mb-0">
      <i class="fas fa-exclamation-triangle me-2"></i>${esc(msg)}
    </div>`;
}

export function showStreamInfo(info: StreamInfo): void {
  currentStreamInfo = info;
  const badge = document.getElementById('streamTypeBadge');
  const body  = document.getElementById('streamInfoBody');
  if (!badge || !body) return;

  if (info.kind === 'master' && info.streams) {
    badge.innerHTML = `<span class="badge bg-info">Master playlist</span>`;
    let html = `<p class="text-muted small mb-3">
      <i class="fas fa-layer-group me-1"></i>${info.streams.length} quality option(s). Select a stream to download:
    </p>`;
    info.streams.forEach((s, i) => {
      const checked = i === 0 ? 'checked' : '';
      html += `
        <label class="quality-option d-flex align-items-center gap-3 w-100">
          <input type="radio" name="quality" value="${i}" ${checked} class="flex-shrink-0" />
          <div class="flex-grow-1">
            <div class="fw-semibold">${esc(s.label)}</div>
            <div class="text-muted small">
              ${s.resolution ? `${esc(s.resolution)} · ` : ''}
              ${Math.round(s.bandwidth / 1000)} kbps
              ${s.codecs ? ` · ${esc(s.codecs)}` : ''}
            </div>
          </div>
          ${i === 0 ? '<span class="badge bg-success">Best</span>' : ''}
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
          : `<dt>Segments</dt><dd>${info.segments ?? ''}</dd>
             <dt>Duration</dt><dd>${formatDuration(info.duration ?? 0)}</dd>`
        }
        <dt>Encryption</dt>
        <dd>${
          info.encrypted
            ? '<span class="badge bg-warning text-dark">AES-128</span>'
            : '<span class="text-muted">None</span>'
        }</dd>
      </dl>` + downloadButton(isLive);
  }

  body.querySelectorAll('.quality-option').forEach((label) => {
    label.addEventListener('click', () => {
      const radio = label.querySelector('input[type=radio]') as HTMLInputElement | null;
      if (radio) radio.checked = true;
    });
  });

  body.querySelector('#startDownloadBtn')?.addEventListener('click', startDownload);
  body.querySelector('#watchStreamBtn')?.addEventListener('click', () => {
    if (!currentRequest.url) return;
    const label =
      (document.getElementById('outputName') as HTMLInputElement | null)?.value.trim() ||
      currentRequest.url.split('/').pop()?.split('?')[0] || 'Watch';
    const isLive = currentStreamInfo?.is_live === true;
    openHLSPlayer(proxyWatchUrl(currentRequest.url), label, isLive);
  });
}

function downloadButton(isLive = false): string {
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
    ${isLive ? `<p class="text-muted small mt-2 mb-0"><i class="fas fa-info-circle me-1"></i>Merges to MP4 automatically when stopped</p>` : ''}
  </div>`;
}

export async function startDownload(): Promise<void> {
  if (!currentRequest.url) {
    toast('Parse a stream first', 'danger');
    return;
  }

  const outputNameEl  = document.getElementById('outputName') as HTMLInputElement | null;
  const concurrencyEl = document.getElementById('concurrency') as HTMLInputElement | null;
  const outputName    = outputNameEl?.value.trim() || null;
  const concurrency   = parseInt(concurrencyEl?.value || '8', 10);

  let quality = 'best';
  if (currentStreamInfo?.kind === 'master') {
    const sel = document.querySelector('input[name="quality"]:checked') as HTMLInputElement | null;
    if (sel) quality = sel.value;
  }

  const btn = document.getElementById('startDownloadBtn') as HTMLButtonElement | null;
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="fas fa-spinner fa-spin me-2"></i>Submitting...'; }

  try {
    const res = await apiFetch('/api/download', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        url:         currentRequest.url,
        headers:     currentRequest.headers,
        output_name: outputName,
        quality,
        concurrency,
      }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Failed to start download');

    addTaskCard(data.task_id, currentRequest.url);
    startPolling(data.task_id);
    showDownloadsTab();
    toast('Download task added', 'info');
  } catch (e) {
    toast((e as Error).message, 'danger');
  } finally {
    if (btn) {
      btn.disabled = false;
      const isLive = currentStreamInfo?.is_live === true;
      btn.innerHTML = isLive
        ? '<i class="fas fa-circle me-2"></i>Start recording'
        : '<i class="fas fa-download me-2"></i>Start download';
    }
  }
}

// showDownloadsTab is defined in ui.ts and exposed on window
function showDownloadsTab(): void {
  (window as unknown as Record<string, Function>).showDownloadsTab?.();
}

// ── Preview / Watch player (hls.js + mpegts.js) ──────────────────────────────
let hlsInstance: Hls | null = null;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let mpegtsPlayer: any = null;
let _transcodeSessionId: string | null = null;

const previewModalEl    = document.getElementById('previewModal')!;
const previewViewportEl  = document.getElementById('previewViewport')!;
const previewVideo      = document.getElementById('previewVideo') as HTMLVideoElement;
const previewTitleEl    = document.getElementById('previewModalTitle');
const previewModal      = Modal.getOrCreateInstance(previewModalEl)!;
const playerQualityBar    = document.getElementById('playerQualityBar');
const playerQualitySelect = document.getElementById('playerQualitySelect') as HTMLSelectElement | null;

// Plyr wraps the video element and provides polished controls (fullscreen button, etc.).
// fullscreen.container points to #previewViewport so OSD (a sibling inside it) is always
// visible in fullscreen — document.fullscreenElement === previewViewportEl.
const plyrPlayer = new Plyr(previewVideo, {
  controls: ['play', 'progress', 'current-time', 'mute', 'volume', 'settings', 'fullscreen'],
  fullscreen: { enabled: true, fallback: true, iosNative: false, container: '#previewViewport' },
  clickToPlay: true,
  keyboard: { focused: false, global: false },
  hideControls: true,
  invertTime: false,
  toggleInvert: false,
});

function isPreviewVisible(): boolean {
  return previewModalEl.classList.contains('show');
}

function setPreviewTitle(title: string): void {
  if (previewTitleEl) {
    previewTitleEl.innerHTML = `<i class="fas fa-play-circle me-2 text-primary"></i>${title}`;
  }
}

function isPreviewFullscreen(): boolean {
  return plyrPlayer.fullscreen.active
    || (previewVideo as HTMLVideoElement & { webkitDisplayingFullscreen?: boolean }).webkitDisplayingFullscreen === true;
}

function enterPreviewFullscreen(): void {
  plyrPlayer.fullscreen.enter();
}

function exitPreviewFullscreen(): void {
  plyrPlayer.fullscreen.exit();
}

function togglePreviewFullscreen(): void {
  plyrPlayer.fullscreen.toggle();
}

async function closePreviewModal(): Promise<void> {
  if (plyrPlayer.fullscreen.active) plyrPlayer.fullscreen.exit();
  previewModal.hide();
}

previewModalEl.addEventListener('shown.bs.modal', () => {
  previewVideo.focus();
});

document.addEventListener('keydown', (event) => {
  if (!isPreviewVisible() || event.altKey || event.ctrlKey || event.metaKey) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    event.stopImmediatePropagation();
    void closePreviewModal();
    return;
  }
  // D-pad up/down: switch to prev/next channel in the current list
  if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
    if (_channelList.length > 1) {
      event.preventDefault();
      event.stopImmediatePropagation();
      switchChannel(event.key === 'ArrowUp' ? -1 : 1);
      return;
    }
  }
  if (!event.repeat && (event.key === 'f' || event.key === 'F')) {
    event.preventDefault();
    togglePreviewFullscreen();
  }
});

// Show channel OSD on mouse move when in fullscreen
previewViewportEl.addEventListener('mousemove', () => {
  if (isPreviewFullscreen() && _channelList.length > 0) _showChOsd();
});

// Plyr fires these events when fullscreen enters/exits via any path
// (button click, keyboard, programmatic, CSS fallback). OSD visibility is managed here.
// is-fs class drives CSS positioning for both native :fullscreen and Plyr CSS-fallback modes.
plyrPlayer.on('enterfullscreen', () => {
  previewViewportEl.classList.add('is-fs');
  if (_channelList.length > 0) setTimeout(_showChOsd, 200);
});
plyrPlayer.on('exitfullscreen', () => {
  previewViewportEl.classList.remove('is-fs');
  _hideChOsd();
});

// Safari iOS webkit fullscreen events (Plyr iosNative: false, so handle manually)
previewVideo.addEventListener('webkitbeginfullscreen', () => {
  previewViewportEl.classList.add('is-fs');
  if (_channelList.length > 0) setTimeout(_showChOsd, 200);
});
previewVideo.addEventListener('webkitendfullscreen', () => {
  previewViewportEl.classList.remove('is-fs');
  _hideChOsd();
});

function _hidePlayerQuality(): void {
  if (playerQualityBar) playerQualityBar.classList.add('d-none');
  if (playerQualitySelect) playerQualitySelect.innerHTML = '<option value="-1">Auto</option>';
}

function _isFlvUrl(url: string): boolean {
  try {
    return new URL(url).pathname.toLowerCase().endsWith('.flv');
  } catch {
    return url.toLowerCase().split('?')[0].endsWith('.flv');
  }
}
void _isFlvUrl;

function _destroyPlayers(): void {
  if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
  if (mpegtsPlayer) { try { mpegtsPlayer.destroy(); } catch { /* ignore */ } mpegtsPlayer = null; }
}

function _originalUrl(url: string): string {
  if (url.startsWith('/api/watch/proxy?')) {
    try {
      return new URLSearchParams(url.slice('/api/watch/proxy?'.length)).get('url') || url;
    } catch { /* fall through */ }
  }
  return url;
}

async function _markCurrentPreviewInvalid(): Promise<void> {
  const url = _currentPreviewHealthUrl;
  if (!url || _reportedPreviewInvalid) return;
  _reportedPreviewInvalid = true;
  upsertHealthEntry(url, { status: 'invalid', checked_at: Date.now() / 1000 });
  try {
    await apiFetch('/api/health-check/invalid', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url }),
    });
  } catch (error) {
    console.warn('failed to persist invalid health state', error);
  }
}

function _stopTranscodeSession(): void {
  if (_transcodeSessionId) {
    const id = _transcodeSessionId;
    _transcodeSessionId = null;
    fetch(`/api/watch/transcode/${id}`, { method: 'DELETE' }).catch(() => {});
  }
}

function _setupPlayerQuality(): void {
  if (!hlsInstance || !playerQualityBar || !playerQualitySelect) return;
  const levels = hlsInstance.levels;
  if (!levels || levels.length <= 1) return;
  let opts = '<option value="-1">Auto</option>';
  levels.forEach((lvl, i) => {
    const res = lvl.height ? `${lvl.height}p` : '';
    const bw  = lvl.bitrate ? ` · ${Math.round(lvl.bitrate / 1000)} kbps` : '';
    opts += `<option value="${i}">${res ? res + bw : `Level ${i + 1}${bw}`}</option>`;
  });
  playerQualitySelect.innerHTML = opts;
  playerQualitySelect.value = '-1';
  playerQualityBar.classList.remove('d-none');
}

playerQualitySelect?.addEventListener('change', () => {
  if (!hlsInstance || !playerQualitySelect) return;
  const val = parseInt(playerQualitySelect.value, 10);
  hlsInstance.currentLevel = val;
  if (val === -1) {
    const autoOpt = playerQualitySelect.querySelector('option[value="-1"]');
    if (autoOpt) autoOpt.textContent = 'Auto';
  }
});

export async function openHLSPlayer(url: string, title = '', isLive = false): Promise<void> {
  setPreviewTitle(title ? esc(title) : 'Watch');
  _currentPreviewTaskId = null;
  _currentPreviewHealthUrl = _originalUrl(url);
  _reportedPreviewInvalid = false;
  if (clipToggleBar) clipToggleBar.classList.add('d-none');
  _hidePlayerQuality();
  _destroyPlayers();
  _stopTranscodeSession();
  previewVideo.pause();
  previewVideo.removeAttribute('src');
  previewModal.show();

  let isFLV = false;
  let probeResult: { kind?: string; final_url?: string } | null = null;
  try {
    const probeUrl = '/api/watch/probe?url=' + encodeURIComponent(_originalUrl(url));
    probeResult = await fetch(probeUrl, { signal: AbortSignal.timeout(5000) })
      .then((r) => (r.ok ? r.json() : null))
      .catch(() => null);
    isFLV = probeResult?.kind === 'flv';
  } catch { /* probe timed out */ }

  if (isFLV && probeResult?.final_url) {
    _loadMpegtsPlayer(probeResult.final_url, isLive);
  } else {
    _loadHlsPlayer(url, isLive);
  }
}

function _loadMpegtsPlayer(url: string, isLive = false): void {
  if (!mpegts.isSupported()) {
    toast('FLV playback not supported in this browser', 'danger');
    return;
  }
  (mpegts.LoggingControl as unknown as Record<string, boolean>).enableAll = false;
  (mpegts.LoggingControl as unknown as Record<string, boolean>).enableError = true;

  let _reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  function _createInstance(): void {
    if (!isPreviewVisible()) return;
    if (mpegtsPlayer) {
      try { mpegtsPlayer.destroy(); } catch { /* ignore */ }
      mpegtsPlayer = null;
    }
    if (_reconnectTimer) { clearTimeout(_reconnectTimer); _reconnectTimer = null; }

    mpegtsPlayer = mpegts.createPlayer(
      { type: 'flv', isLive, url },
      { enableWorker: false, enableStashBuffer: true, stashInitialSize: 128 * 1024, lazyLoadMaxDuration: 3 * 60 },
    );
    mpegtsPlayer.attachMediaElement(previewVideo);
    mpegtsPlayer.load();
    previewVideo.play().catch(() => {});

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    mpegtsPlayer.on((mpegts.Events as any).ERROR, (errorType: string, errorDetail: string, errorInfo: { msg?: string }) => {
      const isEarlyEof = errorDetail === 'NetworkUnrecoverableEarlyEof';
      if (isLive && isEarlyEof) {
        _reconnectTimer = setTimeout(_createInstance, 1000);
      } else {
        void _markCurrentPreviewInvalid();
        const msg = (errorInfo && errorInfo.msg) || errorDetail || errorType || 'unknown';
        toast('Stream error: ' + msg, 'danger');
      }
    });
  }

  _createInstance();
}

function _loadHlsPlayer(url: string, isLive = false): void {
  void isLive;
  if (Hls.isSupported()) {
    hlsInstance = new Hls({ enableWorker: false, liveSyncDurationCount: 3 });
    hlsInstance.loadSource(url);
    hlsInstance.attachMedia(previewVideo);
    hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => {
      previewVideo.play().catch(() => {});
      _setupPlayerQuality();
    });
    hlsInstance.on(Hls.Events.LEVEL_SWITCHED, (_evt, data) => {
      if (!hlsInstance || !playerQualitySelect) return;
      if (hlsInstance.autoLevelEnabled) {
        const autoOpt = playerQualitySelect.querySelector('option[value="-1"]');
        if (autoOpt && hlsInstance.levels[data.level]) {
          const lvl = hlsInstance.levels[data.level];
          const res = lvl.height ? `${lvl.height}p` : `Level ${data.level + 1}`;
          autoOpt.textContent = `Auto (${res})`;
        }
      } else {
        playerQualitySelect.value = String(data.level);
      }
    });
    hlsInstance.on(Hls.Events.ERROR, (_evt, data) => {
      if (!data.fatal) return;
      void _markCurrentPreviewInvalid();
      toast('Stream error: ' + (data.details || 'unknown'), 'danger');
    });
  } else if (previewVideo.canPlayType('application/vnd.apple.mpegurl')) {
    previewVideo.src = url;
    previewVideo.play().catch(() => {});
  } else {
    toast('HLS playback not supported in this browser', 'danger');
  }
}

export function openPreviewDirect(url: string, taskId: string | null = null): void {
  setPreviewTitle('Preview');
  _currentPreviewTaskId = taskId;
  _currentPreviewHealthUrl = null;
  _reportedPreviewInvalid = false;
  if (clipToggleBar) clipToggleBar.classList.toggle('d-none', !taskId);
  _hidePlayerQuality();
  if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
  previewVideo.pause();
  previewVideo.src = url;
  previewModal.show();
  previewVideo.play().catch(() => {});
}

export function openPreview(taskId: string): void {
  setPreviewTitle('Preview');
  _currentPreviewTaskId = taskId;
  _currentPreviewHealthUrl = null;
  _reportedPreviewInvalid = false;
  if (clipToggleBar) clipToggleBar.classList.toggle('d-none', !taskId);
  _hidePlayerQuality();
  if (hlsInstance) { hlsInstance.destroy(); hlsInstance = null; }
  previewVideo.pause();
  previewVideo.removeAttribute('src');

  const src = `/api/tasks/${taskId}/preview.m3u8`;
  if (Hls.isSupported()) {
    hlsInstance = new Hls({ enableWorker: false });
    hlsInstance.loadSource(src);
    hlsInstance.attachMedia(previewVideo);
    hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => previewVideo.play().catch(() => {}));
  } else if (previewVideo.canPlayType('application/vnd.apple.mpegurl')) {
    previewVideo.src = src;
    previewVideo.play().catch(() => {});
  } else {
    toast('HLS preview requires Chrome with hls.js loaded', 'danger');
    return;
  }
  previewModal.show();
}

previewModalEl.addEventListener('hidden.bs.modal', () => {
  setPreviewTitle('Preview');
  _hidePlayerQuality();
  _destroyPlayers();
  _stopTranscodeSession();
  previewVideo.pause();
  previewVideo.removeAttribute('src');
  previewVideo.load();
  deactivateClipMode();
  _currentPreviewTaskId = null;
  _currentPreviewHealthUrl = null;
  _reportedPreviewInvalid = false;
  // Reset TV channel context
  _channelList = [];
  _channelIndex = -1;
  _hideChOsd();
});

previewVideo.addEventListener('error', () => {
  if (!isPreviewVisible() || !_currentPreviewHealthUrl || _reportedPreviewInvalid) return;
  if (previewVideo.error?.code === 1) return;
  void _markCurrentPreviewInvalid();
  toast('Stream error: media playback failed', 'danger');
});

// ── Channel D-pad switching ────────────────────────────────────────────────────
const _chOsdEl       = document.getElementById('chOsd');
const _chOsdName     = document.getElementById('chOsdName');
const _chOsdIndex    = document.getElementById('chOsdIndex');
const _chOsdPrevName = document.getElementById('chOsdPrevName');
const _chOsdNextName = document.getElementById('chOsdNextName');
const _chOsdPrevBtn  = document.getElementById('chOsdPrevBtn');
const _chOsdNextBtn  = document.getElementById('chOsdNextBtn');
const _chOsdCurLogo  = document.getElementById('chOsdCurLogo')  as HTMLImageElement | null;
const _chOsdPrevLogo = document.getElementById('chOsdPrevLogo') as HTMLImageElement | null;
const _chOsdNextLogo = document.getElementById('chOsdNextLogo') as HTMLImageElement | null;

_chOsdPrevBtn?.addEventListener('click', () => switchChannel(-1));
_chOsdNextBtn?.addEventListener('click', () => switchChannel(1));

// Double-click anywhere on the viewport (not on OSD nav buttons) toggles fullscreen
previewViewportEl.addEventListener('dblclick', (e: MouseEvent) => {
  if ((e.target as HTMLElement).closest('.ch-osd-btn')) return;
  togglePreviewFullscreen();
});

// Pause auto-hide while the cursor is inside the OSD pill
_chOsdEl?.addEventListener('mouseenter', () => {
  if (_chOsdTimer) { clearTimeout(_chOsdTimer); _chOsdTimer = null; }
});
_chOsdEl?.addEventListener('mouseleave', () => {
  if (_chOsdEl?.classList.contains('ch-osd-visible')) {
    _chOsdTimer = setTimeout(_hideChOsd, 2000);
  }
});

function _setOsdLogo(img: HTMLImageElement | null, src: string | null | undefined): void {
  if (!img) return;
  if (src) {
    img.src = src;
    img.style.display = '';
    img.onerror = () => { img.style.display = 'none'; };
  } else {
    img.style.display = 'none';
    img.src = '';
  }
}

function _showChOsd(): void {
  if (!_chOsdEl || !_chOsdName || !_chOsdIndex) return;
  const ch     = _channelList[_channelIndex];
  const prevCh = _channelList[_channelIndex - 1];
  const nextCh = _channelList[_channelIndex + 1];

  _chOsdName.textContent  = ch?.name || ch?.url || '';
  _chOsdIndex.textContent = `${_channelIndex + 1} / ${_channelList.length}`;
  if (_chOsdPrevName) _chOsdPrevName.textContent = prevCh?.name || '';
  if (_chOsdNextName) _chOsdNextName.textContent = nextCh?.name  || '';

  // Populate channel logos
  _setOsdLogo(_chOsdCurLogo,  ch?.tvg_logo     || ch?.logo     || null);
  _setOsdLogo(_chOsdPrevLogo, prevCh?.tvg_logo  || prevCh?.logo || null);
  _setOsdLogo(_chOsdNextLogo, nextCh?.tvg_logo  || nextCh?.logo || null);

  // Show/dim prev-next buttons at list boundaries
  if (_chOsdPrevBtn) (_chOsdPrevBtn as HTMLButtonElement).disabled = _channelIndex <= 0;
  if (_chOsdNextBtn) (_chOsdNextBtn as HTMLButtonElement).disabled = _channelIndex >= _channelList.length - 1;

  _chOsdEl.classList.add('ch-osd-visible');
  if (_chOsdTimer) clearTimeout(_chOsdTimer);
  _chOsdTimer = setTimeout(_hideChOsd, 4000);
}

function _hideChOsd(): void {
  _chOsdEl?.classList.remove('ch-osd-visible');
  if (_chOsdTimer) { clearTimeout(_chOsdTimer); _chOsdTimer = null; }
}

function switchChannel(delta: number): void {
  const next = _channelIndex + delta;
  if (next < 0 || next >= _channelList.length) return;
  _channelIndex = next;
  const ch = _channelList[_channelIndex];
  _showChOsd();
  // Load the new stream — modal stays open, fullscreen state preserved
  const wasFullscreen = isPreviewFullscreen();
  void openHLSPlayer(ch.url, ch.name || ch.url, true).then(() => {
    if (wasFullscreen && !isPreviewFullscreen()) enterPreviewFullscreen();
  });
}

// ── Clip mode ─────────────────────────────────────────────────────────────────
let _currentPreviewTaskId: string | null = null;
let _clipTaskId: string | null = null;
let _clipMode = false;

const clipToolbar       = document.getElementById('clipToolbar');
const clipToggleBar     = document.getElementById('clipToggleBar');
const toggleClipBtn     = document.getElementById('toggleClipBtn');
const clipStartInput    = document.getElementById('clipStart') as HTMLInputElement | null;
const clipEndInput      = document.getElementById('clipEnd') as HTMLInputElement | null;
const clipSelection     = document.getElementById('clipSelection');
const clipStartLabel    = document.getElementById('clipStartLabel');
const clipEndLabel      = document.getElementById('clipEndLabel');
const clipDurationLabel = document.getElementById('clipDurationLabel');
const clipDownloadBtn   = document.getElementById('clipDownloadBtn') as HTMLButtonElement | null;
const clipCancelBtn     = document.getElementById('clipCancelBtn');

function deactivateClipMode(): void {
  _clipMode   = false;
  _clipTaskId = null;
  if (clipToolbar)   clipToolbar.classList.add('d-none');
  if (clipToggleBar) clipToggleBar.classList.toggle('d-none', !_currentPreviewTaskId);
}

function _activateClipUI(): void {
  if (clipToolbar)   clipToolbar.classList.remove('d-none');
  if (clipToggleBar) clipToggleBar.classList.add('d-none');
}

function initClipSlider(): void {
  let duration = previewVideo.duration;
  if (!isFinite(duration) || duration <= 0) duration = 3600;
  const maxVal = String(Math.round(duration * 10) / 10);
  if (clipStartInput) { clipStartInput.max = maxVal; clipStartInput.value = '0'; }
  if (clipEndInput)   { clipEndInput.max = maxVal;   clipEndInput.value = maxVal; }
  updateClipUI();
}

function updateClipUI(): void {
  if (!clipStartInput || !clipEndInput) return;
  const start = parseFloat(clipStartInput.value);
  const end   = parseFloat(clipEndInput.value);
  const max   = parseFloat(clipStartInput.max) || 1;
  if (clipStartLabel)    clipStartLabel.textContent    = formatDuration(start);
  if (clipEndLabel)      clipEndLabel.textContent      = formatDuration(end);
  if (clipDurationLabel) clipDurationLabel.textContent = `Clip: ${formatDuration(end - start)}`;
  if (clipSelection) {
    (clipSelection as HTMLElement).style.left  = `${(start / max) * 100}%`;
    (clipSelection as HTMLElement).style.width = `${((end - start) / max) * 100}%`;
  }
}

export function openClipMode(taskId: string, outputUrl: string | null = null): void {
  _clipTaskId = taskId;
  _clipMode   = true;
  if (!isPreviewVisible()) {
    if (outputUrl) {
      openPreviewDirect(outputUrl, taskId);
    } else {
      openPreview(taskId);
    }
  }
  _activateClipUI();
  if (previewVideo.readyState >= 1 && isFinite(previewVideo.duration)) {
    initClipSlider();
  } else {
    previewVideo.addEventListener('loadedmetadata', initClipSlider, { once: true });
  }
}
void _clipMode;

function _pauseForScrub(): void {
  if (!previewVideo.paused) previewVideo.pause();
}
clipStartInput?.addEventListener('pointerdown', _pauseForScrub);
clipEndInput?.addEventListener('pointerdown',   _pauseForScrub);

clipStartInput?.addEventListener('input', () => {
  if (!clipStartInput || !clipEndInput) return;
  let start = parseFloat(clipStartInput.value);
  const end = parseFloat(clipEndInput.value);
  if (start >= end - 0.5) {
    start = Math.max(0, end - 0.5);
    clipStartInput.value = String(start);
  }
  previewVideo.currentTime = start;
  updateClipUI();
});

clipEndInput?.addEventListener('input', () => {
  if (!clipStartInput || !clipEndInput) return;
  const start = parseFloat(clipStartInput.value);
  let end = parseFloat(clipEndInput.value);
  if (end <= start + 0.5) {
    end = Math.min(parseFloat(clipEndInput.max), start + 0.5);
    clipEndInput.value = String(end);
  }
  previewVideo.currentTime = end;
  updateClipUI();
});

clipCancelBtn?.addEventListener('click', deactivateClipMode);

toggleClipBtn?.addEventListener('click', () => {
  _clipTaskId = _currentPreviewTaskId;
  _clipMode   = true;
  _activateClipUI();
  if (previewVideo.readyState >= 1 && isFinite(previewVideo.duration)) {
    initClipSlider();
  } else {
    previewVideo.addEventListener('loadedmetadata', initClipSlider, { once: true });
  }
});

clipDownloadBtn?.addEventListener('click', async () => {
  if (!_clipTaskId || !clipStartInput || !clipEndInput) return;
  const start = parseFloat(clipStartInput.value);
  const end   = parseFloat(clipEndInput.value);
  clipDownloadBtn.disabled = true;
  clipDownloadBtn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Starting…';
  try {
    const res = await apiFetch(`/api/tasks/${_clipTaskId}/clip`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ start, end }),
    });
    const d = await res.json();
    if (!res.ok) throw new Error(d.detail || 'Clip failed');
    // Async response: clip task is running in background
    toast(`✂ Clipping started — check the Tasks tab`, 'success');
    // Exit clip mode and navigate to Tasks tab
    document.getElementById('clipOverlay')?.classList.add('d-none');
    document.getElementById('clipToolbar')?.classList.add('d-none');
    _clipTaskId = null;
    showDownloadsTab();
    // Create a card for the clip task and start polling for status updates
    if (d.clip_task_id) {
      addTaskCard(d.clip_task_id, `✂ ${d.filename || 'clip'}`);
      startPolling(d.clip_task_id);
    }
  } catch (e) {
    toast((e as Error).message, 'danger');
    clipDownloadBtn.disabled = false;
    clipDownloadBtn.innerHTML = '<i class="fas fa-cut me-1"></i>Clip & Save';
  }
});

export function proxyWatchUrl(url: string): string {
  if (!settings.useProxy) return url;
  return '/api/watch/proxy?url=' + encodeURIComponent(url);
}

// Expose functions used via window in other modules
(window as unknown as Record<string, unknown>).openPreview = openPreview;
(window as unknown as Record<string, unknown>).openPreviewDirect = openPreviewDirect;
(window as unknown as Record<string, unknown>).openClipMode = openClipMode;
(window as unknown as Record<string, unknown>).openHLSPlayer = openHLSPlayer;

// Expose showError for ui.ts parse handler
export { showError };
