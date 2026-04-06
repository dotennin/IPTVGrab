import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

import 'api_client.dart';
import 'models.dart';

class LocalMergeResult {
  LocalMergeResult({
    required this.filename,
    required this.size,
    this.durationSec,
  });

  final String filename;
  final int size;
  final double? durationSec;
}

class MobileFfmpeg {
  Future<LocalMergeResult> mergeTask({
    required DownloadTask task,
    required String downloadsDir,
  }) async {
    final tmpdir = _requireTmpdir(task);
    final outputName = _resolveOutputFilename(task);
    final outputFile = File('$downloadsDir/$outputName');

    if (task.isCmaf == true) {
      await _mergeCmaf(task: task, tmpdir: tmpdir, outputFile: outputFile);
    } else {
      await _mergeTs(task: task, tmpdir: tmpdir, outputFile: outputFile);
    }

    return LocalMergeResult(
      filename: outputName,
      size: await outputFile.length(),
      durationSec: _estimatedDuration(task),
    );
  }

  Future<String> clipTask({
    required DownloadTask task,
    required String downloadsDir,
    required double start,
    required double end,
  }) async {
    if (start < 0 || end <= start || (end - start) < 0.5) {
      throw ApiException('Invalid clip range (end must be ≥ start + 0.5 s).');
    }

    final suffix = '${_formatStamp(start)}-${_formatStamp(end)}';
    final stem = _clipStem(task);
    final clipName = '${stem}_clip_$suffix.mp4';
    final clipFile = File('$downloadsDir/$clipName');
    final duration = end - start;

    final completedFile =
        task.output == null ? null : File('$downloadsDir/${task.output!}');
    if (completedFile != null && await completedFile.exists()) {
      await _runFfmpeg(<String>[
        '-y',
        '-ss',
        start.toString(),
        '-i',
        completedFile.path,
        '-t',
        duration.toString(),
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        clipFile.path,
      ]);
      return clipName;
    }

    final tmpdir = _requireTmpdir(task);
    if (task.isCmaf == true) {
      final rawVideo = File('${tmpdir.path}/clip_raw.mp4');
      try {
        await _concatBinarySequence(
          initFile: File('${tmpdir.path}/init.mp4'),
          segmentFiles: await _segmentFiles(tmpdir, task.segExt ?? '.m4s'),
          outputFile: rawVideo,
        );
        await _runFfmpeg(<String>[
          '-y',
          '-ss',
          start.toString(),
          '-i',
          rawVideo.path,
          '-t',
          duration.toString(),
          '-c',
          'copy',
          '-movflags',
          '+faststart',
          clipFile.path,
        ]);
      } finally {
        if (await rawVideo.exists()) {
          await rawVideo.delete();
        }
      }
      return clipName;
    }

    final listFile = File('${tmpdir.path}/clip_concat.txt');
    await _writeConcatList(
      listFile,
      await _segmentFiles(tmpdir, '.ts'),
    );
    try {
      await _runFfmpeg(<String>[
        '-y',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        listFile.path,
        '-ss',
        start.toString(),
        '-t',
        duration.toString(),
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        clipFile.path,
      ]);
      return clipName;
    } finally {
      if (await listFile.exists()) {
        await listFile.delete();
      }
    }
  }

  Future<void> _mergeTs({
    required DownloadTask task,
    required Directory tmpdir,
    required File outputFile,
  }) async {
    final listFile = File('${tmpdir.path}/concat.txt');
    await _writeConcatList(
      listFile,
      await _segmentFiles(tmpdir, '.ts'),
    );
    try {
      await _runFfmpeg(<String>[
        '-y',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        listFile.path,
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        outputFile.path,
      ]);
    } finally {
      if (await listFile.exists()) {
        await listFile.delete();
      }
    }
  }

  Future<void> _mergeCmaf({
    required DownloadTask task,
    required Directory tmpdir,
    required File outputFile,
  }) async {
    final segExt = task.segExt ?? '.m4s';
    final rawVideo = File('${tmpdir.path}/merged_raw.mp4');
    final audioDir = Directory('${tmpdir.path}/audio');
    final hasAudio = await audioDir.exists();
    final rawAudio = File('${audioDir.path}/merged_audio.mp4');

    try {
      await _concatBinarySequence(
        initFile: File('${tmpdir.path}/init.mp4'),
        segmentFiles: await _segmentFiles(tmpdir, segExt),
        outputFile: rawVideo,
      );

      if (hasAudio) {
        await _concatBinarySequence(
          initFile: File('${audioDir.path}/init.mp4'),
          segmentFiles: await _segmentFiles(audioDir, segExt),
          outputFile: rawAudio,
        );
      }

      final args = <String>[
        '-y',
        '-i',
        rawVideo.path,
      ];
      if (hasAudio && await rawAudio.exists()) {
        args
          ..addAll(<String>['-i', rawAudio.path])
          ..addAll(<String>['-map', '0:v', '-map', '1:a']);
      }
      args
        ..addAll(<String>['-c', 'copy', '-movflags', '+faststart'])
        ..add(outputFile.path);
      await _runFfmpeg(args);
    } finally {
      if (await rawVideo.exists()) {
        await rawVideo.delete();
      }
      if (await rawAudio.exists()) {
        await rawAudio.delete();
      }
    }
  }

  Future<void> _concatBinarySequence({
    required File initFile,
    required List<FileSystemEntity> segmentFiles,
    required File outputFile,
  }) async {
    if (!await initFile.exists()) {
      throw ApiException('Missing init segment: ${initFile.path}');
    }
    if (segmentFiles.isEmpty) {
      throw ApiException('No segments available yet.');
    }

    final sink = outputFile.openWrite();
    try {
      sink.add(await initFile.readAsBytes());
      for (final entity in segmentFiles) {
        final file = File(entity.path);
        sink.add(await file.readAsBytes());
      }
    } finally {
      await sink.close();
    }
  }

  Future<void> _writeConcatList(
      File listFile, List<FileSystemEntity> segmentFiles) async {
    if (segmentFiles.isEmpty) {
      throw ApiException('No segments available yet.');
    }
    final buffer = StringBuffer();
    for (final entity in segmentFiles) {
      final file = File(entity.path);
      final escapedPath = file.absolute.path.replaceAll("'", r"'\''");
      buffer.writeln("file '$escapedPath'");
    }
    await listFile.writeAsString(buffer.toString());
  }

  Future<List<FileSystemEntity>> _segmentFiles(
      Directory dir, String ext) async {
    final normalized = ext.startsWith('.') ? ext.substring(1) : ext;
    final entities = await dir
        .list()
        .where(
            (entity) => entity is File && entity.path.endsWith('.$normalized'))
        .toList();
    entities.sort((left, right) => left.path.compareTo(right.path));
    return entities;
  }

  Future<void> _runFfmpeg(List<String> args) async {
    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();
    if (ReturnCode.isSuccess(returnCode)) {
      return;
    }

    final output = (await session.getOutput())?.trim();
    final failStack = (await session.getFailStackTrace())?.trim();
    final detail = <String>[
      if (output != null && output.isNotEmpty) output.split('\n').last,
      if (failStack != null && failStack.isNotEmpty) failStack,
      if (returnCode != null) 'ffmpeg return code: ${returnCode.getValue()}',
    ].join(' | ');
    throw ApiException(detail.isEmpty
        ? 'FFmpegKit command failed.'
        : 'FFmpegKit command failed: $detail');
  }

  Directory _requireTmpdir(DownloadTask task) {
    final raw = task.tmpdir;
    if (raw == null || raw.isEmpty) {
      throw ApiException(
          'This task does not have a temporary segment directory available.');
    }
    final dir = Directory(raw);
    if (!dir.existsSync()) {
      throw ApiException('Segment directory no longer exists: $raw');
    }
    return dir;
  }

  String _resolveOutputFilename(DownloadTask task) {
    final prefixLen = task.id.length < 8 ? task.id.length : 8;
    final candidate =
        task.output ?? task.outputName ?? task.id.substring(0, prefixLen);
    return candidate.endsWith('.mp4') ? candidate : '$candidate.mp4';
  }

  String _clipStem(DownloadTask task) {
    final prefixLen = task.id.length < 8 ? task.id.length : 8;
    final base = task.output != null
        ? task.output!.replaceFirst(RegExp(r'\.mp4$'), '')
        : (task.outputName ?? task.id.substring(0, prefixLen))
            .replaceFirst(RegExp(r'\.mp4$'), '');
    return base;
  }

  double? _estimatedDuration(DownloadTask task) {
    if (task.durationSec != null && task.durationSec! > 0) {
      return task.durationSec;
    }
    final segments = task.total > 0 ? task.total : task.recordedSegments;
    if (segments <= 0 ||
        task.targetDuration == null ||
        task.targetDuration! <= 0) {
      return null;
    }
    return segments * task.targetDuration!;
  }

  String _formatStamp(double secs) {
    final total = secs.floor();
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}h${minutes.toString().padLeft(2, '0')}m${seconds.toString().padLeft(2, '0')}s';
    }
    return '${minutes.toString().padLeft(2, '0')}m${seconds.toString().padLeft(2, '0')}s';
  }
}
