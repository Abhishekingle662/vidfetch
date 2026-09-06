import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/download_manager.dart';
import '../widgets/download_tile.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    final active = manager.activeTasks;
    final finished = manager.finishedTasks;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        centerTitle: false,
        actions: [
          if (finished.isNotEmpty)
            IconButton(
              tooltip: 'Clear finished',
              icon: const Icon(Icons.clear_all),
              onPressed: manager.clearFinished,
            ),
        ],
      ),
      body: manager.tasks.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.download_done_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No downloads yet',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (active.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'Active (${active.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  ...active.map((t) => DownloadTile(task: t)),
                ],
                if (finished.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'Finished (${finished.length})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  ...finished.map((t) => DownloadTile(task: t)),
                ],
              ],
            ),
    );
  }
}
