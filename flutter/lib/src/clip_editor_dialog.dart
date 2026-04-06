import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'api_client.dart';
import 'controller.dart';
import 'media_player_page.dart';
import 'media_utils.dart';
import 'models.dart';
import 'utils.dart';

class ClipSelection {
  const ClipSelection({
    required this.start,
    required this.end,
  });

  final double start;
  final double end;
}

Future<void> showClipDialog(
  BuildContext context,
  AppController controller,
  DownloadTask task,
) async {
  try {
    final previewUri = task.output != null
        ? controller.downloadUri(task.output!)
        : controller.previewUri(task.id);
    final selection = await showDialog<ClipSelection>(
      context: context,
      builder: (_) => ClipEditorDialog(
        task: task,
        uri: previewUri,
        httpHeaders: controller.mediaRequestHeaders,
      ),
    );

    if (selection == null || !context.mounted) {
      return;
    }

    final filename =
        await controller.clipTask(task, selection.start, selection.end);
    if (!context.mounted) {
      return;
    }
    await Clipboard.setData(
        ClipboardData(text: controller.downloadUri(filename).toString()));
    if (!context.mounted) {
      return;
    }
    showMessage(context, 'Clip created. Opening the clipped file player.');
    await openMediaPlayer(
      context,
      title: filename,
      uri: controller.downloadUri(filename),
      httpHeaders: controller.mediaRequestHeaders,
      localFilePath: localMediaPathOrNull(controller, filename),
      localFileName: filename,
    );
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    showMessage(context, error.message, error: true);
  }
}

class ClipEditorDialog extends StatefulWidget {
  const ClipEditorDialog({
    super.key,
    required this.task,
    required this.uri,
    required this.httpHeaders,
  });

  final DownloadTask task;
  final Uri uri;
  final Map<String, String> httpHeaders;

  @override
  State<ClipEditorDialog> createState() => _ClipEditorDialogState();
}

class _ClipEditorDialogState extends State<ClipEditorDialog> {
  static const double _minimumClipLength = 0.5;

  VideoPlayerController? _previewController;
  String? _previewError;
  bool _previewReady = false;
  late double _clipStart;
  late double _clipEnd;

  @override
  void initState() {
    super.initState();
    _clipStart = 0;
    final initialEnd =
        widget.task.durationSec != null && widget.task.durationSec! > 30
            ? 30.0
            : widget.task.durationSec ?? 10.0;
    _clipEnd = math.max(_minimumClipLength, initialEnd);
    unawaited(_initializePreview());
  }

  @override
  void dispose() {
    _previewController?.removeListener(_handlePreviewUpdate);
    _previewController?.dispose();
    super.dispose();
  }

  double get _playerDurationSeconds {
    final controller = _previewController;
    if (controller == null || !controller.value.isInitialized) {
      return 0;
    }
    return controller.value.duration.inMilliseconds / 1000;
  }

  double get _currentPreviewSeconds {
    final controller = _previewController;
    if (controller == null || !controller.value.isInitialized) {
      return 0;
    }
    final current = controller.value.position.inMilliseconds / 1000;
    final max = _effectiveMaxDuration;
    return current.clamp(0.0, max).toDouble();
  }

  double get _effectiveMaxDuration {
    final fromTask = widget.task.durationSec ?? 0;
    final fromPreview = _playerDurationSeconds;
    final resolved = math.max(fromTask, fromPreview);
    if (resolved > 0) {
      return resolved;
    }
    return math.max(_clipEnd, 120.0);
  }

  bool get _hasRangeSlider =>
      (widget.task.hasKnownDuration || _playerDurationSeconds > 0) &&
      _effectiveMaxDuration >= 1;

  Future<void> _initializePreview() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        widget.uri,
        httpHeaders: widget.httpHeaders,
      );
      _previewController = controller;
      controller.addListener(_handlePreviewUpdate);
      await controller.initialize();
      await controller.setLooping(false);
      await controller.pause();
      if (!mounted) {
        controller.removeListener(_handlePreviewUpdate);
        await controller.dispose();
        return;
      }
      setState(() {
        _previewReady = true;
        _applyRangeState(start: _clipStart, end: _clipEnd);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _previewError = error.toString());
    }
  }

  void _handlePreviewUpdate() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  void _applyRangeState({required double start, required double end}) {
    final max = _effectiveMaxDuration;
    var nextStart = start.clamp(0.0, max).toDouble();
    var nextEnd = end.clamp(0.0, max).toDouble();

    if ((nextEnd - nextStart) < _minimumClipLength) {
      nextEnd = math.min(max, nextStart + _minimumClipLength);
      if ((nextEnd - nextStart) < _minimumClipLength) {
        nextStart = math.max(0.0, nextEnd - _minimumClipLength);
      }
    }

    _clipStart = nextStart;
    _clipEnd = nextEnd;
  }

  void _setRange({double? start, double? end}) {
    setState(() {
      _applyRangeState(
        start: start ?? _clipStart,
        end: end ?? _clipEnd,
      );
    });
  }

  Future<void> _seekTo(double seconds) async {
    final controller = _previewController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    final max = controller.value.duration > Duration.zero
        ? controller.value.duration.inMilliseconds / 1000
        : _effectiveMaxDuration;
    final clamped = seconds.clamp(0.0, max).toDouble();
    await controller.seekTo(Duration(milliseconds: (clamped * 1000).round()));
  }

  Future<void> _togglePreviewPlayback() async {
    final controller = _previewController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
      return;
    }
    await controller.play();
  }

  Widget _buildVideoArea(
    BuildContext context,
    VideoPlayerController? previewController,
  ) {
    return GestureDetector(
      onTap: _togglePreviewPlayback,
      child: Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: _previewError != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _previewError!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              )
            : !_previewReady || previewController == null
                ? const CircularProgressIndicator()
                : AspectRatio(
                    aspectRatio: previewController.value.aspectRatio > 0
                        ? previewController.value.aspectRatio
                        : 16 / 9,
                    child: VideoPlayer(previewController),
                  ),
      ),
    );
  }

  Widget _buildPlaybackBar(
    BuildContext context,
    VideoPlayerController? previewController,
    double currentPreview,
    double playerDuration,
    bool isPlaying,
  ) {
    return Container(
      color: const Color(0xFF1E1E2E),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_previewReady && playerDuration > 0)
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: currentPreview.clamp(0.0, playerDuration),
                min: 0,
                max: playerDuration,
                onChanged: (v) => unawaited(_seekTo(v)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: <Widget>[
                IconButton(
                  onPressed: _togglePreviewPlayback,
                  icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                  iconSize: 28,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Text(
                  playerDuration > 0
                      ? '${formatSeconds(currentPreview)} / ${formatSeconds(playerDuration)}'
                      : formatSeconds(currentPreview),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClipControls(BuildContext context) {
    return Container(
      color: const Color(0xFF161622),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_hasRangeSlider) ...<Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.play_arrow, color: Colors.orange, size: 16),
                const SizedBox(width: 4),
                Text(
                  formatSeconds(_clipStart),
                  style:
                      const TextStyle(color: Colors.orange, fontSize: 13),
                ),
                const Spacer(),
                Text(
                  'Clip: ${formatSeconds(_clipEnd - _clipStart)}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.white70),
                ),
                const Spacer(),
                Container(width: 10, height: 10, color: Colors.red),
                const SizedBox(width: 4),
                Text(
                  formatSeconds(_clipEnd),
                  style:
                      const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
            ),
            RangeSlider(
              values: RangeValues(_clipStart, _clipEnd),
              min: 0,
              max: _effectiveMaxDuration,
              divisions: math.max(
                  1, math.min(600, _effectiveMaxDuration.round())),
              labels: RangeLabels(
                formatSeconds(_clipStart),
                formatSeconds(_clipEnd),
              ),
              onChanged: (values) {
                final prevStart = _clipStart;
                final prevEnd = _clipEnd;
                _setRange(start: values.start, end: values.end);
                if ((values.start - prevStart).abs() > 0.01) {
                  unawaited(_seekTo(values.start));
                } else if ((values.end - prevEnd).abs() > 0.01) {
                  unawaited(_seekTo(values.end));
                }
              },
            ),
            const SizedBox(height: 4),
          ],
          Row(
            children: <Widget>[
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white,
                ),
                onPressed: (_clipEnd - _clipStart) < _minimumClipLength
                    ? null
                    : () => Navigator.of(context).pop(
                          ClipSelection(
                              start: _clipStart, end: _clipEnd),
                        ),
                icon: const Icon(Icons.content_cut, size: 16),
                label: const Text('Clip'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final previewController = _previewController;
    final playerDuration = _playerDurationSeconds;
    final currentPreview = _currentPreviewSeconds;
    final isPlaying = previewController?.value.isPlaying ?? false;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    final header = Container(
      color: const Color(0xFF1E1E2E),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: <Widget>[
          const Icon(Icons.play_circle_filled,
              color: Colors.blueAccent, size: 20),
          const SizedBox(width: 8),
          Text(
            'Preview',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            iconSize: 22,
          ),
        ],
      ),
    );

    final videoArea =
        _buildVideoArea(context, previewController);
    final playbackBar = _buildPlaybackBar(
        context, previewController, currentPreview, playerDuration, isPlaying);
    final clipControls = _buildClipControls(context);

    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: isLandscape
            // ── Landscape: video left | controls right ──────────
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  header,
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(child: videoArea),
                        SizedBox(
                          width: 280,
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                playbackBar,
                                clipControls,
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            // ── Portrait: stacked column ─────────────────────────
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  header,
                  Expanded(child: videoArea),
                  playbackBar,
                  clipControls,
                ],
              ),
      ),
    );
  }
}
