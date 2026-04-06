class LocalServerBridgeException implements Exception {
  LocalServerBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

String bridgeStart({
  required String downloadsDir,
  required int port,
  required String? authPassword,
}) {
  throw LocalServerBridgeException(
    'Local server (FFI) is not available on web. '
    'Web builds should connect to a remote Media Nest server via HTTP/WebSocket API.\n'
    'Use ApiClient instead of LocalServerBridge for web builds.'
  );
}

String? bridgeCurrentBaseUrl() {
  return null;
}

void bridgeStop() {
  throw LocalServerBridgeException(
    'Local server (FFI) is not available on web.'
  );
}
