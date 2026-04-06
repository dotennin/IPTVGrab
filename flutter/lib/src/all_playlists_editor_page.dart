import 'package:flutter/material.dart';

import 'api_client.dart';
import 'controller.dart';
import 'models.dart';
import 'task_helpers.dart';
import 'theme.dart';
import 'utils.dart';
import 'widgets.dart';

class AllPlaylistsEditorPage extends StatefulWidget {
  const AllPlaylistsEditorPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<AllPlaylistsEditorPage> createState() =>
      _AllPlaylistsEditorPageState();
}

class _AllPlaylistsEditorPageState extends State<AllPlaylistsEditorPage> {
  late MergedPlaylistConfig _draft;
  String? _selectedGroupId;
  bool _dirty = false;
  bool _saving = false;
  bool _refreshing = false;
  bool _copyingExport = false;

  @override
  void initState() {
    super.initState();
    _hydrateFromController();
  }

  MergedGroup? get _selectedGroup {
    final selectedId = _selectedGroupId;
    if (selectedId == null) {
      return null;
    }
    for (final group in _draft.groups) {
      if (group.id == selectedId) {
        return group;
      }
    }
    return null;
  }

  void _hydrateFromController() {
    final config = widget.controller.mergedPlaylistConfig;
    _draft =
        (config ?? MergedPlaylistConfig(groups: const <MergedGroup>[])).copy();
    if (_selectedGroupId != null &&
        _draft.groups.any((group) => group.id == _selectedGroupId)) {
      return;
    }
    _selectedGroupId = _draft.groups.isEmpty ? null : _draft.groups.first.id;
  }

  Future<void> _handleClose() async {
    if (!_dirty) {
      Navigator.of(context).pop(false);
      return;
    }
    final discard = await _confirmDiscardChanges(
      'Discard your unsaved All Playlists edits?',
    );
    if (!mounted || !discard) {
      return;
    }
    Navigator.of(context).pop(false);
  }

  Future<bool> _confirmDiscardChanges(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Unsaved changes'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Discard'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  void _replaceGroups(
    List<MergedGroup> groups, {
    required bool markDirty,
    String? selectedGroupId,
  }) {
    setState(() {
      _draft = MergedPlaylistConfig(groups: groups);
      if (selectedGroupId != null) {
        _selectedGroupId = selectedGroupId;
      }
      if (_selectedGroupId != null &&
          !_draft.groups.any((group) => group.id == _selectedGroupId)) {
        _selectedGroupId =
            _draft.groups.isEmpty ? null : _draft.groups.first.id;
      }
      if (markDirty) {
        _dirty = true;
      }
    });
  }

  void _toggleGroupEnabled(String groupId, bool enabled) {
    final next = _draft.groups
        .map(
          (group) => group.id == groupId
              ? group.copyWith(enabled: enabled)
              : group.copy(),
        )
        .toList();
    _replaceGroups(next, markDirty: true);
  }

  void _toggleChannelEnabled(String channelId, bool enabled) {
    final selectedGroup = _selectedGroup;
    if (selectedGroup == null) {
      return;
    }
    final nextGroups = _draft.groups.map((group) {
      if (group.id != selectedGroup.id) {
        return group.copy();
      }
      return group.copyWith(
        channels: group.channels
            .map(
              (channel) => channel.id == channelId
                  ? channel.copyWith(enabled: enabled)
                  : channel.copy(),
            )
            .toList(),
      );
    }).toList();
    _replaceGroups(nextGroups,
        markDirty: true, selectedGroupId: selectedGroup.id);
  }

  void _reorderGroups(int oldIndex, int newIndex) {
    final next = _draft.groups.map((group) => group.copy()).toList();
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    _replaceGroups(next, markDirty: true, selectedGroupId: moved.id);
  }

  void _reorderChannels(int oldIndex, int newIndex) {
    final selectedGroup = _selectedGroup;
    if (selectedGroup == null) {
      return;
    }
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final nextChannels =
        selectedGroup.channels.map((channel) => channel.copy()).toList();
    final moved = nextChannels.removeAt(oldIndex);
    nextChannels.insert(newIndex, moved);
    final nextGroups = _draft.groups.map((group) {
      if (group.id != selectedGroup.id) {
        return group.copy();
      }
      return group.copyWith(channels: nextChannels);
    }).toList();
    _replaceGroups(nextGroups,
        markDirty: true, selectedGroupId: selectedGroup.id);
  }

  Future<void> _deleteGroup(MergedGroup group) async {
    if (!group.custom) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete custom group'),
          content:
              Text('Delete "${group.name}" and all of its custom channels?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    final next = _draft.groups
        .where((candidate) => candidate.id != group.id)
        .map((candidate) => candidate.copy())
        .toList();
    _replaceGroups(next, markDirty: true);
  }

  Future<void> _deleteCustomChannel(MergedChannel channel) async {
    final group = _selectedGroup;
    if (group == null || !channel.custom) {
      return;
    }
    final nextGroups = _draft.groups.map((candidate) {
      if (candidate.id != group.id) {
        return candidate.copy();
      }
      return candidate.copyWith(
        channels: candidate.channels
            .where((item) => item.id != channel.id)
            .map((item) => item.copy())
            .toList(),
      );
    }).toList();
    _replaceGroups(nextGroups, markDirty: true, selectedGroupId: group.id);
  }

  Future<void> _showAddGroupDialog() async {
    final controller = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Add custom group'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Group name',
                border: OutlineInputBorder(),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Add group'),
              ),
            ],
          );
        },
      );
      if (confirmed != true) {
        return;
      }
      final name = controller.text.trim();
      if (name.isEmpty) {
        showMessage(context, 'Group name is required.', error: true);
        return;
      }
      if (_draft.groups.any((group) => group.name == name)) {
        showMessage(context, 'Group already exists.', error: true);
        return;
      }
      final next = <MergedGroup>[
        MergedGroup(
          id: randomEditorId('g'),
          name: name,
          enabled: true,
          custom: true,
          channels: const <MergedChannel>[],
        ),
        ..._draft.groups.map((group) => group.copy()),
      ];
      _replaceGroups(next, markDirty: true, selectedGroupId: next.first.id);
    } finally {
      controller.dispose();
    }
  }

  Future<void> _showChannelDialog({MergedChannel? existing}) async {
    final group = _selectedGroup;
    if (group == null) {
      showMessage(context, 'Select a group first.', error: true);
      return;
    }
    final nameController = TextEditingController(text: existing?.name ?? '');
    final urlController = TextEditingController(text: existing?.url ?? '');
    final logoController = TextEditingController(text: existing?.tvgLogo ?? '');
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(existing == null
                ? 'Add custom channel'
                : 'Edit custom channel'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Channel name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: urlController,
                    decoration: const InputDecoration(
                      labelText: 'M3U8 URL',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: logoController,
                    decoration: const InputDecoration(
                      labelText: 'Logo URL (optional)',
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
                child: Text(existing == null ? 'Add channel' : 'Save'),
              ),
            ],
          );
        },
      );
      if (confirmed != true) {
        return;
      }
      final name = nameController.text.trim();
      final url = urlController.text.trim();
      final logo = logoController.text.trim();
      if (name.isEmpty || url.isEmpty) {
        showMessage(context, 'Name and URL are required.', error: true);
        return;
      }
      final nextGroups = _draft.groups.map((candidate) {
        if (candidate.id != group.id) {
          return candidate.copy();
        }
        final nextChannels =
            candidate.channels.map((channel) => channel.copy()).toList();
        if (existing == null) {
          nextChannels.insert(
            0,
            MergedChannel(
              id: randomEditorId('cc'),
              name: name,
              url: url,
              enabled: true,
              custom: true,
              group: group.name,
              tvgLogo: logo,
              sourcePlaylistId: null,
              sourcePlaylistName: null,
            ),
          );
        } else {
          final index =
              nextChannels.indexWhere((channel) => channel.id == existing.id);
          if (index >= 0) {
            nextChannels[index] = nextChannels[index].copyWith(
              name: name,
              url: url,
              tvgLogo: logo,
              group: group.name,
            );
          }
        }
        return candidate.copyWith(channels: nextChannels);
      }).toList();
      _replaceGroups(nextGroups, markDirty: true, selectedGroupId: group.id);
    } finally {
      nameController.dispose();
      urlController.dispose();
      logoController.dispose();
    }
  }

  Future<void> _refreshAll() async {
    if (_dirty) {
      final discard = await _confirmDiscardChanges(
        'Refreshing will replace your unsaved local edits with the latest merged playlist data. Continue?',
      );
      if (!discard) {
        return;
      }
    }
    setState(() => _refreshing = true);
    try {
      await widget.controller.refreshAllPlaylists();
      _hydrateFromController();
      if (!mounted) {
        return;
      }
      setState(() => _dirty = false);
      showMessage(context, 'All playlists refreshed.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      showMessage(context, error.message, error: true);
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _copyExport() async {
    setState(() => _copyingExport = true);
    try {
      final content = await widget.controller.fetchMergedExport();
      if (!mounted) {
        return;
      }
      await copyToClipboard(
        context,
        content,
        label: 'Merged M3U copied to clipboard.',
      );
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      showMessage(context, error.message, error: true);
    } finally {
      if (mounted) {
        setState(() => _copyingExport = false);
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.controller.saveMergedPlaylists(_draft.copy());
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      showMessage(context, error.message, error: true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedGroup = _selectedGroup;
    return PopScope<bool>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          return;
        }
        await _handleClose();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: _handleClose,
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('All playlists editor'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Copy merged M3U',
              onPressed: _copyingExport ? null : _copyExport,
              icon: const Icon(Icons.content_copy),
            ),
            IconButton(
              tooltip: 'Refresh all playlists',
              onPressed: _refreshing ? null : _refreshAll,
              icon: const Icon(Icons.refresh),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving...' : 'Save'),
              ),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Reorder groups and channels, toggle availability, and manage custom groups or custom channels before saving.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: appTextMuted),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: _showAddGroupDialog,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('Add group'),
                      ),
                      if (selectedGroup != null)
                        FilledButton.tonalIcon(
                          onPressed: () => _showChannelDialog(),
                          icon: const Icon(Icons.add_link_outlined),
                          label: const Text('Add channel'),
                        ),
                      Chip(
                        label: Text('${_draft.groups.length} groups'),
                      ),
                      if (selectedGroup != null)
                        Chip(
                          label: Text(
                            '${selectedGroup.channels.length} channels in ${selectedGroup.name}',
                          ),
                        ),
                      if (_dirty)
                        const Chip(
                          avatar: Icon(Icons.edit, size: 18),
                          label: Text('Unsaved changes'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: _draft.groups.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(24),
                      children: const <Widget>[
                        SizedBox(height: 96),
                        Icon(Icons.playlist_play, size: 48),
                        SizedBox(height: 12),
                        Center(
                          child: Text(
                            'No merged playlist data yet. Refresh all playlists or add a custom group.',
                          ),
                        ),
                      ],
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: _draft.groups.length,
                      onReorder: _reorderGroups,
                      itemBuilder: (context, index) {
                        final group = _draft.groups[index];
                        final isSelected = group.id == _selectedGroupId;
                        final enabledChannels = group.channels
                            .where((channel) => channel.enabled)
                            .length;
                        return Card(
                          key: ValueKey(group.id),
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            children: <Widget>[
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    _selectedGroupId =
                                        isSelected ? null : group.id;
                                  });
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Row(
                                    children: <Widget>[
                                      ReorderableDelayedDragStartListener(
                                        index: index,
                                        child: const Padding(
                                          padding: EdgeInsets.only(right: 8),
                                          child: Icon(Icons.drag_indicator),
                                        ),
                                      ),
                                      Checkbox(
                                        value: group.enabled,
                                        onChanged: (value) =>
                                            _toggleGroupEnabled(
                                                group.id, value ?? true),
                                      ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              group.name,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              '${group.custom ? 'Custom group' : 'Source group'} • $enabledChannels/${group.channels.length} enabled',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                      color: appTextMuted),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (group.custom)
                                        IconButton(
                                          tooltip: 'Delete custom group',
                                          onPressed: () => _deleteGroup(group),
                                          icon:
                                              const Icon(Icons.delete_outline),
                                        ),
                                      Icon(
                                        isSelected
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (isSelected) ...<Widget>[
                                const Divider(height: 1),
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(14, 12, 14, 14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: <Widget>[
                                          Chip(
                                            label: Text(
                                              '${group.channels.length} channels',
                                            ),
                                          ),
                                          if (!group.enabled)
                                            const Chip(
                                                label: Text('Group disabled')),
                                          FilledButton.tonalIcon(
                                            onPressed: () =>
                                                _showChannelDialog(),
                                            icon: const Icon(
                                                Icons.add_link_outlined),
                                            label: const Text('Add channel'),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      if (group.channels.isEmpty)
                                        Text(
                                          'No channels in this group yet.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(color: appTextMuted),
                                        )
                                      else
                                        ReorderableListView.builder(
                                          buildDefaultDragHandles: false,
                                          shrinkWrap: true,
                                          physics:
                                              const NeverScrollableScrollPhysics(),
                                          itemCount: group.channels.length,
                                          onReorder: _reorderChannels,
                                          itemBuilder: (context, channelIndex) {
                                            final channel =
                                                group.channels[channelIndex];
                                            final health = widget.controller
                                                .healthForUrl(channel.url);
                                            return Container(
                                              key: ValueKey(channel.id),
                                              margin: const EdgeInsets.only(
                                                  bottom: 8),
                                              decoration: BoxDecoration(
                                                color: appSurfaceAlt,
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                border: Border.all(
                                                  color: Colors.white10,
                                                ),
                                              ),
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.all(12),
                                                child: Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: <Widget>[
                                                    ReorderableDelayedDragStartListener(
                                                      index: channelIndex,
                                                      child: const Padding(
                                                        padding:
                                                            EdgeInsets.only(
                                                          right: 8,
                                                          top: 6,
                                                        ),
                                                        child: Icon(Icons
                                                            .drag_indicator),
                                                      ),
                                                    ),
                                                    ChannelLogo(
                                                      url: channel.tvgLogo,
                                                      size: 36,
                                                    ),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: <Widget>[
                                                          Row(
                                                            children: <Widget>[
                                                              Expanded(
                                                                child: Text(
                                                                  channel.name,
                                                                  style: Theme.of(
                                                                          context)
                                                                      .textTheme
                                                                      .titleSmall,
                                                                ),
                                                              ),
                                                              Container(
                                                                width: 10,
                                                                height: 10,
                                                                decoration:
                                                                    BoxDecoration(
                                                                  color:
                                                                      healthStatusColor(
                                                                    health
                                                                        ?.status,
                                                                  ),
                                                                  shape: BoxShape
                                                                      .circle,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                          const SizedBox(
                                                              height: 4),
                                                          Text(
                                                            channel.url,
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .bodySmall
                                                                ?.copyWith(
                                                                  color:
                                                                      appTextMuted,
                                                                ),
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                          if (channel.sourcePlaylistName !=
                                                                  null &&
                                                              channel
                                                                  .sourcePlaylistName!
                                                                  .isNotEmpty) ...<Widget>[
                                                            const SizedBox(
                                                                height: 4),
                                                            Text(
                                                              channel
                                                                  .sourcePlaylistName!,
                                                              style: Theme.of(
                                                                      context)
                                                                  .textTheme
                                                                  .bodySmall
                                                                  ?.copyWith(
                                                                    color:
                                                                        appTextMuted,
                                                                  ),
                                                            ),
                                                          ],
                                                        ],
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Column(
                                                      children: <Widget>[
                                                        Switch.adaptive(
                                                          value:
                                                              channel.enabled,
                                                          onChanged: (value) =>
                                                              _toggleChannelEnabled(
                                                            channel.id,
                                                            value,
                                                          ),
                                                        ),
                                                        Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: <Widget>[
                                                            IconButton(
                                                              tooltip: channel
                                                                      .custom
                                                                  ? 'Edit custom channel'
                                                                  : 'Only custom channels can be edited',
                                                              onPressed: channel
                                                                      .custom
                                                                  ? () =>
                                                                      _showChannelDialog(
                                                                        existing:
                                                                            channel,
                                                                      )
                                                                  : null,
                                                              icon: const Icon(Icons
                                                                  .edit_outlined),
                                                            ),
                                                            IconButton(
                                                              tooltip: channel
                                                                      .custom
                                                                  ? 'Delete custom channel'
                                                                  : 'Source channels cannot be deleted',
                                                              onPressed: channel
                                                                      .custom
                                                                  ? () =>
                                                                      _deleteCustomChannel(
                                                                          channel)
                                                                  : null,
                                                              icon: const Icon(
                                                                Icons
                                                                    .delete_outline,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
