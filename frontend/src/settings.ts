import type { Settings } from './types';
import { apiFetch } from './api';

export const DEFAULT_SETTINGS: Settings = { useProxy: true, healthOnlyFilter: true };
export let settings: Settings = { ...DEFAULT_SETTINGS };

/** Load settings from the server. Falls back to defaults on error. */
export async function loadSettings(): Promise<void> {
  try {
    const res = await apiFetch('/api/settings');
    if (res.ok) {
      const data = await res.json();
      settings = {
        useProxy: data.use_proxy ?? DEFAULT_SETTINGS.useProxy,
        healthOnlyFilter: data.health_only_filter ?? DEFAULT_SETTINGS.healthOnlyFilter,
      };
    }
  } catch { /* network error — keep defaults */ }
}

/** Persist a partial update to the server. */
export async function saveSettings(patch: Partial<Settings>): Promise<void> {
  if ('useProxy' in patch) settings.useProxy = patch.useProxy!;
  if ('healthOnlyFilter' in patch) settings.healthOnlyFilter = patch.healthOnlyFilter!;
  try {
    await apiFetch('/api/settings', {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        use_proxy: settings.useProxy,
        health_only_filter: settings.healthOnlyFilter,
      }),
    });
  } catch { /* ignore — in-memory value already updated */ }
}
