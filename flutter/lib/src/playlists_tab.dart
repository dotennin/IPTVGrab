import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'all_playlists_editor_page.dart';
import 'api_client.dart';
import 'controller.dart';
import 'media_player_page.dart';
import 'models.dart';
import 'playlist_dialogs.dart';
import 'task_helpers.dart';
import 'theme.dart';
import 'utils.dart';
import 'widgets.dart';

class PlaylistsTab extends StatefulWidget {
  const PlaylistsTab({
    super.key,
    required this.controller,
    required this.onUseChannel,
  });

  final AppController controller;
  final VoidCallback onUseChannel;

  @override
  State<PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<PlaylistsTab> {
  late final TextEditingController _searchController;
  String? _selectedPlaylistId;
  String _selectedGroup = 'All groups';
  bool _showUnavailableChannels = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.readyForApi) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Connect and sign in before loading your source lists.'),
        ),
      );
    }

    final rawItems = controller.playlists
        .expand(
          (playlist) => playlist.channels.map((channel) =>
              PlaylistBrowserItem.fromPlaylist(playlist, channel)),
        )
        .toList();
    final mergedGroups =
        controller.mergedPlaylistConfig?.groups ?? const <MergedGroup>[];
    final mergedItems = mergedGroups
        .where((group) => group.enabled)
        .expand(
          (group) => group.channels.where((channel) => channel.enabled).map(
              (channel) => PlaylistBrowserItem.fromMerged(group, channel)),
        )
        .toList();
    final usingMergedView =
        _selectedPlaylistId == null && controller.mergedPlaylistConfig != null;
    final playlistScoped = usingMergedView
        ? mergedItems
        : _selectedPlaylistId == null
            ? rawItems
            : rawItems
                .where((item) => item.playlistId == _selectedPlaylistId)
                .toList();

    Playlist? selectedPlaylist;
    if (_selectedPlaylistId != null) {
      for (final playlist in controller.playlists) {
        if (playlist.id == _selectedPlaylistId) {
          selectedPlaylist = playlist;
          break;
        }
      }
    }

    final availableGroups = <String>{
      'All groups',
      ...playlistScoped
          .map((item) => item.groupName)
          .where((group) => group.isNotEmpty),
    }.toList()
      ..sort();
    final activeGroup = availableGroups.contains(_selectedGroup)
        ? _selectedGroup
        : 'All groups';
    final query = _searchController.text.trim().toLowerCase();
    final visibleItems = playlistScoped.where((item) {
      final matchesGroup =
          activeGroup == 'All groups' || item.groupName == activeGroup;
      final haystack = <String>[
        item.channelName,
        item.channelUrl,
        item.groupName,
        item.playlistName,
        item.sourcePlaylistName ?? '',
      ].join(' ').toLowerCase();
      final matchesQuery = query.isEmpty || haystack.contains(query);
      if (!matchesGroup || !matchesQuery) {
        return false;
      }
      if (_showUnavailableChannels) {
        return true;
      }
      return controller.healthForUrl(item.channelUrl)?.isAvailable == true;
    }).toList();
    final waitingForInitialHealthResults = !_showUnavailableChannels &&
        controller.healthCache.isEmpty &&
        controller.healthState.running &&
        playlistScoped.isNotEmpty;
    final hiddenUnavailableCount =
        math.max(0, playlistScoped.length - visibleItems.length);
    final playlistSummary = usingMergedView
        ? 'Merged library view'
        : selectedPlaylist?.name ?? 'All source lists';

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Sources',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      playlistSummary,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: appTextMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (selectedPlaylist != null)
                Builder(
                  builder: (context) {
                    final playlist = selectedPlaylist;
                    if (playlist == null) {
                      return const SizedBox.shrink();
                    }
                    return PopupMenuButton<String>(
                      tooltip: 'Manage selected source list',
                      onSelected: (value) async {
                        try {
                          if (value == 'refresh') {
                            await controller.refreshPlaylist(playlist.id);
                            if (!context.mounted) {
                              return;
                            }
                            showMessage(context, 'Source list refreshed.');
                          } else if (value == 'edit') {
                            await showEditPlaylistDialog(
                              context,
                              controller,
                              playlist,
                            );
                          } else if (value == 'delete') {
                            await controller.deletePlaylist(playlist.id);
                            if (!context.mounted) {
                              return;
                            }
                            setState(() => _selectedPlaylistId = null);
                            showMessage(context, 'Source list deleted.');
                          }
                        } on ApiException catch (error) {
                          if (!context.mounted) {
                            return;
                          }
                          showMessage(context, error.message, error: true);
                        }
                      },
                      itemBuilder: (context) => const <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'refresh',
                          child: Text('Refresh selected'),
                        ),
                        PopupMenuItem<String>(
                          value: 'edit',
                          child: Text('Edit selected'),
                        ),
                        PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('Delete selected'),
                        ),
                      ],
                      icon: const Icon(Icons.more_horiz),
                    );
                  },
                ),
              IconButton.filledTonal(
                tooltip: 'Edit all source lists',
                onPressed: controller.isBusy
                    ? null
                    : () async {
                        final saved = await Navigator.of(context).push<bool>(
                          MaterialPageRoute<bool>(
                            builder: (_) => AllPlaylistsEditorPage(
                              controller: controller,
                            ),
                          ),
                        );
                        if (saved == true && context.mounted) {
                          showMessage(context, 'Source list configuration saved.');
                        }
                      },
                icon: const Icon(Icons.edit_note),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                tooltip: 'Add source list',
                onPressed: controller.isBusy
                    ? null
                    : () async {
                        final newId = await showAddPlaylistDialog(
                            context, controller);
                        if (newId != null && mounted) {
                          setState(() => _selectedPlaylistId = newId);
                        }
                      },
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        if (controller.playlists.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: <Widget>[
                    TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                                icon: const Icon(Icons.close),
                              ),
                        labelText: 'Search sources, groups or list names',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedPlaylistId ?? '__all__',
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'Source list',
                            ),
                            items: <DropdownMenuItem<String>>[
                              const DropdownMenuItem<String>(
                                value: '__all__',
                                child: Text('All source lists'),
                              ),
                              ...controller.playlists.map(
                                (playlist) => DropdownMenuItem<String>(
                                  value: playlist.id,
                                  child: Text(playlist.name),
                                ),
                              ),
                            ],
                            onChanged: (value) {
                              setState(() {
                                _selectedPlaylistId =
                                    value == null || value == '__all__'
                                        ? null
                                        : value;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: activeGroup,
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: 'Group',
                            ),
                            items: availableGroups
                                .map(
                                  (group) => DropdownMenuItem<String>(
                                    value: group,
                                    child: Text(group),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() => _selectedGroup = value);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildChannelFilterRow(
                      context,
                      visibleItems: visibleItems,
                      playlistScoped: playlistScoped,
                      hiddenUnavailableCount: hiddenUnavailableCount,
                      waitingForInitialHealthResults:
                          waitingForInitialHealthResults,
                    ),
                    if (controller.healthState.running) ...<Widget>[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: controller.healthState.total <= 0
                            ? null
                            : controller.healthState.done /
                                controller.healthState.total,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => controller.refreshData(
              runHealthCheckAfterRefresh: true,
            ),
            child: controller.playlists.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(24),
                    children: const <Widget>[
                      SizedBox(height: 80),
                      Icon(Icons.playlist_add, size: 48),
                      SizedBox(height: 12),
                      Center(child: Text('No source lists saved yet.')),
                    ],
                  )
                : visibleItems.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.all(24),
                        children: <Widget>[
                          const SizedBox(height: 72),
                          Icon(
                            waitingForInitialHealthResults
                                ? Icons.health_and_safety_outlined
                                : Icons.search_off,
                            size: 48,
                          ),
                          const SizedBox(height: 12),
                          Center(
                            child: Text(
                              waitingForInitialHealthResults
                                  ? 'Scanning source availability. Unavailable entries stay hidden until results arrive.'
                                  : usingMergedView && playlistScoped.isEmpty
                                      ? 'No enabled entries are exposed by the merged library view. Open "Edit all" to re-enable groups or sources.'
                                      : _showUnavailableChannels
                                          ? 'No sources match the current filters.'
                                          : 'No available sources match the current filters. Turn on "Show unavailable channels" to inspect unavailable entries.',
                            ),
                          ),
                        ],
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 320,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          mainAxisExtent: 134,
                        ),
                        itemCount: visibleItems.length,
                        itemBuilder: (context, index) {
                          final item = visibleItems[index];
                          final health =
                              controller.healthForUrl(item.channelUrl);
                          final meta = <String>[
                            item.playlistName,
                            if (item.groupName.isNotEmpty) item.groupName,
                          ].join(' • ');
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      ChannelLogo(url: item.logoUrl, size: 40),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              item.channelName,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              meta,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                      color: appTextMuted),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        width: 12,
                                        height: 12,
                                        decoration: BoxDecoration(
                                          color: healthStatusColor(
                                              health?.status),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Spacer(),
                                  Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: FilledButton.tonalIcon(
                                          style: FilledButton.styleFrom(
                                            minimumSize:
                                                const Size.fromHeight(40),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 8,
                                            ),
                                          ),
                                          onPressed: () {
                                            controller.addToRecentChannels(
                                              name: item.channelName,
                                              url: item.channelUrl,
                                              logoUrl: item.logoUrl,
                                              groupName: item.groupName
                                                      .isNotEmpty
                                                  ? item.groupName
                                                  : null,
                                            );
                                            openMediaPlayer(
                                              context,
                                              title: item.channelName,
                                              uri: Uri.parse(item.channelUrl),
                                              httpHeaders: const {},
                                              isLive: true,
                                              copyUrl: item.channelUrl,
                                              copyLabel: 'Source URL copied.',
                                              probeKind: controller.probeWatchKind,
                                              onGrabRequested: () {
                                                Navigator.of(context)
                                                    .maybePop();
                                                controller.suggestDownloadUrl(
                                                  item.channelUrl,
                                                );
                                                widget.onUseChannel();
                                              },
                                              allowPictureInPicture: true,
                                              onFetchVariants: () =>
                                                  controller.parseStreamVariants(
                                                url: item.channelUrl,
                                              ),
                                            );
                                          },
                                          icon: const Icon(
                                              Icons.play_circle_fill),
                                          label: const Text(''),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton.filledTonal(
                                        tooltip:
                                            'Open Library with this source URL',
                                        onPressed: () {
                                          controller.suggestDownloadUrl(
                                            item.channelUrl,
                                          );
                                          widget.onUseChannel();
                                        },
                                        icon: const Icon(
                                            Icons.download_for_offline),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }

  Widget _buildChannelFilterRow(
    BuildContext context, {
    required List<PlaylistBrowserItem> visibleItems,
    required List<PlaylistBrowserItem> playlistScoped,
    required int hiddenUnavailableCount,
    required bool waitingForInitialHealthResults,
  }) {
    final theme = Theme.of(context);
    final isActiveOnly = !_showUnavailableChannels;

    return Row(
      children: [
        Checkbox(
          value: isActiveOnly,
          onChanged: (value) =>
              setState(() => _showUnavailableChannels = !(value ?? true)),
        ),
        Text(
          'Active Only',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            _buildChannelStatsText(
              waitingForHealthResults: waitingForInitialHealthResults,
              isActiveOnly: isActiveOnly,
              visibleCount: visibleItems.length,
              totalCount: playlistScoped.length,
              hiddenCount: hiddenUnavailableCount,
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: appTextMuted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  String _buildChannelStatsText({
    required bool waitingForHealthResults,
    required bool isActiveOnly,
    required int visibleCount,
    required int totalCount,
    required int hiddenCount,
  }) {
    if (waitingForHealthResults) {
      return 'Source health scan is still running.';
    }

    if (isActiveOnly) {
      return 'Showing $visibleCount/$totalCount matching sources.';
    }

    return 'Healthy $visibleCount/$totalCount · Hidden $hiddenCount';
  }
}

class PlaylistBrowserItem {
  const PlaylistBrowserItem({
    required this.playlistId,
    required this.playlistName,
    required this.channelName,
    required this.channelUrl,
    required this.groupName,
    required this.logoUrl,
    this.sourcePlaylistName,
    this.tvgType,
  });

  factory PlaylistBrowserItem.fromPlaylist(
    Playlist playlist,
    PlaylistChannel channel,
  ) {
    return PlaylistBrowserItem(
      playlistId: playlist.id,
      playlistName: playlist.name,
      channelName: channel.name,
      channelUrl: channel.url,
      groupName: channel.groupName,
      logoUrl: channel.logo,
      sourcePlaylistName: playlist.name,
      tvgType: channel.tvgType,
    );
  }

  factory PlaylistBrowserItem.fromMerged(
    MergedGroup group,
    MergedChannel channel,
  ) {
    return PlaylistBrowserItem(
      playlistId: channel.sourcePlaylistId ?? '__merged__',
      playlistName:
          channel.sourcePlaylistName ?? (channel.custom ? 'Custom' : 'Merged'),
      channelName: channel.name,
      channelUrl: channel.url,
      groupName: group.name,
      logoUrl: channel.tvgLogo.isEmpty ? null : channel.tvgLogo,
      sourcePlaylistName: channel.sourcePlaylistName,
      tvgType: channel.tvgType,
    );
  }

  final String playlistId;
  final String playlistName;
  final String channelName;
  final String channelUrl;
  final String groupName;
  final String? logoUrl;
  final String? sourcePlaylistName;
  final String? tvgType;

  /// Returns true if this item is VOD/movie/series content (not a live channel).
  bool get isVod {
    // 1. Explicit tvg-type from M3U8 attributes.
    final t = tvgType?.toLowerCase();
    if (t != null && t.isNotEmpty && t != 'live') {
      return true;
    }
    // 2. URL file extension heuristic (VOD content typically has a file extension).
    final path = channelUrl.split('?').first.toLowerCase();
    return path.endsWith('.mp4') ||
        path.endsWith('.mkv') ||
        path.endsWith('.avi') ||
        path.endsWith('.mov') ||
        path.endsWith('.wmv') ||
        path.endsWith('.flv') ||
        path.endsWith('.webm') ||
        path.endsWith('.m4v') ||
        path.endsWith('.mpg') ||
        path.endsWith('.mpeg');
  }
}
