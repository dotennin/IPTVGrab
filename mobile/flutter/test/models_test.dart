import 'package:flutter_test/flutter_test.dart';
import 'package:media_nest/src/models.dart';

void main() {
  group('indicatesMissingFfmpeg', () {
    test('recognizes canonical missing binary errors', () {
      expect(
        indicatesMissingFfmpeg(
          'ffmpeg error: ffmpeg not found: No such file or directory (os error 2)',
        ),
        isTrue,
      );
    });

    test('recognizes legacy spawn errors', () {
      expect(
        indicatesMissingFfmpeg(
          'ffmpeg error: Failed to spawn ffmpeg: No such file or directory (os error 2)',
        ),
        isTrue,
      );
    });

    test('returns false for null', () {
      expect(indicatesMissingFfmpeg(null), isFalse);
    });

    test('returns false for empty string', () {
      expect(indicatesMissingFfmpeg(''), isFalse);
    });

    test('returns false for unrelated errors', () {
      expect(indicatesMissingFfmpeg('network timeout'), isFalse);
    });

    test('is case insensitive', () {
      expect(indicatesMissingFfmpeg('FFMPEG NOT FOUND'), isTrue);
    });
  });

  group('StreamVariant', () {
    test('fromJson parses all fields', () {
      final variant = StreamVariant.fromJson({
        'url': 'https://example.com/stream.m3u8',
        'bandwidth': 5000000,
        'label': '1080p',
        'resolution': '1920x1080',
        'codecs': 'avc1.640028',
      });

      expect(variant.url, 'https://example.com/stream.m3u8');
      expect(variant.bandwidth, 5000000);
      expect(variant.label, '1080p');
      expect(variant.resolution, '1920x1080');
      expect(variant.codecs, 'avc1.640028');
    });

    test('fromJson handles null optional fields', () {
      final variant = StreamVariant.fromJson({
        'url': 'https://example.com/stream.m3u8',
        'bandwidth': 3000000,
        'label': 'HD',
      });

      expect(variant.resolution, isNull);
      expect(variant.codecs, isNull);
    });

    test('displayLabel returns label when present', () {
      final variant = StreamVariant(
        url: 'url',
        bandwidth: 5000000,
        label: '1080p',
        resolution: '1920x1080',
      );
      expect(variant.displayLabel, '1080p');
    });

    test('displayLabel falls back to resolution', () {
      final variant = StreamVariant(
        url: 'url',
        bandwidth: 5000000,
        label: '',
        resolution: '1920x1080',
      );
      expect(variant.displayLabel, '1920x1080');
    });

    test('displayLabel falls back to bandwidth', () {
      final variant = StreamVariant(
        url: 'url',
        bandwidth: 5000000,
        label: '',
      );
      expect(variant.displayLabel, '5000 kbps');
    });

    test('displayLabel falls back to url', () {
      final variant = StreamVariant(
        url: 'https://example.com/stream.m3u8',
        bandwidth: 0,
        label: '',
      );
      expect(variant.displayLabel, 'https://example.com/stream.m3u8');
    });
  });

  group('ParsedStreamInfo', () {
    test('fromJson parses all fields', () {
      final info = ParsedStreamInfo.fromJson({
        'kind': 'master',
        'streams': [
          {'url': 'url1', 'bandwidth': 1000, 'label': 'SD'},
          {'url': 'url2', 'bandwidth': 5000, 'label': 'HD'},
        ],
        'segments': 100,
        'duration': 600.5,
        'encrypted': true,
        'is_live': false,
      });

      expect(info.kind, 'master');
      expect(info.streams.length, 2);
      expect(info.segments, 100);
      expect(info.duration, 600.5);
      expect(info.encrypted, isTrue);
      expect(info.isLive, isFalse);
    });

    test('fromJson handles empty streams', () {
      final info = ParsedStreamInfo.fromJson({
        'kind': 'media',
        'segments': 50,
        'duration': 300,
        'encrypted': false,
        'is_live': true,
      });

      expect(info.streams, isEmpty);
    });
  });

  group('PlaylistChannel', () {
    test('fromJson parses all fields', () {
      final channel = PlaylistChannel.fromJson({
        'name': 'CNN',
        'url': 'https://example.com/cnn.m3u8',
        'group': 'News',
        'logo': 'https://example.com/cnn.png',
      });

      expect(channel.name, 'CNN');
      expect(channel.url, 'https://example.com/cnn.m3u8');
      expect(channel.group, 'News');
      expect(channel.logo, 'https://example.com/cnn.png');
    });

    test('fromJson falls back to tvg_logo', () {
      final channel = PlaylistChannel.fromJson({
        'name': 'CNN',
        'url': 'https://example.com/cnn.m3u8',
        'tvg_logo': 'https://example.com/tvg.png',
      });

      expect(channel.logo, 'https://example.com/tvg.png');
    });

    test('groupName returns group when present', () {
      final channel = PlaylistChannel(
        name: 'CNN',
        url: 'url',
        group: 'News',
      );
      expect(channel.groupName, 'News');
    });

    test('groupName returns Ungrouped when null', () {
      final channel = PlaylistChannel(name: 'CNN', url: 'url');
      expect(channel.groupName, 'Ungrouped');
    });

    test('groupName returns Ungrouped when empty/whitespace', () {
      final channel = PlaylistChannel(
        name: 'CNN',
        url: 'url',
        group: '   ',
      );
      expect(channel.groupName, 'Ungrouped');
    });
  });

  group('HealthCheckEntry', () {
    test('fromJson parses fields', () {
      final entry = HealthCheckEntry.fromJson({
        'status': 'ok',
        'checked_at': 1700000000.0,
      });

      expect(entry.status, 'ok');
      expect(entry.checkedAt, 1700000000.0);
    });

    test('isAvailable returns true for ok', () {
      final entry = HealthCheckEntry(status: 'ok', checkedAt: 0);
      expect(entry.isAvailable, isTrue);
    });

    test('isAvailable returns false for dead', () {
      final entry = HealthCheckEntry(status: 'dead', checkedAt: 0);
      expect(entry.isAvailable, isFalse);
    });
  });

  group('HealthCheckState', () {
    test('fromJson parses fields', () {
      final state = HealthCheckState.fromJson({
        'running': true,
        'total': 100,
        'done': 50,
        'started_at': 1700000000.0,
      });

      expect(state.running, isTrue);
      expect(state.total, 100);
      expect(state.done, 50);
      expect(state.startedAt, 1700000000.0);
    });

    test('empty is all zeros/false', () {
      expect(HealthCheckState.empty.running, isFalse);
      expect(HealthCheckState.empty.total, 0);
      expect(HealthCheckState.empty.done, 0);
      expect(HealthCheckState.empty.startedAt, 0);
    });
  });

  group('HealthCheckSnapshot', () {
    test('fromJson parses state and cache', () {
      final snapshot = HealthCheckSnapshot.fromJson({
        'state': {
          'running': false,
          'total': 10,
          'done': 10,
          'started_at': 1700000000.0,
        },
        'cache': {
          'http://example.com/stream': {
            'status': 'ok',
            'checked_at': 1700000000.0,
          },
        },
      });

      expect(snapshot.state.total, 10);
      expect(snapshot.cache.length, 1);
      expect(snapshot.cache['http://example.com/stream']?.status, 'ok');
    });

    test('fromJson handles missing state and cache', () {
      final snapshot = HealthCheckSnapshot.fromJson({});

      expect(snapshot.state.running, isFalse);
      expect(snapshot.cache, isEmpty);
    });
  });

  group('Playlist', () {
    test('fromJson parses all fields', () {
      final playlist = Playlist.fromJson({
        'id': 'pl-1',
        'name': 'My Playlist',
        'url': 'https://example.com/playlist.m3u',
        'channels': [
          {'name': 'Channel 1', 'url': 'url1'},
        ],
        'created_at': 1700000000.0,
        'updated_at': 1700000001.0,
        'channel_count': 5,
      });

      expect(playlist.id, 'pl-1');
      expect(playlist.name, 'My Playlist');
      expect(playlist.url, 'https://example.com/playlist.m3u');
      expect(playlist.channels.length, 1);
      expect(playlist.createdAt, 1700000000.0);
      expect(playlist.channelCount, 5);
    });

    test('fromJson handles missing channels', () {
      final playlist = Playlist.fromJson({
        'id': 'pl-1',
        'name': 'Empty',
        'channels': null,
      });

      expect(playlist.channels, isEmpty);
    });
  });

  group('MergedPlaylistConfig', () {
    test('fromJson parses groups', () {
      final config = MergedPlaylistConfig.fromJson({
        'groups': [
          {
            'id': 'g1',
            'name': 'News',
            'enabled': true,
            'custom': false,
            'channels': [],
          },
        ],
      });

      expect(config.groups.length, 1);
      expect(config.groups[0].name, 'News');
    });

    test('toJson roundtrips', () {
      final config = MergedPlaylistConfig(
        groups: [
          MergedGroup(
            id: 'g1',
            name: 'Sports',
            enabled: true,
            custom: false,
            channels: [
              MergedChannel(
                id: 'ch1',
                name: 'ESPN',
                url: 'url',
                enabled: true,
                custom: false,
                group: 'Sports',
                tvgLogo: '',
              ),
            ],
          ),
        ],
      );

      final json = config.toJson();
      final restored = MergedPlaylistConfig.fromJson(json);

      expect(restored.groups.length, 1);
      expect(restored.groups[0].channels[0].name, 'ESPN');
    });

    test('copy creates independent copy', () {
      final original = MergedPlaylistConfig(
        groups: [
          MergedGroup(
            id: 'g1',
            name: 'News',
            enabled: true,
            custom: false,
            channels: [],
          ),
        ],
      );

      final copied = original.copy();
      expect(copied.groups.length, 1);
      expect(copied.groups[0].name, 'News');
      expect(identical(copied.groups, original.groups), isFalse);
    });
  });

  group('MergedGroup', () {
    test('fromJson defaults enabled to true when null', () {
      final group = MergedGroup.fromJson({
        'id': 'g1',
        'name': 'Test',
        'custom': false,
        'channels': [],
      });

      expect(group.enabled, isTrue);
    });

    test('copyWith overrides specified fields', () {
      final group = MergedGroup(
        id: 'g1',
        name: 'Original',
        enabled: true,
        custom: false,
        channels: [],
      );

      final modified = group.copyWith(name: 'Modified', enabled: false);
      expect(modified.name, 'Modified');
      expect(modified.enabled, isFalse);
      expect(modified.id, 'g1');
    });
  });

  group('MergedChannel', () {
    test('fromJson defaults enabled to true when null', () {
      final channel = MergedChannel.fromJson({
        'id': 'ch1',
        'name': 'CNN',
        'url': 'url',
        'custom': false,
        'group': 'News',
      });

      expect(channel.enabled, isTrue);
    });

    test('fromJson prefers tvg_logo over logo', () {
      final channel = MergedChannel.fromJson({
        'id': 'ch1',
        'name': 'CNN',
        'url': 'url',
        'custom': false,
        'group': 'News',
        'tvg_logo': 'tvg.png',
        'logo': 'logo.png',
      });

      expect(channel.tvgLogo, 'tvg.png');
    });

    test('fromJson falls back to logo when tvg_logo is null', () {
      final channel = MergedChannel.fromJson({
        'id': 'ch1',
        'name': 'CNN',
        'url': 'url',
        'custom': false,
        'group': 'News',
        'logo': 'logo.png',
      });

      expect(channel.tvgLogo, 'logo.png');
    });

    test('copyWith overrides specified fields', () {
      final channel = MergedChannel(
        id: 'ch1',
        name: 'Original',
        url: 'url',
        enabled: true,
        custom: false,
        group: 'News',
        tvgLogo: '',
      );

      final modified = channel.copyWith(name: 'Modified', enabled: false);
      expect(modified.name, 'Modified');
      expect(modified.enabled, isFalse);
      expect(modified.url, 'url');
    });

    test('toJson includes all fields', () {
      final channel = MergedChannel(
        id: 'ch1',
        name: 'CNN',
        url: 'url',
        enabled: true,
        custom: false,
        group: 'News',
        tvgLogo: 'logo.png',
        sourcePlaylistId: 'pl1',
        sourcePlaylistName: 'My Playlist',
      );

      final json = channel.toJson();
      expect(json['id'], 'ch1');
      expect(json['name'], 'CNN');
      expect(json['tvg_logo'], 'logo.png');
      expect(json['source_playlist_id'], 'pl1');
      expect(json['source_playlist_name'], 'My Playlist');
    });
  });

  group('DownloadTask', () {
    DownloadTask makeTask({
      String status = 'downloading',
      String? error,
      String? tmpdir,
      double? durationSec,
    }) {
      return DownloadTask(
        id: 'task-1',
        url: 'https://example.com/video.m3u8',
        status: status,
        progress: 50,
        createdAt: 1700000000.0,
        error: error,
        tmpdir: tmpdir,
        durationSec: durationSec,
      );
    }

    test('fromJson parses all fields', () {
      final task = DownloadTask.fromJson({
        'id': 'task-1',
        'url': 'https://example.com/video.m3u8',
        'status': 'downloading',
        'progress': 75,
        'created_at': 1700000000.0,
        'total': 100,
        'downloaded': 75,
        'failed': 2,
        'speed_mbps': 5.5,
        'bytes_downloaded': 52428800,
        'output': 'video.mp4',
        'size': 104857600,
        'quality': '1080p',
        'concurrency': 16,
        'tmpdir': '/tmp/task-1',
        'is_cmaf': true,
        'seg_ext': '.m4s',
        'target_duration': 6.0,
        'duration_sec': 600.5,
        'recorded_segments': 100,
        'elapsed_sec': 300,
      });

      expect(task.id, 'task-1');
      expect(task.total, 100);
      expect(task.downloaded, 75);
      expect(task.speedMbps, 5.5);
      expect(task.quality, '1080p');
      expect(task.concurrency, 16);
      expect(task.isCmaf, isTrue);
      expect(task.durationSec, 600.5);
    });

    test('fromJson defaults quality to best when empty', () {
      final task = DownloadTask.fromJson({
        'id': 't1',
        'url': 'url',
        'status': 'queued',
        'progress': 0,
        'created_at': 0,
        'quality': '',
      });

      expect(task.quality, 'best');
    });

    test('fromJson defaults concurrency to 8 when 0', () {
      final task = DownloadTask.fromJson({
        'id': 't1',
        'url': 'url',
        'status': 'queued',
        'progress': 0,
        'created_at': 0,
        'concurrency': 0,
      });

      expect(task.concurrency, 8);
    });

    group('computed properties', () {
      test('isTerminal for completed', () {
        expect(makeTask(status: 'completed').isTerminal, isTrue);
      });

      test('isTerminal for failed', () {
        expect(makeTask(status: 'failed').isTerminal, isTrue);
      });

      test('isTerminal for cancelled', () {
        expect(makeTask(status: 'cancelled').isTerminal, isTrue);
      });

      test('isTerminal for interrupted', () {
        expect(makeTask(status: 'interrupted').isTerminal, isTrue);
      });

      test('isTerminal for paused', () {
        expect(makeTask(status: 'paused').isTerminal, isTrue);
      });

      test('isTerminal false for downloading', () {
        expect(makeTask(status: 'downloading').isTerminal, isFalse);
      });

      test('isActive is inverse of isTerminal', () {
        expect(makeTask(status: 'downloading').isActive, isTrue);
        expect(makeTask(status: 'completed').isActive, isFalse);
      });

      test('isRecording', () {
        expect(makeTask(status: 'recording').isRecording, isTrue);
        expect(makeTask(status: 'downloading').isRecording, isFalse);
      });

      test('isStopping', () {
        expect(makeTask(status: 'stopping').isStopping, isTrue);
        expect(makeTask(status: 'recording').isStopping, isFalse);
      });

      test('canPause', () {
        expect(makeTask(status: 'downloading').canPause, isTrue);
        expect(makeTask(status: 'recording').canPause, isTrue);
        expect(makeTask(status: 'queued').canPause, isTrue);
        expect(makeTask(status: 'completed').canPause, isFalse);
      });

      test('canResume', () {
        expect(makeTask(status: 'failed').canResume, isTrue);
        expect(makeTask(status: 'interrupted').canResume, isTrue);
        expect(makeTask(status: 'paused').canResume, isTrue);
        expect(makeTask(status: 'downloading').canResume, isFalse);
      });

      test('canRestart', () {
        expect(makeTask(status: 'completed').canRestart, isTrue);
        expect(makeTask(status: 'failed').canRestart, isTrue);
        expect(makeTask(status: 'downloading').canRestart, isFalse);
      });

      test('canClip', () {
        expect(makeTask(status: 'completed').canClip, isTrue);
        expect(makeTask(status: 'downloading').canClip, isTrue);
        expect(makeTask(status: 'recording').canClip, isTrue);
        expect(makeTask(status: 'failed').canClip, isFalse);
      });

      test('canPreview', () {
        expect(makeTask(status: 'downloading').canPreview, isTrue);
        expect(makeTask(status: 'recording').canPreview, isTrue);
        expect(makeTask(status: 'completed').canPreview, isFalse);
      });

      test('canForkRecording', () {
        expect(makeTask(status: 'recording').canForkRecording, isTrue);
        expect(makeTask(status: 'downloading').canForkRecording, isFalse);
      });

      test('hasKnownDuration', () {
        expect(makeTask(durationSec: 600).hasKnownDuration, isTrue);
        expect(makeTask(durationSec: 0).hasKnownDuration, isFalse);
        expect(makeTask(durationSec: null).hasKnownDuration, isFalse);
      });
    });

    test('needsLocalMerge stays available for legacy spawn errors', () {
      final task = DownloadTask(
        id: 'task-1',
        url: 'https://example.com/live.m3u8',
        status: 'failed',
        progress: 100,
        createdAt: 0,
        error:
            'ffmpeg error: Failed to spawn ffmpeg: No such file or directory (os error 2)',
        tmpdir: '/tmp/m3u8-task-1',
      );

      expect(task.needsLocalMerge, isTrue);
    });

    test('needsLocalMerge false when status not failed', () {
      final task = makeTask(
        status: 'completed',
        error: 'ffmpeg not found',
        tmpdir: '/tmp/task',
      );
      expect(task.needsLocalMerge, isFalse);
    });

    test('needsLocalMerge false when no tmpdir', () {
      final task = makeTask(
        status: 'failed',
        error: 'ffmpeg not found',
      );
      expect(task.needsLocalMerge, isFalse);
    });

    test('needsLocalMerge false when error is unrelated', () {
      final task = makeTask(
        status: 'failed',
        error: 'network timeout',
        tmpdir: '/tmp/task',
      );
      expect(task.needsLocalMerge, isFalse);
    });

    test('placeholder creates queued task', () {
      final task = DownloadTask.placeholder(
        id: 'test-id',
        url: 'https://example.com/stream.m3u8',
      );

      expect(task.id, 'test-id');
      expect(task.status, 'queued');
      expect(task.progress, 0);
    });
  });
}
