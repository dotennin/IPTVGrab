export interface Task {
  id: string;
  url: string;
  status: string;
  progress: number;
  total: number;
  downloaded: number;
  failed: number;
  speed_mbps: number;
  bytes_downloaded: number;
  output: string | null;
  size: number;
  error: string | null;
  created_at: number;
  req_headers: Record<string, string>;
  output_name: string | null;
  quality: string;
  concurrency: number;
  tmpdir: string | null;
  is_cmaf: boolean | null;
  seg_ext: string | null;
  target_duration: number | null;
  duration_sec: number | null;
  recorded_segments: number | null;
  elapsed_sec: number | null;
  task_type?: string;
}

export interface Channel {
  id?: string;
  name: string;
  url: string;
  group: string | null;
  logo?: string | null;
  tvg_logo?: string;
  tvg_type?: string | null;
  playlist_name?: string;
}

export interface SavedPlaylist {
  id: string;
  name: string;
  url: string | null;
  channels: Channel[];
  created_at: number;
  updated_at: number;
  channel_count: number;
}

export interface OriginLabel {
  group_name: string;
  channel_name: string;
  source_playlist_name: string;
  alive: boolean;
}

export interface MergedChannel {
  id: string;
  name: string;
  url: string;
  enabled: boolean;
  custom: boolean;
  group: string;
  tvg_logo: string;
  tvg_type?: string | null;
  source_playlist_id: string | null;
  source_playlist_name: string | null;
  origin_id?: string | null;
  origin_label?: OriginLabel | null;
}

export interface MergedGroup {
  id: string;
  name: string;
  enabled: boolean;
  custom: boolean;
  channels: MergedChannel[];
}

export interface MergedConfig {
  groups: MergedGroup[];
}

export interface HealthEntry {
  status: 'ok' | 'dead' | 'playable' | 'invalid';
  checked_at: number;
  latency_ms?: number;
}

export interface HealthState {
  running: boolean;
  total: number;
  done: number;
  started_at: number;
  cache: Record<string, HealthEntry>;
}

export interface Quality {
  index: number;
  label: string;
  bandwidth?: number;
}

export interface StreamInfo {
  url: string;
  is_live: boolean;
  qualities: Quality[];
  headers: Record<string, string>;
  has_audio: boolean;
  is_encrypted: boolean;
  duration_sec?: number | null;
  // parser may return kind/streams/segments/duration/encrypted for display
  kind?: string;
  streams?: Array<{ label: string; resolution?: string; bandwidth: number; codecs?: string }>;
  segments?: number;
  duration?: number;
  encrypted?: boolean;
}

export interface Settings {
  useProxy: boolean;
  healthOnlyFilter: boolean;
  recentLimit: number;
}

export interface RecentChannel {
  id: string;
  name: string;
  url: string;
  tvg_logo: string;
  group: string;
  watched_at: number;
}
