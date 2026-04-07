import 'package:flutter/material.dart';

import 'api_client.dart';
import 'controller.dart';
import 'models.dart';
import 'utils.dart';

Future<void> showEditPlaylistDialog(
  BuildContext context,
  AppController controller,
  Playlist playlist,
) async {
  final nameController = TextEditingController(text: playlist.name);
  final urlController = TextEditingController(text: playlist.url ?? '');

  try {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Edit source list'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: 'Source list URL',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (result != true || !context.mounted) {
      return;
    }

    await controller.editPlaylist(
      playlist.id,
      name: nameController.text.trim(),
      url: urlController.text.trim().isEmpty ? null : urlController.text.trim(),
    );
    if (!context.mounted) {
      return;
    }
    showMessage(context, 'Source list updated.');
  } on ApiException catch (error) {
    if (!context.mounted) {
      return;
    }
    showMessage(context, error.message, error: true);
  } finally {
    nameController.dispose();
    urlController.dispose();
  }
}

Future<String?> showAddPlaylistDialog(
    BuildContext context, AppController controller) async {
  final nameController = TextEditingController();
  final urlController = TextEditingController();
  final rawController = TextEditingController();

  try {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add source list'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: 'Source list URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: rawController,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Raw list contents (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (result != true || !context.mounted) {
      return null;
    }

    final newId = await controller.addPlaylist(
      name: nameController.text.trim(),
      url: urlController.text.trim().isEmpty ? null : urlController.text.trim(),
      raw: rawController.text.trim().isEmpty ? null : rawController.text.trim(),
    );
    if (!context.mounted) {
      return null;
    }
    showMessage(context, 'Source list added.');
    return newId;
  } on ApiException catch (error) {
    if (!context.mounted) {
      return null;
    }
    showMessage(context, error.message, error: true);
    return null;
  } finally {
    nameController.dispose();
    urlController.dispose();
    rawController.dispose();
  }
}
