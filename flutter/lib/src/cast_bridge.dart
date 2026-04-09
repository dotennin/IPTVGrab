import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform bridge for AirPlay (iOS) and Chromecast (Android) casting.
///
/// iOS  → triggers the system AVRoutePickerView (AirPlay / Bluetooth).
/// Android → opens the Google Cast device-chooser dialog (Chromecast).
class CastBridge {
  static const _channel = MethodChannel('medianest/cast');

  static CastBridge? _instance;
  static CastBridge get instance => _instance ??= CastBridge._();
  CastBridge._() {
    // Receive events pushed by native (e.g. AVPlayerVC dismissed by user).
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCastPlayerDismissed') {
        final cb = _onDismissed;
        _onDismissed = null;
        cb?.call();
      }
    });
  }

  /// Whether the current platform supports casting at all.
  bool get isCastSupported => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  // In-memory flag set when a cast session is started and cleared when stopped.
  // Used synchronously in initState so the new page can skip VLC init without
  // needing an async native call.
  static bool _activelyCasting = false;
  static String? _castingUrl;

  /// True when a cast session is active (player has been handed to AirPlay /
  /// Chromecast).  Persists across MediaPlayerPage navigations within the same
  /// app session.
  static bool get isActivelyCasting => _activelyCasting;

  /// The URL currently being cast, or null when no session is active.
  static String? get castingUrl => _castingUrl;

  /// Called when the user dismisses the native AVPlayerViewController that was
  /// presented via [showCastPlayerVC].  Set once per navigation; cleared after
  /// it fires or when the page is disposed.
  static VoidCallback? _onDismissed;

  /// Registers a one-shot callback invoked when the native cast player VC is
  /// dismissed.  Pass null to cancel a previously registered callback.
  static void setOnCastPlayerDismissed(VoidCallback? cb) => _onDismissed = cb;

  /// Presents a fullscreen native AVPlayerViewController for the given [url]
  /// using the platform's built-in player (AVPlayer on iOS, ExoPlayer on
  /// Android).  Unlike [showCastPicker], the AirPlay/Cast route-picker sheet
  /// is NOT opened automatically — this is a plain local-playback presentation.
  Future<void> showNativePlayer({
    required String url,
    String title = '',
    Map<String, String> headers = const {},
    bool isLive = false,
  }) async {
    if (!isCastSupported) return;
    _activelyCasting = true;
    _castingUrl = url;
    try {
      await _channel.invokeMethod<void>('showNativePlayer', {
        'url': url,
        'title': title,
        'headers': headers,
        'isLive': isLive,
      });
    } catch (_) {
      _activelyCasting = false;
      _castingUrl = null;
      rethrow;
    }
  }

  /// Shows the platform-native cast picker for [url] and marks the session as
  /// active.  On iOS this presents a fullscreen AVPlayerViewController that
  /// immediately opens the AirPlay route sheet.
  Future<void> showCastPicker({
    required String url,
    String title = '',
    Map<String, String> headers = const {},
    bool isLive = false,
  }) async {
    if (!isCastSupported) return;
    // Mark active optimistically so the next page skips VLC immediately.
    _activelyCasting = true;
    _castingUrl = url;
    try {
      await _channel.invokeMethod<void>('showCastPicker', {
        'url': url,
        'title': title,
        'headers': headers,
        'isLive': isLive,
      });
    } catch (_) {
      _activelyCasting = false;
      _castingUrl = null;
      rethrow;
    }
  }

  /// Replaces the cast content with a new stream without interrupting the
  /// active AirPlay / Chromecast route.  Called when the user navigates to a
  /// new channel while a cast session is already running.
  Future<void> switchCastMedia({
    required String url,
    String title = '',
    Map<String, String> headers = const {},
    bool isLive = false,
  }) async {
    if (!isCastSupported) return;
    _castingUrl = url;
    await _channel.invokeMethod<void>('switchCastMedia', {
      'url': url,
      'title': title,
      'headers': headers,
      'isLive': isLive,
    });
  }

  /// Stops the active cast session and clears the in-memory flag so the next
  /// page initialises VLC normally.
  Future<void> stopCast() async {
    _activelyCasting = false;
    _castingUrl = null;
    if (!isCastSupported) return;
    await _channel.invokeMethod<void>('stopCast');
  }

  /// Shows the system AirPlay / Cast device-picker sheet while a cast session
  /// is already running so the user can switch or disconnect devices.
  Future<void> showRoutePicker() async {
    if (!isCastSupported) return;
    await _channel.invokeMethod<void>('showRoutePicker');
  }

  /// Presents a fullscreen native AVPlayerViewController backed by the
  /// existing cast [AVPlayer].  The user gets full seek / subtitle controls.
  /// When they tap "Done" the native side fires [onCastPlayerDismissed].
  Future<void> showCastPlayerVC() async {
    if (!isCastSupported) return;
    await _channel.invokeMethod<void>('showCastPlayerVC');
  }
}
