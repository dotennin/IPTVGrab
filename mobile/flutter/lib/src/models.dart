class StreamVariant {
  StreamVariant({
    required this.url,
    required this.bandwidth,
    required this.label,
    this.resolution,
    this.codecs,
  });

  final String url;
  final int bandwidth;
  final String label;
  final String? resolution;
  final String? codecs;

  factory StreamVariant.fromJson(Map<String, dynamic> json) {
    return StreamVariant(
      url: _asString(json['url']),
      bandwidth: _asInt(json['bandwidth']),
      label: _asString(json['label']),
      resolution: _nullableString(json['resolution']),
      codecs: _nullableString(json['codecs']),
    );
  }

  String get displayLabel {
    if (label.isNotEmpty) {
      return label;
    }
    if (resolution != null && resolution!.isNotEmpty) {
      return resolution!;
    }
    if (bandwidth > 0) {
      return '${(bandwidth / 1000).round()} kbps';
    }
    return url;
  }
}

class ParsedStreamInfo {
  ParsedStreamInfo({
    required this.kind,
    required this.streams,
    required this.segments,
    required this.duration,
    required this.encrypted,
    required this.isLive,
  });

  final String kind;
  final List<StreamVariant> streams;
  final int segments;
  final double duration;
  final bool encrypted;
  final bool isLive;

  factory ParsedStreamInfo.fromJson(Map<String, dynamic> json) {
    final streamsJson = json['streams'];
    return ParsedStreamInfo(
      kind: _asString(json['kind']),
      streams: streamsJson is List
          ? streamsJson
              .whereType<Map>()
              .map((item) =>
                  StreamVariant.fromJson(item.cast<String, dynamic>()))
              .toList()
          : const [],
      segments: _asInt(json['segments']),
      duration: _asDouble(json['duration']),
      encrypted: _asBool(json['encrypted']),
      isLive: _asBool(json['is_live']),
    );
  }
}

class PlaylistChannel {
  PlaylistChannel({
    required this.name,
    required this.url,
    this.group,
    this.logo,
  });

  final String name;
  final String url;
  final String? group;
  final String? logo;

  String get groupName =>
      group != null && group!.trim().isNotEmpty ? group!.trim() : 'Ungrouped';

  factory PlaylistChannel.fromJson(Map<String, dynamic> json) {
    return PlaylistChannel(
      name: _asString(json['name']),
      url: _asString(json['url']),
      group: _nullableString(json['group']),
      logo: _nullableString(json['logo']) ?? _nullableString(json['tvg_logo']),
    );
  }
}

class HealthCheckEntry {
  HealthCheckEntry({
    required this.status,
    required this.checkedAt,
  });

  final String status;
  final double checkedAt;

  bool get isAvailable => status == 'ok';

  factory HealthCheckEntry.fromJson(Map<String, dynamic> json) {
    return HealthCheckEntry(
      status: _asString(json['status']),
      checkedAt: _asDouble(json['checked_at']),
    );
  }
}

class HealthCheckState {
  const HealthCheckState({
    required this.running,
    required this.total,
    required this.done,
    required this.startedAt,
  });

  final bool running;
  final int total;
  final int done;
  final double startedAt;

  factory HealthCheckState.fromJson(Map<String, dynamic> json) {
    return HealthCheckState(
      running: _asBool(json['running']),
      total: _asInt(json['total']),
      done: _asInt(json['done']),
      startedAt: _asDouble(json['started_at']),
    );
  }

  static const HealthCheckState empty = HealthCheckState(
    running: false,
    total: 0,
    done: 0,
    startedAt: 0,
  );
}

class HealthCheckSnapshot {
  HealthCheckSnapshot({
    required this.state,
    required this.cache,
  });

  final HealthCheckState state;
  final Map<String, HealthCheckEntry> cache;

  factory HealthCheckSnapshot.fromJson(Map<String, dynamic> json) {
    final stateJson = json['state'];
    final cacheJson = json['cache'];
    return HealthCheckSnapshot(
      state: stateJson is Map<String, dynamic>
          ? HealthCheckState.fromJson(stateJson)
          : HealthCheckState.empty,
      cache: cacheJson is Map
          ? cacheJson.map<String, HealthCheckEntry>(
              (key, value) => MapEntry(
                key.toString(),
                value is Map
                    ? HealthCheckEntry.fromJson(value.cast<String, dynamic>())
                    : HealthCheckEntry(status: '', checkedAt: 0),
              ),
            )
          : const <String, HealthCheckEntry>{},
    );
  }
}

class Playlist {
  Playlist({
    required this.id,
    required this.name,
    required this.channels,
    this.url,
    this.createdAt,
    this.updatedAt,
    this.channelCount,
  });

  final String id;
  final String name;
  final String? url;
  final List<PlaylistChannel> channels;
  final double? createdAt;
  final double? updatedAt;
  final int? channelCount;

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final channelsJson = json['channels'];
    return Playlist(
      id: _asString(json['id']),
      name: _asString(json['name']),
      url: _nullableString(json['url']),
      channels: channelsJson is List
          ? channelsJson
              .whereType<Map>()
              .map((item) =>
                  PlaylistChannel.fromJson(item.cast<String, dynamic>()))
              .toList()
          : const [],
      createdAt: _nullableDouble(json['created_at']),
      updatedAt: _nullableDouble(json['updated_at']),
      channelCount: _nullableInt(json['channel_count']),
    );
  }
}

class MergedPlaylistConfig {
  MergedPlaylistConfig({required this.groups});

  final List<MergedGroup> groups;

  factory MergedPlaylistConfig.fromJson(Map<String, dynamic> json) {
    final groupsJson = json['groups'];
    return MergedPlaylistConfig(
      groups: groupsJson is List
          ? groupsJson
              .whereType<Map>()
              .map((item) => MergedGroup.fromJson(item.cast<String, dynamic>()))
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'groups': groups.map((group) => group.toJson()).toList(),
      };

  MergedPlaylistConfig copy() => MergedPlaylistConfig(
      groups: groups.map((group) => group.copy()).toList());
}

class MergedGroup {
  MergedGroup({
    required this.id,
    required this.name,
    required this.enabled,
    required this.custom,
    required this.channels,
  });

  final String id;
  final String name;
  final bool enabled;
  final bool custom;
  final List<MergedChannel> channels;

  factory MergedGroup.fromJson(Map<String, dynamic> json) {
    final channelsJson = json['channels'];
    return MergedGroup(
      id: _asString(json['id']),
      name: _asString(json['name']),
      enabled: json['enabled'] == null ? true : _asBool(json['enabled']),
      custom: _asBool(json['custom']),
      channels: channelsJson is List
          ? channelsJson
              .whereType<Map>()
              .map(
                (item) => MergedChannel.fromJson(item.cast<String, dynamic>()),
              )
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'enabled': enabled,
        'custom': custom,
        'channels': channels.map((channel) => channel.toJson()).toList(),
      };

  MergedGroup copyWith({
    String? id,
    String? name,
    bool? enabled,
    bool? custom,
    List<MergedChannel>? channels,
  }) {
    return MergedGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      custom: custom ?? this.custom,
      channels:
          channels ?? this.channels.map((channel) => channel.copy()).toList(),
    );
  }

  MergedGroup copy() => copyWith();
}

class MergedChannel {
  MergedChannel({
    required this.id,
    required this.name,
    required this.url,
    required this.enabled,
    required this.custom,
    required this.group,
    required this.tvgLogo,
    this.sourcePlaylistId,
    this.sourcePlaylistName,
  });

  final String id;
  final String name;
  final String url;
  final bool enabled;
  final bool custom;
  final String group;
  final String tvgLogo;
  final String? sourcePlaylistId;
  final String? sourcePlaylistName;

  factory MergedChannel.fromJson(Map<String, dynamic> json) {
    return MergedChannel(
      id: _asString(json['id']),
      name: _asString(json['name']),
      url: _asString(json['url']),
      enabled: json['enabled'] == null ? true : _asBool(json['enabled']),
      custom: _asBool(json['custom']),
      group: _asString(json['group']),
      tvgLogo: _nullableString(json['tvg_logo']) ??
          _nullableString(json['logo']) ??
          '',
      sourcePlaylistId: _nullableString(json['source_playlist_id']),
      sourcePlaylistName: _nullableString(json['source_playlist_name']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        'custom': custom,
        'group': group,
        'tvg_logo': tvgLogo,
        'source_playlist_id': sourcePlaylistId,
        'source_playlist_name': sourcePlaylistName,
      };

  MergedChannel copyWith({
    String? id,
    String? name,
    String? url,
    bool? enabled,
    bool? custom,
    String? group,
    String? tvgLogo,
    String? sourcePlaylistId,
    String? sourcePlaylistName,
  }) {
    return MergedChannel(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      enabled: enabled ?? this.enabled,
      custom: custom ?? this.custom,
      group: group ?? this.group,
      tvgLogo: tvgLogo ?? this.tvgLogo,
      sourcePlaylistId: sourcePlaylistId ?? this.sourcePlaylistId,
      sourcePlaylistName: sourcePlaylistName ?? this.sourcePlaylistName,
    );
  }

  MergedChannel copy() => copyWith();
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.url,
    required this.status,
    required this.progress,
    required this.createdAt,
    this.total = 0,
    this.downloaded = 0,
    this.failed = 0,
    this.speedMbps = 0,
    this.bytesDownloaded = 0,
    this.output,
    this.size = 0,
    this.error,
    this.outputName,
    this.quality = 'best',
    this.concurrency = 8,
    this.tmpdir,
    this.isCmaf,
    this.segExt,
    this.targetDuration,
    this.durationSec,
    this.recordedSegments = 0,
    this.elapsedSec = 0,
  });

  final String id;
  final String url;
  final String status;
  final int progress;
  final double createdAt;
  final int total;
  final int downloaded;
  final int failed;
  final double speedMbps;
  final int bytesDownloaded;
  final String? output;
  final int size;
  final String? error;
  final String? outputName;
  final String quality;
  final int concurrency;
  final String? tmpdir;
  final bool? isCmaf;
  final String? segExt;
  final double? targetDuration;
  final double? durationSec;
  final int recordedSegments;
  final int elapsedSec;

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: _asString(json['id']),
      url: _asString(json['url']),
      status: _asString(json['status']),
      progress: _asInt(json['progress']),
      createdAt: _asDouble(json['created_at']),
      total: _asInt(json['total']),
      downloaded: _asInt(json['downloaded']),
      failed: _asInt(json['failed']),
      speedMbps: _asDouble(json['speed_mbps']),
      bytesDownloaded: _asInt(json['bytes_downloaded']),
      output: _nullableString(json['output']),
      size: _asInt(json['size']),
      error: _nullableString(json['error']),
      outputName: _nullableString(json['output_name']),
      quality: _asString(json['quality']).isEmpty
          ? 'best'
          : _asString(json['quality']),
      concurrency:
          _asInt(json['concurrency']) == 0 ? 8 : _asInt(json['concurrency']),
      tmpdir: _nullableString(json['tmpdir']),
      isCmaf: json['is_cmaf'] == null ? null : _asBool(json['is_cmaf']),
      segExt: _nullableString(json['seg_ext']),
      targetDuration: _nullableDouble(json['target_duration']),
      durationSec: _nullableDouble(json['duration_sec']),
      recordedSegments: _asInt(json['recorded_segments']),
      elapsedSec: _asInt(json['elapsed_sec']),
    );
  }

  factory DownloadTask.placeholder({
    required String id,
    required String url,
  }) {
    return DownloadTask(
      id: id,
      url: url,
      status: 'queued',
      progress: 0,
      createdAt: DateTime.now().millisecondsSinceEpoch / 1000,
    );
  }

  bool get isTerminal => const {
        'completed',
        'failed',
        'cancelled',
        'interrupted',
        'paused',
      }.contains(status);

  bool get isRecording => status == 'recording';

  bool get isStopping => status == 'stopping';

  bool get isActive => !isTerminal;

  bool get canPause => const {
        'downloading',
        'recording',
        'queued',
      }.contains(status);

  bool get canResume => const {'failed', 'interrupted', 'paused'}.contains(status);

  bool get canRestart => const {
        'completed',
        'failed',
        'cancelled',
        'interrupted',
        'paused',
      }.contains(status);

  bool get canClip => const {
        'completed',
        'downloading',
        'recording',
        'stopping',
        'merging',
      }.contains(status);

  bool get canPreview => const {
        'downloading',
        'recording',
        'stopping',
        'merging',
      }.contains(status);

  bool get canForkRecording => status == 'recording';

  bool get canRestartRecording => status == 'recording';

  bool get hasKnownDuration => durationSec != null && durationSec! > 0;

  bool get needsLocalMerge =>
      status == 'failed' &&
      indicatesMissingFfmpeg(error) &&
      tmpdir != null &&
      tmpdir!.isNotEmpty;
}

bool indicatesMissingFfmpeg(String? error) {
  final normalized = error?.toLowerCase();
  if (normalized == null || normalized.isEmpty) {
    return false;
  }
  return normalized.contains('ffmpeg not found') ||
      (normalized.contains('failed to spawn ffmpeg') &&
          normalized.contains('no such file or directory'));
}

int _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.round();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

double _asDouble(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is int) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? 0;
  }
  return 0;
}

bool _asBool(dynamic value) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    return value.toLowerCase() == 'true';
  }
  if (value is num) {
    return value != 0;
  }
  return false;
}

String _asString(dynamic value) {
  if (value == null) {
    return '';
  }
  return value.toString();
}

String? _nullableString(dynamic value) {
  if (value == null) {
    return null;
  }
  final text = value.toString();
  return text.isEmpty ? null : text;
}

double? _nullableDouble(dynamic value) {
  if (value == null) {
    return null;
  }
  return _asDouble(value);
}

int? _nullableInt(dynamic value) {
  if (value == null) {
    return null;
  }
  return _asInt(value);
}
