import 'package:flutter/services.dart';

class BackgroundExecutionBridgeException implements Exception {
  BackgroundExecutionBridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackgroundExecutionBridge {
  BackgroundExecutionBridge._();

  static final BackgroundExecutionBridge instance =
      BackgroundExecutionBridge._();
  static const MethodChannel _channel =
      MethodChannel('iptvgrab/background-control');

  Future<void> setKeepAlive(bool enabled) async {
    try {
      await _channel.invokeMethod<void>(
        'setKeepAlive',
        <String, dynamic>{'enabled': enabled},
      );
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      throw BackgroundExecutionBridgeException(
        error.message ?? 'Failed to toggle background execution.',
      );
    }
  }

  Future<bool> enterPictureInPicture({
    required Uri uri,
    Map<String, String> headers = const <String, String>{},
    Duration? position,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'enterPictureInPicture',
        <String, dynamic>{
          'url': uri.toString(),
          'headers': headers,
          if (position != null) 'positionMillis': position.inMilliseconds,
        },
      );
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      throw BackgroundExecutionBridgeException(
        error.message ?? 'Failed to enter picture-in-picture mode.',
      );
    }
  }
}
