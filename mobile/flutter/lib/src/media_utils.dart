import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import 'api_client.dart';
import 'controller.dart';
import 'utils.dart';

File localMediaFile(AppController controller, String filename) {
  final path = localMediaPathOrNull(controller, filename);
  if (path == null) {
    throw ApiException('Local downloads directory is not ready yet.');
  }
  return File(path);
}

String? localMediaPathOrNull(AppController controller, String filename) {
  final downloadsDir = controller.localDownloadsDir;
  if (downloadsDir == null || downloadsDir.isEmpty) {
    return null;
  }
  return '$downloadsDir/$filename';
}

Future<void> shareLocalMediaFromController(
  BuildContext context,
  AppController controller,
  String filename,
) async {
  try {
    await shareLocalMediaFile(
      context,
      localMediaFile(controller, filename),
      filename: filename,
    );
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    showMessage(context, error.message, error: true);
  }
}

Future<void> saveLocalMediaToPhotosFromController(
  BuildContext context,
  AppController controller,
  String filename,
) async {
  try {
    await saveLocalMediaToPhotos(
      context,
      localMediaFile(controller, filename),
      filename: filename,
    );
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    showMessage(context, error.message, error: true);
  }
}

Rect? shareOriginForContext(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox) {
    return null;
  }
  final origin = renderObject.localToGlobal(Offset.zero);
  return origin & renderObject.size;
}

Future<void> shareLocalMediaFile(
  BuildContext context,
  File file, {
  required String filename,
}) async {
  try {
    if (!await file.exists()) {
      throw ApiException('Local media file not found: $filename');
    }
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[
          XFile(
            file.path,
            mimeType: 'video/mp4',
            name: filename,
          ),
        ],
        title: filename,
        subject: filename,
        text: filename,
        sharePositionOrigin: shareOriginForContext(context),
      ),
    );
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    showMessage(context, error.message, error: true);
  } on Exception catch (error) {
    if (!context.mounted) {
      return;
    }
    showMessage(context, error.toString(), error: true);
  }
}

Future<void> saveLocalMediaToPhotos(
  BuildContext context,
  File file, {
  required String filename,
}) async {
  try {
    if (!await file.exists()) {
      throw ApiException('Local media file not found: $filename');
    }

    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        iosAccessLevel: IosAccessLevel.addOnly,
        androidPermission: AndroidPermission(
          type: RequestType.video,
          mediaLocation: false,
        ),
      ),
    );
    if (!permission.hasAccess) {
      throw ApiException(
        'Photo library permission is required before videos can be exported to Photos.',
      );
    }

    await PhotoManager.editor.saveVideo(
      file,
      title: filename.replaceFirst(RegExp(r'\.mp4$'), ''),
    );
    if (!context.mounted) {
      return;
    }
    showMessage(context, 'Saved to Photos.');
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    showMessage(context, error.message, error: true);
  } on Exception catch (error) {
    if (!context.mounted) {
      return;
    }
    showMessage(context, error.toString(), error: true);
  }
}
