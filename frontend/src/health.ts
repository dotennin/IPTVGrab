import { apiFetch } from './api';
import { esc } from './utils';
import type { HealthEntry, OriginLabel } from './types';

// Forward-declared references to functions defined in other modules
// (health.ts is imported by playlists.ts which defines renderChannels/getFilteredChannels)
declare function renderChannels(channels: unknown[]): void;
declare function getFilteredChannels(): unknown[];

export let healthCache: Record<string, HealthEntry> = {};
let _healthPollTimer: ReturnType<typeof setInterval> | null = null;
export let healthOnlyFilter = false;

export function setHealthOnlyFilter(value: boolean): void {
  healthOnlyFilter = value;
}

/** Returns the CSS class name for a given health status. */
function healthClass(status: string): string {
  switch (status) {
    case 'ok':      return 'health-ok';
    case 'playable': return 'health-playable';
    case 'dead':    return 'health-dead';
    case 'invalid': return 'health-invalid';
    default:        return 'health-unknown';
  }
}

/** Human-readable tooltip for a health status. */
function healthTitle(status: string, latencyMs?: number): string {
  const ms = latencyMs != null ? ` (${latencyMs}ms)` : '';
  switch (status) {
    case 'ok':       return `Reachable${ms}`;
    case 'playable': return `Playable ✓${ms}`;
    case 'dead':     return 'Unreachable';
    case 'invalid':  return `Reachable but invalid stream${ms}`;
    default:         return 'Not checked';
  }
}

/** Returns true if the health status counts as "available" for filter purposes. */
export function healthIsAvailable(status: string): boolean {
  return status === 'ok' || status === 'playable';
}

export function _healthDot(url: string): string {
  const h = healthCache[url];
  const cls = h ? healthClass(h.status) : 'health-unknown';
  const title = h ? healthTitle(h.status, h.latency_ms) : 'Not checked';
  return `<span class="health-dot ${cls}" data-health-url="${esc(url)}" title="${title}"></span>`;
}

export function _healthDotInline(url: string): string {
  const h = healthCache[url];
  if (!h) return '';
  const cls = healthClass(h.status);
  const title = healthTitle(h.status, h.latency_ms);
  return `<span class="health-dot-inline ${cls}" data-health-url="${esc(url)}" title="${title}"></span>`;
}

export function _originLabel(label: OriginLabel | null | undefined): string {
  if (!label) {
    return `<div class="editor-origin-label editor-origin-unknown"><i class="fas fa-link"></i> Synced from source</div>`;
  }
  if (!label.alive) {
    return `<div class="editor-origin-label editor-origin-dead" title="Source channel no longer found in any playlist"><i class="fas fa-exclamation-triangle"></i> Source removed</div>`;
  }
  const parts = [label.group_name, label.source_playlist_name].filter(Boolean).join(' · ');
  return `<div class="editor-origin-label editor-origin-alive" title="Auto-synced from: ${esc(label.group_name)} (${esc(label.source_playlist_name)})"><i class="fas fa-link"></i> ${esc(parts)}</div>`;
}

export function updateHealthDots(): void {
  document.querySelectorAll('[data-health-url]').forEach((el) => {
    const htmlEl = el as HTMLElement;
    const url = htmlEl.dataset.healthUrl!;
    const h = healthCache[url];
    htmlEl.classList.remove('health-ok', 'health-dead', 'health-unknown', 'health-invalid', 'health-playable');
    if (!h) {
      htmlEl.classList.add('health-unknown');
      htmlEl.title = 'Not checked';
    } else {
      htmlEl.classList.add(healthClass(h.status));
      htmlEl.title = healthTitle(h.status, h.latency_ms);
    }
  });
  // If health filter is active, re-render so counts stay accurate
  // (renderChannels/getFilteredChannels are provided by playlists.ts at runtime)
  if (healthOnlyFilter) {
    try {
      renderChannels(getFilteredChannels());
    } catch { /* playlists module not yet loaded */ }
  }
}

function _updateHealthProgress(data: { running: boolean; done: number; total: number }): void {
  const badge = document.getElementById('healthProgressBadge');
  const text = document.getElementById('healthProgressText');
  if (!badge || !text) return;
  if (data.running) {
    badge.classList.remove('d-none');
    text.textContent = `${data.done} / ${data.total}`;
  } else {
    badge.classList.add('d-none');
  }
}

export function startHealthPoll(): void {
  _stopHealthPoll();
  const poll = async () => {
    try {
      const res = await apiFetch('/api/health-check');
      if (!res.ok) return;
      const data = await res.json();
      debugger
      healthCache = data.cache || {};
      _updateHealthProgress(data);
      updateHealthDots();
      if (!data.running) _stopHealthPoll();
    } catch { /* ignore */ }
  };
  poll();
  _healthPollTimer = setInterval(poll, 2000);
}

function _stopHealthPoll(): void {
  if (_healthPollTimer) {
    clearInterval(_healthPollTimer);
    _healthPollTimer = null;
  }
}

export async function refreshHealthOnce(): Promise<void> {
  try {
    const res = await apiFetch('/api/health-check');
    if (!res.ok) return;
    const data = await res.json();
    healthCache = data.cache || {};
    _updateHealthProgress(data);
    updateHealthDots();
    if (data.running && !_healthPollTimer) startHealthPoll();
  } catch { /* ignore */ }
}

/**
 * Triggers a deep playability check on the server (`POST /api/health-check?deep=true`).
 * The server fetches each M3U8 manifest and validates its content.
 * Returns immediately; use startHealthPoll() to track progress.
 */
export async function triggerDeepCheck(): Promise<void> {
  try {
    const res = await apiFetch('/api/health-check?deep=true', { method: 'POST' });
    if (res.ok) startHealthPoll();
  } catch { /* ignore */ }
}
