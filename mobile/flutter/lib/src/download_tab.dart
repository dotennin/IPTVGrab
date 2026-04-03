import 'package:flutter/material.dart';

import 'api_client.dart';
import 'controller.dart';
import 'theme.dart';
import 'utils.dart';
import 'widgets.dart';

class DownloadTab extends StatefulWidget {
  const DownloadTab({
    super.key,
    required this.controller,
    required this.onOpenTasks,
  });

  final AppController controller;
  final VoidCallback onOpenTasks;

  @override
  State<DownloadTab> createState() => _DownloadTabState();
}

class _DownloadTabState extends State<DownloadTab> {
  late final TextEditingController _urlController;
  late final TextEditingController _headersController;
  late final TextEditingController _outputNameController;
  late final TextEditingController _concurrencyController;

  String _selectedQuality = 'best';

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _headersController = TextEditingController();
    _outputNameController = TextEditingController();
    _concurrencyController = TextEditingController(text: '8');
    widget.controller.suggestedUrl.addListener(_applySuggestedUrl);
  }

  @override
  void dispose() {
    widget.controller.suggestedUrl.removeListener(_applySuggestedUrl);
    _urlController.dispose();
    _headersController.dispose();
    _outputNameController.dispose();
    _concurrencyController.dispose();
    super.dispose();
  }

  void _applySuggestedUrl() {
    final url = widget.controller.suggestedUrl.value;
    if (url == null || url.isEmpty) {
      return;
    }
    _urlController.text = url;
    if (mounted) {
      showMessage(context, 'Filled the source URL from your saved sources.');
    }
  }

  Future<void> _parse() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      showMessage(context, 'Please enter a source URL.', error: true);
      return;
    }
    final headers = parseHeadersText(_headersController.text);
    try {
      await widget.controller.parseInput(
        url: url,
        headers: headers,
      );
      if (!mounted) {
        return;
      }
      setState(() => _selectedQuality = 'best');
      showMessage(context, 'Source checked successfully.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      showMessage(context, error.message, error: true);
    }
  }

  Future<void> _startDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      showMessage(context, 'Please enter a source URL.', error: true);
      return;
    }
    final headers = parseHeadersText(_headersController.text);
    try {
      await widget.controller.startDownload(
        url: url,
        headers: headers,
        quality: _selectedQuality,
        concurrency: int.tryParse(_concurrencyController.text.trim()) ?? 8,
        outputName: _outputNameController.text.trim().isEmpty
            ? null
            : _outputNameController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      widget.onOpenTasks();
      showMessage(context, 'Archive job started.');
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      showMessage(context, error.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final parsedInfo = controller.parsedInfo;
    final qualityOptions = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: 'best', child: Text('Best')),
      const DropdownMenuItem(value: 'worst', child: Text('Worst')),
      if (parsedInfo != null)
        ...parsedInfo.streams.asMap().entries.map(
              (entry) => DropdownMenuItem<String>(
                value: entry.key.toString(),
                child: Text('#${entry.key} · ${entry.value.displayLabel}'),
              ),
            ),
    ];
    final selectedQuality =
        qualityOptions.any((item) => item.value == _selectedQuality)
            ? _selectedQuality
            : 'best';

    if (!controller.readyForApi) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Start the on-device media service first.'),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: appPrimary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.video_library_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Build your offline library',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        'Import a source you control, inspect its variants, and save a local copy for playback, clipping, and export.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: appTextMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Import a source',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Use media URLs and headers from sources you own or are authorized to access.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: appTextMuted),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'Source URL',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _headersController,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Request headers (optional)',
                    helperText:
                        'One header per line, for example Authorization: Bearer ...',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _outputNameController,
                        decoration: const InputDecoration(
                          labelText: 'Saved file name (optional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _concurrencyController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Workers',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedQuality,
                  items: qualityOptions,
                  onChanged: controller.isBusy
                      ? null
                      : (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() => _selectedQuality = value);
                        },
                  decoration: const InputDecoration(
                    labelText: 'Variant',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: controller.isBusy ? null : _parse,
                      icon: const Icon(Icons.analytics_outlined),
                      label: const Text('Inspect source'),
                    ),
                    FilledButton.icon(
                      onPressed: controller.isBusy ? null : _startDownload,
                      icon: const Icon(Icons.download_for_offline_outlined),
                      label: const Text('Save offline'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (parsedInfo != null) ...<Widget>[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Source details',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      InfoChip(label: 'Type', value: parsedInfo.kind),
                      InfoChip(
                          label: 'Live',
                          value: parsedInfo.isLive ? 'Yes' : 'No'),
                      InfoChip(
                          label: 'Encrypted',
                          value: parsedInfo.encrypted ? 'Yes' : 'No'),
                      InfoChip(
                          label: 'Segments',
                          value: parsedInfo.segments.toString()),
                      InfoChip(
                          label: 'Duration',
                          value: formatSeconds(parsedInfo.duration)),
                    ],
                  ),
                  if (parsedInfo.streams.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text('Available variants',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    ...parsedInfo.streams.asMap().entries.map(
                          (entry) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: CircleAvatar(child: Text('${entry.key}')),
                            title: Text(entry.value.displayLabel),
                            subtitle: Text(entry.value.url),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
