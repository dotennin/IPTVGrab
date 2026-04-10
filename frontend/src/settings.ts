import type { Settings } from './types';

export const SETTINGS_KEY = 'mn_settings';
export const DEFAULT_SETTINGS: Settings = { useProxy: true };
export let settings: Settings = { ...DEFAULT_SETTINGS };

export function loadSettings(): void {
  try {
    const saved = localStorage.getItem(SETTINGS_KEY);
    if (saved) settings = { ...DEFAULT_SETTINGS, ...JSON.parse(saved) };
  } catch { /* ignore */ }
}

export function saveSettings(): void {
  try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch { /* ignore */ }
}

loadSettings();
