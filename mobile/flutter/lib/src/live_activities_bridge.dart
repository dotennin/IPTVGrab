import 'dart:io';

import 'package:flutter/services.dart';

/// Drives iOS Live Activities (lock screen + Dynamic Island) for active
/// downloads. No-op on Android and when running below iOS 16.2.
class LiveActivitiesBridge {
  LiveActivitiesBridge._();

  static final LiveActivitiesBridge instance = LiveActivitiesBridge._();

  static const _channel = MethodChannel('iptvgrab/live-activities');

  bool get isSupported => Platform.isIOS;

  Future<void> startActivity({
    required String taskId,
    required String taskName,
    required bool isRecording,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('startLiveActivity', {
        'taskId': taskId,
        'taskName': taskName,
        'isRecording': isRecording,
      });
    } on PlatformException catch (e) {
      if (e.code != 'unsupported') {
        _log('startActivity $taskId: ${e.message}');
      }
    } on MissingPluginException {
      // Channel not yet registered (app still launching) — silently ignore.
    } catch (e) {
      _log('startActivity $taskId unexpected: $e');
    }
  }

  Future<void> updateActivity({
    required String taskId,
    required double progress,
    required double speedMbps,
    required int done,
    required int total,
    required String status,
    required int elapsedSec,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('updateLiveActivity', {
        'taskId': taskId,
        'progress': progress,
        'speedMbps': speedMbps,
        'done': done,
        'total': total,
        'status': status,
        'elapsedSec': elapsedSec,
      });
    } on PlatformException catch (e) {
      if (e.code != 'unsupported') {
        _log('updateActivity $taskId: ${e.message}');
      }
    } on MissingPluginException {
      // Channel not yet registered — silently ignore.
    } catch (e) {
      _log('updateActivity $taskId unexpected: $e');
    }
  }

  Future<void> endActivity(String taskId) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('endLiveActivity', {
        'taskId': taskId,
      });
    } on PlatformException catch (e) {
      if (e.code != 'unsupported') {
        _log('endActivity $taskId: ${e.message}');
      }
    } on MissingPluginException {
      // Channel not yet registered — silently ignore.
    } catch (e) {
      _log('endActivity $taskId unexpected: $e');
    }
  }

  void _log(String msg) {
    // ignore: avoid_print
    print('[LiveActivities] $msg');
  }
}
