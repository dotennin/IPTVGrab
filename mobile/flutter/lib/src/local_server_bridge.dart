import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

class LocalServerBridgeException implements Exception {
  LocalServerBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalServerBridge {
  LocalServerBridge._();

  static final LocalServerBridge instance = LocalServerBridge._();

  late final ffi.DynamicLibrary _library = _openLibrary();
  late final _startServer = _lookupStartServer();
  late final _serverStatus = _lookupServerStatus();
  late final _stopServer = _lookupStopServer();
  late final _freeString = _lookupFreeString();

  String start({
    required String downloadsDir,
    int port = 0,
    String? authPassword,
  }) {
    final downloadsDirPtr = downloadsDir.toNativeUtf8();
    final passwordPtr = (authPassword == null || authPassword.isEmpty)
        ? ffi.nullptr.cast<Utf8>()
        : authPassword.toNativeUtf8();
    try {
      final payload = _decodePayload(_takeString(_startServer(port, downloadsDirPtr, passwordPtr)));
      if (payload['ok'] != true) {
        throw LocalServerBridgeException(payload['error']?.toString() ?? 'Failed to start local server.');
      }
      final baseUrl = payload['base_url']?.toString();
      if (baseUrl == null || baseUrl.isEmpty) {
        throw LocalServerBridgeException('Rust local server did not return a base URL.');
      }
      return baseUrl;
    } finally {
      malloc.free(downloadsDirPtr);
      if (passwordPtr != ffi.nullptr.cast<Utf8>()) {
        malloc.free(passwordPtr);
      }
    }
  }

  String? currentBaseUrl() {
    final payload = _decodePayload(_takeString(_serverStatus()));
    if (payload['running'] == true) {
      final baseUrl = payload['base_url']?.toString();
      if (baseUrl != null && baseUrl.isNotEmpty) {
        return baseUrl;
      }
    }
    return null;
  }

  void stop() {
    final payload = _decodePayload(_takeString(_stopServer()));
    if (payload['ok'] != true) {
      throw LocalServerBridgeException(payload['error']?.toString() ?? 'Failed to stop local server.');
    }
  }

  ffi.DynamicLibrary _openLibrary() {
    try {
      if (Platform.isAndroid) {
        return ffi.DynamicLibrary.open('libmobile_ffi.so');
      }
      return ffi.DynamicLibrary.process();
    } on Object catch (error) {
      throw LocalServerBridgeException('Failed to load native mobile_ffi library: $error');
    }
  }

  ffi.Pointer<Utf8> Function(int, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>) _lookupStartServer() {
    final symbol = _nativeSymbol('m3u8_local_server_start');
    try {
      return _library.lookupFunction<
          ffi.Pointer<Utf8> Function(ffi.Uint16, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>),
          ffi.Pointer<Utf8> Function(int, ffi.Pointer<Utf8>, ffi.Pointer<Utf8>)>(symbol);
    } on Object catch (error) {
      throw _symbolLookupError('m3u8_local_server_start', error);
    }
  }

  ffi.Pointer<Utf8> Function() _lookupServerStatus() {
    final symbol = _nativeSymbol('m3u8_local_server_status');
    try {
      return _library.lookupFunction<ffi.Pointer<Utf8> Function(), ffi.Pointer<Utf8> Function()>(symbol);
    } on Object catch (error) {
      throw _symbolLookupError('m3u8_local_server_status', error);
    }
  }

  ffi.Pointer<Utf8> Function() _lookupStopServer() {
    final symbol = _nativeSymbol('m3u8_local_server_stop');
    try {
      return _library.lookupFunction<ffi.Pointer<Utf8> Function(), ffi.Pointer<Utf8> Function()>(symbol);
    } on Object catch (error) {
      throw _symbolLookupError('m3u8_local_server_stop', error);
    }
  }

  void Function(ffi.Pointer<Utf8>) _lookupFreeString() {
    final symbol = _nativeSymbol('m3u8_string_free');
    try {
      return _library.lookupFunction<ffi.Void Function(ffi.Pointer<Utf8>), void Function(ffi.Pointer<Utf8>)>(symbol);
    } on Object catch (error) {
      throw _symbolLookupError('m3u8_string_free', error);
    }
  }

  String _nativeSymbol(String symbol) {
    if (!Platform.isIOS) {
      return symbol;
    }
    return switch (symbol) {
      'm3u8_local_server_start' => 'm3u8_flutter_local_server_start',
      'm3u8_local_server_status' => 'm3u8_flutter_local_server_status',
      'm3u8_local_server_stop' => 'm3u8_flutter_local_server_stop',
      'm3u8_string_free' => 'm3u8_flutter_string_free',
      _ => symbol,
    };
  }

  LocalServerBridgeException _symbolLookupError(String symbol, Object error) {
    final platformHint = Platform.isIOS
        ? 'Run `make flutter-rust-ios`, then fully rebuild and reinstall the iOS app so Runner includes the native bridge symbols.'
        : 'Rebuild the mobile app so the Rust native library is bundled correctly.';
    return LocalServerBridgeException('Failed to lookup native symbol `$symbol`: $error\n$platformHint');
  }

  String _takeString(ffi.Pointer<Utf8> ptr) {
    try {
      return ptr.toDartString();
    } finally {
      _freeString(ptr);
    }
  }

  Map<String, dynamic> _decodePayload(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw LocalServerBridgeException('Unexpected local server payload: $raw');
    }
    return decoded;
  }
}
