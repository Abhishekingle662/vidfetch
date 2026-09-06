import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/download_task.dart';
import '../utils/url_normalizer.dart';
import 'android_ytdlp_engine.dart';
import 'background_service.dart';
import 'download_engine.dart';
import 'notification_service.dart';
import 'settings_service.dart';
import 'ytdlp_engine.dart';

/// Central state for the download queue. Starts queued tasks up to
/// [maxConcurrent], tracks progress, and exposes pause/resume/cancel.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.settings,
    required this.notifications,
  }) : _engine = Platform.isAndroid ? AndroidYtDlpEngine() : YtDlpEngine();

  final SettingsService settings;
  final NotificationService notifications;
  final DownloadEngine _engine;

  static const maxConcurrent = 2;

  final List<DownloadTask> _tasks = [];
  final Map<String, DownloadHandle> _handles = {};

  /// Task ids the user paused/canceled — distinguishes an intentional kill
  /// from a crash when the process exits.
  final Set<String> _pausedIds = {};
  final Set<String> _canceledIds = {};

  int _nextId = 1;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  List<DownloadTask> get activeTasks =>
      _tasks.where((t) => !t.status.isFinished).toList();

  List<DownloadTask> get finishedTasks =>
      _tasks.where((t) => t.status.isFinished).toList();

  int get runningCount =>
      _tasks.where((t) => t.status.isActive).length;

  bool get engineSupported => _engine.supported;

  /// Adds a single URL (or Instagram username) to the queue. Returns an
  /// error message on invalid input, null on success.
  String? addUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return 'Please paste a video URL or Instagram username first.';
    }
    final normalized = normalizeDownloadInput(trimmed);
    if (normalized == null) {
      return 'That does not look like a valid URL or Instagram username.';
    }
    final task = DownloadTask(
      id: '${_nextId++}',
      url: normalized,
      quality: settings.quality,
      destinationFolder: settings.downloadFolder,
    );
    _tasks.insert(0, task);
    notifyListeners();
    _pump();
    return null;
  }

  /// Loads URLs (one per line, # comments allowed) from a .txt file.
  /// Returns the number of URLs added.
  Future<int> addBatchFromFile(String path) async {
    final lines = await File(path).readAsLines();
    var added = 0;
    for (final line in lines) {
      final url = line.trim();
      if (url.isEmpty || url.startsWith('#')) continue;
      if (addUrl(url) == null) added++;
    }
    return added;
  }

  void pause(DownloadTask task) {
    final handle = _handles[task.id];
    if (handle == null) return;
    _pausedIds.add(task.id);
    handle.kill();
  }

  void resume(DownloadTask task) {
    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed) {
      return;
    }
    task.status = DownloadStatus.queued;
    task.error = null;
    notifyListeners();
    _pump();
  }

  void cancel(DownloadTask task) {
    final handle = _handles[task.id];
    if (handle != null) {
      _canceledIds.add(task.id);
      handle.kill();
    } else {
      task.status = DownloadStatus.canceled;
      notifyListeners();
    }
  }

  void remove(DownloadTask task) {
    if (task.status.isActive) cancel(task);
    _tasks.remove(task);
    notifyListeners();
  }

  void clearFinished() {
    _tasks.removeWhere((t) => t.status.isFinished);
    notifyListeners();
  }

  void _pump() {
    final engine = _engine;
    if (engine is YtDlpEngine) {
      engine.executableOverride = settings.ytDlpPath;
    }
    while (runningCount < maxConcurrent) {
      DownloadTask? next;
      for (final t in _tasks.reversed) {
        if (t.status == DownloadStatus.queued) {
          next = t;
          break;
        }
      }
      if (next == null) break;
      _start(next);
    }
    _syncBackgroundService();
  }

  Future<void> _start(DownloadTask task) async {
    task.status = DownloadStatus.fetching;
    task.error = null;
    notifyListeners();

    final notifId = int.tryParse(task.id) ?? 0;
    final cookies = settings.resolvedCookieFilePath;

    final result = await _engine.download(
      url: task.url,
      outputFolder: task.destinationFolder,
      formatSelector: Platform.isAndroid
          ? VideoQuality.androidFormatFor(task.quality)
          : VideoQuality.formatFor(task.quality),
      ignoreSslErrors: settings.ignoreSslErrors,
      cookieFilePath: cookies.isEmpty ? null : cookies,
      onHandle: (handle) => _handles[task.id] = handle,
      onTitle: (title) {
        task.title = title;
        notifyListeners();
      },
      onProgress: (fraction, speed, eta) {
        task.status = DownloadStatus.downloading;
        task.progress = fraction;
        task.speed = speed;
        task.eta = eta;
        notifyListeners();
        if (settings.notificationsEnabled) {
          notifications.showProgress(
            id: notifId,
            title: task.displayName,
            progress: fraction,
          );
        }
      },
    );

    _handles.remove(task.id);
    if (result.filePath != null) task.filePath = result.filePath;
    if (result.uri != null) task.uri = result.uri;
    if (result.title != null && result.title!.isNotEmpty) {
      task.title = result.title;
    }
    final count = result.fileCount;
    if (count != null && count > 1) {
      final base = (task.title != null && task.title!.isNotEmpty)
          ? task.title!
          : 'Download';
      task.title = '$base ($count files)';
    }

    if (_canceledIds.remove(task.id)) {
      task.status = DownloadStatus.canceled;
      notifications.cancel(notifId);
    } else if (_pausedIds.remove(task.id)) {
      task.status = DownloadStatus.paused;
      notifications.cancel(notifId);
    } else if (result.success) {
      task.status = DownloadStatus.completed;
      task.progress = 1.0;
      task.speed = null;
      task.eta = null;
      notifications.cancel(notifId);
      if (settings.notificationsEnabled) {
        notifications.showDone(
            id: 100000 + notifId, title: task.displayName, success: true);
      }
    } else {
      task.status = DownloadStatus.failed;
      task.error = _friendlyDownloadError(result.error, task.url);
      notifications.cancel(notifId);
      if (settings.notificationsEnabled) {
        notifications.showDone(
            id: 100000 + notifId, title: task.displayName, success: false);
      }
    }

    notifyListeners();
    _pump();
  }

  void _syncBackgroundService() {
    final active = runningCount;
    if (active > 0) {
      BackgroundKeeper.instance.onDownloadsActive(active);
    } else {
      BackgroundKeeper.instance.onDownloadsIdle();
    }
  }
}

/// Maps common yt-dlp failures into short, actionable UI messages.
String _friendlyDownloadError(String? raw, String url) {
  final error = (raw ?? 'Unknown error').trim();
  final lower = error.toLowerCase();

  if (looksLikeTikTokInput(url) &&
      (lower.contains('ip address is blocked') ||
          lower.contains('your ip is blocked') ||
          lower.contains('blocked from accessing'))) {
    return 'TikTok blocked this network/IP. Try mobile data or another '
        'network. Importing TikTok browser cookies in Settings can also help.';
  }

  if (looksLikeSnapchatInput(url) &&
      (lower.contains('unsupported url') ||
          lower.contains('no video formats') ||
          lower.contains('unable to extract') ||
          lower.contains('not a valid url'))) {
    return 'Only Snapchat Spotlight links work '
        '(snapchat.com/spotlight/…). Stories and private Snaps are not supported.';
  }

  return error;
}
