import 'package:flutter/material.dart';

import 'api_client.dart';
import 'clip_editor_dialog.dart';
import 'controller.dart';
import 'media_player_page.dart';
import 'media_utils.dart';
import 'task_helpers.dart';
import 'theme.dart';
import 'utils.dart';
import 'widgets.dart';

class TasksTab extends StatelessWidget {
  const TasksTab({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.readyForApi) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Connect and sign in before managing library activity.'),
        ),
      );
    }

    final tasks = controller.tasks;
    if (tasks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.task_alt, size: 48),
              const SizedBox(height: 12),
              const Text('No library activity yet.'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    await controller.refreshTasks();
                  } on ApiException catch (error) {
                    if (!context.mounted) {
                      return;
                    }
                    showMessage(context, error.message, error: true);
                  }
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: controller.refreshTasks,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: tasks.length,
        itemBuilder: (context, index) {
          final task = tasks[index];
          final autoFinalizing = controller.isAutoFinalizingTask(task.id);
          final treatedAsStopped = controller.treatTaskAsStopped(task);
          final label = taskStatusLabel(task, controller);
          final color = taskStatusColor(task, controller);
          final displayError = taskErrorMessage(task, controller);
          final progressValue =
              task.isRecording || task.isStopping || autoFinalizing
                  ? null
                  : task.progress.clamp(0, 100) / 100;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          task.output ?? task.outputName ?? task.url,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Chip(
                        avatar: Icon(Icons.circle, size: 12, color: color),
                        label: Text(label),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    task.url,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: appTextMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progressValue),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      InfoChip(label: 'Progress', value: '${task.progress}%'),
                      InfoChip(
                          label: 'Speed',
                          value: '${task.speedMbps.toStringAsFixed(2)} Mbps'),
                      InfoChip(
                          label: 'Saved',
                          value: formatBytes(task.bytesDownloaded)),
                      if (task.total > 0)
                        InfoChip(
                            label: 'Parts',
                            value: '${task.downloaded}/${task.total}'),
                      if (task.recordedSegments > 0)
                        InfoChip(
                            label: 'Captured',
                            value: task.recordedSegments.toString()),
                      if (task.elapsedSec > 0)
                        InfoChip(
                            label: 'Elapsed',
                            value: formatClock(task.elapsedSec)),
                      if (task.hasKnownDuration)
                        InfoChip(
                          label: 'Duration',
                          value: formatSeconds(task.durationSec!),
                        ),
                      InfoChip(label: 'Quality', value: task.quality),
                    ],
                  ),
                  if (displayError != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (task.needsLocalMerge ? appWarning : appDanger)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: (task.needsLocalMerge ? appWarning : appDanger)
                              .withValues(alpha: 0.28),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(
                            task.needsLocalMerge
                                ? Icons.build_circle_outlined
                                : Icons.warning_amber_rounded,
                            color:
                                task.needsLocalMerge ? appWarning : appDanger,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              displayError,
                              style: TextStyle(
                                color: task.needsLocalMerge
                                    ? appWarning
                                    : Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: controller.isBusy ||
                                task.isStopping ||
                                autoFinalizing
                            ? null
                            : () async {
                                try {
                                  final result =
                                      await controller.deleteOrStopTask(task);
                                  if (!context.mounted) {
                                    return;
                                  }
                                  if (task.isRecording &&
                                      result == 'stopping') {
                                    showMessage(
                                      context,
                                      'Stop requested. Finalizing the local media file...',
                                    );
                                  } else {
                                    showMessage(
                                        context, 'Action completed: $result');
                                  }
                                } on ApiException catch (error) {
                                  if (!context.mounted) {
                                    return;
                                  }
                                  showMessage(context, error.message,
                                      error: true);
                                }
                              },
                        icon: Icon(autoFinalizing
                            ? Icons.save_alt_rounded
                            : task.isRecording
                                ? Icons.stop
                                : task.isStopping
                                    ? Icons.hourglass_bottom
                                    : task.isTerminal
                                        ? Icons.delete
                                        : Icons.close),
                        label: Text(autoFinalizing
                            ? 'Saving...'
                            : task.isRecording
                                ? 'Stop'
                                : task.isStopping
                                    ? 'Stopping...'
                                    : task.isTerminal
                                        ? 'Remove'
                                        : 'Cancel job'),
                      ),
                      if (task.canPause)
                        OutlinedButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () async {
                                  try {
                                    await controller.pauseTask(task.id);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context,
                                        'Paused — segments preserved.');
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.pause),
                          label: const Text('Pause'),
                        ),
                      if (task.canResume)
                        OutlinedButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () async {
                                  try {
                                    await controller.resumeTask(task.id);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context, 'Resume requested.');
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Resume'),
                        ),
                      if (task.canRestart)
                        OutlinedButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () async {
                                  try {
                                    await controller.restartTask(task.id);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context, 'Restart requested.');
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.restart_alt),
                          label: const Text('Restart'),
                        ),
                      if (task.canRestartRecording)
                        OutlinedButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () async {
                                  try {
                                    final newTaskId = await controller
                                        .restartRecording(task.id);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context,
                                        'Capture restarted (${shortId(newTaskId)}).');
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.replay_circle_filled_outlined),
                          label: const Text('Restart'),
                        ),
                      if (task.needsLocalMerge)
                        FilledButton.tonalIcon(
                          onPressed: controller.isBusy || autoFinalizing
                              ? null
                              : () async {
                                  try {
                                    final filename = await controller
                                        .finalizeTaskLocally(task);
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context,
                                        'Merged locally with FFmpegKit.');
                                    await openMediaPlayer(
                                      context,
                                      title: filename,
                                      uri: controller.downloadUri(filename),
                                      httpHeaders:
                                          controller.mediaRequestHeaders,
                                      localFilePath: localMediaPathOrNull(
                                        controller,
                                        filename,
                                      ),
                                      localFileName: filename,
                                    );
                                  } on ApiException catch (error) {
                                    if (!context.mounted) {
                                      return;
                                    }
                                    showMessage(context, error.message,
                                        error: true);
                                  }
                                },
                          icon: const Icon(Icons.build_circle_outlined),
                          label: Text(autoFinalizing
                              ? 'Saving locally...'
                              : 'Finalize locally'),
                        ),
                      if (task.canClip)
                        OutlinedButton.icon(
                          onPressed: controller.isBusy
                              ? null
                              : () => showClipDialog(context, controller, task),
                          icon: const Icon(Icons.content_cut),
                          label: const Text('Clip'),
                        ),
                      if (task.output != null)
                        FilledButton.tonalIcon(
                          onPressed: () => openMediaPlayer(
                            context,
                            title: task.output!,
                            uri: controller.downloadUri(task.output!),
                            httpHeaders: controller.mediaRequestHeaders,
                            localFilePath:
                                localMediaPathOrNull(controller, task.output!),
                            localFileName: task.output!,
                          ),
                          icon: const Icon(Icons.play_circle_fill),
                          label: const Text('Watch file'),
                        ),
                      if (task.output != null)
                        OutlinedButton.icon(
                          onPressed: () => shareLocalMediaFromController(
                            context,
                            controller,
                            task.output!,
                          ),
                          icon: const Icon(Icons.ios_share),
                          label: const Text('Share'),
                        ),
                      if (task.output != null)
                        OutlinedButton.icon(
                          onPressed: () => saveLocalMediaToPhotosFromController(
                            context,
                            controller,
                            task.output!,
                          ),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Save to Photos'),
                        ),
                      if (task.canPreview)
                        FilledButton.tonalIcon(
                          onPressed: () => openMediaPlayer(
                            context,
                            title: 'Preview · ${task.id}',
                            uri: controller.previewUri(task.id),
                            httpHeaders: controller.mediaRequestHeaders,
                            isLive: true,
                          ),
                          icon: const Icon(Icons.live_tv),
                          label: Text(treatedAsStopped
                              ? 'Open closing preview'
                              : 'Preview'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
