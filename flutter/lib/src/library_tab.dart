import 'package:flutter/material.dart';

import 'channel_browser_page.dart';
import 'controller.dart';
import 'media_player_page.dart';
import 'models.dart';
import 'playlists_tab.dart';
import 'task_helpers.dart';
import 'theme.dart';
import 'widgets.dart';

/// Landing page for the "Library" tab.
/// Shows navigation rows for Channels and Movies, plus recently watched.
class LibraryTab extends StatefulWidget {
  const LibraryTab({
    super.key,
    required this.controller,
    required this.onUseChannel,
  });

  final AppController controller;
  final VoidCallback onUseChannel;

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  AppController get _ctrl => widget.controller;

  // ── Counts ─────────────────────────────────────────────────────────────────

  List<PlaylistBrowserItem> get _allItems {
    final rawItems = _ctrl.playlists
        .expand((p) =>
            p.channels.map((c) => PlaylistBrowserItem.fromPlaylist(p, c)))
        .toList();
    final mergedGroups =
        _ctrl.mergedPlaylistConfig?.groups ?? const <MergedGroup>[];
    final mergedItems = mergedGroups
        .where((g) => g.enabled)
        .expand((g) => g.channels
            .where((c) => c.enabled)
            .map((c) => PlaylistBrowserItem.fromMerged(g, c)))
        .toList();
    return _ctrl.mergedPlaylistConfig != null ? mergedItems : rawItems;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final query = _searchCtrl.text.trim().toLowerCase();
        final isSearching = query.isNotEmpty;

        return CustomScrollView(
          slivers: [
            // ── Header ──────────────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Library',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 14),
                    _SearchField(controller: _searchCtrl),
                  ],
                ),
              ),
            ),

            if (!isSearching) ...[
              // ── Nav rows: Channels / Movies ────────────────────────────────
              SliverToBoxAdapter(
                child: _buildNavSection(context),
              ),

              // ── Recently Watched ──────────────────────────────────────────
              SliverToBoxAdapter(
                child: _buildRecentsSection(context),
              ),
            ] else ...[
              // ── Inline search results ─────────────────────────────────────
              _SearchResultsSliver(
                query: query,
                allItems: _allItems,
                controller: _ctrl,
                onUseChannel: widget.onUseChannel,
              ),
            ],

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        );
      },
    );
  }

  // ── Nav Section ─────────────────────────────────────────────────────────────

  Widget _buildNavSection(BuildContext context) {
    final all = _allItems;
    final channelCount = all.where((i) => !i.isVod).length;
    final movieCount = all.where((i) => i.isVod).length;

    return Column(
      children: [
        _NavRow(
          label: 'Channels',
          count: channelCount,
          icon: Icons.live_tv_rounded,
          onTap: () => _openBrowser(context, isMovies: false),
        ),
        const Divider(height: 1, indent: 20, endIndent: 20),
        _NavRow(
          label: 'Movies',
          count: movieCount,
          icon: Icons.movie_filter_rounded,
          onTap: () => _openBrowser(context, isMovies: true),
        ),
        const Divider(height: 1, indent: 20, endIndent: 20),
        const SizedBox(height: 8),
      ],
    );
  }

  void _openBrowser(BuildContext context, {required bool isMovies}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChannelBrowserPage(
        controller: _ctrl,
        isMovies: isMovies,
        onUseChannel: widget.onUseChannel,
      ),
    ));
  }

  // ── Recents Section ──────────────────────────────────────────────────────────

  Widget _buildRecentsSection(BuildContext context) {
    final recents = _ctrl.recentChannels;
    if (recents.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Text(
                'Recently watched',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: appTextMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: () => _ctrl.clearRecentChannels(),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        ListView.separated(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: recents.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, indent: 72, endIndent: 20),
          itemBuilder: (context, index) {
            final ch = recents[index];
            return _RecentListTile(
              channel: ch,
              controller: _ctrl,
              onUseChannel: widget.onUseChannel,
            );
          },
        ),
      ],
    );
  }
}

// ── Nav Row ───────────────────────────────────────────────────────────────────

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.label,
    required this.count,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final int count;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: appPrimary, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: appPrimary,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ),
            if (count > 0)
              Text(
                '$count',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: appTextMuted),
              ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: appPrimary, size: 20),
          ],
        ),
      ),
    );
  }
}

// ── Recent Channel List Tile ──────────────────────────────────────────────────

class _RecentListTile extends StatelessWidget {
  const _RecentListTile({
    required this.channel,
    required this.controller,
    required this.onUseChannel,
  });
  final RecentChannel channel;
  final AppController controller;
  final VoidCallback onUseChannel;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ChannelLogo(url: channel.logoUrl, size: 48),
      ),
      title: Text(
        channel.name,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: channel.groupName != null
          ? Text(
              channel.groupName!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: appTextMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      onTap: () => _play(context),
    );
  }

  void _play(BuildContext context) {
    controller.addToRecentChannels(
      name: channel.name,
      url: channel.url,
      logoUrl: channel.logoUrl,
      groupName: channel.groupName,
    );
    openMediaPlayer(
      context,
      title: channel.name,
      uri: Uri.parse(channel.url),
      httpHeaders: const {},
      isLive: true,
      copyUrl: channel.url,
      copyLabel: 'Source URL copied.',
      onGrabRequested: () {
        Navigator.of(context).maybePop();
        controller.suggestDownloadUrl(channel.url);
        onUseChannel();
      },
      allowPictureInPicture: true,
      onFetchVariants: () => controller.parseStreamVariants(url: channel.url),
      probeKind: controller.probeWatchKind,
    );
  }
}

// ── Search Field ──────────────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 20),
        hintText: 'Search…',
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                onPressed: controller.clear,
                icon: const Icon(Icons.close, size: 18),
              ),
      ),
    );
  }
}

// ── Search Results ────────────────────────────────────────────────────────────

class _SearchResultsSliver extends StatelessWidget {
  const _SearchResultsSliver({
    required this.query,
    required this.allItems,
    required this.controller,
    required this.onUseChannel,
  });
  final String query;
  final List<PlaylistBrowserItem> allItems;
  final AppController controller;
  final VoidCallback onUseChannel;

  @override
  Widget build(BuildContext context) {
    final results = allItems
        .where((item) =>
            item.channelName.toLowerCase().contains(query) ||
            item.groupName.toLowerCase().contains(query))
        .toList();

    if (results.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            children: [
              Icon(Icons.search_off, size: 48, color: appTextMuted.withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text('No results for "$query"',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final item = results[index];
          final health = controller.healthForUrl(item.channelUrl);
          return Column(
            children: [
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  item.groupName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: appTextMuted, fontSize: 12),
                ),
                onTap: () => _play(context, item),
              ),
              if (index < results.length - 1)
                const Divider(height: 1, indent: 72, endIndent: 20),
            ],
          );
        },
        childCount: results.length,
      ),
    );
  }

  void _play(BuildContext context, PlaylistBrowserItem item) {
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
      probeKind: controller.probeWatchKind,
    );
  }
}
