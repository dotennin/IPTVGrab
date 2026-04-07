import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'background_execution_bridge.dart';
import 'live_activities_bridge.dart';
import 'local_server_bridge.dart';
import 'mobile_ffmpeg.dart';
import 'models.dart';

class AppController extends ChangeNotifier {
  AppController({
    ApiClient? apiClient,
    BackgroundExecutionBridge? backgroundExecution,
    LocalServerBridge? localServerBridge,
    MobileFfmpeg? mobileFfmpeg,
    LiveActivitiesBridge? liveActivities,
  })  : api = apiClient ?? ApiClient(),
        backgroundExecution =
            backgroundExecution ?? BackgroundExecutionBridge.instance,
        localServer = localServerBridge ?? LocalServerBridge.instance,
        mobileFfmpeg = mobileFfmpeg ?? MobileFfmpeg(),
        liveActivities = liveActivities ?? LiveActivitiesBridge.instance;

  final ApiClient api;
  final BackgroundExecutionBridge backgroundExecution;
  final LocalServerBridge localServer;
  final MobileFfmpeg mobileFfmpeg;
  final LiveActivitiesBridge liveActivities;
  final ValueNotifier<String?> suggestedUrl = ValueNotifier<String?>(null);

  final Map<String, DownloadTask> _tasksById = <String, DownloadTask>{};
  final Map<String, WebSocket> _taskSockets = <String, WebSocket>{};
  final Set<String> _userRequestedStops = <String>{};
  final Set<String> _autoFinalizeRequested = <String>{};
  final Set<String> _autoFinalizingTasks = <String>{};
  // Task IDs that were actively downloading/recording when the app went to
  // the background. Used to auto-resume them if the server restarted them
  // as "interrupted" after we return to the foreground.
  final Set<String> _activeTaskIdsBeforeBackground = <String>{};

  Timer? _tasksRefreshTimer;
  Timer? _healthRefreshTimer;
  bool _refreshingTasks = false;
  bool _isBusy = false;
  bool _disposed = false;
  bool _recoveringFromResume = false;
  bool _localServerRunning = false;
  bool _shouldKeepLocalServerRunning = true;
  bool _startupHealthCheckRequested = false;
  bool _appInBackground = false;
  bool _backgroundKeepAliveEnabled = false;
  bool? _authRequired;

  String? _localServerError;
  String? _localDownloadsDir;
  String? _serverAuthPassword;
  ParsedStreamInfo? _parsedInfo;
  List<Playlist> _playlists = const [];
  MergedPlaylistConfig? _mergedPlaylistConfig;
  HealthCheckSnapshot? _healthSnapshot;
  int? _preferredLocalServerPort;

  bool get isBusy => _isBusy;
  bool get localServerRunning => _localServerRunning;
  bool get isConnected => localServerRunning && api.baseUrl.isNotEmpty;
  bool get authRequired => _authRequired ?? false;
  bool get needsLogin => authRequired && !api.hasSession;
  bool get readyForApi => isConnected && !needsLogin;
  String get baseUrl => api.baseUrl;
  bool get hasSession => api.hasSession;
  String? get localServerError => _localServerError;
  String? get localDownloadsDir => _localDownloadsDir;
  ParsedStreamInfo? get parsedInfo => _parsedInfo;
  List<Playlist> get playlists => _playlists;
  MergedPlaylistConfig? get mergedPlaylistConfig => _mergedPlaylistConfig;
  HealthCheckState get healthState =>
      _healthSnapshot?.state ?? HealthCheckState.empty;
  Map<String, HealthCheckEntry> get healthCache =>
      _healthSnapshot?.cache ?? const <String, HealthCheckEntry>{};
  Map<String, String> get mediaRequestHeaders => api.mediaHeaders();
  bool isAutoFinalizingTask(String taskId) =>
      _autoFinalizingTasks.contains(taskId);
  bool get hasActiveTasks => _tasksById.values.any((task) => !task.isTerminal);

  List<DownloadTask> get tasks {
    final values = _tasksById.values.toList();
    values.sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return values;
  }

  Future<void> bootstrapLocalServer() async {
    try {
      await startLocalServer();
    } on ApiException catch (error) {
      _localServerError = error.message;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<void> startLocalServer({
    String? authPassword,
    bool forceRestart = false,
  }) async {
    return _runBusy(() async {
      final downloadsDir = await _ensureDownloadsDir();
      final normalizedPassword = _normalizePassword(authPassword);
      final restartPort = _preferredLocalServerPort;
      _localDownloadsDir = downloadsDir;
      _serverAuthPassword = normalizedPassword;
      _shouldKeepLocalServerRunning = true;
      _startupHealthCheckRequested = false;

      if (forceRestart) {
        _stopTaskSync();
        _stopHealthSync();
        _closeAllSockets();
        try {
          localServer.stop();
        } on LocalServerBridgeException catch (error) {
          throw ApiException(error.message);
        }
      }

      final baseUrl = forceRestart
          ? _startNativeLocalServer(
              downloadsDir: downloadsDir,
              authPassword: normalizedPassword,
              port: restartPort,
            )
          : await _ensureReachableLocalServer(
              downloadsDir: downloadsDir,
              authPassword: normalizedPassword,
              port: restartPort,
            );

      await _connectToLocalServer(
        baseUrl: baseUrl,
        authPassword: normalizedPassword,
        allowAutoLogin: true,
      );
    });
  }

  Future<void> refreshLocalServer() async {
    return _runBusy(() async {
      final downloadsDir = _localDownloadsDir ?? await _ensureDownloadsDir();
      _localDownloadsDir = downloadsDir;
      _shouldKeepLocalServerRunning = true;
      final baseUrl = await _ensureReachableLocalServer(
        downloadsDir: downloadsDir,
        authPassword: _serverAuthPassword,
        port: _preferredLocalServerPort,
      );
      await _connectToLocalServer(
        baseUrl: baseUrl,
        authPassword: _serverAuthPassword,
        allowAutoLogin: true,
      );
    });
  }

  Future<void> stopLocalServer() async {
    return _runBusy(() async {
      await _setBackgroundKeepAlive(false);
      try {
        localServer.stop();
      } on LocalServerBridgeException catch (error) {
        throw ApiException(error.message);
      }

      _shouldKeepLocalServerRunning = false;
      _startupHealthCheckRequested = false;
      _serverAuthPassword = null;
      _localServerRunning = false;
      _localServerError = null;
      _authRequired = false;
      _parsedInfo = null;
      _playlists = const [];
      _mergedPlaylistConfig = null;
      _healthSnapshot = null;
      _tasksById.clear();
      _stopTaskSync();
      _stopHealthSync();
      _closeAllSockets();
      api.disconnect();
    });
  }

  Future<void> login(String password) async {
    return _runBusy(() async {
      await api.login(password);
      _authRequired = await api.fetchAuthStatus();
      _startupHealthCheckRequested = false;
      await refreshData();
      _startTaskSync();
    });
  }

  Future<void> logout() async {
    return _runBusy(() async {
      await api.logout();
      _stopTaskSync();
      _stopHealthSync();
      _closeAllSockets();
      _tasksById.clear();
      _playlists = const [];
      _healthSnapshot = null;
      _parsedInfo = null;
      _mergedPlaylistConfig = null;
      _startupHealthCheckRequested = false;
      notifyListeners();
    });
  }

  Future<void> refreshData({bool runHealthCheckAfterRefresh = false}) async {
    await Future.wait(<Future<void>>[
      refreshPlaylists(),
      refreshMergedPlaylists(),
      refreshTasks(),
      refreshHealthCheck(),
    ]);
    if (runHealthCheckAfterRefresh) {
      await _refreshHealthAfterPlaylistMutation();
      return;
    }
    unawaited(_ensureStartupHealthCheck());
  }

  Future<void> parseInput({
    required String url,
    Map<String, String>? headers,
  }) async {
    return _runBusy(() async {
      _parsedInfo = await api.parse(
        url: url,
        headers: headers,
      );
      notifyListeners();
    });
  }

  /// Fetches quality variants for [url] without modifying any controller state.
  Future<List<StreamVariant>> parseStreamVariants({
    required String url,
    Map<String, String>? headers,
  }) async {
    try {
      final info = await api.parse(url: url, headers: headers);
      return info.streams;
    } catch (_) {
      return const [];
    }
  }

  Future<String> startDownload({
    required String url,
    required Map<String, String> headers,
    required String quality,
    required int concurrency,
    String? outputName,
  }) async {
    return _runBusy(() async {
      final taskId = await api.startDownload(
        url: url,
        headers: headers,
        quality: quality,
        concurrency: concurrency,
        outputName: outputName,
      );
      if (taskId.isEmpty) {
        throw ApiException('Server returned an empty task id.');
      }
      _tasksById[taskId] = DownloadTask.placeholder(id: taskId, url: url);
      notifyListeners();
      unawaited(_refreshTasksQuietly());
      unawaited(_ensureTaskSocket(taskId));
      _startTaskSync();
      unawaited(_syncBackgroundExecution());
      return taskId;
    });
  }

  Future<String> deleteOrStopTask(DownloadTask task) async {
    return _runBusy(() async {
      if (!task.isTerminal) {
        _userRequestedStops.add(task.id);
        if (task.isRecording) {
          _autoFinalizeRequested.add(task.id);
        }
      }
      final status = await api.deleteOrStopTask(task.id);
      if (status == 'deleted') {
        _tasksById.remove(task.id);
        _userRequestedStops.remove(task.id);
        _autoFinalizeRequested.remove(task.id);
        _autoFinalizingTasks.remove(task.id);
        await _closeSocket(task.id);
      }
      notifyListeners();
      unawaited(_refreshTasksQuietly());
      unawaited(_syncBackgroundExecution());
      return status;
    });
  }

  Future<void> resumeTask(String taskId) async {
    return _runBusy(() async {
      await api.resumeTask(taskId);
      unawaited(_refreshTasksQuietly());
      _startTaskSync();
      unawaited(_syncBackgroundExecution());
    });
  }

  Future<void> pauseTask(String taskId) async {
    return _runBusy(() async {
      await api.pauseTask(taskId);
      unawaited(_refreshTasksQuietly());
      unawaited(_syncBackgroundExecution());
    });
  }

  Future<void> restartTask(String taskId) async {
    return _runBusy(() async {
      _userRequestedStops.remove(taskId);
      await api.restartTask(taskId);
      unawaited(_refreshTasksQuietly());
      _startTaskSync();
      unawaited(_syncBackgroundExecution());
    });
  }

  Future<String> restartRecording(String taskId) async {
    return _runBusy(() async {
      _userRequestedStops.remove(taskId);
      _autoFinalizeRequested.remove(taskId);
      _autoFinalizingTasks.remove(taskId);
      final newTaskId = await api.restartRecording(taskId);
      unawaited(_refreshTasksQuietly());
      _startTaskSync();
      unawaited(_syncBackgroundExecution());
      return newTaskId;
    });
  }

  Future<String> forkRecording(String taskId) async {
    return _runBusy(() async {
      _userRequestedStops.add(taskId);
      _autoFinalizeRequested.add(taskId);
      final newTaskId = await api.forkRecording(taskId);
      unawaited(_refreshTasksQuietly());
      _startTaskSync();
      unawaited(_syncBackgroundExecution());
      return newTaskId;
    });
  }

  Future<String> clipTask(DownloadTask task, double start, double end) async {
    return _runBusy(() async {
      try {
        return await api.clipTask(task.id, start, end);
      } on ApiException catch (error) {
        if (!_shouldUseLocalFfmpeg(error)) {
          rethrow;
        }
        final downloadsDir = _requireLocalDownloadsDir();
        return mobileFfmpeg.clipTask(
          task: task,
          downloadsDir: downloadsDir,
          start: start,
          end: end,
        );
      }
    });
  }

  Future<String> finalizeTaskLocally(DownloadTask task) async {
    return _runBusy(() async {
      final filename = await _finalizeTaskLocallyImpl(task);
      final latest = await api.fetchTasks();
      await _storeTasks(latest);
      _autoFinalizeRequested.remove(task.id);
      _autoFinalizingTasks.remove(task.id);
      return filename;
    });
  }

  Future<void> refreshTasks() async {
    if (!readyForApi || _refreshingTasks) {
      return;
    }
    _refreshingTasks = true;
    try {
      final latest = await api.fetchTasks();
      await _storeTasks(latest);
    } on ApiException catch (error) {
      _handleAuthFailure(error);
      rethrow;
    } finally {
      _refreshingTasks = false;
    }
  }

  Future<void> refreshPlaylists() async {
    if (!readyForApi) {
      return;
    }
    try {
      _playlists = await api.fetchPlaylists();
      notifyListeners();
    } on ApiException catch (error) {
      _handleAuthFailure(error);
      rethrow;
    }
  }

  Future<void> refreshMergedPlaylists() async {
    if (!readyForApi) {
      return;
    }
    try {
      _mergedPlaylistConfig = await api.fetchMergedPlaylists();
      notifyListeners();
    } on ApiException catch (error) {
      _handleAuthFailure(error);
      rethrow;
    }
  }

  Future<void> refreshHealthCheck() async {
    if (!readyForApi) {
      return;
    }
    try {
      _healthSnapshot = await api.fetchHealthCheck();
      _syncHealthPolling();
      notifyListeners();
    } on ApiException catch (error) {
      _handleAuthFailure(error);
      rethrow;
    }
  }

  Future<void> runHealthCheck() async {
    return _runBusy(() async {
      await api.runHealthCheck();
      _startupHealthCheckRequested = true;
      await refreshHealthCheck();
      _syncHealthPolling();
    });
  }

  Future<String> addPlaylist({
    required String name,
    String? url,
    String? raw,
  }) async {
    return _runBusy(() async {
      final newPlaylist = await api.addPlaylist(name: name, url: url, raw: raw);
      await refreshPlaylists();
      await refreshMergedPlaylists();
      await _refreshHealthAfterPlaylistMutation();
      return newPlaylist.id;
    });
  }

  Future<void> editPlaylist(
    String playlistId, {
    required String name,
    String? url,
  }) async {
    return _runBusy(() async {
      await api.editPlaylist(playlistId, name: name, url: url);
      await refreshPlaylists();
      await refreshMergedPlaylists();
      await _refreshHealthAfterPlaylistMutation();
    });
  }

  Future<void> deletePlaylist(String playlistId) async {
    return _runBusy(() async {
      await api.deletePlaylist(playlistId);
      await refreshPlaylists();
      await refreshMergedPlaylists();
      await _refreshHealthAfterPlaylistMutation();
    });
  }

  Future<void> refreshPlaylist(String playlistId) async {
    return _runBusy(() async {
      await api.refreshPlaylist(playlistId);
      await refreshPlaylists();
      await refreshMergedPlaylists();
      await _refreshHealthAfterPlaylistMutation();
    });
  }

  Future<void> refreshAllPlaylists() async {
    return _runBusy(() async {
      await api.refreshAllPlaylists();
      await refreshPlaylists();
      await refreshMergedPlaylists();
      await _refreshHealthAfterPlaylistMutation();
    });
  }

  Future<void> saveMergedPlaylists(MergedPlaylistConfig config) async {
    return _runBusy(() async {
      await api.saveMergedPlaylists(config);
      await refreshMergedPlaylists();
      await _refreshHealthAfterPlaylistMutation();
    });
  }

  Future<String> fetchMergedExport() => api.fetchMergedExport();

  void suggestDownloadUrl(String url) {
    suggestedUrl.value = url;
  }

  Uri previewUri(String taskId) => api.previewUri(taskId);

  Uri downloadUri(String filename) => api.downloadUri(filename);

  Uri watchProxyUri(String streamUrl) => api.watchProxyUri(streamUrl);

  Future<Uri> mergedExportUri() async {
    final token = await api.getExportToken();
    return api.mergedExportUri(token: token);
  }

  HealthCheckEntry? healthForUrl(String url) => healthCache[url];

  Future<void> handleAppLifecycleState(AppLifecycleState state) async {
    if (_disposed) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        _appInBackground = false;
        await _syncBackgroundExecution();
        await _recoverLocalServerAfterResume();
        return;
      case AppLifecycleState.inactive:
        _appInBackground = true;
        await _syncBackgroundExecution();
        return;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _appInBackground = true;
        _activeTaskIdsBeforeBackground
          ..clear()
          ..addAll(
            _tasksById.values
                .where((t) => !t.isTerminal)
                .map((t) => t.id),
          );
        await _syncBackgroundExecution();
        _stopTaskSync();
        _stopHealthSync();
        _closeAllSockets();
        if (!_disposed) {
          notifyListeners();
        }
        return;
    }
  }

  bool treatTaskAsStopped(DownloadTask task) {
    if (!_userRequestedStops.contains(task.id)) {
      return false;
    }
    final error = task.error?.toLowerCase() ?? '';
    return task.status == 'cancelled' ||
        (task.status == 'failed' &&
            (error.contains('some(254)') ||
                error.contains('code 254') ||
                error.contains('signal')));
  }

  @override
  void dispose() {
    _disposed = true;
    suggestedUrl.dispose();
    _stopTaskSync();
    _stopHealthSync();
    _closeAllSockets();
    unawaited(_setBackgroundKeepAlive(false));
    super.dispose();
  }

  Future<T> _runBusy<T>(Future<T> Function() action) async {
    _isBusy = true;
    notifyListeners();
    try {
      return await action();
    } on ApiException catch (error) {
      _handleAuthFailure(error);
      rethrow;
    } finally {
      _isBusy = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void _handleAuthFailure(ApiException error) {
    if (error.statusCode != 401) {
      return;
    }
    api.clearSession();
    _stopTaskSync();
    _closeAllSockets();
    _tasksById.clear();
    _playlists = const [];
    _mergedPlaylistConfig = null;
    unawaited(_setBackgroundKeepAlive(false));
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _startTaskSync() {
    _tasksRefreshTimer?.cancel();
    if (!readyForApi) {
      return;
    }
    _tasksRefreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshTasksQuietly()),
    );
  }

  void _stopTaskSync() {
    _tasksRefreshTimer?.cancel();
    _tasksRefreshTimer = null;
  }

  void _syncHealthPolling() {
    if (healthState.running) {
      _healthRefreshTimer ??= Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_refreshHealthQuietly()),
      );
      return;
    }
    _stopHealthSync();
  }

  void _stopHealthSync() {
    _healthRefreshTimer?.cancel();
    _healthRefreshTimer = null;
  }

  Future<void> _syncTaskSockets() async {
    final activeIds = _tasksById.values
        .where((task) => !task.isTerminal)
        .map((task) => task.id)
        .toSet();

    final staleSockets =
        _taskSockets.keys.where((id) => !activeIds.contains(id)).toList();
    for (final taskId in staleSockets) {
      await _closeSocket(taskId);
    }

    for (final taskId in activeIds) {
      await _ensureTaskSocket(taskId);
    }
  }

  Future<void> _ensureTaskSocket(String taskId) async {
    if (!readyForApi || _taskSockets.containsKey(taskId)) {
      return;
    }
    try {
      final socket = await api.connectTaskSocket(taskId);
      _taskSockets[taskId] = socket;
      socket.listen(
        (dynamic message) {
          if (message is! String) {
            return;
          }
          final decoded = jsonDecode(message);
          if (decoded is Map<String, dynamic> && decoded['type'] == 'ping') {
            return;
          }
          if (decoded is! Map<String, dynamic>) {
            return;
          }
          final task = DownloadTask.fromJson(decoded);
          _tasksById[task.id] = task;
          _reconcileTaskFlags();
          if (task.isTerminal) {
            unawaited(_closeSocket(task.id));
          }
          if (!_disposed) {
            notifyListeners();
          }
          unawaited(_maybeAutoFinalizeTask(task));
        },
        onDone: () => _scheduleSocketReconnect(taskId),
        onError: (_) => _scheduleSocketReconnect(taskId),
        cancelOnError: true,
      );
    } on ApiException catch (error) {
      _handleAuthFailure(error);
    } catch (_) {
      _scheduleSocketReconnect(taskId);
    }
  }

  void _scheduleSocketReconnect(String taskId) {
    _taskSockets.remove(taskId);
    final task = _tasksById[taskId];
    if (_disposed || !readyForApi || task == null || task.isTerminal) {
      return;
    }
    Future<void>.delayed(const Duration(seconds: 2), () async {
      if (_disposed || !readyForApi || _taskSockets.containsKey(taskId)) {
        return;
      }
      final latest = _tasksById[taskId];
      if (latest == null || latest.isTerminal) {
        return;
      }
      await _ensureTaskSocket(taskId);
    });
  }

  Future<void> _closeSocket(String taskId) async {
    final socket = _taskSockets.remove(taskId);
    await socket?.close();
  }

  Future<void> _storeTasks(List<DownloadTask> latest) async {
    final previousById = Map<String, DownloadTask>.from(_tasksById);
    _tasksById
      ..clear()
      ..addEntries(latest.map((task) => MapEntry(task.id, task)));
    await _syncTaskSockets();
    _reconcileTaskFlags();
    await _syncBackgroundExecution();
    unawaited(_syncLiveActivities(previousById));
    if (!_disposed) {
      notifyListeners();
    }
    for (final task in _tasksById.values) {
      unawaited(_maybeAutoFinalizeTask(task));
    }
  }

  Future<void> _syncLiveActivities(
    Map<String, DownloadTask> previousById,
  ) async {
    for (final task in _tasksById.values) {
      final wasActive = previousById[task.id]?.isActive ?? false;
      if (task.isActive) {
        if (!wasActive) {
          // Newly started or resumed — open a Live Activity.
          await liveActivities.startActivity(
            taskId: task.id,
            taskName: task.outputName ?? _shortTaskName(task.url),
            isRecording: task.isRecording,
          );
        }
        // Push progress update.
        await liveActivities.updateActivity(
          taskId: task.id,
          progress: (task.progress / 100.0).clamp(0.0, 1.0),
          speedMbps: task.speedMbps,
          done: task.isRecording ? task.recordedSegments : task.downloaded,
          total: task.total,
          status: task.status,
          elapsedSec: task.elapsedSec,
        );
      } else if (wasActive && task.isTerminal) {
        // Task just finished — close the Live Activity.
        await liveActivities.endActivity(task.id);
      }
    }
    // End activities for tasks that were removed entirely.
    for (final taskId in previousById.keys) {
      if (!_tasksById.containsKey(taskId)) {
        await liveActivities.endActivity(taskId);
      }
    }
  }

  static String _shortTaskName(String url) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      return segments.isNotEmpty ? segments.last : uri.host;
    } catch (_) {
      return 'Download';
    }
  }

  Future<void> _refreshTasksQuietly() async {
    try {
      await refreshTasks();
    } catch (_) {
      // Auth failures are already surfaced through state updates.
    }
  }

  Future<void> _refreshHealthQuietly() async {
    try {
      await refreshHealthCheck();
    } catch (_) {
      // Auth failures are already surfaced through state updates.
    }
  }

  void _closeAllSockets() {
    final sockets = _taskSockets.values.toList();
    _taskSockets.clear();
    for (final socket in sockets) {
      socket.close();
    }
  }

  Future<String> _ensureDownloadsDir() async {
    final baseDir = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory('${baseDir.path}/media_nest');
    final legacyDownloadsDir = Directory('${baseDir.path}/m3u8-downloader');
    if (!await downloadsDir.exists() && await legacyDownloadsDir.exists()) {
      await legacyDownloadsDir.rename(downloadsDir.path);
    }
    await downloadsDir.create(recursive: true);
    return downloadsDir.path;
  }

  String _startNativeLocalServer({
    required String downloadsDir,
    String? authPassword,
    int? port,
  }) {
    try {
      return localServer.start(
        downloadsDir: downloadsDir,
        port: port ?? 0,
        authPassword: authPassword,
      );
    } on LocalServerBridgeException catch (error) {
      throw ApiException(error.message);
    }
  }

  String? _currentNativeLocalServerBaseUrl() {
    try {
      return localServer.currentBaseUrl();
    } on LocalServerBridgeException catch (error) {
      throw ApiException(error.message);
    }
  }

  String _requireLocalDownloadsDir() {
    final downloadsDir = _localDownloadsDir;
    if (downloadsDir == null || downloadsDir.isEmpty) {
      throw ApiException('Local downloads directory is not ready yet.');
    }
    return downloadsDir;
  }

  String? _normalizePassword(String? password) {
    if (password == null) {
      return null;
    }
    final trimmed = password.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _connectToLocalServer({
    required String baseUrl,
    String? authPassword,
    required bool allowAutoLogin,
  }) async {
    _rememberLocalServerBaseUrl(baseUrl);
    _localServerRunning = true;
    _localServerError = null;
    _parsedInfo = null;

    _authRequired = await api.fetchAuthStatus();
    final normalizedPassword = _normalizePassword(authPassword);
    if ((_authRequired ?? false) &&
        allowAutoLogin &&
        normalizedPassword != null) {
      await api.login(normalizedPassword);
      _authRequired = await api.fetchAuthStatus();
    }

    if (readyForApi) {
      await refreshData();
      _startTaskSync();
      await _syncBackgroundExecution();
      return;
    }

    _tasksById.clear();
    _playlists = const [];
    _mergedPlaylistConfig = null;
    _stopTaskSync();
    _stopHealthSync();
    _closeAllSockets();
    await _syncBackgroundExecution();
  }

  Future<void> _ensureStartupHealthCheck() async {
    if (_startupHealthCheckRequested || !readyForApi || healthState.running) {
      return;
    }
    _startupHealthCheckRequested = true;
    try {
      await api.runHealthCheck();
      await refreshHealthCheck();
      _syncHealthPolling();
    } on ApiException catch (error) {
      if (error.statusCode == 409) {
        await refreshHealthCheck();
        return;
      }
      _startupHealthCheckRequested = false;
      _handleAuthFailure(error);
      debugPrint('Initial channel health scan failed: ${error.message}');
    }
  }

  Future<void> _refreshHealthAfterPlaylistMutation() async {
    if (!readyForApi) {
      return;
    }
    _startupHealthCheckRequested = true;
    try {
      await api.runHealthCheck();
      await refreshHealthCheck();
      _syncHealthPolling();
    } on ApiException catch (error) {
      if (error.statusCode == 409) {
        await refreshHealthCheck();
        return;
      }
      _handleAuthFailure(error);
      debugPrint(
        'Playlist-triggered channel health scan failed: ${error.message}',
      );
    }
  }

  Future<void> _recoverLocalServerAfterResume() async {
    if (_recoveringFromResume || !_shouldKeepLocalServerRunning) {
      return;
    }
    _recoveringFromResume = true;
    try {
      final downloadsDir = _localDownloadsDir ?? await _ensureDownloadsDir();
      _localDownloadsDir = downloadsDir;
      final baseUrl = await _ensureReachableLocalServer(
        downloadsDir: downloadsDir,
        authPassword: _serverAuthPassword,
        port: _preferredLocalServerPort,
      );
      await _connectToLocalServer(
        baseUrl: baseUrl,
        authPassword: _serverAuthPassword,
        allowAutoLogin: true,
      );
      await _autoResumeInterruptedTasks();
    } on ApiException catch (error) {
      _localServerError = error.message;
    } finally {
      _recoveringFromResume = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  // Auto-resume tasks that were actively downloading/recording when the app
  // went to the background and are now "interrupted" (server restarted).
  // Skips tasks that the user had explicitly stopped.
  Future<void> _autoResumeInterruptedTasks() async {
    if (_activeTaskIdsBeforeBackground.isEmpty || !readyForApi) {
      return;
    }
    final toResume = _activeTaskIdsBeforeBackground
        .where(
          (id) =>
              _tasksById[id]?.status == 'interrupted' &&
              !_userRequestedStops.contains(id),
        )
        .toList();
    _activeTaskIdsBeforeBackground.clear();

    for (final taskId in toResume) {
      try {
        await api.resumeTask(taskId);
      } on ApiException catch (e) {
        debugPrint('Auto-resume $taskId failed: ${e.message}');
      }
    }

    if (toResume.isNotEmpty) {
      unawaited(_refreshTasksQuietly());
      _startTaskSync();
      unawaited(_syncBackgroundExecution());
    }
  }

  void _rememberLocalServerBaseUrl(String baseUrl) {
    api.baseUrl = baseUrl;
    final uri = Uri.tryParse(baseUrl);
    if (uri != null && uri.hasPort && uri.port > 0) {
      _preferredLocalServerPort = uri.port;
    }
  }

  Future<String?> _currentReachableLocalServerBaseUrl() async {
    final baseUrl = _currentNativeLocalServerBaseUrl();
    if (baseUrl == null || baseUrl.isEmpty) {
      return null;
    }
    return await api.probeBaseUrl(baseUrl) ? baseUrl : null;
  }

  Future<String> _ensureReachableLocalServer({
    required String downloadsDir,
    String? authPassword,
    int? port,
  }) async {
    final reachableBaseUrl = await _currentReachableLocalServerBaseUrl();
    if (reachableBaseUrl != null) {
      return reachableBaseUrl;
    }

    final staleBaseUrl = _currentNativeLocalServerBaseUrl();
    if (staleBaseUrl != null && staleBaseUrl.isNotEmpty) {
      try {
        localServer.stop();
      } on LocalServerBridgeException catch (error) {
        debugPrint('Failed to stop stale local server: ${error.message}');
      }
    }

    return _startNativeLocalServer(
      downloadsDir: downloadsDir,
      authPassword: authPassword,
      port: port,
    );
  }

  Future<String> _finalizeTaskLocallyImpl(DownloadTask task) async {
    try {
      final downloadsDir = _requireLocalDownloadsDir();
      final result = await mobileFfmpeg.mergeTask(
        task: task,
        downloadsDir: downloadsDir,
      );
      await api.completeLocalMerge(
        task.id,
        filename: result.filename,
        size: result.size,
        durationSec: result.durationSec,
      );
      return result.filename;
    } on ApiException {
      rethrow;
    } on Exception catch (error) {
      throw ApiException(error.toString());
    }
  }

  Future<void> _maybeAutoFinalizeTask(DownloadTask task) async {
    if (!_autoFinalizeRequested.contains(task.id) ||
        !task.needsLocalMerge ||
        _autoFinalizingTasks.contains(task.id)) {
      return;
    }

    _autoFinalizingTasks.add(task.id);
    if (!_disposed) {
      notifyListeners();
    }

    try {
      await _finalizeTaskLocallyImpl(task);
      final latest = await api.fetchTasks();
      await _storeTasks(latest);
    } on ApiException {
      _autoFinalizeRequested.remove(task.id);
    } finally {
      _autoFinalizingTasks.remove(task.id);
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void _reconcileTaskFlags() {
    final knownTaskIds = _tasksById.keys.toSet();
    _userRequestedStops.removeWhere((taskId) => !knownTaskIds.contains(taskId));
    _autoFinalizeRequested
        .removeWhere((taskId) => !knownTaskIds.contains(taskId));
    _autoFinalizingTasks
        .removeWhere((taskId) => !knownTaskIds.contains(taskId));

    for (final task in _tasksById.values) {
      if (task.status == 'completed' ||
          task.status == 'cancelled' ||
          task.status == 'interrupted' ||
          task.status == 'paused') {
        _userRequestedStops.remove(task.id);
        _autoFinalizeRequested.remove(task.id);
        _autoFinalizingTasks.remove(task.id);
      } else if (task.status == 'failed' && !task.needsLocalMerge) {
        _autoFinalizeRequested.remove(task.id);
        _autoFinalizingTasks.remove(task.id);
      }
    }
  }

  bool _shouldUseLocalFfmpeg(ApiException error) {
    return indicatesMissingFfmpeg(error.message);
  }

  Future<void> _syncBackgroundExecution() async {
    final shouldEnable = _appInBackground && hasActiveTasks;
    await _setBackgroundKeepAlive(shouldEnable);
  }

  Future<void> _setBackgroundKeepAlive(bool enabled) async {
    if (_backgroundKeepAliveEnabled == enabled) {
      return;
    }
    try {
      await backgroundExecution.setKeepAlive(enabled);
      _backgroundKeepAliveEnabled = enabled;
    } on BackgroundExecutionBridgeException catch (error) {
      debugPrint('Background execution update failed: ${error.message}');
    }
  }
}
