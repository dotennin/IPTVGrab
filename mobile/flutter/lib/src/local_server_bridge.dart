import 'local_server_bridge_native.dart'
    if (dart.library.html) 'local_server_bridge_web.dart' as bridge_impl;

class LocalServerBridgeException implements Exception {
  LocalServerBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalServerBridge {
  LocalServerBridge._();

  static final LocalServerBridge instance = LocalServerBridge._();

  String start({
    required String downloadsDir,
    int port = 0,
    String? authPassword,
  }) {
    return bridge_impl.bridgeStart(downloadsDir: downloadsDir, port: port, authPassword: authPassword);
  }

  String? currentBaseUrl() {
    return bridge_impl.bridgeCurrentBaseUrl();
  }

  void stop() {
    bridge_impl.bridgeStop();
  }
}
