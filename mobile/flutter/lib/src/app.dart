import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'api_client.dart';
import 'controller.dart';
import 'models.dart';

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

class _M3u8FlutterClientAppState extends State<M3u8FlutterClientApp> {
  late final AppController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = AppController();
    unawaited(_controller.bootstrapLocalServer());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'M3U8 On-Device',
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
                  Text('M3U8 On-Device'),
                  SizedBox(height: 2),
                  Text(
                    'Local downloader, live preview, clip & playlists',
                    style: TextStyle(fontSize: 12, color: _appTextMuted),
                  ),
                ],
              ),
              actions: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child:
                      Center(child: _ConnectionBadge(controller: _controller)),
                ),
              ],
            ),
            body: IndexedStack(
              index: _index,
              children: <Widget>[
                _ConnectionTab(controller: _controller),
                _DownloadTab(
                  controller: _controller,
                  onOpenTasks: () => setState(() => _index = 2),
                ),
                _TasksTab(controller: _controller),
                _PlaylistsTab(
                  controller: _controller,
                  onUseChannel: () => setState(() => _index = 1),
                ),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.developer_board),
                  label: 'Server',
                ),
                NavigationDestination(
                  icon: Icon(Icons.download),
                  label: 'Grab',
                ),
                NavigationDestination(
                  icon: Icon(Icons.task_alt),
                  label: 'Tasks',
                ),
                NavigationDestination(
                  icon: Icon(Icons.playlist_play),
                  label: 'Channels',
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

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch ((
      controller.localServerRunning,
      controller.readyForApi,
      controller.needsLogin
    )) {
      (false, _, _) => ('Local server offline', Colors.grey),
      (true, false, true) => ('Login required', Colors.orange),
      (true, true, _) => ('Local server ready', Colors.green),
      _ => ('Starting', Colors.blueGrey),
    };

    return Chip(
      avatar: Icon(Icons.circle, size: 12, color: color),
      label: Text(label),
    );
  }
}

class _ConnectionTab extends StatefulWidget {
  const _ConnectionTab({required this.controller});

  final AppController controller;

  @override
  State<_ConnectionTab> createState() => _ConnectionTabState();
}

class _ConnectionTabState extends State<_ConnectionTab> {
  late final TextEditingController _passwordController;

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _startOrRestart({required bool restart}) async {
    try {
      await widget.controller.startLocalServer(
        authPassword: _passwordController.text.trim().isEmpty
            ? null
            : _passwordController.text.trim(),
        forceRestart: restart,
      );
      if (!mounted) {
        return;
      }
      _showMessage(
          context,
          restart
              ? 'On-device server restarted.'
              : 'On-device server started.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    }
  }

  Future<void> _login() async {
    try {
      await widget.controller.login(_passwordController.text);
      if (!mounted) {
        return;
      }
      _passwordController.clear();
      _showMessage(context, 'Logged in.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    }
  }

  Future<void> _logout() async {
    try {
      await widget.controller.logout();
      if (!mounted) {
        return;
      }
      _showMessage(context, 'Logged out.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    }
  }

  Future<void> _stopServer() async {
    try {
      await widget.controller.stopLocalServer();
      if (!mounted) {
        return;
      }
      _showMessage(context, 'On-device server stopped.');
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
    final statusText = controller.localServerRunning
        ? (controller.authRequired
            ? 'The on-device Rust server is running and local auth is enabled.'
            : 'The on-device Rust server is running with local auth disabled.')
        : 'This app runs the Rust server inside the device and talks to it over localhost.';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('On-device Rust server',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: controller.isBusy
                          ? null
                          : () => _startOrRestart(restart: false),
                      icon: const Icon(Icons.play_circle_outline),
                      label: const Text('Start local server'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          controller.isBusy || !controller.localServerRunning
                              ? null
                              : () => _startOrRestart(restart: true),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Restart server'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          controller.isBusy || !controller.localServerRunning
                              ? null
                              : _stopServer,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Stop server'),
                    ),
                    if (controller.hasSession)
                      OutlinedButton.icon(
                        onPressed: controller.isBusy ? null : _logout,
                        icon: const Icon(Icons.logout),
                        label: const Text('Logout'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(statusText),
                if (controller.localServerError != null &&
                    controller.localServerError!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    controller.localServerError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                if (controller.localServerRunning) ...<Widget>[
                  const SizedBox(height: 8),
                  Text('Localhost API: ${controller.baseUrl}'),
                ],
                if (controller.localDownloadsDir != null) ...<Widget>[
                  const SizedBox(height: 8),
                  SelectableText(
                      'Downloads dir: ${controller.localDownloadsDir!}'),
                ],
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
                Text('Optional local auth',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'Password (optional)',
                    helperText:
                        'If filled, Start / Restart will launch the embedded server with auth enabled and auto-login.',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (controller.needsLogin)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Authentication',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: controller.isBusy ? null : _login,
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Login'),
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
                Text('Architecture',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text(
                  'Flutter is only the UI layer. The full Rust HTTP / WebSocket server runs inside the same mobile app process and is accessed through 127.0.0.1, so no remote desktop connection is required.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'This keeps one codepath for download, playlists, preview, clip, and task streaming while still letting you ship a single Flutter app as APK / IPA.',
                ),
              ],
            ),
          ),
        ),
      ],
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
  late final TextEditingController _curlController;
  late final TextEditingController _headersController;
  late final TextEditingController _outputNameController;
  late final TextEditingController _concurrencyController;

  String _selectedQuality = 'best';

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _curlController = TextEditingController();
    _headersController = TextEditingController();
    _outputNameController = TextEditingController();
    _concurrencyController = TextEditingController(text: '8');
    widget.controller.suggestedUrl.addListener(_applySuggestedUrl);
  }

  @override
  void dispose() {
    widget.controller.suggestedUrl.removeListener(_applySuggestedUrl);
    _urlController.dispose();
    _curlController.dispose();
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
    _curlController.clear();
    if (mounted) {
      _showMessage(context, 'Filled the download URL from playlists.');
    }
  }

  Future<void> _parse() async {
    final resolved = _resolveDownloadInputs(
      urlText: _urlController.text,
      curlText: _curlController.text,
      headerText: _headersController.text,
    );
    try {
      await widget.controller.parseInput(
        url: resolved.url,
        headers: resolved.headers,
      );
      if (!mounted) {
        return;
      }
      setState(() => _selectedQuality = 'best');
      _showMessage(context, 'Stream parsed successfully.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(context, error.message, error: true);
    }
  }

  Future<void> _startDownload() async {
    try {
      final resolved = _resolveDownloadInputs(
        urlText: _urlController.text,
        curlText: _curlController.text,
        headerText: _headersController.text,
      );
      await widget.controller.startDownload(
        url: resolved.url,
        headers: resolved.headers,
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
      _showMessage(context, 'Download started.');
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
          child: Text('Start the on-device Rust server first.'),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Create a download',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: _curlController,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'curl command (optional)',
                    helperText:
                        'Paste a full curl command here when you need headers or tokens extracted automatically.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'M3U8 URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _headersController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Headers (optional)',
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
                          labelText: 'Output file name (optional)',
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
                          labelText: 'Concurrency',
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
                    labelText: 'Quality',
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
                      label: const Text('Parse'),
                    ),
                    FilledButton.icon(
                      onPressed: controller.isBusy ? null : _startDownload,
                      icon: const Icon(Icons.download_for_offline_outlined),
                      label: const Text('Start download'),
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
                  Text('Parsed stream',
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
                    Text('Variants',
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
          child: Text('Connect and log in before managing tasks.'),
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
              const Text('No tasks yet.'),
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
          final treatedAsStopped = controller.treatTaskAsStopped(task);
          final statusLabel = _taskStatusLabel(task, controller);
          final statusColor = _taskStatusColor(task, controller);
          final displayError = _taskErrorMessage(task, controller);
          final progressValue = task.isRecording || task.isStopping
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
                          label: 'Downloaded',
                          value: _formatBytes(task.bytesDownloaded)),
                      if (task.total > 0)
                        _InfoChip(
                            label: 'Segments',
                            value: '${task.downloaded}/${task.total}'),
                      if (task.recordedSegments > 0)
                        _InfoChip(
                            label: 'Recorded',
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
                        onPressed: controller.isBusy || task.isStopping
                            ? null
                            : () async {
                                try {
                                  final result =
                                      await controller.deleteOrStopTask(task);
                                  if (!context.mounted) {
                                    return;
                                  }
                                  _showMessage(context, 'Task action: $result');
                                } on ApiException catch (error) {
                                  if (!context.mounted) {
                                    return;
                                  }
                                  _showMessage(context, error.message,
                                      error: true);
                                }
                              },
                        icon: Icon(task.isRecording
                            ? Icons.stop
                            : task.isStopping
                                ? Icons.hourglass_bottom
                                : task.isTerminal
                                    ? Icons.delete
                                    : Icons.close),
                        label: Text(task.isRecording
                            ? 'Stop'
                            : task.isStopping
                                ? 'Stopping...'
                                : task.isTerminal
                                    ? 'Delete'
                                    : 'Cancel'),
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
                                        'Stopped current recording and started a new one (${_shortId(newTaskId)}).');
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
                                        'Recording restarted (${_shortId(newTaskId)}).');
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
                          onPressed: controller.isBusy
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
                          label: const Text('Finalize locally'),
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
                          ),
                          icon: const Icon(Icons.play_circle_fill),
                          label: const Text('Watch file'),
                        ),
                      if (task.output != null)
                        OutlinedButton.icon(
                          onPressed: () => _copyToClipboard(
                            context,
                            controller.downloadUri(task.output!).toString(),
                            label:
                                'Download URL copied. It still requires the active session cookie when auth is enabled.',
                          ),
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy MP4 URL'),
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
          child: Text('Connect and log in before loading playlists.'),
        ),
      );
    }

    final allItems = controller.playlists
        .expand(
          (playlist) => playlist.channels.map((channel) =>
              _PlaylistBrowserItem(playlist: playlist, channel: channel)),
        )
        .toList();
    final playlistScoped = _selectedPlaylistId == null
        ? allItems
        : allItems
            .where((item) => item.playlist.id == _selectedPlaylistId)
            .toList();
    final availableGroups = <String>{
      'All groups',
      ...playlistScoped.map((item) => item.channel.groupName),
    }.toList()
      ..sort();
    final activeGroup = availableGroups.contains(_selectedGroup)
        ? _selectedGroup
        : 'All groups';
    Playlist? selectedPlaylist;
    if (_selectedPlaylistId != null) {
      for (final playlist in controller.playlists) {
        if (playlist.id == _selectedPlaylistId) {
          selectedPlaylist = playlist;
          break;
        }
      }
    }
    final query = _searchController.text.trim().toLowerCase();
    final visibleItems = playlistScoped.where((item) {
      final matchesGroup =
          activeGroup == 'All groups' || item.channel.groupName == activeGroup;
      final haystack = <String>[
        item.channel.name,
        item.channel.url,
        item.channel.groupName,
        item.playlist.name,
      ].join(' ').toLowerCase();
      final matchesQuery = query.isEmpty || haystack.contains(query);
      return matchesGroup && matchesQuery;
    }).toList();

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Channels & playlists',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (selectedPlaylist != null)
                PopupMenuButton<String>(
                  tooltip: 'Manage selected playlist',
                  onSelected: (value) async {
                    try {
                      if (value == 'refresh') {
                        await controller.refreshPlaylist(selectedPlaylist!.id);
                        if (!context.mounted) {
                          return;
                        }
                        _showMessage(context, 'Playlist refreshed.');
                      } else if (value == 'delete') {
                        await controller.deletePlaylist(selectedPlaylist!.id);
                        if (!context.mounted) {
                          return;
                        }
                        setState(() => _selectedPlaylistId = null);
                        _showMessage(context, 'Playlist deleted.');
                      }
                    } on ApiException catch (error) {
                      if (!context.mounted) {
                        return;
                      }
                      _showMessage(context, error.message, error: true);
                    }
                  },
                  itemBuilder: (context) => const <PopupMenuEntry<String>>[
                    PopupMenuItem(
                      value: 'refresh',
                      child: Text('Refresh selected'),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete selected'),
                    ),
                  ],
                  icon: const Icon(Icons.more_horiz),
                ),
              if (selectedPlaylist != null) const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: controller.isBusy || controller.healthState.running
                    ? null
                    : () async {
                        try {
                          await controller.runHealthCheck();
                          if (!context.mounted) {
                            return;
                          }
                          _showMessage(
                              context, 'Channel health check started.');
                        } on ApiException catch (error) {
                          if (!context.mounted) {
                            return;
                          }
                          _showMessage(context, error.message, error: true);
                        }
                      },
                icon: const Icon(Icons.health_and_safety_outlined),
                label: Text(
                    controller.healthState.running ? 'Checking...' : 'Health'),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh playlists',
                onPressed: controller.isBusy
                    ? null
                    : () async {
                        try {
                          await controller.refreshData();
                        } on ApiException catch (error) {
                          if (!context.mounted) {
                            return;
                          }
                          _showMessage(context, error.message, error: true);
                        }
                      },
                icon: const Icon(Icons.refresh),
              ),
              FilledButton.icon(
                onPressed: controller.isBusy
                    ? null
                    : () => _showAddPlaylistDialog(context, controller),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ],
          ),
        ),
        if (controller.healthState.running || controller.healthCache.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Icon(Icons.favorite_outline, color: _appAccent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            controller.healthState.running
                                ? 'Health check running'
                                : 'Health cache ready',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          controller.healthState.total > 0
                              ? '${controller.healthState.done}/${controller.healthState.total}'
                              : '${controller.healthCache.length} cached',
                          style: const TextStyle(color: _appTextMuted),
                        ),
                      ],
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
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
              labelText: 'Search channels, groups or playlist names',
            ),
          ),
        ),
        if (controller.playlists.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    selected: _selectedPlaylistId == null,
                    label: const Text('All playlists'),
                    onSelected: (_) =>
                        setState(() => _selectedPlaylistId = null),
                  ),
                ),
                for (final playlist in controller.playlists)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      selected: _selectedPlaylistId == playlist.id,
                      label: Text(playlist.name),
                      onSelected: (_) =>
                          setState(() => _selectedPlaylistId = playlist.id),
                    ),
                  ),
              ],
            ),
          ),
        if (availableGroups.length > 1)
          SizedBox(
            height: 48,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                for (final group in availableGroups)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      selected: activeGroup == group,
                      label: Text(group),
                      onSelected: (_) => setState(() => _selectedGroup = group),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: controller.refreshData,
            child: controller.playlists.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(24),
                    children: const <Widget>[
                      SizedBox(height: 80),
                      Icon(Icons.playlist_add, size: 48),
                      SizedBox(height: 12),
                      Center(child: Text('No playlists saved yet.')),
                    ],
                  )
                : visibleItems.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(24),
                        children: const <Widget>[
                          SizedBox(height: 72),
                          Icon(Icons.search_off, size: 48),
                          SizedBox(height: 12),
                          Center(
                              child: Text(
                                  'No channels match the current filters.')),
                        ],
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 360,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          mainAxisExtent: 228,
                        ),
                        itemCount: visibleItems.length,
                        itemBuilder: (context, index) {
                          final item = visibleItems[index];
                          final health =
                              controller.healthForUrl(item.channel.url);
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      _ChannelLogo(
                                          url: item.channel.logo, size: 48),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              item.channel.name,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              item.playlist.name,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                      color: _appTextMuted),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        width: 12,
                                        height: 12,
                                        margin: const EdgeInsets.only(top: 6),
                                        decoration: BoxDecoration(
                                          color: _healthStatusColor(
                                              health?.status),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: <Widget>[
                                      Chip(label: Text(item.channel.groupName)),
                                      Chip(
                                        label: Text(
                                          health == null
                                              ? 'Unchecked'
                                              : _titleCase(health.status),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    item.channel.url,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: _appTextMuted),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const Spacer(),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: <Widget>[
                                      FilledButton.icon(
                                        onPressed: () => _openMediaPlayer(
                                          context,
                                          title: item.channel.name,
                                          uri: controller
                                              .watchProxyUri(item.channel.url),
                                          httpHeaders:
                                              controller.mediaRequestHeaders,
                                          isLive: true,
                                        ),
                                        icon:
                                            const Icon(Icons.play_circle_fill),
                                        label: const Text('Watch'),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed: () {
                                          controller.suggestDownloadUrl(
                                              item.channel.url);
                                          widget.onUseChannel();
                                          _showMessage(context,
                                              'Filled the download URL from channels.');
                                        },
                                        icon: const Icon(Icons.call_made),
                                        label: const Text('Use'),
                                      ),
                                      IconButton(
                                        tooltip: 'Copy watch proxy URL',
                                        onPressed: () => _copyToClipboard(
                                          context,
                                          controller
                                              .watchProxyUri(item.channel.url)
                                              .toString(),
                                          label:
                                              'Watch proxy URL copied. It still requires the active session cookie when auth is enabled.',
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
}

class _PlaylistBrowserItem {
  const _PlaylistBrowserItem({
    required this.playlist,
    required this.channel,
  });

  final Playlist playlist;
  final PlaylistChannel channel;
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
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _MediaPlayerPage(
        title: title,
        uri: uri,
        httpHeaders: httpHeaders,
        isLive: isLive,
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
  });

  final String title;
  final Uri uri;
  final Map<String, String> httpHeaders;
  final bool isLive;

  @override
  State<_MediaPlayerPage> createState() => _MediaPlayerPageState();
}

class _MediaPlayerPageState extends State<_MediaPlayerPage> {
  late final VideoPlayerController _controller;
  String? _error;
  bool _initialized = false;
  bool _isFullscreen = false;
  bool _showControls = true;
  bool _muted = false;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(
      widget.uri,
      httpHeaders: widget.httpHeaders,
    );
    _controller.addListener(_handleControllerUpdate);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _controller.initialize();
      await _controller.setLooping(!widget.isLive);
      await _controller.play();
      if (!mounted) {
        return;
      }
      setState(() => _initialized = true);
      _scheduleControlsHide();
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
  }

  Future<void> _togglePlayback() async {
    if (_controller.value.isPlaying) {
      await _controller.pause();
      _controlsTimer?.cancel();
      setState(() => _showControls = true);
      return;
    }
    await _controller.play();
    _scheduleControlsHide();
  }

  Future<void> _seekRelative(int seconds) async {
    final position = await _controller.position ?? Duration.zero;
    final duration = _controller.value.duration;
    final target = position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (duration > Duration.zero && target > duration ? duration : target);
    await _controller.seekTo(clamped);
    _scheduleControlsHide();
  }

  Future<void> _setMuted(bool value) async {
    await _controller.setVolume(value ? 0 : 1);
    if (!mounted) {
      return;
    }
    setState(() => _muted = value);
  }

  Future<void> _setFullscreen(bool enabled) async {
    if (enabled) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      _restoreSystemUi();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isFullscreen = enabled;
      _showControls = true;
    });
    _scheduleControlsHide();
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
    if (!_isFullscreen || !_controller.value.isPlaying) {
      return;
    }
    _controlsTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || !_controller.value.isPlaying) {
        return;
      }
      setState(() => _showControls = false);
    });
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _restoreSystemUi();
    _controller.removeListener(_handleControllerUpdate);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aspectRatio =
        _controller.value.isInitialized && _controller.value.aspectRatio > 0
            ? _controller.value.aspectRatio
            : 16 / 9;

    final player = GestureDetector(
      onTap: _initialized ? _toggleControls : null,
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
                child: _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      )
                    : !_initialized
                        ? const Center(child: CircularProgressIndicator())
                        : Center(child: VideoPlayer(_controller)),
              ),
            ),
          ),
          Positioned.fill(child: _buildControls(context)),
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
                  IconButton(
                    tooltip: 'Copy URL',
                    onPressed: () => _copyToClipboard(
                      context,
                      widget.uri.toString(),
                      label:
                          'Media URL copied. It still requires the active session cookie when auth is enabled.',
                    ),
                    icon: const Icon(Icons.copy),
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
                                  ? 'Live stream / preview'
                                  : 'Drag the timeline, clip a segment, or go fullscreen.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: _appTextMuted),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          widget.uri.toString(),
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
    final current = _controller.value.position;
    final total = _controller.value.duration;
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
              if (_initialized && _isFullscreen)
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.55),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _togglePlayback,
                  icon: Icon(
                    _controller.value.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                color: Colors.black.withValues(alpha: 0.36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (!widget.isLive && _initialized)
                      VideoProgressIndicator(
                        _controller,
                        allowScrubbing: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        colors: const VideoProgressColors(
                          playedColor: _appPrimary,
                          bufferedColor: Color(0xFF475569),
                          backgroundColor: Color(0xFF1E293B),
                        ),
                      ),
                    Row(
                      children: <Widget>[
                        if (!widget.isLive)
                          IconButton(
                            onPressed:
                                _initialized ? () => _seekRelative(-10) : null,
                            icon: const Icon(Icons.replay_10),
                          ),
                        IconButton(
                          onPressed: _initialized ? _togglePlayback : null,
                          icon: Icon(
                            _controller.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                          ),
                        ),
                        if (!widget.isLive)
                          IconButton(
                            onPressed:
                                _initialized ? () => _seekRelative(10) : null,
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
                          onPressed:
                              _initialized ? () => _setMuted(!_muted) : null,
                          icon: Icon(
                            _muted ? Icons.volume_off : Icons.volume_up,
                          ),
                        ),
                        IconButton(
                          onPressed: _initialized
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
          title: const Text('Add playlist'),
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
                    labelText: 'Playlist URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: rawController,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Raw M3U (optional)',
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
    _showMessage(context, 'Playlist added.');
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
  double clipStart = 0;
  final maxDuration = task.durationSec ?? 120;
  final defaultEnd = task.durationSec != null && task.durationSec! > 30
      ? 30.0
      : task.durationSec ?? 10;
  double clipEnd = defaultEnd;
  final startController = TextEditingController(text: '0');
  final endController =
      TextEditingController(text: defaultEnd.toStringAsFixed(1));
  final hasSlider = task.hasKnownDuration && maxDuration >= 1;

  try {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setLocalState) => AlertDialog(
            title: const Text('Create clip'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (hasSlider) ...<Widget>[
                    Text(
                      'Choose a clip range on the downloaded timeline.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: _appTextMuted),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _InfoChip(
                            label: 'Start',
                            value: _formatSeconds(clipStart),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _InfoChip(
                            label: 'End',
                            value: _formatSeconds(clipEnd),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _InfoChip(
                            label: 'Length',
                            value: _formatSeconds(clipEnd - clipStart),
                          ),
                        ),
                      ],
                    ),
                    RangeSlider(
                      values: RangeValues(clipStart, clipEnd),
                      min: 0,
                      max: maxDuration,
                      divisions:
                          math.max(1, math.min(600, maxDuration.round())),
                      labels: RangeLabels(
                        _formatSeconds(clipStart),
                        _formatSeconds(clipEnd),
                      ),
                      onChanged: (values) {
                        setLocalState(() {
                          clipStart = values.start;
                          clipEnd = values.end;
                          startController.text = clipStart.toStringAsFixed(1);
                          endController.text = clipEnd.toStringAsFixed(1);
                        });
                      },
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final preset in <double>[15, 30, 60])
                          if (maxDuration >= preset)
                            OutlinedButton(
                              onPressed: () {
                                setLocalState(() {
                                  clipEnd =
                                      math.min(clipStart + preset, maxDuration);
                                  startController.text =
                                      clipStart.toStringAsFixed(1);
                                  endController.text =
                                      clipEnd.toStringAsFixed(1);
                                });
                              },
                              child: Text('${preset.toInt()}s'),
                            ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: startController,
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
                      setLocalState(() {
                        clipStart = parsed.clamp(0, maxDuration).toDouble();
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: endController,
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
                      setLocalState(() {
                        clipEnd = parsed.clamp(0, maxDuration).toDouble();
                      });
                    },
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
                child: const Text('Clip'),
              ),
            ],
          ),
        );
      },
    );

    if (result != true || !context.mounted) {
      return;
    }

    final startTime = double.tryParse(startController.text.trim());
    final endTime = double.tryParse(endController.text.trim());
    if (startTime == null || endTime == null) {
      _showMessage(context, 'Please enter valid clip timestamps.', error: true);
      return;
    }

    final filename = await controller.clipTask(task, startTime, endTime);
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
    );
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    _showMessage(context, error.message, error: true);
  } finally {
    startController.dispose();
    endController.dispose();
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

_ResolvedDownloadRequest _resolveDownloadInputs({
  required String urlText,
  required String curlText,
  required String headerText,
}) {
  final manualHeaders = _parseHeadersText(headerText);
  final trimmedCurl = curlText.trim();
  if (trimmedCurl.isEmpty) {
    final trimmedUrl = urlText.trim();
    if (trimmedUrl.isEmpty) {
      throw ApiException('Please enter either a URL or a curl command.');
    }
    return _ResolvedDownloadRequest(url: trimmedUrl, headers: manualHeaders);
  }

  final parsedCurl = _parseCurlCommand(trimmedCurl);
  final resolvedUrl =
      parsedCurl.url.isNotEmpty ? parsedCurl.url : urlText.trim();
  if (resolvedUrl.isEmpty) {
    throw ApiException('Could not extract a URL from the curl command.');
  }

  return _ResolvedDownloadRequest(
    url: resolvedUrl,
    headers: <String, String>{
      ...parsedCurl.headers,
      ...manualHeaders,
    },
  );
}

_ParsedCurlCommand _parseCurlCommand(String command) {
  final flattened =
      command.replaceAll('\\\n', ' ').replaceAll('\n', ' ').trim();
  final headerPattern =
      RegExp(r'''(?:-H|--header)\s+(?:"([^"]+)"|'([^']+)')''');
  final headers = <String, String>{};
  for (final match in headerPattern.allMatches(flattened)) {
    final rawHeader = match.group(1) ?? match.group(2);
    if (rawHeader == null || rawHeader.isEmpty) {
      continue;
    }
    final separatorIndex = rawHeader.indexOf(':');
    if (separatorIndex <= 0) {
      continue;
    }
    final name = rawHeader.substring(0, separatorIndex).trim();
    final value = rawHeader.substring(separatorIndex + 1).trim();
    if (name.isEmpty || value.isEmpty) {
      continue;
    }
    headers[name] = value;
  }

  final quotedUrlPattern = RegExp(r'''(?:"|')(https?://[^"']+)(?:"|')''');
  final bareUrlPattern = RegExp(r'''https?://\S+''');
  final quotedUrlMatch = quotedUrlPattern.firstMatch(flattened);
  final bareUrlMatch = bareUrlPattern.firstMatch(flattened);
  final url = quotedUrlMatch?.group(1) ?? bareUrlMatch?.group(0) ?? '';

  return _ParsedCurlCommand(url: url, headers: headers);
}

class _ResolvedDownloadRequest {
  const _ResolvedDownloadRequest({
    required this.url,
    required this.headers,
  });

  final String url;
  final Map<String, String> headers;
}

class _ParsedCurlCommand {
  const _ParsedCurlCommand({
    required this.url,
    required this.headers,
  });

  final String url;
  final Map<String, String> headers;
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
  if (controller.treatTaskAsStopped(task)) {
    return Colors.blueGrey;
  }
  if (task.needsLocalMerge) {
    return _appWarning;
  }
  return _statusColor(task.status);
}

String _taskStatusLabel(DownloadTask task, AppController controller) {
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
  if (error == null || error.isEmpty) {
    return null;
  }
  if (controller.treatTaskAsStopped(task)) {
    return null;
  }
  if (task.needsLocalMerge) {
    return 'FFmpeg is unavailable inside the embedded server. Tap “Finalize locally” to merge on-device and keep the download usable.';
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
