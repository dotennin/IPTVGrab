import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class NativeIosPlayerException implements Exception {
  NativeIosPlayerException(this.message, {this.details = const <String>[]});

  final String message;
  final List<String> details;

  @override
  String toString() => message;
}

class NativeIosPlayerController extends ChangeNotifier {
  NativeIosPlayerController({
    required this.uri,
    required this.httpHeaders,
    required this.isLive,
    this.muted = false,
  });

  final Uri uri;
  final Map<String, String> httpHeaders;
  final bool isLive;
  final bool muted;

  MethodChannel? _methodChannel;
  EventChannel? _eventChannel;
  StreamSubscription<dynamic>? _eventSubscription;
  bool _disposed = false;
  bool _attached = false;

  bool initialized = false;
  bool isPlaying = false;
  bool isBuffering = true;
  bool isPictureInPictureSupported = false;
  bool isPictureInPicturePossible = false;
  bool isPictureInPictureActive = false;
  double aspectRatio = 16 / 9;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  String? error;
  List<String> diagnostics = const <String>[];

  Map<String, dynamic> get creationParams => <String, dynamic>{
        'url': uri.toString(),
        'headers': httpHeaders,
        'isLive': isLive,
        'muted': muted,
      };

  void attach(int viewId) {
    if (_disposed || _attached) {
      return;
    }
    _attached = true;
    _methodChannel = MethodChannel('iptvgrab/native-player/$viewId/method');
    _eventChannel = EventChannel('iptvgrab/native-player/$viewId/events');
    _eventSubscription = _eventChannel!
        .receiveBroadcastStream()
        .listen(_handleEvent, onError: _handleStreamError);
  }

  Future<void> play() => _invoke<void>('play');

  Future<void> pause() => _invoke<void>('pause');

  Future<void> seekTo(Duration target) => _invoke<void>(
        'seekToMillis',
        <String, dynamic>{'positionMillis': target.inMilliseconds},
      );

  Future<void> setMuted(bool value) => _invoke<void>(
        'setMuted',
        <String, dynamic>{'muted': value},
      );

  Future<void> setPreferredBitRate(int bandwidth) => _invoke<void>(
        'setPreferredBitRate',
        <String, dynamic>{'bandwidth': bandwidth.toDouble()},
      );

  Future<bool> enterPictureInPicture() async =>
      (await _invoke<bool>('enterPictureInPicture')) ?? false;

  Future<void> disposePlayer() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final channel = _methodChannel;
    _methodChannel = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    if (channel != null) {
      try {
        await channel.invokeMethod<void>('dispose');
      } on PlatformException {
        // Ignore native teardown failures when the widget tree is already closing.
      }
    }
  }

  @override
  void dispose() {
    unawaited(disposePlayer());
    super.dispose();
  }

  Future<T?> _invoke<T>(
    String method, [
    Map<String, dynamic> arguments = const <String, dynamic>{},
  ]) async {
    final channel = _methodChannel;
    if (channel == null) {
      throw NativeIosPlayerException(
        'The native iOS player has not attached to its platform view yet.',
      );
    }
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw _toException(error);
    }
  }

  NativeIosPlayerException _toException(PlatformException error) {
    final details = <String>[];
    final rawDetails = error.details;
    if (rawDetails is List) {
      for (final item in rawDetails) {
        if (item != null) {
          details.add(item.toString());
        }
      }
    } else if (rawDetails is Map) {
      for (final entry in rawDetails.entries) {
        details.add('${entry.key}: ${entry.value}');
      }
    } else if (rawDetails != null) {
      details.add(rawDetails.toString());
    }
    return NativeIosPlayerException(
      error.message ?? 'The native iOS player operation failed.',
      details: details,
    );
  }

  void _handleEvent(dynamic rawEvent) {
    if (_disposed || rawEvent is! Map) {
      return;
    }
    final event = rawEvent.cast<Object?, Object?>();
    if (event['type'] != 'state') {
      return;
    }
    initialized = event['initialized'] == true;
    isPlaying = event['isPlaying'] == true;
    isBuffering = event['isBuffering'] == true;
    isPictureInPictureSupported = event['isPictureInPictureSupported'] == true;
    isPictureInPicturePossible = event['isPictureInPicturePossible'] == true;
    isPictureInPictureActive = event['isPictureInPictureActive'] == true;
    aspectRatio = (event['aspectRatio'] as num?)?.toDouble() ?? 16 / 9;
    position = Duration(
      milliseconds: (event['positionMillis'] as num?)?.round() ?? 0,
    );
    duration = Duration(
      milliseconds: (event['durationMillis'] as num?)?.round() ?? 0,
    );
    error = event['error'] as String?;
    diagnostics = (event['diagnostics'] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => item.toString())
        .toList(growable: false);
    notifyListeners();
  }

  void _handleStreamError(Object error, StackTrace stackTrace) {
    this.error = error.toString();
    notifyListeners();
  }
}

class NativeIosPlayerView extends StatelessWidget {
  const NativeIosPlayerView({
    super.key,
    required this.controller,
  });

  final NativeIosPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return UiKitView(
      viewType: 'iptvgrab/native-inline-player',
      creationParams: controller.creationParams,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: controller.attach,
    );
  }
}
