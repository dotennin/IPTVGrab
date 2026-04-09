import 'package:flutter/material.dart';

import 'controller.dart';
import 'media_player_page.dart';
import 'models.dart';
import 'playlists_tab.dart';
import 'task_helpers.dart';
import 'theme.dart';
import 'widgets.dart';

/// Full-screen page showing all Channels or Movies with group sections,
/// collapsible groups, list/grid view and active-only filter.
class ChannelBrowserPage extends StatefulWidget {
  const ChannelBrowserPage({
    super.key,
    required this.controller,
    required this.isMovies,
    required this.onUseChannel,
  });

  final AppController controller;
  final bool isMovies;
  final VoidCallback onUseChannel;

  @override
  State<ChannelBrowserPage> createState() => _ChannelBrowserPageState();
}

class _ChannelBrowserPageState extends State<ChannelBrowserPage> {
  late final TextEditingController _searchCtrl;
  final Set<String> _expandedGroups = {};

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController()
      ..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  AppController get _ctrl => widget.controller;

  bool get _isList =>
      widget.isMovies ? _ctrl.movieBrowserList : _ctrl.channelBrowserList;

  bool get _showAll =>
      widget.isMovies ? _ctrl.movieBrowserShowAll : _ctrl.channelBrowserShowAll;

  /// All items filtered by movies vs channels classification.
  List<PlaylistBrowserItem> get _allItems {
    final rawItems = _ctrl.playlists
        .expand((p) => p.channels.map((c) => PlaylistBrowserItem.fromPlaylist(p, c)))
        .toList();
    final mergedGroups = _ctrl.mergedPlaylistConfig?.groups ?? const <MergedGroup>[];
    final mergedItems = mergedGroups
        .where((g) => g.enabled)
        .expand((g) =>
            g.channels.where((c) => c.enabled).map((c) => PlaylistBrowserItem.fromMerged(g, c)))
        .toList();
    final source = _ctrl.mergedPlaylistConfig != null ? mergedItems : rawItems;
    return source
        .where((item) => item.isVod == widget.isMovies)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final all = _allItems;
    final query = _searchCtrl.text.trim().toLowerCase();

    // Build per-group map preserving order.
    final groupOrder = <String>[];
    final groupMap = <String, List<PlaylistBrowserItem>>{};
    for (final item in all) {
      if (!groupMap.containsKey(item.groupName)) {
        groupOrder.add(item.groupName);
        groupMap[item.groupName] = [];
      }
      groupMap[item.groupName]!.add(item);
    }

    // Apply health filter + search.
    final filteredGroupMap = <String, List<PlaylistBrowserItem>>{};
    for (final group in groupOrder) {
      final items = (groupMap[group] ?? []).where((item) {
        final matchesSearch = query.isEmpty ||
            item.channelName.toLowerCase().contains(query) ||
            item.groupName.toLowerCase().contains(query);
        final matchesHealth = _showAll ||
            _ctrl.healthForUrl(item.channelUrl)?.isAvailable == true;
        return matchesSearch && matchesHealth;
      }).toList();
      if (items.isNotEmpty) {
        filteredGroupMap[group] = items;
      }
    }
    final filteredGroups = groupOrder.where(filteredGroupMap.containsKey).toList();

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.isMovies ? 'Movies' : 'Channels'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'View & Filter options',
            onPressed: () => _showOptionsSheet(context),
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Column(
            children: [
              _SearchBar(controller: _searchCtrl),
              if (_ctrl.healthState.running)
                LinearProgressIndicator(
                  value: _ctrl.healthState.total <= 0
                      ? null
                      : _ctrl.healthState.done / _ctrl.healthState.total,
                ),
              Expanded(
                child: filteredGroups.isEmpty
                    ? _emptyState(context, all.isEmpty)
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: filteredGroups.length,
                        itemBuilder: (context, index) {
                          final group = filteredGroups[index];
                          final items = filteredGroupMap[group]!;
                          final expanded = _expandedGroups.contains(group);
                          return _GroupSection(
                            group: group,
                            items: items,
                            expanded: expanded,
                            isList: _isList,
                            controller: _ctrl,
                            onUseChannel: widget.onUseChannel,
                            onToggle: () => setState(() {
                              if (expanded) {
                                _expandedGroups.remove(group);
                              } else {
                                _expandedGroups.add(group);
                              }
                            }),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _emptyState(BuildContext context, bool noData) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              noData ? Icons.playlist_add : Icons.search_off,
              size: 56,
              color: appTextMuted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              noData
                  ? 'No ${widget.isMovies ? "movies" : "channels"} found in your source lists.'
                  : 'No results match the current filters.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (!_showAll && !noData) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => _ctrl.setChannelBrowserPrefs(
                  showAll: true,
                  isMovies: widget.isMovies,
                ),
                child: const Text('Show unavailable'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showOptionsSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => AnimatedBuilder(
        animation: _ctrl,
        builder: (ctx, _) => _OptionsSheet(
          isList: _isList,
          showAll: _showAll,
          isMovies: widget.isMovies,
          controller: _ctrl,
        ),
      ),
    );
  }
}

// ── Options Bottom Sheet ──────────────────────────────────────────────────────

class _OptionsSheet extends StatelessWidget {
  const _OptionsSheet({
    required this.isList,
    required this.showAll,
    required this.isMovies,
    required this.controller,
  });

  final bool isList;
  final bool showAll;
  final bool isMovies;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: appTextMuted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('View', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                _ViewModeButton(
                  icon: Icons.view_list_rounded,
                  label: 'List',
                  selected: isList,
                  onTap: () => controller.setChannelBrowserPrefs(
                      isList: true, isMovies: isMovies),
                ),
                const SizedBox(width: 10),
                _ViewModeButton(
                  icon: Icons.grid_view_rounded,
                  label: 'Grid',
                  selected: !isList,
                  onTap: () => controller.setChannelBrowserPrefs(
                      isList: false, isMovies: isMovies),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Filter', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            _FilterTile(
              label: 'Active sources only',
              selected: !showAll,
              onTap: () => controller.setChannelBrowserPrefs(
                  showAll: false, isMovies: isMovies),
            ),
            _FilterTile(
              label: 'Show all sources',
              selected: showAll,
              onTap: () => controller.setChannelBrowserPrefs(
                  showAll: true, isMovies: isMovies),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewModeButton extends StatelessWidget {
  const _ViewModeButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? appPrimary.withValues(alpha: 0.15) : appSurfaceAlt,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? appPrimary : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            children: [
              Icon(icon, color: selected ? appPrimary : appTextMuted, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: selected ? appPrimary : appTextMuted,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterTile extends StatelessWidget {
  const _FilterTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: selected
          ? Icon(Icons.check_circle_rounded, color: appPrimary)
          : Icon(Icons.radio_button_unchecked, color: appTextMuted),
      onTap: onTap,
    );
  }
}

// ── Group Section ─────────────────────────────────────────────────────────────

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.group,
    required this.items,
    required this.expanded,
    required this.isList,
    required this.controller,
    required this.onUseChannel,
    required this.onToggle,
  });

  final String group;
  final List<PlaylistBrowserItem> items;
  final bool expanded;
  final bool isList;
  final AppController controller;
  final VoidCallback onUseChannel;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group header row
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 22,
                    color: appTextMuted,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    group,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: appSurfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${items.length}',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: appTextMuted),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        if (expanded) ...[
          isList
              ? _ListItems(
                  items: items,
                  controller: controller,
                  onUseChannel: onUseChannel,
                )
              : _GridItems(
                  items: items,
                  controller: controller,
                  onUseChannel: onUseChannel,
                ),
        ],
      ],
    );
  }
}

// ── List Items ────────────────────────────────────────────────────────────────

class _ListItems extends StatelessWidget {
  const _ListItems({
    required this.items,
    required this.controller,
    required this.onUseChannel,
  });
  final List<PlaylistBrowserItem> items;
  final AppController controller;
  final VoidCallback onUseChannel;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, indent: 72, endIndent: 16),
      itemBuilder: (context, index) {
        final item = items[index];
        final health = controller.healthForUrl(item.channelUrl);
        return _ChannelListTile(
          item: item,
          health: health,
          controller: controller,
          onUseChannel: onUseChannel,
        );
      },
    );
  }
}

class _ChannelListTile extends StatelessWidget {
  const _ChannelListTile({
    required this.item,
    required this.health,
    required this.controller,
    required this.onUseChannel,
  });
  final PlaylistBrowserItem item;
  final HealthCheckEntry? health;
  final AppController controller;
  final VoidCallback onUseChannel;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          ChannelLogo(url: item.logoUrl, size: 44),
          Positioned(
            right: -3,
            bottom: -3,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: healthStatusColor(health?.status),
                shape: BoxShape.circle,
                border: Border.all(color: appSurface, width: 1.5),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        item.channelName,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.download_for_offline_outlined, size: 20),
        tooltip: 'Grab to library',
        color: appTextMuted,
        onPressed: () {
          controller.suggestDownloadUrl(item.channelUrl);
          onUseChannel();
        },
      ),
      onTap: () => _play(context),
    );
  }

  void _play(BuildContext context) {
    controller.addToRecentChannels(
      name: item.channelName,
      url: item.channelUrl,
      logoUrl: item.logoUrl,
      groupName: item.groupName.isNotEmpty ? item.groupName : null,
    );
    openMediaPlayer(
      context,
      title: item.channelName,
      uri: Uri.parse(item.channelUrl),
      httpHeaders: const {},
      isLive: true,
      copyUrl: item.channelUrl,
      copyLabel: 'Source URL copied.',
      onGrabRequested: () {
        Navigator.of(context).maybePop();
        controller.suggestDownloadUrl(item.channelUrl);
        onUseChannel();
      },
      allowPictureInPicture: true,
      onFetchVariants: () => controller.parseStreamVariants(url: item.channelUrl),
    );
  }
}

// ── Grid Items ────────────────────────────────────────────────────────────────

class _GridItems extends StatelessWidget {
  const _GridItems({
    required this.items,
    required this.controller,
    required this.onUseChannel,
  });
  final List<PlaylistBrowserItem> items;
  final AppController controller;
  final VoidCallback onUseChannel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          mainAxisExtent: 110,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final health = controller.healthForUrl(item.channelUrl);
          return _ChannelGridCard(
            item: item,
            health: health,
            controller: controller,
            onUseChannel: onUseChannel,
          );
        },
      ),
    );
  }
}

class _ChannelGridCard extends StatelessWidget {
  const _ChannelGridCard({
    required this.item,
    required this.health,
    required this.controller,
    required this.onUseChannel,
  });
  final PlaylistBrowserItem item;
  final HealthCheckEntry? health;
  final AppController controller;
  final VoidCallback onUseChannel;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _play(context),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ChannelLogo(url: item.logoUrl, size: 34),
                  const SizedBox(width: 6),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: healthStatusColor(health?.status),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                item.channelName,
                style: Theme.of(context).textTheme.labelMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _play(BuildContext context) {
    controller.addToRecentChannels(
      name: item.channelName,
      url: item.channelUrl,
      logoUrl: item.logoUrl,
      groupName: item.groupName.isNotEmpty ? item.groupName : null,
    );
    openMediaPlayer(
      context,
      title: item.channelName,
      uri: Uri.parse(item.channelUrl),
      httpHeaders: const {},
      isLive: true,
      copyUrl: item.channelUrl,
      copyLabel: 'Source URL copied.',
      onGrabRequested: () {
        Navigator.of(context).maybePop();
        controller.suggestDownloadUrl(item.channelUrl);
        onUseChannel();
      },
      allowPictureInPicture: true,
      onFetchVariants: () => controller.parseStreamVariants(url: item.channelUrl),
    );
  }
}

// ── Search Bar ────────────────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: 'Search by name, group…',
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  onPressed: controller.clear,
                  icon: const Icon(Icons.close, size: 18),
                ),
        ),
      ),
    );
  }
}
