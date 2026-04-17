import type { Settings } from './types';
import { apiFetch } from './api';

export const DEFAULT_SETTINGS: Settings = {
  useProxy: true,
  healthOnlyFilter: true,
  recentLimit: 20,
  autoFullscreen: false,
  recordingIntervalMinutes: 60,
  recordingAutoRestart: false,
};
export let settings: Settings = { ...DEFAULT_SETTINGS };

function normalizeRecentLimit(value: unknown): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return DEFAULT_SETTINGS.recentLimit;
  return Math.min(200, Math.max(1, Math.round(parsed)));
}

export function normalizeRecordingIntervalMinutes(value: unknown): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return DEFAULT_SETTINGS.recordingIntervalMinutes;
  return Math.min(1440, Math.max(1, Math.round(parsed)));
}

/** Load settings from the server. Falls back to defaults on error. */
export async function loadSettings(): Promise<void> {
  try {
    const res = await apiFetch('/api/settings');
    if (res.ok) {
      const data = await res.json();
      settings = {
        useProxy: data.use_proxy ?? DEFAULT_SETTINGS.useProxy,
        healthOnlyFilter: data.health_only_filter ?? DEFAULT_SETTINGS.healthOnlyFilter,
        recentLimit: normalizeRecentLimit(data.recent_limit),
        autoFullscreen: data.auto_fullscreen ?? DEFAULT_SETTINGS.autoFullscreen,
        recordingIntervalMinutes: normalizeRecordingIntervalMinutes(data.recording_interval_minutes),
        recordingAutoRestart: data.recording_auto_restart ?? DEFAULT_SETTINGS.recordingAutoRestart,
      };
    }
  } catch { /* network error — keep defaults */ }
}

/** Persist a partial update to the server. */
export async function saveSettings(patch: Partial<Settings>): Promise<void> {
  if ('useProxy' in patch) settings.useProxy = patch.useProxy!;
  if ('healthOnlyFilter' in patch) settings.healthOnlyFilter = patch.healthOnlyFilter!;
  if ('recentLimit' in patch) settings.recentLimit = normalizeRecentLimit(patch.recentLimit);
  if ('autoFullscreen' in patch) settings.autoFullscreen = patch.autoFullscreen!;
  if ('recordingIntervalMinutes' in patch) {
    settings.recordingIntervalMinutes = normalizeRecordingIntervalMinutes(patch.recordingIntervalMinutes);
  }
  if ('recordingAutoRestart' in patch) settings.recordingAutoRestart = patch.recordingAutoRestart!;
  try {
    await apiFetch('/api/settings', {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        use_proxy: settings.useProxy,
        health_only_filter: settings.healthOnlyFilter,
        recent_limit: settings.recentLimit,
        auto_fullscreen: settings.autoFullscreen,
        recording_interval_minutes: settings.recordingIntervalMinutes,
        recording_auto_restart: settings.recordingAutoRestart,
      }),
    });
  } catch { /* ignore — in-memory value already updated */ }
}
