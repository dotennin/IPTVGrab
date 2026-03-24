import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'local_server_bridge.dart';
import 'mobile_ffmpeg.dart';
import 'models.dart';

class AppController extends ChangeNotifier {
  AppController({
    ApiClient? apiClient,
    LocalServerBridge? localServerBridge,
    MobileFfmpeg? mobileFfmpeg,
  })  : api = apiClient ?? ApiClient(),
        localServer = localServerBridge ?? LocalServerBridge.instance,
        mobileFfmpeg = mobileFfmpeg ?? MobileFfmpeg();

  final ApiClient api;
  final LocalServerBridge localServer;
  final MobileFfmpeg mobileFfmpeg;
  final ValueNotifier<String?> suggestedUrl = ValueNotifier<String?>(null);

  final Map<String, DownloadTask> _tasksById = <String, DownloadTask>{};
  final Map<String, WebSocket> _taskSockets = <String, WebSocket>{};
  final Set<String> _userRequestedStops = <String>{};

  Timer? _tasksRefreshTimer;
  Timer? _healthRefreshTimer;
  bool _refreshingTasks = false;
  bool _isBusy = false;
  bool _disposed = false;
  bool _localServerRunning = false;
  bool? _authRequired;

  String? _localServerError;
  String? _localDownloadsDir;
  ParsedStreamInfo? _parsedInfo;
  List<Playlist> _playlists = const [];
  HealthCheckSnapshot? _healthSnapshot;

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
  HealthCheckState get healthState =>
      _healthSnapshot?.state ?? HealthCheckState.empty;
  Map<String, HealthCheckEntry> get healthCache =>
      _healthSnapshot?.cache ?? const <String, HealthCheckEntry>{};
  Map<String, String> get mediaRequestHeaders => api.mediaHeaders();

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

      if (forceRestart) {
        _stopTaskSync();
        _closeAllSockets();
        try {
          localServer.stop();
        } on LocalServerBridgeException catch (error) {
          throw ApiException(error.message);
        }
      }

      final existingBaseUrl = _currentNativeLocalServerBaseUrl();
      final baseUrl = forceRestart || existingBaseUrl == null
          ? _startNativeLocalServer(
              downloadsDir: downloadsDir,
              authPassword: authPassword,
            )
          : existingBaseUrl;

      api.baseUrl = baseUrl;
      _localServerRunning = true;
      _localDownloadsDir = downloadsDir;
      _localServerError = null;
      _parsedInfo = null;

      _authRequired = await api.fetchAuthStatus();
      if ((_authRequired ?? false) &&
          authPassword != null &&
          authPassword.isNotEmpty) {
        await api.login(authPassword);
        _authRequired = await api.fetchAuthStatus();
      }

      if (readyForApi) {
        await refreshData();
        _startTaskSync();
      } else {
        _tasksById.clear();
        _playlists = const [];
        _stopTaskSync();
        _closeAllSockets();
      }
    });
  }

  Future<void> refreshLocalServer() async {
    return _runBusy(() async {
      final baseUrl = _currentNativeLocalServerBaseUrl();
      if (baseUrl == null || baseUrl.isEmpty) {
        throw ApiException('The on-device Rust server is not running.');
      }
      api.baseUrl = baseUrl;
      _localServerRunning = true;
      _localServerError = null;
      _authRequired = await api.fetchAuthStatus();
      if (readyForApi) {
        await refreshData();
        _startTaskSync();
      }
    });
  }

  Future<void> stopLocalServer() async {
    return _runBusy(() async {
      try {
        localServer.stop();
      } on LocalServerBridgeException catch (error) {
        throw ApiException(error.message);
      }

      _localServerRunning = false;
      _localServerError = null;
      _authRequired = false;
      _parsedInfo = null;
      _playlists = const [];
      _tasksById.clear();
      _stopTaskSync();
      _closeAllSockets();
      api.disconnect();
    });
  }

  Future<void> login(String password) async {
    return _runBusy(() async {
      await api.login(password);
      _authRequired = await api.fetchAuthStatus();
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
      notifyListeners();
    });
  }

  Future<void> refreshData() async {
    await Future.wait(<Future<void>>[
      refreshPlaylists(),
      refreshTasks(),
      refreshHealthCheck(),
    ]);
  }

  Future<void> parseInput({
    String? url,
    String? curlCommand,
    Map<String, String>? headers,
  }) async {
    return _runBusy(() async {
      _parsedInfo = await api.parse(
        url: url,
        curlCommand: curlCommand,
        headers: headers,
      );
      notifyListeners();
    });
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
      return taskId;
    });
  }

  Future<String> deleteOrStopTask(DownloadTask task) async {
    return _runBusy(() async {
      if (!task.isTerminal) {
        _userRequestedStops.add(task.id);
      }
      final status = await api.deleteOrStopTask(task.id);
      if (status == 'deleted') {
        _tasksById.remove(task.id);
        _userRequestedStops.remove(task.id);
        await _closeSocket(task.id);
      }
      notifyListeners();
      unawaited(_refreshTasksQuietly());
      return status;
    });
  }

  Future<void> resumeTask(String taskId) async {
    return _runBusy(() async {
      await api.resumeTask(taskId);
      unawaited(_refreshTasksQuietly());
      _startTaskSync();
    });
  }

  Future<void> restartTask(String taskId) async {
    return _runBusy(() async {
      _userRequestedStops.remove(taskId);
      await api.restartTask(taskId);
      unawaited(_refreshTasksQuietly());
      _startTaskSync();
    });
  }

  Future<String> restartRecording(String taskId) async {
    return _runBusy(() async {
      _userRequestedStops.remove(taskId);
      final newTaskId = await api.restartRecording(taskId);
      unawaited(_refreshTasksQuietly());
      _startTaskSync();
      return newTaskId;
    });
  }

  Future<String> forkRecording(String taskId) async {
    return _runBusy(() async {
      _userRequestedStops.add(taskId);
      final newTaskId = await api.forkRecording(taskId);
      unawaited(_refreshTasksQuietly());
      _startTaskSync();
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
      await refreshTasks();
      return result.filename;
    });
  }

  Future<void> refreshTasks() async {
    if (!readyForApi || _refreshingTasks) {
      return;
    }
    _refreshingTasks = true;
    try {
      final latest = await api.fetchTasks();
      _tasksById
        ..clear()
        ..addEntries(latest.map((task) => MapEntry(task.id, task)));
      await _syncTaskSockets();
      notifyListeners();
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
      await refreshHealthCheck();
      _syncHealthPolling();
    });
  }

  Future<void> addPlaylist({
    required String name,
    String? url,
    String? raw,
  }) async {
    return _runBusy(() async {
      await api.addPlaylist(name: name, url: url, raw: raw);
      await refreshPlaylists();
    });
  }

  Future<void> deletePlaylist(String playlistId) async {
    return _runBusy(() async {
      await api.deletePlaylist(playlistId);
      _playlists =
          _playlists.where((playlist) => playlist.id != playlistId).toList();
      notifyListeners();
    });
  }

  Future<void> refreshPlaylist(String playlistId) async {
    return _runBusy(() async {
      await api.refreshPlaylist(playlistId);
      await refreshPlaylists();
    });
  }

  void suggestDownloadUrl(String url) {
    suggestedUrl.value = url;
  }

  Uri previewUri(String taskId) => api.previewUri(taskId);

  Uri downloadUri(String filename) => api.downloadUri(filename);

  Uri watchProxyUri(String streamUrl) => api.watchProxyUri(streamUrl);

  HealthCheckEntry? healthForUrl(String url) => healthCache[url];

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
          if (task.isTerminal) {
            unawaited(_closeSocket(task.id));
          }
          if (!_disposed) {
            notifyListeners();
          }
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
    final downloadsDir = Directory('${baseDir.path}/m3u8-downloader');
    await downloadsDir.create(recursive: true);
    return downloadsDir.path;
  }

  String _startNativeLocalServer({
    required String downloadsDir,
    String? authPassword,
  }) {
    try {
      return localServer.start(
        downloadsDir: downloadsDir,
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

  bool _shouldUseLocalFfmpeg(ApiException error) {
    return error.message.toLowerCase().contains('ffmpeg not found');
  }
}
