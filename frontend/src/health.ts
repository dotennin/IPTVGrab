import { apiFetch } from './api';
import { esc } from './utils';
import type { HealthEntry, OriginLabel } from './types';

// Forward-declared references to functions defined in other modules
// (health.ts is imported by playlists.ts which defines renderChannels/getFilteredChannels)
declare function renderChannels(channels: unknown[]): void;
declare function getFilteredChannels(): unknown[];

export let healthCache: Record<string, HealthEntry> = {};
let _healthPollTimer: ReturnType<typeof setInterval> | null = null;
export let healthOnlyFilter = true;

export function setHealthOnlyFilter(value: boolean): void {
  healthOnlyFilter = value;
}

export function _healthDot(url: string): string {
  const h = healthCache[url];
  const cls = h ? (h.status === 'ok' ? 'health-ok' : 'health-dead') : 'health-unknown';
  const title = h ? (h.status === 'ok' ? 'Reachable' : 'Unreachable') : 'Not checked';
  return `<span class="health-dot ${cls}" data-health-url="${esc(url)}" title="${title}"></span>`;
}

export function _healthDotInline(url: string): string {
  const h = healthCache[url];
  if (!h) return '';
  const cls = h.status === 'ok' ? 'health-ok' : 'health-dead';
  const title = h.status === 'ok' ? 'Reachable' : 'Unreachable';
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
    htmlEl.classList.remove('health-ok', 'health-dead', 'health-unknown');
    if (!h) {
      htmlEl.classList.add('health-unknown');
      htmlEl.title = 'Not checked';
    } else if (h.status === 'ok') {
      htmlEl.classList.add('health-ok');
      htmlEl.title = 'Reachable';
    } else {
      htmlEl.classList.add('health-dead');
      htmlEl.title = 'Unreachable';
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
