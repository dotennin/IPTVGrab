import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String formatBytes(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  double size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return unit == 0
      ? '${size.round()} ${units[unit]}'
      : '${size.toStringAsFixed(1)} ${units[unit]}';
}

String formatSeconds(double seconds) {
  if (seconds <= 0) {
    return '0s';
  }
  final whole = seconds.round();
  return formatClock(whole);
}

String formatClock(int seconds) {
  final duration = Duration(seconds: seconds);
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final secs = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours}h ${minutes}m ${secs}s';
  }
  if (minutes > 0) {
    return '${minutes}m ${secs}s';
  }
  return '${secs}s';
}

String formatDurationLabel(Duration? duration) {
  if (duration == null || duration.inMilliseconds <= 0) {
    return '0:00';
  }
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String shortId(String value) {
  if (value.length <= 8) {
    return value;
  }
  return value.substring(0, 8);
}

String titleCase(String value) {
  if (value.isEmpty) {
    return value;
  }
  return value[0].toUpperCase() + value.substring(1);
}

List<String> dedupeMessages(Iterable<String> messages) {
  final seen = <String>{};
  final deduped = <String>[];
  for (final message in messages) {
    final normalized = message.trim();
    if (normalized.isEmpty || !seen.add(normalized)) {
      continue;
    }
    deduped.add(normalized);
  }
  return deduped;
}

Map<String, String> parseHeadersText(String text) {
  final headers = <String, String>{};
  final lines = text.split('\n');
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      continue;
    }
    if (line.startsWith('GET ') ||
        line.startsWith('POST ') ||
        line.startsWith('HEAD ')) {
      continue;
    }
    final separator = line.contains(':') ? ':' : '=';
    final index = line.indexOf(separator);
    if (index <= 0) {
      continue;
    }
    final name = line.substring(0, index).trim();
    final value = line.substring(index + 1).trim();
    if (name.isEmpty || value.isEmpty) {
      continue;
    }
    headers[name] = value;
  }
  return headers;
}

String randomEditorId(String prefix) {
  return '${prefix}_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}

void showMessage(
  BuildContext context,
  String message, {
  bool error = false,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ),
  );
}

Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  required String label,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) {
    return;
  }
  showMessage(context, label);
}
