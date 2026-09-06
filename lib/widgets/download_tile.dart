import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../models/download_task.dart';
import '../services/android_ytdlp_engine.dart';
import '../services/download_manager.dart';

class DownloadTile extends StatelessWidget {
  const DownloadTile({super.key, required this.task});

  final DownloadTask task;

  Color _statusColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (task.status) {
      case DownloadStatus.completed:
        return Colors.greenAccent;
      case DownloadStatus.failed:
        return scheme.error;
      case DownloadStatus.canceled:
        return scheme.outline;
      case DownloadStatus.paused:
        return Colors.amberAccent;
      default:
        return scheme.primary;
    }
  }

  Future<void> _openFile(BuildContext context) async {
    // Android files live in MediaStore Downloads; open via content URI.
    if (task.uri != null) {
      final ok = await AndroidYtDlpEngine.openUri(task.uri!);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No app found to play this file')),
        );
      }
      return;
    }
    final path = task.filePath;
    if (path == null) return;
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open file: ${result.message}')),
      );
    }
  }

  Future<void> _openFolder(BuildContext context) async {
    final folder = task.filePath != null
        ? File(task.filePath!).parent.path
        : task.destinationFolder;
    if (Platform.isWindows) {
      if (task.filePath != null && await File(task.filePath!).exists()) {
        await Process.run('explorer.exe', ['/select,', task.filePath!]);
      } else {
        await Process.run('explorer.exe', [folder]);
      }
    } else {
      final result = await OpenFilex.open(folder);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open folder')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.read<DownloadManager>();
    final statusColor = _statusColor(context);

    final subtitleParts = <String>[task.status.label];
    if (task.status == DownloadStatus.downloading) {
      if (task.progress != null) {
        subtitleParts.add('${(task.progress! * 100).toStringAsFixed(1)}%');
      }
      if (task.speed != null) subtitleParts.add(task.speed!);
      if (task.eta != null) subtitleParts.add('ETA ${task.eta}');
    }
    if (task.status == DownloadStatus.failed && task.error != null) {
      subtitleParts.add(task.error!.split('\n').first);
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitleParts.join('  ·  '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: statusColor),
                      ),
                    ],
                  ),
                ),
                ..._actions(context, manager),
              ],
            ),
            if (task.status == DownloadStatus.downloading ||
                task.status == DownloadStatus.fetching) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: task.progress),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context, DownloadManager manager) {
    switch (task.status) {
      case DownloadStatus.downloading:
      case DownloadStatus.fetching:
        return [
          IconButton(
            tooltip: 'Pause',
            icon: const Icon(Icons.pause),
            onPressed: () => manager.pause(task),
          ),
          IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: () => manager.cancel(task),
          ),
        ];
      case DownloadStatus.paused:
        return [
          IconButton(
            tooltip: 'Resume',
            icon: const Icon(Icons.play_arrow),
            onPressed: () => manager.resume(task),
          ),
          IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: () => manager.cancel(task),
          ),
        ];
      case DownloadStatus.queued:
        return [
          IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close),
            onPressed: () => manager.cancel(task),
          ),
        ];
      case DownloadStatus.completed:
        return [
          IconButton(
            tooltip: 'Open file',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () => _openFile(context),
          ),
          // On Android the file lives in the system Downloads app; a folder
          // browser is not reachable from here.
          if (!Platform.isAndroid)
            IconButton(
              tooltip: 'Show in folder',
              icon: const Icon(Icons.folder_open),
              onPressed: () => _openFolder(context),
            ),
          IconButton(
            tooltip: 'Remove from list',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => manager.remove(task),
          ),
        ];
      case DownloadStatus.failed:
        return [
          IconButton(
            tooltip: 'Retry',
            icon: const Icon(Icons.refresh),
            onPressed: () => manager.resume(task),
          ),
          IconButton(
            tooltip: 'Remove from list',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => manager.remove(task),
          ),
        ];
      case DownloadStatus.canceled:
        return [
          IconButton(
            tooltip: 'Remove from list',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => manager.remove(task),
          ),
        ];
    }
  }
}
