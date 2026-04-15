import 'package:flutter/material.dart';

import 'all_playlists_editor_page.dart';
import 'api_client.dart';
import 'controller.dart';
import 'models.dart';
import 'playlist_dialogs.dart';
import 'theme.dart';
import 'utils.dart';

/// Source management page: list of M3U playlists with add / edit / delete /
/// refresh actions plus access to the All Playlists Editor.
/// Channel browsing is intentionally not included here — that's in Library.
class SourceSettingsPage extends StatelessWidget {
  const SourceSettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: const Text('Stream Sources'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Add source list',
            onPressed: controller.isBusy ? null : () => _addPlaylist(context),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final playlists = controller.playlists;

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              // ── All Playlists Editor row ─────────────────────────────────
              _SettingsRow(
                icon: Icons.edit_note_rounded,
                label: 'All Playlists Editor',
                subtitle: 'Manage groups, ordering and visibility',
                onTap: () async {
                  final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) =>
                          AllPlaylistsEditorPage(controller: controller),
                    ),
                  );
                  if (saved == true && context.mounted) {
                    showMessage(context, 'Source list configuration saved.');
                  }
                },
              ),
              const Divider(height: 1, indent: 64, endIndent: 0),

              // ── Health check row ─────────────────────────────────────────
              _SettingsRow(
                icon: Icons.health_and_safety_outlined,
                label: 'Check Source Availability',
                subtitle: controller.healthState.running
                    ? 'Scanning… ${controller.healthState.done}/${controller.healthState.total}'
                    : 'Test all channel URLs',
                trailing: controller.healthState.running
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: controller.healthState.running
                    ? null
                    : () async {
                        try {
                          await controller.runHealthCheck();
                        } on ApiException catch (e) {
                          if (context.mounted) {
                            showMessage(context, e.message, error: true);
                          }
                        }
                      },
              ),
              if (playlists.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    'Configured Sources',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: appTextMuted,
                          letterSpacing: 0.5,
                        ),
                  ),
                ),
                ...playlists.map((playlist) => _PlaylistTile(
                      playlist: playlist,
                      controller: controller,
                    )),
              ] else ...[
                const SizedBox(height: 60),
                const Icon(Icons.playlist_add, size: 48, color: appTextMuted),
                const SizedBox(height: 12),
                const Center(
                  child: Text('No source lists added yet.'),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: FilledButton.icon(
                    onPressed: () => _addPlaylist(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Add M3U Source'),
                  ),
                ),
              ],
            ],
          );
        },
      ),
      floatingActionButton: controller.playlists.isEmpty
          ? null
          : FloatingActionButton(
              tooltip: 'Add source list',
              onPressed: controller.isBusy ? null : () => _addPlaylist(context),
              child: const Icon(Icons.add),
            ),
    );
  }

  Future<void> _addPlaylist(BuildContext context) async {
    await showAddPlaylistDialog(context, controller);
  }
}

// ── Playlist List Tile ────────────────────────────────────────────────────────

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({required this.playlist, required this.controller});
  final Playlist playlist;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: appSurfaceAlt,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.playlist_play, color: appPrimary, size: 22),
          ),
          title: Text(
            playlist.name,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
          subtitle: Text(
            '${playlist.channelCount ?? playlist.channels.length} channels'
            '${playlist.url != null ? " · ${playlist.url}" : ""}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: appTextMuted, fontSize: 12),
          ),
          trailing: _PlaylistMenu(playlist: playlist, controller: controller),
        ),
        const Divider(height: 1, indent: 72, endIndent: 0),
      ],
    );
  }
}

class _PlaylistMenu extends StatelessWidget {
  const _PlaylistMenu({required this.playlist, required this.controller});
  final Playlist playlist;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Manage',
      onSelected: (value) async {
        try {
          if (value == 'refresh') {
            await controller.refreshPlaylist(playlist.id);
            if (context.mounted) showMessage(context, 'Source refreshed.');
          } else if (value == 'edit') {
            await showEditPlaylistDialog(context, controller, playlist);
          } else if (value == 'delete') {
            await controller.deletePlaylist(playlist.id);
            if (context.mounted) showMessage(context, 'Source deleted.');
          }
        } on ApiException catch (e) {
          if (context.mounted) showMessage(context, e.message, error: true);
        }
      },
      itemBuilder: (_) => const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(value: 'refresh', child: Text('Refresh')),
        PopupMenuItem<String>(value: 'edit', child: Text('Edit')),
        PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'delete',
          child: Text('Delete', style: TextStyle(color: Colors.red)),
        ),
      ],
      icon: const Icon(Icons.more_horiz, color: appTextMuted),
    );
  }
}

// ── Settings Row ──────────────────────────────────────────────────────────────

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    this.subtitle,
    this.trailing,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: appSurfaceAlt,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: appPrimary, size: 20),
      ),
      title: Text(label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              )),
      subtitle: subtitle != null
          ? Text(subtitle!,
              style: TextStyle(color: appTextMuted, fontSize: 12))
          : null,
      trailing: trailing ?? Icon(Icons.chevron_right_rounded, color: appTextMuted),
      onTap: onTap,
    );
  }
}
