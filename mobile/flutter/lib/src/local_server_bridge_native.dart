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

late final ffi.DynamicLibrary _library = _openLibrary();
late final _startServer = _lookupStartServer();
late final _serverStatus = _lookupServerStatus();
late final _stopServer = _lookupStopServer();
late final _freeString = _lookupFreeString();

String bridgeStart({
  required String downloadsDir,
  required int port,
  required String? authPassword,
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

String? bridgeCurrentBaseUrl() {
  final payload = _decodePayload(_takeString(_serverStatus()));
  if (payload['running'] == true) {
    final baseUrl = payload['base_url']?.toString();
    if (baseUrl != null && baseUrl.isNotEmpty) {
      return baseUrl;
    }
  }
  return null;
}

void bridgeStop() {
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
    if (Platform.isMacOS) {
      // Try different possible locations for the dylib
      // Note: On macOS, DynamicLibrary.open() uses different search paths than standard dyld
      final candidates = [
        // System library path (recommended for development)
        '/usr/local/lib/libmobile_ffi.dylib',
        // Absolute path to development build
        '/Users/dotennin-mac14/projects/m3u8-downloader-rs/target/aarch64-apple-darwin/release/libmobile_ffi.dylib',
        // Embedded in app bundle Frameworks (for release builds)
        'libmobile_ffi.dylib',
      ];
      
      List<String> errors = [];
      for (final candidate in candidates) {
        try {
          final lib = ffi.DynamicLibrary.open(candidate);
          // Successfully loaded - return immediately
          return lib;
        } catch (e) {
          errors.add('$candidate: $e');
          continue;
        }
      }
      
      // If all candidates failed, provide detailed error
      String errorDetails = errors.map((e) => '  • $e').join('\n');
      throw LocalServerBridgeException(
        'Failed to load libmobile_ffi.dylib from any known location:\n$errorDetails\n\n'
        'Solutions:\n'
        '1. Run `make flutter-run-macos` to build and install\n'
        '2. Verify /usr/local/lib/libmobile_ffi.dylib exists: ls -la /usr/local/lib/libmobile_ffi.dylib\n'
        '3. Check codesign: codesign -vvv /usr/local/lib/libmobile_ffi.dylib\n'
      );
    }
    // iOS: handled by MobileFfiForceLink() - use DynamicLibrary.process()
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
