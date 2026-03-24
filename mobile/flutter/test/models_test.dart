import 'package:flutter_test/flutter_test.dart';
import 'package:iptvgrab/src/models.dart';

void main() {
  test('indicatesMissingFfmpeg recognizes canonical missing binary errors', () {
    expect(
      indicatesMissingFfmpeg(
        'ffmpeg error: ffmpeg not found: No such file or directory (os error 2)',
      ),
      isTrue,
    );
  });

  test('indicatesMissingFfmpeg recognizes legacy spawn errors', () {
    expect(
      indicatesMissingFfmpeg(
        'ffmpeg error: Failed to spawn ffmpeg: No such file or directory (os error 2)',
      ),
      isTrue,
    );
  });

  test('DownloadTask.needsLocalMerge stays available for legacy spawn errors',
      () {
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
}
