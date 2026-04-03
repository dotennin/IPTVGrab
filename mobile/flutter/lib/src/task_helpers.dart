import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';
import 'theme.dart';
import 'utils.dart';

Color statusColor(String status) {
  switch (status) {
    case 'downloading':
      return appPrimary;
    case 'recording':
      return appDanger;
    case 'stopping':
      return appWarning;
    case 'merging':
      return appWarning;
    case 'completed':
      return appSuccess;
    case 'failed':
      return appDanger;
    case 'cancelled':
    case 'interrupted':
      return Colors.grey;
    case 'paused':
      return appWarning;
    default:
      return Colors.blueGrey;
  }
}

Color taskStatusColor(DownloadTask task, AppController controller) {
  if (controller.isAutoFinalizingTask(task.id)) {
    return appWarning;
  }
  if (controller.treatTaskAsStopped(task)) {
    return Colors.blueGrey;
  }
  if (task.needsLocalMerge) {
    return appWarning;
  }
  return statusColor(task.status);
}

String taskStatusLabel(DownloadTask task, AppController controller) {
  if (controller.isAutoFinalizingTask(task.id)) {
    return 'Saving locally';
  }
  if (controller.treatTaskAsStopped(task)) {
    return 'Stopped';
  }
  if (task.needsLocalMerge) {
    return 'Needs merge';
  }
  if (task.isStopping) {
    return 'Stopping';
  }
  return titleCase(task.status);
}

String? taskErrorMessage(DownloadTask task, AppController controller) {
  final error = task.error?.trim();
  if (controller.isAutoFinalizingTask(task.id)) {
    return null;
  }
  if (error == null || error.isEmpty) {
    return null;
  }
  if (controller.treatTaskAsStopped(task)) {
    return null;
  }
  if (task.needsLocalMerge) {
    return 'FFmpeg is unavailable inside the embedded service. Tap "Finalize locally" to merge on-device and keep the saved media usable.';
  }
  return error;
}

Color healthStatusColor(String? status) {
  switch (status?.toLowerCase()) {
    case 'ok':
      return appSuccess;
    case 'dead':
      return appDanger;
    default:
      return const Color(0xFF64748B);
  }
}
