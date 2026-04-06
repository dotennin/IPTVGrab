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
import 'theme.dart';
import 'utils.dart';
import 'widgets.dart';

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

  late final TextEditingController _startController;
  late final TextEditingController _endController;

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
    _startController = TextEditingController(text: '0.0');
    _endController = TextEditingController(text: _clipEnd.toStringAsFixed(1));
    unawaited(_initializePreview());
  }

  @override
  void dispose() {
    _previewController?.removeListener(_handlePreviewUpdate);
    _previewController?.dispose();
    _startController.dispose();
    _endController.dispose();
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
        _applyRangeState(
          start: _clipStart,
          end: _clipEnd,
          syncTextFields: true,
        );
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

  void _syncTextFields() {
    _startController.value = TextEditingValue(
      text: _clipStart.toStringAsFixed(1),
      selection: TextSelection.collapsed(
        offset: _clipStart.toStringAsFixed(1).length,
      ),
    );
    _endController.value = TextEditingValue(
      text: _clipEnd.toStringAsFixed(1),
      selection: TextSelection.collapsed(
        offset: _clipEnd.toStringAsFixed(1).length,
      ),
    );
  }

  void _applyRangeState({
    required double start,
    required double end,
    required bool syncTextFields,
  }) {
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
    if (syncTextFields) {
      _syncTextFields();
    }
  }

  void _setRange({
    double? start,
    double? end,
    bool syncTextFields = true,
  }) {
    setState(() {
      _applyRangeState(
        start: start ?? _clipStart,
        end: end ?? _clipEnd,
        syncTextFields: syncTextFields,
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

  Future<void> _seekRelative(double seconds) async {
    await _seekTo(_currentPreviewSeconds + seconds);
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

  @override
  Widget build(BuildContext context) {
    final previewController = _previewController;
    final previewAspect = previewController != null &&
            previewController.value.isInitialized &&
            previewController.value.aspectRatio > 0
        ? previewController.value.aspectRatio
        : 16 / 9;
    final playerDuration = _playerDurationSeconds;
    final currentPreview = _currentPreviewSeconds;

    return AlertDialog(
      title: const Text('Create clip'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AspectRatio(
              aspectRatio: previewAspect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _previewError != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              _previewError!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        )
                      : !_previewReady || previewController == null
                          ? const Center(child: CircularProgressIndicator())
                          : VideoPlayer(previewController),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_previewReady && previewController != null) ...<Widget>[
              if (playerDuration > 0)
                Slider(
                  value: currentPreview.clamp(0.0, playerDuration),
                  min: 0,
                  max: playerDuration,
                  onChanged: (value) => unawaited(_seekTo(value)),
                ),
              Row(
                children: <Widget>[
                  Text(
                    playerDuration > 0
                        ? '${formatSeconds(currentPreview)} / ${formatSeconds(playerDuration)}'
                        : 'Current: ${formatSeconds(currentPreview)}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: appTextMuted),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => unawaited(_seekRelative(-5)),
                    icon: const Icon(Icons.replay_5),
                  ),
                  IconButton(
                    onPressed: _togglePreviewPlayback,
                    icon: Icon(
                      previewController.value.isPlaying
                          ? Icons.pause
                          : Icons.play_arrow,
                    ),
                  ),
                  IconButton(
                    onPressed: () => unawaited(_seekRelative(5)),
                    icon: const Icon(Icons.forward_5),
                  ),
                ],
              ),
              Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _setRange(start: currentPreview),
                          icon: const Icon(Icons.flag_outlined, size: 18),
                          label: const Text('Set start'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _setRange(end: currentPreview),
                          icon: const Icon(Icons.outlined_flag, size: 18),
                          label: const Text('Set end'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => unawaited(_seekTo(_clipStart)),
                          icon: const Icon(Icons.first_page, size: 18),
                          label: const Text('Jump to start'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => unawaited(_seekTo(_clipEnd)),
                          icon: const Icon(Icons.last_page, size: 18),
                          label: const Text('Jump to end'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            if (_hasRangeSlider) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: InfoChip(
                      label: 'Start',
                      value: formatSeconds(_clipStart),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InfoChip(
                      label: 'End',
                      value: formatSeconds(_clipEnd),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InfoChip(
                      label: 'Length',
                      value: formatSeconds(_clipEnd - _clipStart),
                    ),
                  ),
                ],
              ),
              RangeSlider(
                values: RangeValues(_clipStart, _clipEnd),
                min: 0,
                max: _effectiveMaxDuration,
                divisions:
                    math.max(1, math.min(600, _effectiveMaxDuration.round())),
                labels: RangeLabels(
                  formatSeconds(_clipStart),
                  formatSeconds(_clipEnd),
                ),
                onChanged: (values) => _setRange(
                  start: values.start,
                  end: values.end,
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final preset in <double>[15, 30, 60])
                    if (_effectiveMaxDuration >= preset)
                      OutlinedButton(
                        onPressed: () => _setRange(
                          end: math.min(
                              _clipStart + preset, _effectiveMaxDuration),
                        ),
                        child: Text('${preset.toInt()}s'),
                      ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _startController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Start (s)',
                      isDense: true,
                    ),
                    onChanged: (value) {
                      final parsed = double.tryParse(value.trim());
                      if (parsed == null) {
                        return;
                      }
                      _setRange(start: parsed, syncTextFields: false);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _endController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'End (s)',
                      isDense: true,
                    ),
                    onChanged: (value) {
                      final parsed = double.tryParse(value.trim());
                      if (parsed == null) {
                        return;
                      }
                      _setRange(end: parsed, syncTextFields: false);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_clipEnd - _clipStart) < _minimumClipLength
              ? null
              : () => Navigator.of(context).pop(
                    ClipSelection(start: _clipStart, end: _clipEnd),
                  ),
          child: const Text('Clip'),
        ),
      ],
    );
  }
}
