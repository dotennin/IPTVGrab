import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'api_client.dart';
import 'background_execution_bridge.dart';
import 'controller.dart';
import 'models.dart';
import 'native_ios_player.dart';

const Color _appBackground = Color(0xFF0B1220);
const Color _appSurface = Color(0xFF111827);
const Color _appSurfaceAlt = Color(0xFF172033);
const Color _appPrimary = Color(0xFF3B82F6);
const Color _appAccent = Color(0xFFF97316);
const Color _appSuccess = Color(0xFF22C55E);
const Color _appWarning = Color(0xFFF59E0B);
const Color _appDanger = Color(0xFFEF4444);
const Color _appTextMuted = Color(0xFF94A3B8);

class M3u8FlutterClientApp extends StatefulWidget {
  const M3u8FlutterClientApp({super.key});

  @override
  State<M3u8FlutterClientApp> createState() => _M3u8FlutterClientAppState();
}

class _M3u8FlutterClientAppState extends State<M3u8FlutterClientApp>
    with WidgetsBindingObserver {
  late final AppController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AppController();
    unawaited(_controller.bootstrapLocalServer());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_controller.handleAppLifecycleState(state));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MediaNest',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _appBackground,
        colorScheme: const ColorScheme.dark(
          primary: _appPrimary,
          secondary: _appAccent,
          surface: _appSurface,
          error: _appDanger,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: Color(0xFFE5E7EB),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _appBackground,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: _appSurface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _appSurfaceAlt,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            borderSide: BorderSide(color: _appPrimary, width: 1.4),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        progressIndicatorTheme:
            const ProgressIndicatorThemeData(color: _appPrimary),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _appSurface,
          indicatorColor: _appPrimary.withValues(alpha: 0.18),
          surfaceTintColor: Colors.transparent,
          height: 74,
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: _appSurfaceAlt,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          labelStyle: const TextStyle(color: Colors.white),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _appPrimary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Scaffold(
            appBar: AppBar(
              title: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('MediaNest',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text(
                    'Personal media archive',
                    style: TextStyle(fontSize: 12, color: _appTextMuted),
                  ),
                ],
              ),
              actions: <Widget>[],
            ),
            body: IndexedStack(
              index: _index,
              children: <Widget>[
                _PlaylistsTab(
                  controller: _controller,
                  onUseChannel: () => setState(() => _index = 2),
                ),
                _TasksTab(controller: _controller),
                _DownloadTab(
                  controller: _controller,
                  onOpenTasks: () => setState(() => _index = 1),
                ),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.playlist_play),
                  label: 'Sources',
                ),
                NavigationDestination(
                  icon: Icon(Icons.task_alt),
                  label: 'Activity',
                ),
                NavigationDestination(
                  icon: Icon(Icons.download),
                  label: 'Library',
                ),
              ],
              onDestinationSelected: (index) => setState(() => _index = index),
            ),
          );
        },
      ),
    );
  }
}

class _DownloadTab extends StatefulWidget {
  const _DownloadTab({
    required this.controller,
    required this.onOpenTasks,
  });

  final AppController controller;
  final VoidCallback onOpenTasks;

  @override
  State<_DownloadTab> createState() => _DownloadTabState();
}

class _DownloadTabState extends State<_DownloadTab> {
  late final TextEditingController _urlController;
  late final TextEditingController _headersController;
  late final TextEditingController _outputNameController;
  late final TextEditingController _concurrencyController;

  String _selectedQuality = 'best';

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _headersController = TextEditingController();
    _outputNameController = TextEditingController();
    _concurrencyController = TextEditingController(text: '8');
    widget.controller.suggestedUrl.addListener(_applySuggestedUrl);
  }

  @override
  void dispose() {
    widget.controller.suggestedUrl.removeListener(_applySuggestedUrl);
    _urlController.dispose();
    _headersController.dispose();
    _outputNameController.dispose();
    _concurrencyController.dispose();
    super.dispose();
  }

  void _applySuggestedUrl() {
    final url = widget.controller.suggestedUrl.value;
    if (url == null || url.isEmpty) {
      return;
    }
    _urlController.text = url;
    if (mounted) {
      _showMessage(context, 'Filled the source URL from your saved sources.');
    }
  }

  Future<void> _parse() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showMessage(context, 'Please enter a source URL.', error: true);
      return;
    }
    final headers = _parseHeadersText(_headersController.text);
    try {
      await widget.controller.parseInput(
        url: url,
        headers: headers,
      );
      if (!mounted) {
        return;
      }
      setState(() => _selectedQuality = 'best');
      _showMessage(context, 'Source checked successfully.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    }
  }

  Future<void> _startDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showMessage(context, 'Please enter a source URL.', error: true);
      return;
    }
    final headers = _parseHeadersText(_headersController.text);
    try {
      await widget.controller.startDownload(
        url: url,
        headers: headers,
        quality: _selectedQuality,
        concurrency: int.tryParse(_concurrencyController.text.trim()) ?? 8,
        outputName: _outputNameController.text.trim().isEmpty
            ? null
            : _outputNameController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      widget.onOpenTasks();
      _showMessage(context, 'Archive job started.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final parsedInfo = controller.parsedInfo;
    final qualityOptions = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: 'best', child: Text('Best')),
      const DropdownMenuItem(value: 'worst', child: Text('Worst')),
      if (parsedInfo != null)
        ...parsedInfo.streams.asMap().entries.map(
              (entry) => DropdownMenuItem<String>(
                value: entry.key.toString(),
                child: Text('#${entry.key} · ${entry.value.displayLabel}'),
              ),
            ),
    ];
    final selectedQuality =
        qualityOptions.any((item) => item.value == _selectedQuality)
            ? _selectedQuality
            : 'best';

    if (!controller.readyForApi) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Start the on-device media service first.'),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _appPrimary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.video_library_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Build your offline library',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        'Import a source you control, inspect its variants, and save a local copy for playback, clipping, and export.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: _appTextMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Import a source',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Use media URLs and headers from sources you own or are authorized to access.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: _appTextMuted),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'Source URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _headersController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Request headers (optional)',
                    helperText:
                        'One header per line, for example Authorization: Bearer ...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _outputNameController,
                        decoration: const InputDecoration(
                          labelText: 'Saved file name (optional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _concurrencyController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Workers',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedQuality,
                  items: qualityOptions,
                  onChanged: controller.isBusy
                      ? null
                      : (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() => _selectedQuality = value);
                        },
                  decoration: const InputDecoration(
                    labelText: 'Variant',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: controller.isBusy ? null : _parse,
                      icon: const Icon(Icons.analytics_outlined),
                      label: const Text('Inspect source'),
                    ),
                    FilledButton.icon(
                      onPressed: controller.isBusy ? null : _startDownload,
                      icon: const Icon(Icons.download_for_offline_outlined),
                      label: const Text('Save offline'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (parsedInfo != null) ...<Widget>[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Source details',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _InfoChip(label: 'Type', value: parsedInfo.kind),
                      _InfoChip(
                          label: 'Live',
                          value: parsedInfo.isLive ? 'Yes' : 'No'),
                      _InfoChip(
                          label: 'Encrypted',
                          value: parsedInfo.encrypted ? 'Yes' : 'No'),
                      _InfoChip(
                          label: 'Segments',
                          value: parsedInfo.segments.toString()),
                      _InfoChip(
                          label: 'Duration',
                          value: _formatSeconds(parsedInfo.duration)),
                    ],
                  ),
                  if (parsedInfo.streams.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text('Available variants',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ...parsedInfo.streams.asMap().entries.map(
                          (entry) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: CircleAvatar(child: Text('${entry.key}')),
                            title: Text(entry.value.displayLabel),
                            subtitle: Text(entry.value.url),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _TasksTab extends StatelessWidget {
  const _TasksTab({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.readyForApi) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Connect and sign in before managing library activity.'),
        ),
      );
    }

    final tasks = controller.tasks;
    if (tasks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.task_alt, size: 48),
              const SizedBox(height: 12),
              const Text('No library activity yet.'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    await controller.refreshTasks();
                  } on ApiException catch (error) {
                    if (!context.mounted) {
                      return;
                    }
                    _showMessage(context, error.message, error: true);
                  }
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: controller.refreshTasks,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: tasks.length,
        itemBuilder: (context, index) {
          final task = tasks[index];
          final autoFinalizing = controller.isAutoFinalizingTask(task.id);
          final treatedAsStopped = controller.treatTaskAsStopped(task);
          final statusLabel = _taskStatusLabel(task, controller);
          final statusColor = _taskStatusColor(task, controller);
          final displayError = _taskErrorMessage(task, controller);
          final progressValue =
              task.isRecording || task.isStopping || autoFinalizing
                  ? null
                  : task.progress.clamp(0, 100) / 100;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          task.output ?? task.outputName ?? task.url,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Chip(
                        avatar:
                            Icon(Icons.circle, size: 12, color: statusColor),
                        label: Text(statusLabel),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    task.url,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: _appTextMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progressValue),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _InfoChip(label: 'Progress', value: '${task.progress}%'),
                      _InfoChip(
                          label: 'Speed',
                          value: '${task.speedMbps.toStringAsFixed(2)} Mbps'),
                      _InfoChip(
                          label: 'Saved',
                          value: _formatBytes(task.bytesDownloaded)),
                      if (task.total > 0)
                        _InfoChip(
                            label: 'Parts',
                            value: '${task.downloaded}/${task.total}'),
                      if (task.recordedSegments > 0)
                        _InfoChip(
                            label: 'Captured',
                            value: task.recordedSegments.toString()),
                      if (task.elapsedSec > 0)
                        _InfoChip(
                            label: 'Elapsed',
                            value: _formatClock(task.elapsedSec)),
                      if (task.hasKnownDuration)
                        _InfoChip(
                          label: 'Duration',
                          value: _formatSeconds(task.durationSec!),
                        ),
                      _InfoChip(label: 'Quality', value: task.quality),
                    ],
                  ),
                  if (displayError != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (task.needsLocalMerge ? _appWarning : _appDanger)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color:
                              (task.needsLocalMerge ? _appWarning : _appDanger)
                                  .withValues(alpha: 0.28),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(
                            task.needsLocalMerge
                                ? Icons.build_circle_outlined
                                : Icons.warning_amber_rounded,
                            color:
                                task.needsLocalMerge ? _appWarning : _appDanger,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              displayError,
                              style: TextStyle(
                                color: task.needsLocalMerge
                                    ? _appWarning
                                    : Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: controller.isBusy ||
                                task.isStopping ||
                                autoFinalizing
                            ? null
                            : () async {
                                try {
                                  final result =
                                      await controller.deleteOrStopTask(task);
                                  if (!context.mounted) {
                                    return;
                                  }
                                  if (task.isRecording &&
                                      result == 'stopping') {
                                    _showMessage(
                                      context,
                                      'Stop requested. Finalizing the local media file...',
                                    );
                                  } else {
                                      _showMessage(
                                          context, 'Action completed: $result');
                                  }
                                } on ApiException catch (error) {
                                  if (!context.mounted) {
                                    return;
                                  }
                                  _showMessage(context, error.message,
                                      error: true);
                                }
                              },
                        icon: Icon(autoFinalizing
                            ? Icons.save_alt_rounded
                            : task.isRecording
                                ? Icons.stop
                                : task.isStopping
                                    ? Icons.hourglass_bottom
                                    : task.isTerminal
                                        ? Icons.delete
                                        : Icons.close),
                        label: Text(autoFinalizing
                            ? 'Saving...'
                            : task.isRecording
                                ? 'Stop & finalize'
                                : task.isStopping
                                    ? 'Stopping...'
                                    : task.isTerminal
                                        ? 'Remove'
                                        : 'Cancel job'),
                      ),
                      if (task.canResume)
                        OutlinedButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () async {
                                  try {
                                    await controller.resumeTask(task.id);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context, 'Resume requested.');
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Resume'),
                        ),
                      if (task.canRestart)
                        OutlinedButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () async {
                                  try {
                                    await controller.restartTask(task.id);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context, 'Restart requested.');
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.restart_alt),
                          label: const Text('Restart'),
                        ),
                      if (task.canForkRecording)
                        FilledButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () async {
                                  try {
                                    final newTaskId =
                                        await controller.forkRecording(task.id);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context,
                                        'Stopped the current capture and started a new one (${_shortId(newTaskId)}).');
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.call_split),
                          label: const Text('Stop & new'),
                        ),
                      if (task.canRestartRecording)
                        OutlinedButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () async {
                                  try {
                                    final newTaskId = await controller
                                        .restartRecording(task.id);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context,
                                        'Capture restarted (${_shortId(newTaskId)}).');
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.replay_circle_filled_outlined),
                          label: const Text('Restart rec'),
                        ),
                      if (task.needsLocalMerge)
                        FilledButton.tonalIcon(
                          onPressed: controller.isBusy || autoFinalizing
                              ? null
                              : () async {
                                  try {
                                    final filename = await controller
                                        .finalizeTaskLocally(task);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context,
                                        'Merged locally with FFmpegKit.');
                                    await _openMediaPlayer(
                                      context,
                                      title: filename,
                                      uri: controller.downloadUri(filename),
                                      httpHeaders:
                                          controller.mediaRequestHeaders,
                                      localFilePath: _localMediaPathOrNull(
                                        controller,
                                        filename,
                                      ),
                                      localFileName: filename,
                                    );
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    _showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.build_circle_outlined),
                          label: Text(autoFinalizing
                              ? 'Saving locally...'
                              : 'Finalize locally'),
                        ),
                      if (task.canClip)
                        OutlinedButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () =>
                                  _showClipDialog(context, controller, task),
                          icon: const Icon(Icons.content_cut),
                          label: const Text('Clip'),
                        ),
                      if (task.output != null)
                        FilledButton.tonalIcon(
                          onPressed: () => _openMediaPlayer(
                            context,
                            title: task.output!,
                            uri: controller.downloadUri(task.output!),
                            httpHeaders: controller.mediaRequestHeaders,
                            localFilePath:
                                _localMediaPathOrNull(controller, task.output!),
                            localFileName: task.output!,
                          ),
                          icon: const Icon(Icons.play_circle_fill),
                          label: const Text('Watch file'),
                        ),
                      if (task.output != null)
                        OutlinedButton.icon(
                          onPressed: () => _shareLocalMediaFromController(
                            context,
                            controller,
                            task.output!,
                          ),
                          icon: const Icon(Icons.ios_share),
                          label: const Text('Share'),
                        ),
                      if (task.output != null)
                        OutlinedButton.icon(
                          onPressed: () =>
                              _saveLocalMediaToPhotosFromController(
                            context,
                            controller,
                            task.output!,
                          ),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Save to Photos'),
                        ),
                      if (task.canPreview)
                        FilledButton.tonalIcon(
                          onPressed: () => _openMediaPlayer(
                            context,
                            title: 'Preview · ${task.id}',
                            uri: controller.previewUri(task.id),
                            httpHeaders: controller.mediaRequestHeaders,
                            isLive: true,
                          ),
                          icon: const Icon(Icons.live_tv),
                          label: Text(treatedAsStopped
                              ? 'Open closing preview'
                              : 'Open preview'),
                        ),
                      if (task.canPreview)
                        OutlinedButton.icon(
                          onPressed: () => _copyToClipboard(
                            context,
                            controller.previewUri(task.id).toString(),
                            label:
                                'Preview URL copied. It still requires the active session cookie when auth is enabled.',
                          ),
                          icon: const Icon(Icons.live_tv),
                          label: const Text('Copy preview URL'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PlaylistsTab extends StatefulWidget {
  const _PlaylistsTab({
    required this.controller,
    required this.onUseChannel,
  });

  final AppController controller;
  final VoidCallback onUseChannel;

  @override
  State<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<_PlaylistsTab> {
  late final TextEditingController _searchController;
  String? _selectedPlaylistId;
  String _selectedGroup = 'All groups';
  bool _showUnavailableChannels = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.readyForApi) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Connect and sign in before loading your source lists.'),
        ),
      );
    }

    final rawItems = controller.playlists
        .expand(
          (playlist) => playlist.channels.map((channel) =>
              _PlaylistBrowserItem.fromPlaylist(playlist, channel)),
        )
        .toList();
    final mergedGroups =
        controller.mergedPlaylistConfig?.groups ?? const <MergedGroup>[];
    final mergedItems = mergedGroups
        .where((group) => group.enabled)
        .expand(
          (group) => group.channels.where((channel) => channel.enabled).map(
              (channel) => _PlaylistBrowserItem.fromMerged(group, channel)),
        )
        .toList();
    final usingMergedView =
        _selectedPlaylistId == null && controller.mergedPlaylistConfig != null;
    final playlistScoped = usingMergedView
        ? mergedItems
        : _selectedPlaylistId == null
            ? rawItems
            : rawItems
                .where((item) => item.playlistId == _selectedPlaylistId)
                .toList();

    Playlist? selectedPlaylist;
    if (_selectedPlaylistId != null) {
      for (final playlist in controller.playlists) {
        if (playlist.id == _selectedPlaylistId) {
          selectedPlaylist = playlist;
          break;
        }
      }
    }

    final availableGroups = <String>{
      'All groups',
      ...playlistScoped
          .map((item) => item.groupName)
          .where((group) => group.isNotEmpty),
    }.toList()
      ..sort();
    final activeGroup = availableGroups.contains(_selectedGroup)
        ? _selectedGroup
        : 'All groups';
    final query = _searchController.text.trim().toLowerCase();
    final visibleItems = playlistScoped.where((item) {
      final matchesGroup =
          activeGroup == 'All groups' || item.groupName == activeGroup;
      final haystack = <String>[
        item.channelName,
        item.channelUrl,
        item.groupName,
        item.playlistName,
        item.sourcePlaylistName ?? '',
      ].join(' ').toLowerCase();
      final matchesQuery = query.isEmpty || haystack.contains(query);
      if (!matchesGroup || !matchesQuery) {
        return false;
      }
      if (_showUnavailableChannels) {
        return true;
      }
      return controller.healthForUrl(item.channelUrl)?.isAvailable == true;
    }).toList();
    final waitingForInitialHealthResults = !_showUnavailableChannels &&
        controller.healthCache.isEmpty &&
        controller.healthState.running &&
        playlistScoped.isNotEmpty;
    final hiddenUnavailableCount =
        math.max(0, playlistScoped.length - visibleItems.length);
    final playlistSummary = usingMergedView
        ? 'Merged library view'
        : selectedPlaylist?.name ?? 'All source lists';

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Sources',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      playlistSummary,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: _appTextMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (selectedPlaylist != null)
                Builder(
                  builder: (context) {
                    final playlist = selectedPlaylist;
                    if (playlist == null) {
                      return const SizedBox.shrink();
                    }
                    return PopupMenuButton<String>(
                      tooltip: 'Manage selected source list',
                      onSelected: (value) async {
                        try {
                          if (value == 'refresh') {
                            await controller.refreshPlaylist(playlist.id);
                            if (!context.mounted) {
                              return;
                            }
                            _showMessage(context, 'Source list refreshed.');
                          } else if (value == 'edit') {
                            await _showEditPlaylistDialog(
                              context,
                              controller,
                              playlist,
                            );
                          } else if (value == 'delete') {
                            await controller.deletePlaylist(playlist.id);
                            if (!context.mounted) {
                              return;
                            }
                            setState(() => _selectedPlaylistId = null);
                            _showMessage(context, 'Source list deleted.');
                          }
                        } on ApiException catch (error) {
                          if (!context.mounted) {
                            return;
                          }
                          _showMessage(context, error.message, error: true);
                        }
                      },
                      itemBuilder: (context) => const <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'refresh',
                          child: Text('Refresh selected'),
                        ),
                        PopupMenuItem<String>(
                          value: 'edit',
                          child: Text('Edit selected'),
                        ),
                        PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('Delete selected'),
                        ),
                      ],
                      icon: const Icon(Icons.more_horiz),
                    );
                  },
                ),
              IconButton.filledTonal(
                tooltip: controller.healthState.running
                    ? 'Source health check is running'
                    : 'Run health check',
                onPressed: controller.isBusy || controller.healthState.running
                    ? null
                    : () async {
                        try {
                          await controller.runHealthCheck();
                          if (!context.mounted) {
                            return;
                          }
                          _showMessage(
                              context, 'Source health check started.');
                        } on ApiException catch (error) {
                          if (!context.mounted) {
                            return;
                          }
                          _showMessage(context, error.message, error: true);
                        }
                      },
                icon: Icon(
                  controller.healthState.running
                      ? Icons.sync
                      : Icons.health_and_safety_outlined,
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                tooltip: 'Refresh sources',
                onPressed: controller.isBusy
                    ? null
                    : () async {
                        try {
                          await controller.refreshData(
                            runHealthCheckAfterRefresh: true,
                          );
                        } on ApiException catch (error) {
                          if (!context.mounted) {
                            return;
                          }
                          _showMessage(context, error.message, error: true);
                        }
                      },
                icon: const Icon(Icons.refresh),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                tooltip: 'Edit all source lists',
                onPressed: controller.isBusy
                    ? null
                    : () async {
                        final saved = await Navigator.of(context).push<bool>(
                          MaterialPageRoute<bool>(
                            builder: (_) => _AllPlaylistsEditorPage(
                              controller: controller,
                            ),
                          ),
                        );
                        if (saved == true && context.mounted) {
                          _showMessage(context, 'Source list configuration saved.');
                        }
                      },
                icon: const Icon(Icons.edit_note),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                tooltip: 'Add source list',
                onPressed: controller.isBusy
                    ? null
                    : () => _showAddPlaylistDialog(context, controller),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        if (controller.playlists.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: <Widget>[
                    TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                                icon: const Icon(Icons.close),
                              ),
                        labelText: 'Search sources, groups or list names',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedPlaylistId ?? '__all__',
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'Source list',
                            ),
                            items: <DropdownMenuItem<String>>[
                              const DropdownMenuItem<String>(
                                value: '__all__',
                                child: Text('All source lists'),
                              ),
                              ...controller.playlists.map(
                                (playlist) => DropdownMenuItem<String>(
                                  value: playlist.id,
                                  child: Text(playlist.name),
                                ),
                              ),
                            ],
                            onChanged: (value) {
                              setState(() {
                                _selectedPlaylistId =
                                    value == null || value == '__all__'
                                        ? null
                                        : value;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: activeGroup,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'Group',
                            ),
                            items: availableGroups
                                .map(
                                  (group) => DropdownMenuItem<String>(
                                    value: group,
                                    child: Text(group),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() => _selectedGroup = value);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildChannelFilterRow(
                      context,
                      visibleItems: visibleItems,
                      playlistScoped: playlistScoped,
                      hiddenUnavailableCount: hiddenUnavailableCount,
                      waitingForInitialHealthResults:
                          waitingForInitialHealthResults,
                    ),
                    if (controller.healthState.running) ...<Widget>[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: controller.healthState.total <= 0
                            ? null
                            : controller.healthState.done /
                                controller.healthState.total,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => controller.refreshData(
              runHealthCheckAfterRefresh: true,
            ),
            child: controller.playlists.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(24),
                    children: const <Widget>[
                      SizedBox(height: 80),
                      Icon(Icons.playlist_add, size: 48),
                      SizedBox(height: 12),
                      Center(child: Text('No source lists saved yet.')),
                    ],
                  )
                : visibleItems.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(24),
                        children: <Widget>[
                          const SizedBox(height: 72),
                          Icon(
                            waitingForInitialHealthResults
                                ? Icons.health_and_safety_outlined
                                : Icons.search_off,
                            size: 48,
                          ),
                          const SizedBox(height: 12),
                          Center(
                            child: Text(
                              waitingForInitialHealthResults
                                  ? 'Scanning source availability. Unavailable entries stay hidden until results arrive.'
                                  : usingMergedView && playlistScoped.isEmpty
                                      ? 'No enabled entries are exposed by the merged library view. Open "Edit all" to re-enable groups or sources.'
                                      : _showUnavailableChannels
                                          ? 'No sources match the current filters.'
                                          : 'No available sources match the current filters. Turn on "Show unavailable channels" to inspect unavailable entries.',
                            ),
                          ),
                        ],
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 320,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          mainAxisExtent: 134,
                        ),
                        itemCount: visibleItems.length,
                        itemBuilder: (context, index) {
                          final item = visibleItems[index];
                          final health =
                              controller.healthForUrl(item.channelUrl);
                          final meta = <String>[
                            item.playlistName,
                            if (item.groupName.isNotEmpty) item.groupName,
                          ].join(' • ');
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      _ChannelLogo(url: item.logoUrl, size: 40),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              item.channelName,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              meta,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                      color: _appTextMuted),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        width: 12,
                                        height: 12,
                                        decoration: BoxDecoration(
                                          color: _healthStatusColor(
                                              health?.status),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Spacer(),
                                  Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: FilledButton.tonalIcon(
                                          style: FilledButton.styleFrom(
                                            minimumSize:
                                                const Size.fromHeight(40),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 8,
                                            ),
                                          ),
                                          onPressed: () => _openMediaPlayer(
                                            context,
                                            title: item.channelName,
                                            uri: controller.watchProxyUri(
                                              item.channelUrl,
                                            ),
                                            httpHeaders:
                                                controller.mediaRequestHeaders,
                                            isLive: true,
                                            copyUrl: item.channelUrl,
                                            copyLabel: 'Source URL copied.',
                                            onGrabRequested: () {
                                              Navigator.of(context).maybePop();
                                              controller.suggestDownloadUrl(
                                                item.channelUrl,
                                              );
                                              widget.onUseChannel();
                                            },
                                            allowPictureInPicture: true,
                                            onFetchVariants: () =>
                                                controller.parseStreamVariants(
                                              url: item.channelUrl,
                                              headers: controller
                                                  .mediaRequestHeaders,
                                            ),
                                          ),
                                          icon: const Icon(
                                              Icons.play_circle_fill),
                                          label: const Text(''),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton.filledTonal(
                                        tooltip:
                                            'Open Library with this source URL',
                                        onPressed: () {
                                          controller.suggestDownloadUrl(
                                            item.channelUrl,
                                          );
                                          widget.onUseChannel();
                                        },
                                        icon: const Icon(
                                            Icons.download_for_offline),
                                      ),
                                      const SizedBox(width: 4),
                                      IconButton.outlined(
                                        tooltip: 'Copy source M3U8 URL',
                                        onPressed: () => _copyToClipboard(
                                          context,
                                          item.channelUrl,
                                          label: 'Source URL copied.',
                                        ),
                                        icon: const Icon(Icons.copy),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }

  /// Builds the channel filter row with toggle and statistics.
  Widget _buildChannelFilterRow(
    BuildContext context, {
    required List visibleItems,
    required List playlistScoped,
    required int hiddenUnavailableCount,
    required bool waitingForInitialHealthResults,
  }) {
    final theme = Theme.of(context);
    final isActiveOnly = !_showUnavailableChannels;

    return Row(
      children: [
        // Checkbox for toggling "Active Only"
        Checkbox(
          value: isActiveOnly,
          onChanged: (value) =>
              setState(() => _showUnavailableChannels = !(value ?? true)),
        ),
        // Label text
        Text(
          'Active Only',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(width: 16),
        // Statistics text
        Expanded(
          child: Text(
            _buildChannelStatsText(
              waitingForHealthResults: waitingForInitialHealthResults,
              isActiveOnly: isActiveOnly,
              visibleCount: visibleItems.length,
              totalCount: playlistScoped.length,
              hiddenCount: hiddenUnavailableCount,
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: _appTextMuted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// Builds the statistics text for channel count display.
  String _buildChannelStatsText({
    required bool waitingForHealthResults,
    required bool isActiveOnly,
    required int visibleCount,
    required int totalCount,
    required int hiddenCount,
  }) {
    if (waitingForHealthResults) {
      return 'Source health scan is still running.';
    }

    if (isActiveOnly) {
      return 'Showing $visibleCount/$totalCount matching sources.';
    }

    return 'Healthy $visibleCount/$totalCount · Hidden $hiddenCount';
  }
}

class _PlaylistBrowserItem {
  const _PlaylistBrowserItem({
    required this.playlistId,
    required this.playlistName,
    required this.channelName,
    required this.channelUrl,
    required this.groupName,
    required this.logoUrl,
    this.sourcePlaylistName,
  });

  factory _PlaylistBrowserItem.fromPlaylist(
    Playlist playlist,
    PlaylistChannel channel,
  ) {
    return _PlaylistBrowserItem(
      playlistId: playlist.id,
      playlistName: playlist.name,
      channelName: channel.name,
      channelUrl: channel.url,
      groupName: channel.groupName,
      logoUrl: channel.logo,
      sourcePlaylistName: playlist.name,
    );
  }

  factory _PlaylistBrowserItem.fromMerged(
    MergedGroup group,
    MergedChannel channel,
  ) {
    return _PlaylistBrowserItem(
      playlistId: channel.sourcePlaylistId ?? '__merged__',
      playlistName:
          channel.sourcePlaylistName ?? (channel.custom ? 'Custom' : 'Merged'),
      channelName: channel.name,
      channelUrl: channel.url,
      groupName: group.name,
      logoUrl: channel.tvgLogo,
      sourcePlaylistName: channel.sourcePlaylistName,
    );
  }

  final String playlistId;
  final String playlistName;
  final String channelName;
  final String channelUrl;
  final String groupName;
  final String? logoUrl;
  final String? sourcePlaylistName;
}

class _ChannelLogo extends StatelessWidget {
  const _ChannelLogo({
    required this.url,
    this.size = 40,
  });

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return CircleAvatar(
        radius: size / 2,
        child: const Icon(Icons.tv),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => CircleAvatar(
            radius: size / 2, child: const Icon(Icons.broken_image)),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(label: Text('$label: $value'));
  }
}

Future<void> _openMediaPlayer(
  BuildContext context, {
  required String title,
  required Uri uri,
  required Map<String, String> httpHeaders,
  bool isLive = false,
  String? localFilePath,
  String? localFileName,
  String? copyUrl,
  String? copyLabel,
  VoidCallback? onGrabRequested,
  bool allowPictureInPicture = false,
  Future<List<StreamVariant>> Function()? onFetchVariants,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _MediaPlayerPage(
        title: title,
        uri: uri,
        httpHeaders: httpHeaders,
        isLive: isLive,
        localFilePath: localFilePath,
        localFileName: localFileName,
        copyUrl: copyUrl,
        copyLabel: copyLabel,
        onGrabRequested: onGrabRequested,
        allowPictureInPicture: allowPictureInPicture,
        onFetchVariants: onFetchVariants,
      ),
    ),
  );
}

class _MediaPlayerPage extends StatefulWidget {
  const _MediaPlayerPage({
    required this.title,
    required this.uri,
    required this.httpHeaders,
    this.isLive = false,
    this.localFilePath,
    this.localFileName,
    this.copyUrl,
    this.copyLabel,
    this.onGrabRequested,
    this.allowPictureInPicture = false,
    this.onFetchVariants,
  });

  final String title;
  final Uri uri;
  final Map<String, String> httpHeaders;
  final bool isLive;
  final String? localFilePath;
  final String? localFileName;
  final String? copyUrl;
  final String? copyLabel;
  final VoidCallback? onGrabRequested;
  final bool allowPictureInPicture;
  final Future<List<StreamVariant>> Function()? onFetchVariants;

  @override
  State<_MediaPlayerPage> createState() => _MediaPlayerPageState();
}

class _MediaPlayerPageState extends State<_MediaPlayerPage> {
  VideoPlayerController? _controller;
  NativeIosPlayerController? _iosController;
  String? _error;
  bool _initialized = false;
  bool _isFullscreen = false;
  bool _showControls = true;
  bool _muted = false;
  bool _enteringPictureInPicture = false;
  String? _pictureInPictureFailure;
  List<String> _pictureInPictureReasons = const <String>[];
  Timer? _controlsTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  bool _settingFullscreen = false;
  DateTime? _gyroToggleTime;
  // Stable key so Flutter moves rather than recreates the player subtree
  // when _isFullscreen flips (tree depth changes Center→Padding/Column).
  // Without this, VideoPlayer/_NativeIosPlayerView is destroyed and
  // rebuilt every fullscreen toggle, opening a duplicate audio stream.
  final GlobalKey _playerKey = GlobalKey();

  // Quality / variant selection
  List<StreamVariant> _variants = const [];
  bool _fetchingVariants = false;
  bool _variantsLoaded = false;
  int _selectedVariantIndex = -1; // -1 = original / auto

  // Double-tap seek + visual feedback
  Offset? _doubleTapPos;
  int _seekFeedback = 0; // positive = forward, negative = rewind
  Timer? _seekFeedbackTimer;

  bool get _usesNativeIosPlayer => Platform.isIOS;

  bool get _playerInitialized => _usesNativeIosPlayer
      ? (_iosController?.initialized ?? false)
      : _initialized;

  bool get _playerIsPlaying => _usesNativeIosPlayer
      ? (_iosController?.isPlaying ?? false)
      : _controller!.value.isPlaying;

  Duration get _playerPosition => _usesNativeIosPlayer
      ? (_iosController?.position ?? Duration.zero)
      : _controller!.value.position;

  Duration get _playerDuration => _usesNativeIosPlayer
      ? (_iosController?.duration ?? Duration.zero)
      : _controller!.value.duration;

  double get _playerAspectRatio {
    if (_usesNativeIosPlayer) {
      final aspectRatio = _iosController?.aspectRatio ?? 16 / 9;
      return aspectRatio > 0 ? aspectRatio : 16 / 9;
    }
    final controller = _controller!;
    return controller.value.isInitialized && controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
  }

  String? get _playerError =>
      _usesNativeIosPlayer ? (_iosController?.error ?? _error) : _error;

  List<String> get _pictureInPictureDiagnostics {
    final reasons = <String>[
      ...(_iosController?.diagnostics ?? const <String>[]),
      ..._pictureInPictureReasons,
    ];
    if (_usesNativeIosPlayer &&
        !(_iosController?.isPictureInPictureSupported ?? false)) {
      reasons.add(
        'This iPhone or iOS build reports that Picture in Picture is not supported.',
      );
    }
    if (_usesNativeIosPlayer &&
        _playerInitialized &&
        !(_iosController?.isPictureInPicturePossible ?? false)) {
      reasons.add(
        'The native AVPictureInPictureController still reports that Picture in Picture is not currently possible for this stream.',
      );
    }
    if (_usesNativeIosPlayer && !_playerInitialized) {
      reasons.add(
        'The native player is still initializing, so Picture in Picture is not ready yet.',
      );
    }
    if (_playerError != null) {
      reasons.add('Playback error: $_playerError');
    }
    return _dedupeMessages(reasons);
  }

  @override
  void initState() {
    super.initState();
    if (_usesNativeIosPlayer) {
      _iosController = NativeIosPlayerController(
        uri: widget.uri,
        httpHeaders: widget.httpHeaders,
        isLive: widget.isLive,
      )..addListener(_handleControllerUpdate);
    } else {
      _controller = VideoPlayerController.networkUrl(
        widget.uri,
        httpHeaders: widget.httpHeaders,
      );
      _controller!.addListener(_handleControllerUpdate);
      unawaited(_initialize());
    }
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen(_onAccelerometer);
  }

  void _onAccelerometer(AccelerometerEvent event) {
    if (_settingFullscreen) return;
    // Ignore sensor for 1.5 s after each gyro toggle to prevent rapid
    // re-triggering that would restart the video_player audio session
    // and create overlapping streams.
    final now = DateTime.now();
    if (_gyroToggleTime != null &&
        now.difference(_gyroToggleTime!) <
            const Duration(milliseconds: 1500)) {
      return;
    }
    final absX = event.x.abs();
    final absY = event.y.abs();
    // Hysteresis: strong landscape signal (≥7) with portrait axis quiet (<5).
    if (!_isFullscreen && absX >= 7.0 && absY < 5.0) {
      _gyroToggleTime = now;
      unawaited(_setFullscreen(true, fromGyro: true));
    } else if (_isFullscreen && absY >= 7.0 && absX < 5.0) {
      _gyroToggleTime = now;
      unawaited(_setFullscreen(false, fromGyro: true));
    }
  }

  Future<void> _initialize() async {
    try {
      final controller = _controller!;
      await controller.initialize();
      await controller.setLooping(!widget.isLive);
      await controller.setVolume(_muted ? 0 : 1);
      await controller.play();
      if (!mounted) {
        return;
      }
      setState(() => _initialized = true);
      _scheduleControlsHide();
      unawaited(_loadVariants());
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  void _handleControllerUpdate() {
    if (!mounted) {
      return;
    }
    setState(() {});
    // Trigger variant loading once when the native iOS player finishes init.
    if (_usesNativeIosPlayer && _playerInitialized && !_variantsLoaded) {
      _variantsLoaded = true;
      unawaited(_loadVariants());
    }
  }

  Future<void> _togglePlayback() async {
    if (_playerIsPlaying) {
      if (_usesNativeIosPlayer) {
        await _iosController!.pause();
      } else {
        await _controller!.pause();
      }
      _controlsTimer?.cancel();
      setState(() => _showControls = true);
      return;
    }
    if (_usesNativeIosPlayer) {
      await _iosController!.play();
    } else {
      await _controller!.play();
    }
    _scheduleControlsHide();
  }

  Future<void> _seekRelative(int seconds) async {
    final position = _playerPosition;
    final duration = _playerDuration;
    final target = position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (duration > Duration.zero && target > duration ? duration : target);
    await _seekTo(clamped);
    _scheduleControlsHide();
  }

  Future<void> _seekTo(Duration position) async {
    if (_usesNativeIosPlayer) {
      await _iosController!.seekTo(position);
    } else {
      await _controller!.seekTo(position);
    }
  }

  Future<void> _setMuted(bool value) async {
    if (_usesNativeIosPlayer) {
      await _iosController!.setMuted(value);
    } else {
      await _controller!.setVolume(value ? 0 : 1);
    }
    if (!mounted) {
      return;
    }
    setState(() => _muted = value);
    _scheduleControlsHide();
  }

  Future<void> _setFullscreen(bool enabled, {bool fromGyro = false}) async {
    if (_settingFullscreen) return;
    _settingFullscreen = true;
    try {
      if (enabled) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        // When triggered by gyroscope the device is already in the correct
        // orientation; locking here would cause an Activity re-creation on
        // Android and respawn the video player (duplicate audio/stutter).
        if (!fromGyro) {
          await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        }
      } else {
        _restoreSystemUi();
      }
      if (!mounted) return;
      setState(() {
        _isFullscreen = enabled;
        _showControls = true;
      });
      _scheduleControlsHide();
    } finally {
      _settingFullscreen = false;
    }
  }

  void _restoreSystemUi() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _scheduleControlsHide();
    } else {
      _controlsTimer?.cancel();
    }
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_isFullscreen || !_playerIsPlaying) {
      return;
    }
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !_playerIsPlaying) {
        return;
      }
      setState(() => _showControls = false);
    });
  }

  String get _resolvedCopyUrl => widget.copyUrl ?? widget.uri.toString();

  // ── Quality / variant selection ──────────────────────────────────────────

  Future<void> _loadVariants() async {
    if (widget.onFetchVariants == null || _fetchingVariants) return;
    setState(() => _fetchingVariants = true);
    try {
      final variants = await widget.onFetchVariants!();
      if (!mounted) return;
      setState(() {
        _variants = variants;
        _selectedVariantIndex = variants.isEmpty ? -1 : 0;
        _variantsLoaded = true;
        _fetchingVariants = false;
      });
    } catch (_) {
      if (mounted) setState(() => _fetchingVariants = false);
    }
  }

  Future<void> _switchVariant(int index) async {
    if (index == _selectedVariantIndex) return;
    final variant = _variants[index];
    final uri = Uri.parse(variant.url);
    setState(() {
      _selectedVariantIndex = index;
      _initialized = false;
    });
    if (_usesNativeIosPlayer) {
      final oldCtrl = _iosController;
      oldCtrl?.removeListener(_handleControllerUpdate);
      oldCtrl?.dispose();
      _iosController = null;
      final ctrl = NativeIosPlayerController(
        uri: uri,
        httpHeaders: widget.httpHeaders,
        isLive: widget.isLive,
        muted: _muted,
      );
      ctrl.addListener(_handleControllerUpdate);
      if (mounted) setState(() => _iosController = ctrl);
    } else {
      final oldCtrl = _controller;
      oldCtrl?.removeListener(_handleControllerUpdate);
      await oldCtrl?.pause();
      await oldCtrl?.dispose();
      _controller = null;
      final ctrl = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: widget.httpHeaders,
      );
      _controller = ctrl;
      ctrl.addListener(_handleControllerUpdate);
      await ctrl.initialize();
      await ctrl.setVolume(_muted ? 0 : 1);
      await ctrl.play();
      if (mounted) setState(() => _initialized = true);
    }
  }

  void _showQualitySheet(BuildContext context) {
    if (_variants.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'Quality',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const Divider(color: Colors.white24, height: 1),
            ..._variants.asMap().entries.map((e) {
              final i = e.key;
              final v = e.value;
              final selected = i == _selectedVariantIndex;
              return ListTile(
                leading: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? Colors.blue : Colors.white54,
                  size: 20,
                ),
                title: Text(
                  v.displayLabel,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                  ),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_switchVariant(i));
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  // ── Double-tap seek ──────────────────────────────────────────────────────

  void _handleDoubleTap() {
    if (!_isFullscreen || !_playerInitialized || widget.isLive) return;
    final pos = _doubleTapPos;
    if (pos == null) return;
    final screenW = MediaQuery.of(context).size.width;
    final seconds = pos.dx > screenW / 2 ? 10 : -10;
    unawaited(_seekRelative(seconds));
    _showSeekFeedback(seconds);
  }

  void _showSeekFeedback(int seconds) {
    _seekFeedbackTimer?.cancel();
    setState(() => _seekFeedback = seconds);
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFeedback = 0);
    });
  }

  String get _resolvedCopyLabel =>
      widget.copyLabel ??
      'Media URL copied. It still requires the active session cookie when auth is enabled.';

  bool get _canUsePictureInPicture =>
      widget.allowPictureInPicture && (Platform.isAndroid || Platform.isIOS);

  Future<void> _enterPictureInPicture() async {
    if (_enteringPictureInPicture) {
      return;
    }
    setState(() => _enteringPictureInPicture = true);
    try {
      final entered = _usesNativeIosPlayer
          ? await _iosController!.enterPictureInPicture()
          : await BackgroundExecutionBridge.instance.enterPictureInPicture(
              uri: widget.uri,
              headers: widget.httpHeaders,
              position: widget.isLive ? null : await _controller!.position,
            );
      if (!mounted) {
        return;
      }
      if (entered) {
        setState(() {
          _pictureInPictureFailure = null;
          _pictureInPictureReasons = const <String>[];
        });
      } else {
        _recordPictureInPictureFailure(
          'Picture in Picture is unavailable right now.',
          _pictureInPictureDiagnostics,
        );
      }
    } on NativeIosPlayerException catch (error) {
      if (!mounted) {
        return;
      }
      _recordPictureInPictureFailure(error.message, error.details);
    } on BackgroundExecutionBridgeException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    } finally {
      if (mounted) {
        setState(() => _enteringPictureInPicture = false);
      }
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _accelSub?.cancel();
    _restoreSystemUi();
    _iosController?.removeListener(_handleControllerUpdate);
    _controller?.removeListener(_handleControllerUpdate);
    _controller?.dispose();
    _iosController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aspectRatio = _playerAspectRatio;

    // Gesture-capture layer: sits between the player surface and the controls
    // overlay in the Stack so it is hit-tested AFTER the controls. When
    // controls are hidden their IgnorePointer returns false, so the Stack
    // descends to this layer and all taps/double-taps are captured here —
    // even through iOS platform-views (UIKit) that would otherwise swallow
    // every touch before Flutter sees it.
    final gestureLayer = Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _playerInitialized ? _toggleControls : null,
        onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
        onDoubleTap: _handleDoubleTap,
        child: const SizedBox.expand(),
      ),
    );

    final player = SizedBox(
      key: _playerKey,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(_isFullscreen ? 0 : 20),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_isFullscreen ? 0 : 20),
                child: _buildPlayerSurface(context),
              ),
            ),
          ),
          // Gesture layer is BELOW controls so button taps reach controls first.
          // When controls' IgnorePointer is on (hidden), this layer is reached.
          gestureLayer,
          Positioned.fill(child: _buildControls(context)),
          // Seek feedback flash
          if (_seekFeedback != 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(32),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _seekFeedback > 0
                              ? Icons.forward_10
                              : Icons.replay_10,
                          color: Colors.white,
                          size: 30,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_seekFeedback.abs()}s',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return PopScope<void>(
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_isFullscreen) {
          return;
        }
        await _setFullscreen(false);
      },
      child: Scaffold(
        backgroundColor: _isFullscreen ? Colors.black : null,
        appBar: _isFullscreen
            ? null
            : AppBar(
                title: Text(widget.title),
                actions: <Widget>[
                  if (widget.onGrabRequested != null)
                    IconButton(
                      tooltip: 'Save offline',
                      onPressed: widget.onGrabRequested,
                      icon: const Icon(Icons.download_for_offline),
                    ),
                  if (_canUsePictureInPicture)
                    IconButton(
                      tooltip: 'Picture in picture',
                      onPressed: _enteringPictureInPicture
                          ? null
                          : _enterPictureInPicture,
                      icon: const Icon(Icons.picture_in_picture_alt_outlined),
                    ),
                  IconButton(
                    tooltip: 'Copy URL',
                    onPressed: () => _copyToClipboard(
                      context,
                      _resolvedCopyUrl,
                      label: _resolvedCopyLabel,
                    ),
                    icon: const Icon(Icons.copy),
                  ),
                  if (widget.localFilePath != null &&
                      widget.localFileName != null)
                    IconButton(
                      tooltip: 'Share file',
                      onPressed: () => _shareLocalMediaFile(
                        context,
                        File(widget.localFilePath!),
                        filename: widget.localFileName!,
                      ),
                      icon: const Icon(Icons.ios_share),
                    ),
                  if (widget.localFilePath != null &&
                      widget.localFileName != null)
                    IconButton(
                      tooltip: 'Save to Photos',
                      onPressed: () => _saveLocalMediaToPhotos(
                        context,
                        File(widget.localFilePath!),
                        filename: widget.localFileName!,
                      ),
                      icon: const Icon(Icons.photo_library_outlined),
                    ),
                ],
              ),
        body: SafeArea(
          top: !_isFullscreen,
          bottom: !_isFullscreen,
          child: _isFullscreen
              ? Center(
                  child: AspectRatio(
                    aspectRatio: aspectRatio,
                    child: player,
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: <Widget>[
                      AspectRatio(
                        aspectRatio: aspectRatio,
                        child: player,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              widget.isLive
                                  ? 'Live preview from your source. Use fullscreen for a cleaner view.'
                                  : 'Pause, seek, clip a segment, or keep a local copy in your library.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: _appTextMuted),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_usesNativeIosPlayer &&
                          _canUsePictureInPicture &&
                          _pictureInPictureFailure != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _showPictureInPictureDiagnosticsDialog,
                            icon: const Icon(Icons.info_outline),
                            label: const Text('Show PiP diagnostics'),
                          ),
                        ),
                      if (_usesNativeIosPlayer &&
                          _canUsePictureInPicture &&
                          _pictureInPictureFailure != null)
                        const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          _resolvedCopyUrl,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final current = _playerPosition;
    final total = _playerDuration;
    final hasTimeline =
        _playerInitialized && !widget.isLive && total > Duration.zero;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: !_isFullscreen || _showControls ? 1 : 0,
      child: IgnorePointer(
        ignoring: _isFullscreen && !_showControls,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.black.withValues(alpha: _isFullscreen ? 0.38 : 0.12),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.56),
              ],
            ),
          ),
          child: Column(
            children: <Widget>[
              if (_isFullscreen)
                SafeArea(
                  bottom: false,
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        onPressed: () => _setFullscreen(false),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              if (_playerInitialized && _isFullscreen)
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.55),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _togglePlayback,
                  icon: Icon(_playerIsPlaying ? Icons.pause : Icons.play_arrow),
                ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                color: Colors.black.withValues(alpha: 0.36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (hasTimeline) _buildTimeline(context, current, total),
                    Row(
                      children: <Widget>[
                        if (hasTimeline)
                          IconButton(
                            onPressed: _playerInitialized
                                ? () => _seekRelative(-10)
                                : null,
                            icon: const Icon(Icons.replay_10),
                          ),
                        IconButton(
                          onPressed:
                              _playerInitialized ? _togglePlayback : null,
                          icon: Icon(
                            _playerIsPlaying ? Icons.pause : Icons.play_arrow,
                          ),
                        ),
                        if (hasTimeline)
                          IconButton(
                            onPressed: _playerInitialized
                                ? () => _seekRelative(10)
                                : null,
                            icon: const Icon(Icons.forward_10),
                          ),
                        if (widget.isLive)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: _appDanger.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'LIVE',
                              style: TextStyle(
                                color: _appDanger,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        const Spacer(),
                        Text(
                          widget.isLive
                              ? 'Live'
                              : '${_formatDurationLabel(current)} / ${_formatDurationLabel(total)}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        IconButton(
                          onPressed: _playerInitialized
                              ? () => _setMuted(!_muted)
                              : null,
                          icon: Icon(
                            _muted ? Icons.volume_off : Icons.volume_up,
                          ),
                        ),
                        if (_fetchingVariants)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white54,
                            ),
                          )
                        else if (_variants.length > 1)
                          TextButton.icon(
                            onPressed: () => _showQualitySheet(context),
                            icon: const Icon(Icons.hd, size: 18),
                            label: Text(
                              _selectedVariantIndex >= 0
                                  ? _variants[_selectedVariantIndex].displayLabel
                                  : 'Auto',
                              style: const TextStyle(fontSize: 12),
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              minimumSize: Size.zero,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        IconButton(
                          onPressed: _playerInitialized
                              ? () => _setFullscreen(!_isFullscreen)
                              : null,
                          icon: Icon(
                            _isFullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerSurface(BuildContext context) {
    final overlay = _playerError != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _playerError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          )
        : !_playerInitialized
            ? const Center(child: CircularProgressIndicator())
            : null;

    if (_usesNativeIosPlayer) {
      return Stack(
        children: <Widget>[
          Positioned.fill(
              child: NativeIosPlayerView(controller: _iosController!)),
          if (overlay != null) Positioned.fill(child: overlay),
        ],
      );
    }

    if (overlay != null) {
      return overlay;
    }
    return Center(child: VideoPlayer(_controller!));
  }

  Widget _buildTimeline(
    BuildContext context,
    Duration current,
    Duration total,
  ) {
    if (!_usesNativeIosPlayer) {
      return VideoProgressIndicator(
        _controller!,
        allowScrubbing: true,
        padding: const EdgeInsets.symmetric(vertical: 10),
        colors: const VideoProgressColors(
          playedColor: _appPrimary,
          bufferedColor: Color(0xFF475569),
          backgroundColor: Color(0xFF1E293B),
        ),
      );
    }

    final totalMs = math.max(total.inMilliseconds, 1);
    final currentMs = current.inMilliseconds.clamp(0, totalMs).toDouble();
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: _appPrimary,
        inactiveTrackColor: const Color(0xFF1E293B),
        thumbColor: _appPrimary,
        overlayColor: _appPrimary.withValues(alpha: 0.16),
        trackHeight: 3,
      ),
      child: Slider(
        value: currentMs,
        min: 0,
        max: totalMs.toDouble(),
        onChanged: _playerInitialized
            ? (value) =>
                unawaited(_seekTo(Duration(milliseconds: value.round())))
            : null,
      ),
    );
  }

  Future<void> _showPictureInPictureDiagnosticsDialog() {
    final message =
        _pictureInPictureFailure ?? 'Picture in Picture diagnostics';
    final mergedReasons = _dedupeMessages(<String>[
      ..._pictureInPictureDiagnostics,
      ...(_iosController?.diagnostics ?? const <String>[]),
    ]);
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Picture in Picture diagnostics'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(message),
                if (mergedReasons.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  for (final reason in mergedReasons)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('• $reason'),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _recordPictureInPictureFailure(
    String message,
    List<String> reasons,
  ) {
    final mergedReasons = _dedupeMessages(<String>[
      ...reasons,
      ...(_iosController?.diagnostics ?? const <String>[]),
    ]);
    setState(() {
      _pictureInPictureFailure = message;
      _pictureInPictureReasons = mergedReasons;
    });
    _showMessage(context, message, error: true);
    unawaited(_showPictureInPictureDiagnosticsDialog());
  }
}

class _AllPlaylistsEditorPage extends StatefulWidget {
  const _AllPlaylistsEditorPage({required this.controller});

  final AppController controller;

  @override
  State<_AllPlaylistsEditorPage> createState() =>
      _AllPlaylistsEditorPageState();
}

class _AllPlaylistsEditorPageState extends State<_AllPlaylistsEditorPage> {
  late MergedPlaylistConfig _draft;
  String? _selectedGroupId;
  bool _dirty = false;
  bool _saving = false;
  bool _refreshing = false;
  bool _copyingExport = false;

  @override
  void initState() {
    super.initState();
    _hydrateFromController();
  }

  MergedGroup? get _selectedGroup {
    final selectedId = _selectedGroupId;
    if (selectedId == null) {
      return null;
    }
    for (final group in _draft.groups) {
      if (group.id == selectedId) {
        return group;
      }
    }
    return null;
  }

  void _hydrateFromController() {
    final config = widget.controller.mergedPlaylistConfig;
    _draft =
        (config ?? MergedPlaylistConfig(groups: const <MergedGroup>[])).copy();
    if (_selectedGroupId != null &&
        _draft.groups.any((group) => group.id == _selectedGroupId)) {
      return;
    }
    _selectedGroupId = _draft.groups.isEmpty ? null : _draft.groups.first.id;
  }

  Future<void> _handleClose() async {
    if (!_dirty) {
      Navigator.of(context).pop(false);
      return;
    }
    final discard = await _confirmDiscardChanges(
      'Discard your unsaved All Playlists edits?',
    );
    if (!mounted || !discard) {
      return;
    }
    Navigator.of(context).pop(false);
  }

  Future<bool> _confirmDiscardChanges(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Unsaved changes'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Discard'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  void _replaceGroups(
    List<MergedGroup> groups, {
    required bool markDirty,
    String? selectedGroupId,
  }) {
    setState(() {
      _draft = MergedPlaylistConfig(groups: groups);
      if (selectedGroupId != null) {
        _selectedGroupId = selectedGroupId;
      }
      if (_selectedGroupId != null &&
          !_draft.groups.any((group) => group.id == _selectedGroupId)) {
        _selectedGroupId =
            _draft.groups.isEmpty ? null : _draft.groups.first.id;
      }
      if (markDirty) {
        _dirty = true;
      }
    });
  }

  void _toggleGroupEnabled(String groupId, bool enabled) {
    final next = _draft.groups
        .map(
          (group) => group.id == groupId
              ? group.copyWith(enabled: enabled)
              : group.copy(),
        )
        .toList();
    _replaceGroups(next, markDirty: true);
  }

  void _toggleChannelEnabled(String channelId, bool enabled) {
    final selectedGroup = _selectedGroup;
    if (selectedGroup == null) {
      return;
    }
    final nextGroups = _draft.groups.map((group) {
      if (group.id != selectedGroup.id) {
        return group.copy();
      }
      return group.copyWith(
        channels: group.channels
            .map(
              (channel) => channel.id == channelId
                  ? channel.copyWith(enabled: enabled)
                  : channel.copy(),
            )
            .toList(),
      );
    }).toList();
    _replaceGroups(nextGroups,
        markDirty: true, selectedGroupId: selectedGroup.id);
  }

  void _reorderGroups(int oldIndex, int newIndex) {
    final next = _draft.groups.map((group) => group.copy()).toList();
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    _replaceGroups(next, markDirty: true, selectedGroupId: moved.id);
  }

  void _reorderChannels(int oldIndex, int newIndex) {
    final selectedGroup = _selectedGroup;
    if (selectedGroup == null) {
      return;
    }
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final nextChannels =
        selectedGroup.channels.map((channel) => channel.copy()).toList();
    final moved = nextChannels.removeAt(oldIndex);
    nextChannels.insert(newIndex, moved);
    final nextGroups = _draft.groups.map((group) {
      if (group.id != selectedGroup.id) {
        return group.copy();
      }
      return group.copyWith(channels: nextChannels);
    }).toList();
    _replaceGroups(nextGroups,
        markDirty: true, selectedGroupId: selectedGroup.id);
  }

  Future<void> _deleteGroup(MergedGroup group) async {
    if (!group.custom) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete custom group'),
          content:
              Text('Delete "${group.name}" and all of its custom channels?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    final next = _draft.groups
        .where((candidate) => candidate.id != group.id)
        .map((candidate) => candidate.copy())
        .toList();
    _replaceGroups(next, markDirty: true);
  }

  Future<void> _deleteCustomChannel(MergedChannel channel) async {
    final group = _selectedGroup;
    if (group == null || !channel.custom) {
      return;
    }
    final nextGroups = _draft.groups.map((candidate) {
      if (candidate.id != group.id) {
        return candidate.copy();
      }
      return candidate.copyWith(
        channels: candidate.channels
            .where((item) => item.id != channel.id)
            .map((item) => item.copy())
            .toList(),
      );
    }).toList();
    _replaceGroups(nextGroups, markDirty: true, selectedGroupId: group.id);
  }

  Future<void> _showAddGroupDialog() async {
    final controller = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Add custom group'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Group name',
                border: OutlineInputBorder(),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Add group'),
              ),
            ],
          );
        },
      );
      if (confirmed != true) {
        return;
      }
      final name = controller.text.trim();
      if (name.isEmpty) {
        _showMessage(context, 'Group name is required.', error: true);
        return;
      }
      if (_draft.groups.any((group) => group.name == name)) {
        _showMessage(context, 'Group already exists.', error: true);
        return;
      }
      final next = <MergedGroup>[
        MergedGroup(
          id: _randomEditorId('g'),
          name: name,
          enabled: true,
          custom: true,
          channels: const <MergedChannel>[],
        ),
        ..._draft.groups.map((group) => group.copy()),
      ];
      _replaceGroups(next, markDirty: true, selectedGroupId: next.first.id);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _showChannelDialog({MergedChannel? existing}) async {
    final group = _selectedGroup;
    if (group == null) {
      _showMessage(context, 'Select a group first.', error: true);
      return;
    }
    final nameController = TextEditingController(text: existing?.name ?? '');
    final urlController = TextEditingController(text: existing?.url ?? '');
    final logoController = TextEditingController(text: existing?.tvgLogo ?? '');
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(existing == null
                ? 'Add custom channel'
                : 'Edit custom channel'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Channel name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: urlController,
                    decoration: const InputDecoration(
                      labelText: 'M3U8 URL',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: logoController,
                    decoration: const InputDecoration(
                      labelText: 'Logo URL (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(existing == null ? 'Add channel' : 'Save'),
              ),
            ],
          );
        },
      );
      if (confirmed != true) {
        return;
      }
      final name = nameController.text.trim();
      final url = urlController.text.trim();
      final logo = logoController.text.trim();
      if (name.isEmpty || url.isEmpty) {
        _showMessage(context, 'Name and URL are required.', error: true);
        return;
      }
      final nextGroups = _draft.groups.map((candidate) {
        if (candidate.id != group.id) {
          return candidate.copy();
        }
        final nextChannels =
            candidate.channels.map((channel) => channel.copy()).toList();
        if (existing == null) {
          nextChannels.insert(
            0,
            MergedChannel(
              id: _randomEditorId('cc'),
              name: name,
              url: url,
              enabled: true,
              custom: true,
              group: group.name,
              tvgLogo: logo,
              sourcePlaylistId: null,
              sourcePlaylistName: null,
            ),
          );
        } else {
          final index =
              nextChannels.indexWhere((channel) => channel.id == existing.id);
          if (index >= 0) {
            nextChannels[index] = nextChannels[index].copyWith(
              name: name,
              url: url,
              tvgLogo: logo,
              group: group.name,
            );
          }
        }
        return candidate.copyWith(channels: nextChannels);
      }).toList();
      _replaceGroups(nextGroups, markDirty: true, selectedGroupId: group.id);
    } finally {
      nameController.dispose();
      urlController.dispose();
      logoController.dispose();
    }
  }

  Future<void> _refreshAll() async {
    if (_dirty) {
      final discard = await _confirmDiscardChanges(
        'Refreshing will replace your unsaved local edits with the latest merged playlist data. Continue?',
      );
      if (!discard) {
        return;
      }
    }
    setState(() => _refreshing = true);
    try {
      await widget.controller.refreshAllPlaylists();
      _hydrateFromController();
      if (!mounted) {
        return;
      }
      setState(() => _dirty = false);
      _showMessage(context, 'All playlists refreshed.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _copyExport() async {
    setState(() => _copyingExport = true);
    try {
      final content = await widget.controller.fetchMergedExport();
      if (!mounted) {
        return;
      }
      await _copyToClipboard(
        context,
        content,
        label: 'Merged M3U copied to clipboard.',
      );
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    } finally {
      if (mounted) {
        setState(() => _copyingExport = false);
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.controller.saveMergedPlaylists(_draft.copy());
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedGroup = _selectedGroup;
    return PopScope<bool>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          return;
        }
        await _handleClose();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: _handleClose,
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('All playlists editor'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Copy merged M3U',
              onPressed: _copyingExport ? null : _copyExport,
              icon: const Icon(Icons.content_copy),
            ),
            IconButton(
              tooltip: 'Refresh all playlists',
              onPressed: _refreshing ? null : _refreshAll,
              icon: const Icon(Icons.refresh),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving...' : 'Save'),
              ),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Reorder groups and channels, toggle availability, and manage custom groups or custom channels before saving.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: _appTextMuted),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: _showAddGroupDialog,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('Add group'),
                      ),
                      if (selectedGroup != null)
                        FilledButton.tonalIcon(
                          onPressed: () => _showChannelDialog(),
                          icon: const Icon(Icons.add_link_outlined),
                          label: const Text('Add channel'),
                        ),
                      Chip(
                        label: Text('${_draft.groups.length} groups'),
                      ),
                      if (selectedGroup != null)
                        Chip(
                          label: Text(
                            '${selectedGroup.channels.length} channels in ${selectedGroup.name}',
                          ),
                        ),
                      if (_dirty)
                        const Chip(
                          avatar: Icon(Icons.edit, size: 18),
                          label: Text('Unsaved changes'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: _draft.groups.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(24),
                      children: const <Widget>[
                        SizedBox(height: 96),
                        Icon(Icons.playlist_play, size: 48),
                        SizedBox(height: 12),
                        Center(
                          child: Text(
                            'No merged playlist data yet. Refresh all playlists or add a custom group.',
                          ),
                        ),
                      ],
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: _draft.groups.length,
                      onReorder: _reorderGroups,
                      itemBuilder: (context, index) {
                        final group = _draft.groups[index];
                        final isSelected = group.id == _selectedGroupId;
                        final enabledChannels = group.channels
                            .where((channel) => channel.enabled)
                            .length;
                        return Card(
                          key: ValueKey(group.id),
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            children: <Widget>[
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    _selectedGroupId =
                                        isSelected ? null : group.id;
                                  });
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Row(
                                    children: <Widget>[
                                      ReorderableDelayedDragStartListener(
                                        index: index,
                                        child: const Padding(
                                          padding: EdgeInsets.only(right: 8),
                                          child: Icon(Icons.drag_indicator),
                                        ),
                                      ),
                                      Checkbox(
                                        value: group.enabled,
                                        onChanged: (value) =>
                                            _toggleGroupEnabled(
                                                group.id, value ?? true),
                                      ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              group.name,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${group.custom ? 'Custom group' : 'Source group'} • $enabledChannels/${group.channels.length} enabled',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                      color: _appTextMuted),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (group.custom)
                                        IconButton(
                                          tooltip: 'Delete custom group',
                                          onPressed: () => _deleteGroup(group),
                                          icon:
                                              const Icon(Icons.delete_outline),
                                        ),
                                      Icon(
                                        isSelected
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (isSelected) ...<Widget>[
                                const Divider(height: 1),
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(14, 12, 14, 14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: <Widget>[
                                          Chip(
                                            label: Text(
                                              '${group.channels.length} channels',
                                            ),
                                          ),
                                          if (!group.enabled)
                                            const Chip(
                                                label: Text('Group disabled')),
                                          FilledButton.tonalIcon(
                                            onPressed: () =>
                                                _showChannelDialog(),
                                            icon: const Icon(
                                                Icons.add_link_outlined),
                                            label: const Text('Add channel'),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      if (group.channels.isEmpty)
                                        Text(
                                          'No channels in this group yet.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(color: _appTextMuted),
                                        )
                                      else
                                        ReorderableListView.builder(
                                          buildDefaultDragHandles: false,
                                          shrinkWrap: true,
                                          physics:
                                              const NeverScrollableScrollPhysics(),
                                          itemCount: group.channels.length,
                                          onReorder: _reorderChannels,
                                          itemBuilder: (context, channelIndex) {
                                            final channel =
                                                group.channels[channelIndex];
                                            final health = widget.controller
                                                .healthForUrl(channel.url);
                                            return Container(
                                              key: ValueKey(channel.id),
                                              margin: const EdgeInsets.only(
                                                  bottom: 8),
                                              decoration: BoxDecoration(
                                                color: _appSurfaceAlt,
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                border: Border.all(
                                                  color: Colors.white10,
                                                ),
                                              ),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.all(12),
                                                child: Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: <Widget>[
                                                    ReorderableDelayedDragStartListener(
                                                      index: channelIndex,
                                                      child: const Padding(
                                                        padding:
                                                            EdgeInsets.only(
                                                          right: 8,
                                                          top: 6,
                                                        ),
                                                        child: Icon(Icons
                                                            .drag_indicator),
                                                      ),
                                                    ),
                                                    _ChannelLogo(
                                                      url: channel.tvgLogo,
                                                      size: 36,
                                                    ),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: <Widget>[
                                                          Row(
                                                            children: <Widget>[
                                                              Expanded(
                                                                child: Text(
                                                                  channel.name,
                                                                  style: Theme.of(
                                                                          context)
                                                                      .textTheme
                                                                      .titleSmall,
                                                                ),
                                                              ),
                                                              Container(
                                                                width: 10,
                                                                height: 10,
                                                                decoration:
                                                                    BoxDecoration(
                                                                  color:
                                                                      _healthStatusColor(
                                                                    health
                                                                        ?.status,
                                                                  ),
                                                                  shape: BoxShape
                                                                      .circle,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                          const SizedBox(
                                                              height: 4),
                                                          Text(
                                                            channel.url,
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .bodySmall
                                                                ?.copyWith(
                                                                  color:
                                                                      _appTextMuted,
                                                                ),
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                          if (channel.sourcePlaylistName !=
                                                                  null &&
                                                              channel
                                                                  .sourcePlaylistName!
                                                                  .isNotEmpty) ...<Widget>[
                                                            const SizedBox(
                                                                height: 4),
                                                            Text(
                                                              channel
                                                                  .sourcePlaylistName!,
                                                              style: Theme.of(
                                                                      context)
                                                                  .textTheme
                                                                  .bodySmall
                                                                  ?.copyWith(
                                                                    color:
                                                                        _appTextMuted,
                                                                  ),
                                                            ),
                                                          ],
                                                        ],
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Column(
                                                      children: <Widget>[
                                                        Switch.adaptive(
                                                          value:
                                                              channel.enabled,
                                                          onChanged: (value) =>
                                                              _toggleChannelEnabled(
                                                            channel.id,
                                                            value,
                                                          ),
                                                        ),
                                                        Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: <Widget>[
                                                            IconButton(
                                                              tooltip: channel
                                                                      .custom
                                                                  ? 'Edit custom channel'
                                                                  : 'Only custom channels can be edited',
                                                              onPressed: channel
                                                                      .custom
                                                                  ? () =>
                                                                      _showChannelDialog(
                                                                        existing:
                                                                            channel,
                                                                      )
                                                                  : null,
                                                              icon: const Icon(Icons
                                                                  .edit_outlined),
                                                            ),
                                                            IconButton(
                                                              tooltip: channel
                                                                      .custom
                                                                  ? 'Delete custom channel'
                                                                  : 'Source channels cannot be deleted',
                                                              onPressed: channel
                                                                      .custom
                                                                  ? () =>
                                                                      _deleteCustomChannel(
                                                                          channel)
                                                                  : null,
                                                              icon: const Icon(
                                                                Icons
                                                                    .delete_outline,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClipSelection {
  const _ClipSelection({
    required this.start,
    required this.end,
  });

  final double start;
  final double end;
}

class _ClipEditorDialog extends StatefulWidget {
  const _ClipEditorDialog({
    required this.task,
    required this.uri,
    required this.httpHeaders,
  });

  final DownloadTask task;
  final Uri uri;
  final Map<String, String> httpHeaders;

  @override
  State<_ClipEditorDialog> createState() => _ClipEditorDialogState();
}

class _ClipEditorDialogState extends State<_ClipEditorDialog> {
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
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Preview the media, scrub to the right frame, then set the clip start/end from the current playback position.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: _appTextMuted),
            ),
            const SizedBox(height: 12),
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
                        ? '${_formatSeconds(currentPreview)} / ${_formatSeconds(playerDuration)}'
                        : 'Current: ${_formatSeconds(currentPreview)}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: _appTextMuted),
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
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: () => _setRange(start: currentPreview),
                    icon: const Icon(Icons.flag_outlined),
                    label: const Text('Set start here'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _setRange(end: currentPreview),
                    icon: const Icon(Icons.outlined_flag),
                    label: const Text('Set end here'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_seekTo(_clipStart)),
                    icon: const Icon(Icons.first_page),
                    label: const Text('Jump to start'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_seekTo(_clipEnd)),
                    icon: const Icon(Icons.last_page),
                    label: const Text('Jump to end'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (_hasRangeSlider) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: _InfoChip(
                      label: 'Start',
                      value: _formatSeconds(_clipStart),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _InfoChip(
                      label: 'End',
                      value: _formatSeconds(_clipEnd),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _InfoChip(
                      label: 'Length',
                      value: _formatSeconds(_clipEnd - _clipStart),
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
                  _formatSeconds(_clipStart),
                  _formatSeconds(_clipEnd),
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
            TextField(
              controller: _startController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Start (seconds)',
              ),
              onChanged: (value) {
                final parsed = double.tryParse(value.trim());
                if (parsed == null) {
                  return;
                }
                _setRange(start: parsed, syncTextFields: false);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _endController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'End (seconds)',
              ),
              onChanged: (value) {
                final parsed = double.tryParse(value.trim());
                if (parsed == null) {
                  return;
                }
                _setRange(end: parsed, syncTextFields: false);
              },
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
                    _ClipSelection(start: _clipStart, end: _clipEnd),
                  ),
          child: const Text('Clip'),
        ),
      ],
    );
  }
}

String _randomEditorId(String prefix) {
  return '${prefix}_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}

Future<void> _showEditPlaylistDialog(
  BuildContext context,
  AppController controller,
  Playlist playlist,
) async {
  final nameController = TextEditingController(text: playlist.name);
  final urlController = TextEditingController(text: playlist.url ?? '');

  try {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Edit source list'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: 'Source list URL',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (result != true || !context.mounted) {
      return;
    }

    await controller.editPlaylist(
      playlist.id,
      name: nameController.text.trim(),
      url: urlController.text.trim().isEmpty ? null : urlController.text.trim(),
    );
    if (!context.mounted) {
      return;
    }
    _showMessage(context, 'Source list updated.');
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.message, error: true);
  } finally {
    nameController.dispose();
    urlController.dispose();
  }
}

Future<void> _showAddPlaylistDialog(
    BuildContext context, AppController controller) async {
  final nameController = TextEditingController();
  final urlController = TextEditingController();
  final rawController = TextEditingController();

  try {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add source list'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: 'Source list URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: rawController,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Raw list contents (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (result != true || !context.mounted) {
      return;
    }

    await controller.addPlaylist(
      name: nameController.text.trim(),
      url: urlController.text.trim().isEmpty ? null : urlController.text.trim(),
      raw: rawController.text.trim().isEmpty ? null : rawController.text.trim(),
    );
    if (!context.mounted) {
      return;
    }
    _showMessage(context, 'Source list added.');
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.message, error: true);
  } finally {
    nameController.dispose();
    urlController.dispose();
    rawController.dispose();
  }
}

Future<void> _showClipDialog(
  BuildContext context,
  AppController controller,
  DownloadTask task,
) async {
  try {
    final previewUri = task.output != null
        ? controller.downloadUri(task.output!)
        : controller.previewUri(task.id);
    final selection = await showDialog<_ClipSelection>(
      context: context,
      builder: (_) => _ClipEditorDialog(
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
    _showMessage(context, 'Clip created. Opening the clipped file player.');
    await _openMediaPlayer(
      context,
      title: filename,
      uri: controller.downloadUri(filename),
      httpHeaders: controller.mediaRequestHeaders,
      localFilePath: _localMediaPathOrNull(controller, filename),
      localFileName: filename,
    );
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.message, error: true);
  }
}

File _localMediaFile(AppController controller, String filename) {
  final path = _localMediaPathOrNull(controller, filename);
  if (path == null) {
    throw ApiException('Local downloads directory is not ready yet.');
  }
  return File(path);
}

String? _localMediaPathOrNull(AppController controller, String filename) {
  final downloadsDir = controller.localDownloadsDir;
  if (downloadsDir == null || downloadsDir.isEmpty) {
    return null;
  }
  return '$downloadsDir/$filename';
}

Future<void> _shareLocalMediaFromController(
  BuildContext context,
  AppController controller,
  String filename,
) async {
  try {
    await _shareLocalMediaFile(
      context,
      _localMediaFile(controller, filename),
      filename: filename,
    );
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.message, error: true);
  }
}

Future<void> _saveLocalMediaToPhotosFromController(
  BuildContext context,
  AppController controller,
  String filename,
) async {
  try {
    await _saveLocalMediaToPhotos(
      context,
      _localMediaFile(controller, filename),
      filename: filename,
    );
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.message, error: true);
  }
}

Rect? _shareOriginForContext(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox) {
    return null;
  }
  final origin = renderObject.localToGlobal(Offset.zero);
  return origin & renderObject.size;
}

Future<void> _shareLocalMediaFile(
  BuildContext context,
  File file, {
  required String filename,
}) async {
  try {
    if (!await file.exists()) {
      throw ApiException('Local media file not found: $filename');
    }
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[
          XFile(
            file.path,
            mimeType: 'video/mp4',
            name: filename,
          ),
        ],
        title: filename,
        subject: filename,
        text: filename,
        sharePositionOrigin: _shareOriginForContext(context),
      ),
    );
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.message, error: true);
  } on Exception catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.toString(), error: true);
  }
}

Future<void> _saveLocalMediaToPhotos(
  BuildContext context,
  File file, {
  required String filename,
}) async {
  try {
    if (!await file.exists()) {
      throw ApiException('Local media file not found: $filename');
    }

    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        iosAccessLevel: IosAccessLevel.addOnly,
        androidPermission: AndroidPermission(
          type: RequestType.video,
          mediaLocation: false,
        ),
      ),
    );
    if (!permission.hasAccess) {
      throw ApiException(
        'Photo library permission is required before videos can be exported to Photos.',
      );
    }

    await PhotoManager.editor.saveVideo(
      file,
      title: filename.replaceFirst(RegExp(r'\.mp4$'), ''),
    );
    if (!context.mounted) {
      return;
    }
    _showMessage(context, 'Saved to Photos.');
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.message, error: true);
  } on Exception catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.toString(), error: true);
  }
}

Map<String, String> _parseHeadersText(String text) {
  final headers = <String, String>{};
  final lines = text.split('\n');
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith('GET ') ||
        line.startsWith('POST ') ||
        line.startsWith('HEAD ')) {
      continue;
    }
    final separator = line.contains(':') ? ':' : '=';
    final index = line.indexOf(separator);
    if (index <= 0) {
      continue;
    }
    final name = line.substring(0, index).trim();
    final value = line.substring(index + 1).trim();
    if (name.isEmpty || value.isEmpty) {
      continue;
    }
    headers[name] = value;
  }
  return headers;
}

Color _statusColor(String status) {
  switch (status) {
    case 'downloading':
      return _appPrimary;
    case 'recording':
      return _appDanger;
    case 'stopping':
      return _appWarning;
    case 'merging':
      return _appWarning;
    case 'completed':
      return _appSuccess;
    case 'failed':
      return _appDanger;
    case 'cancelled':
    case 'interrupted':
      return Colors.grey;
    default:
      return Colors.blueGrey;
  }
}

Color _taskStatusColor(DownloadTask task, AppController controller) {
  if (controller.isAutoFinalizingTask(task.id)) {
    return _appWarning;
  }
  if (controller.treatTaskAsStopped(task)) {
    return Colors.blueGrey;
  }
  if (task.needsLocalMerge) {
    return _appWarning;
  }
  return _statusColor(task.status);
}

String _taskStatusLabel(DownloadTask task, AppController controller) {
  if (controller.isAutoFinalizingTask(task.id)) {
    return 'Saving locally';
  }
  if (controller.treatTaskAsStopped(task)) {
    return 'Stopped';
  }
  if (task.needsLocalMerge) {
    return 'Needs merge';
  }
  if (task.isStopping) {
    return 'Stopping';
  }
  return _titleCase(task.status);
}

String? _taskErrorMessage(DownloadTask task, AppController controller) {
  final error = task.error?.trim();
  if (controller.isAutoFinalizingTask(task.id)) {
    return null;
  }
  if (error == null || error.isEmpty) {
    return null;
  }
  if (controller.treatTaskAsStopped(task)) {
    return null;
  }
  if (task.needsLocalMerge) {
      return 'FFmpeg is unavailable inside the embedded service. Tap “Finalize locally” to merge on-device and keep the saved media usable.';
  }
  return error;
}

Color _healthStatusColor(String? status) {
  switch (status?.toLowerCase()) {
    case 'ok':
      return _appSuccess;
    case 'dead':
      return _appDanger;
    default:
      return const Color(0xFF64748B);
  }
}

String _titleCase(String value) {
  if (value.isEmpty) {
    return value;
  }
  return value[0].toUpperCase() + value.substring(1);
}

String _formatBytes(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return unit == 0
      ? '${size.round()} ${units[unit]}'
      : '${size.toStringAsFixed(1)} ${units[unit]}';
}

String _formatSeconds(double seconds) {
  if (seconds <= 0) {
    return '0s';
  }
  final whole = seconds.round();
  return _formatClock(whole);
}

String _formatClock(int seconds) {
  final duration = Duration(seconds: seconds);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final secs = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours}h ${minutes}m ${secs}s';
  }
  if (minutes > 0) {
    return '${minutes}m ${secs}s';
  }
  return '${secs}s';
}

String _formatDurationLabel(Duration? duration) {
  if (duration == null || duration.inMilliseconds <= 0) {
    return '0:00';
  }
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _shortId(String value) {
  if (value.length <= 8) {
    return value;
  }
  return value.substring(0, 8);
}

List<String> _dedupeMessages(Iterable<String> messages) {
  final seen = <String>{};
  final deduped = <String>[];
  for (final message in messages) {
    final normalized = message.trim();
    if (normalized.isEmpty || !seen.add(normalized)) {
      continue;
    }
    deduped.add(normalized);
  }
  return deduped;
}

void _showMessage(
  BuildContext context,
  String message, {
  bool error = false,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ),
  );
}

Future<void> _copyToClipboard(
  BuildContext context,
  String text, {
  required String label,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) {
    return;
  }
  _showMessage(context, label);
}
