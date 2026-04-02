import 'dart:convert';
import 'dart:io';

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ApiClient {
  final HttpClient _httpClient = HttpClient();

  String _baseUrl = '';
  String? _sessionCookie;

  String get baseUrl => _baseUrl;
  String? get sessionCookie => _sessionCookie;
  bool get hasSession => _sessionCookie != null && _sessionCookie!.isNotEmpty;

  set baseUrl(String value) {
    _baseUrl = normalizeBaseUrl(value);
  }

  void disconnect() {
    _baseUrl = '';
    _sessionCookie = null;
  }

  void clearSession() {
    _sessionCookie = null;
  }

  Map<String, String> mediaHeaders() {
    if (!hasSession) {
      return const {};
    }
    return <String, String>{HttpHeaders.cookieHeader: _sessionCookie!};
  }

  Future<bool> fetchAuthStatus() async {
    final json =
        await _requestJson('GET', '/api/auth/status') as Map<String, dynamic>;
    return json['auth_required'] == true;
  }

  Future<void> login(String password) async {
    await _requestJson('POST', '/api/login', body: {'password': password});
  }

  Future<void> logout() async {
    await _requestJson('POST', '/api/logout');
    clearSession();
  }

  Future<ParsedStreamInfo> parse({
    required String url,
    Map<String, String>? headers,
  }) async {
    final body = <String, dynamic>{
      'url': url.trim(),
    };
    if (headers != null && headers.isNotEmpty) {
      body['headers'] = headers;
    }
    final json = await _requestJson('POST', '/api/parse', body: body)
        as Map<String, dynamic>;
    return ParsedStreamInfo.fromJson(json);
  }

  Future<String> startDownload({
    required String url,
    required Map<String, String> headers,
    required String quality,
    required int concurrency,
    String? outputName,
  }) async {
    final body = <String, dynamic>{
      'url': url,
      'headers': headers,
      'quality': quality,
      'concurrency': concurrency,
    };
    if (outputName != null && outputName.trim().isNotEmpty) {
      body['output_name'] = outputName.trim();
    }
    final json = await _requestJson('POST', '/api/download', body: body)
        as Map<String, dynamic>;
    return json['task_id']?.toString() ?? '';
  }

  Future<List<DownloadTask>> fetchTasks() async {
    final json = await _requestJson('GET', '/api/tasks');
    if (json is! List) {
      return const [];
    }
    return json
        .whereType<Map>()
        .map((item) => DownloadTask.fromJson(item.cast<String, dynamic>()))
        .toList();
  }

  Future<String> deleteOrStopTask(String taskId) async {
    final json = await _requestJson('DELETE', '/api/tasks/$taskId')
        as Map<String, dynamic>;
    return json['status']?.toString() ?? 'ok';
  }

  Future<void> resumeTask(String taskId) async {
    await _requestJson('POST', '/api/tasks/$taskId/resume');
  }

  Future<void> pauseTask(String taskId) async {
    await _requestJson('POST', '/api/tasks/$taskId/pause');
  }

  Future<void> restartTask(String taskId) async {
    await _requestJson('POST', '/api/tasks/$taskId/restart');
  }

  Future<String> restartRecording(String taskId) async {
    final json =
        await _requestJson('POST', '/api/tasks/$taskId/recording-restart')
            as Map<String, dynamic>;
    return json['new_task_id']?.toString() ?? '';
  }

  Future<String> forkRecording(String taskId) async {
    final json = await _requestJson('POST', '/api/tasks/$taskId/fork')
        as Map<String, dynamic>;
    return json['new_task_id']?.toString() ?? '';
  }

  Future<String> clipTask(String taskId, double start, double end) async {
    final json = await _requestJson(
      'POST',
      '/api/tasks/$taskId/clip',
      body: {'start': start, 'end': end},
    ) as Map<String, dynamic>;
    return json['filename']?.toString() ?? '';
  }

  Future<void> completeLocalMerge(
    String taskId, {
    required String filename,
    required int size,
    double? durationSec,
  }) async {
    final body = <String, dynamic>{
      'filename': filename,
      'size': size,
    };
    if (durationSec != null) {
      body['duration_sec'] = durationSec;
    }
    await _requestJson(
      'POST',
      '/api/tasks/$taskId/local-complete',
      body: body,
    );
  }

  Future<HealthCheckSnapshot> fetchHealthCheck() async {
    final json =
        await _requestJson('GET', '/api/health-check') as Map<String, dynamic>;
    return HealthCheckSnapshot.fromJson(json);
  }

  Future<void> runHealthCheck() async {
    await _requestJson('POST', '/api/health-check');
  }

  Future<List<Playlist>> fetchPlaylists() async {
    final json = await _requestJson('GET', '/api/playlists');
    if (json is! List) {
      return const [];
    }
    return json
        .whereType<Map>()
        .map((item) => Playlist.fromJson(item.cast<String, dynamic>()))
        .toList();
  }

  Future<Playlist> addPlaylist({
    required String name,
    String? url,
    String? raw,
  }) async {
    final body = <String, dynamic>{'name': name};
    if (url != null && url.trim().isNotEmpty) {
      body['url'] = url.trim();
    }
    if (raw != null && raw.trim().isNotEmpty) {
      body['raw'] = raw.trim();
    }
    final json = await _requestJson('POST', '/api/playlists', body: body)
        as Map<String, dynamic>;
    return Playlist.fromJson(json);
  }

  Future<void> deletePlaylist(String playlistId) async {
    await _requestJson('DELETE', '/api/playlists/$playlistId');
  }

  Future<void> editPlaylist(
    String playlistId, {
    required String name,
    String? url,
  }) async {
    final body = <String, dynamic>{'name': name.trim()};
    if (url != null && url.trim().isNotEmpty) {
      body['url'] = url.trim();
    }
    await _requestJson('PATCH', '/api/playlists/$playlistId', body: body);
  }

  Future<void> refreshPlaylist(String playlistId) async {
    await _requestJson('POST', '/api/playlists/$playlistId/refresh');
  }

  Future<MergedPlaylistConfig> fetchMergedPlaylists() async {
    final json =
        await _requestJson('GET', '/api/all-playlists') as Map<String, dynamic>;
    return MergedPlaylistConfig.fromJson(json);
  }

  Future<void> saveMergedPlaylists(MergedPlaylistConfig config) async {
    await _requestJson('PUT', '/api/all-playlists', body: config.toJson());
  }

  Future<void> refreshAllPlaylists() async {
    await _requestJson('POST', '/api/all-playlists/refresh');
  }

  Future<String> fetchMergedExport() async {
    return _requestText('GET', '/api/all-playlists/export.m3u');
  }

  Future<bool> probeBaseUrl(String baseUrl) async {
    final uri =
        Uri.parse(normalizeBaseUrl(baseUrl)).resolve('/api/auth/status');
    try {
      final request =
          await _httpClient.getUrl(uri).timeout(const Duration(seconds: 2));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (hasSession) {
        request.headers.set(HttpHeaders.cookieHeader, _sessionCookie!);
      }
      final response =
          await request.close().timeout(const Duration(seconds: 2));
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } on Exception {
      return false;
    }
  }

  Future<WebSocket> connectTaskSocket(String taskId) {
    final uri = taskWebSocketUri(taskId);
    final headers = <String, dynamic>{};
    if (hasSession) {
      headers[HttpHeaders.cookieHeader] = _sessionCookie!;
    }
    return WebSocket.connect(uri.toString(), headers: headers);
  }

  Uri taskWebSocketUri(String taskId) {
    _ensureBaseUrl();
    final base = Uri.parse(_baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws/tasks/$taskId',
      queryParameters: null,
      fragment: null,
    );
  }

  Uri previewUri(String taskId) => _buildUri('/api/tasks/$taskId/preview.m3u8');

  Uri downloadUri(String filename) =>
      _buildUri('/downloads/${Uri.encodeComponent(filename)}');

  Uri watchProxyUri(String streamUrl) => _buildUri(
        '/api/watch/proxy',
        queryParameters: {'url': streamUrl},
      );

  Uri mergedExportUri() => _buildUri('/api/all-playlists/export.m3u');

  Future<dynamic> _requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
  }) async {
    _ensureBaseUrl();
    final uri = _buildUri(path, queryParameters: queryParameters);
    final request = await _httpClient.openUrl(method, uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
    }
    if (hasSession) {
      request.headers.set(HttpHeaders.cookieHeader, _sessionCookie!);
    }
    if (body != null) {
      request.write(jsonEncode(body));
    }

    final response = await request.close();
    _captureSessionCookie(response);
    final text = await response.transform(utf8.decoder).join();
    final payload = text.isEmpty ? null : jsonDecode(text);
    if (response.statusCode >= 400) {
      throw ApiException(_extractMessage(payload) ?? 'Request failed',
          statusCode: response.statusCode);
    }
    return payload;
  }

  Future<String> _requestText(
    String method,
    String path, {
    Map<String, String>? queryParameters,
  }) async {
    _ensureBaseUrl();
    final uri = _buildUri(path, queryParameters: queryParameters);
    final request = await _httpClient.openUrl(method, uri);
    request.headers.set(HttpHeaders.acceptHeader, 'text/plain');
    if (hasSession) {
      request.headers.set(HttpHeaders.cookieHeader, _sessionCookie!);
    }

    final response = await request.close();
    _captureSessionCookie(response);
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode >= 400) {
      throw ApiException(text.isEmpty ? 'Request failed' : text,
          statusCode: response.statusCode);
    }
    return text;
  }

  Uri _buildUri(
    String path, {
    Map<String, String>? queryParameters,
  }) {
    final filteredQuery = <String, String>{};
    queryParameters?.forEach((key, value) {
      if (value.isNotEmpty) {
        filteredQuery[key] = value;
      }
    });
    final resolved = Uri.parse(_baseUrl).resolve(path);
    return filteredQuery.isEmpty
        ? resolved
        : resolved.replace(queryParameters: filteredQuery);
  }

  void _captureSessionCookie(HttpClientResponse response) {
    final cookies = response.headers[HttpHeaders.setCookieHeader];
    if (cookies == null) {
      return;
    }
    for (final cookie in cookies) {
      final firstPart = cookie.split(';').first.trim();
      if (!firstPart.startsWith('session=')) {
        continue;
      }
      final token = firstPart.substring('session='.length);
      if (token.isEmpty) {
        _sessionCookie = null;
      } else {
        _sessionCookie = firstPart;
      }
    }
  }

  void _ensureBaseUrl() {
    if (_baseUrl.isEmpty) {
      throw ApiException('Please connect to a server first.');
    }
  }

  String? _extractMessage(dynamic payload) {
    if (payload is Map<String, dynamic>) {
      final detail = payload['detail'];
      if (detail != null) {
        return detail.toString();
      }
      final status = payload['status'];
      if (status != null) {
        return status.toString();
      }
    }
    return null;
  }
}

String normalizeBaseUrl(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ApiException('Server URL is required.');
  }
  final withScheme =
      trimmed.startsWith('http://') || trimmed.startsWith('https://')
          ? trimmed
          : 'http://$trimmed';
  final uri = Uri.parse(withScheme);
  if (uri.host.isEmpty) {
    throw ApiException('Please enter a valid server URL.');
  }
  final path = uri.path == '/' ? '' : uri.path.replaceFirst(RegExp(r'/$'), '');
  return uri
      .replace(path: path, queryParameters: null, fragment: null)
      .toString();
}
