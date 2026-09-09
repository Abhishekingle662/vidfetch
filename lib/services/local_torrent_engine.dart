import 'dart:async';
import 'dart:io';

import 'package:b_encode_decode/b_encode_decode.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/torrent_files.dart';
import 'android_ytdlp_engine.dart';
import 'download_engine.dart';

class _TorrentHandle implements DownloadHandle {
  void Function() onKill = () {};
  bool _killed = false;

  @override
  bool get wasKilled => _killed;

  @override
  void kill() {
    _killed = true;
    onKill();
  }
}

class _AndroidTorrentJob {
  _AndroidTorrentJob({
    required this.onProgress,
    required this.onTitle,
    required this.completer,
  });

  final ProgressCallback onProgress;
  final void Function(String title) onTitle;
  final Completer<DownloadResult> completer;
}

/// On-device BitTorrent engine. Download only — no seeding after finish.
///
/// Android uses libtorrent4j (DHT + PEX and a listen port only while a
/// torrent is active; UPnP/NAT-PMP/LSD off). Desktop uses
/// `dtorrent_task_v2` so Windows can download without a bridge. That
/// library starts DHT/LSD/listen itself and may try UPnP while a task
/// is running; we stop the task as soon as the file is done or the
/// user pauses/cancels.
///
/// The device IP is visible to trackers and peers while downloading.
/// That is inherent to speaking BitTorrent from the phone/PC.
class LocalTorrentEngine implements DownloadEngine {
  LocalTorrentEngine() {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler(_onMethodCall);
    }
  }

  static const _channel = MethodChannel('vidfetch/torrent');

  final Map<String, _AndroidTorrentJob> _androidJobs = {};
  int _seq = 0;
  final Map<String, TorrentTask> _desktopTasks = {};

  @override
  bool get supported => Platform.isAndroid || Platform.isWindows;

  Future<void> abandon(String source) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('abandon', {'source': source});
      } catch (_) {}
      return;
    }
    await _stopDesktopTask(source);
  }

  Future<void> _stopDesktopTask(String source) async {
    final task = _desktopTasks.remove(source);
    if (task == null) return;
    try {
      await task.stop();
    } catch (_) {}
  }

  @override
  Future<DownloadResult> download({
    required String url,
    required String outputFolder,
    required String formatSelector,
    required ProgressCallback onProgress,
    required void Function(String title) onTitle,
    required void Function(DownloadHandle handle) onHandle,
    bool ignoreSslErrors = false,
    String? cookieFilePath,
  }) async {
    if (Platform.isAndroid) {
      return _downloadAndroid(
        source: url,
        onProgress: onProgress,
        onTitle: onTitle,
        onHandle: onHandle,
      );
    }
    return _downloadDesktop(
      source: url,
      outputFolder: outputFolder,
      onProgress: onProgress,
      onTitle: onTitle,
      onHandle: onHandle,
    );
  }

  Future<DownloadResult> _downloadAndroid({
    required String source,
    required ProgressCallback onProgress,
    required void Function(String title) onTitle,
    required void Function(DownloadHandle handle) onHandle,
  }) async {
    final id = 't${_seq++}';
    final job = _AndroidTorrentJob(
      onProgress: onProgress,
      onTitle: onTitle,
      completer: Completer<DownloadResult>(),
    );
    _androidJobs[id] = job;
    final handle = _TorrentHandle()
      ..onKill = () {
        _channel.invokeMethod('kill', {'id': id});
      };
    onHandle(handle);

    try {
      await _channel.invokeMethod('start', {
        'id': id,
        'source': source,
      });
    } on PlatformException catch (e) {
      _androidJobs.remove(id);
      return DownloadResult(
        success: false,
        error: e.message ?? 'Could not start torrent',
      );
    }

    final result = await job.completer.future;
    if (!result.success || result.filePath == null) return result;
    final exported = await AndroidYtDlpEngine.exportFile(result.filePath!);
    return DownloadResult(
      success: exported.success,
      filePath: exported.filePath,
      uri: exported.uri,
      title: result.title,
      error: exported.error,
    );
  }

  Future<void> _onMethodCall(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, dynamic>();
    final id = args['id'] as String?;
    if (id == null) return;
    final job = _androidJobs[id];
    if (job == null) return;

    switch (call.method) {
      case 'title':
        final title = args['title'] as String?;
        if (title != null && title.isNotEmpty) job.onTitle(title);
      case 'progress':
        final name = args['name'] as String?;
        if (name != null && name.isNotEmpty) job.onTitle(name);
        job.onProgress(
          (args['progress'] as num?)?.toDouble(),
          _formatTorrentSpeed(
            (args['speed'] as num?)?.toDouble(),
            (args['peers'] as num?)?.toInt(),
            (args['dhtNodes'] as num?)?.toInt(),
          ),
          _formatEta((args['eta'] as num?)?.toInt()),
        );
      case 'complete':
        _androidJobs.remove(id);
        job.completer.complete(DownloadResult(
          success: args['success'] == true,
          filePath: args['filePath'] as String?,
          title: args['title'] as String?,
          error: args['error'] as String?,
        ));
    }
  }

  Future<DownloadResult> _downloadDesktop({
    required String source,
    required String outputFolder,
    required ProgressCallback onProgress,
    required void Function(String title) onTitle,
    required void Function(DownloadHandle handle) onHandle,
  }) async {
    final handle = _TorrentHandle();
    onHandle(handle);

    final saveDir = await _desktopSaveDir(source);
    TorrentTask? task;
    try {
      final model = await _loadModel(source, handle);
      if (model.name.isNotEmpty) onTitle(model.name);
      if (handle.wasKilled) {
        return DownloadResult(success: false);
      }

      // Library start() opens listen/DHT/LSD and may try UPnP. We do
      // not call addDHTNode or PortForwardingManager from app code.
      // Stop (not pause) as soon as the file is done or the user
      // cancels — pause still keeps sockets/DHT alive.
      task = TorrentTask.newTask(model, saveDir.path);
      _desktopTasks[source] = task;
      handle.onKill = () {
        unawaited(_stopDesktopTask(source));
      };

      final done = Completer<void>();
      final listener = task.createListener();
      listener
        ..on<TaskCompleted>((_) {
          // Pause now so we do not upload while stop()/copy run.
          try {
            task?.pause();
          } catch (_) {}
          if (!done.isCompleted) done.complete();
        })
        ..on<TaskStopped>((_) {
          if (!done.isCompleted) done.complete();
        });

      await task.start();
      if (looksLikeMagnetSource(source)) {
        final magnet = MagnetParser.parse(source);
        if (magnet != null) {
          for (final tracker in magnet.trackers) {
            task.startAnnounceUrl(tracker, model.infoHashBuffer);
          }
        }
      }

      Timer? timer;
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (handle.wasKilled) {
          timer?.cancel();
          unawaited(_stopDesktopTask(source));
          if (!done.isCompleted) done.complete();
          return;
        }
        final running = _desktopTasks[source];
        if (running == null) return;
        if (running.name.isNotEmpty) onTitle(running.name);
        final total = model.totalSize;
        final downloaded = running.downloaded ?? 0;
        final fraction = total > 0
            ? (downloaded / total).clamp(0.0, 1.0)
            : running.progress.clamp(0.0, 1.0);
        final speed = running.currentDownloadSpeed * 1000;
        final remain = total > 0 ? (total - downloaded) : 0;
        final eta = speed > 0 ? (remain / speed).round() : null;
        onProgress(fraction, _formatSpeed(speed), _formatEta(eta));
      });

      await done.future;
      timer.cancel();
      await _stopDesktopTask(source);

      if (handle.wasKilled) {
        return DownloadResult(success: false);
      }

      final primary = _desktopPrimaryFile(model, saveDir.path);
      if (primary == null || !File(primary.path).existsSync()) {
        return DownloadResult(
          success: false,
          error: 'Torrent finished but the file is missing.',
        );
      }
      await Directory(outputFolder).create(recursive: true);
      final dest = File(
        '$outputFolder${Platform.pathSeparator}${safeFileName(primary.path)}',
      );
      await File(primary.path).copy(dest.path);
      return DownloadResult(
        success: true,
        filePath: dest.path,
        title: model.name,
      );
    } catch (e) {
      await _stopDesktopTask(source);
      if (handle.wasKilled) {
        return DownloadResult(success: false);
      }
      return DownloadResult(success: false, error: e.toString());
    }
  }

  Future<TorrentModel> _loadModel(String source, _TorrentHandle handle) async {
    if (looksLikeMagnetSource(source)) {
      return _metadataFromMagnet(magnet: source, handle: handle);
    }
    return TorrentModel.parse(source);
  }

  Future<TorrentModel> _metadataFromMagnet({
    required String magnet,
    required _TorrentHandle handle,
  }) async {
    final parsed = MagnetParser.parse(magnet);
    if (parsed == null) {
      throw StateError('That magnet link is not valid.');
    }
    final downloader = MetadataDownloader.fromMagnet(magnet);
    final completer = Completer<TorrentModel>();
    final listener = downloader.createListener();
    listener
      ..on<MetaDataDownloadComplete>((event) {
        if (completer.isCompleted) return;
        try {
          final info = decode(Uint8List.fromList(event.data));
          if (info is! Map) {
            completer.completeError(
              StateError('Could not parse torrent metadata.'),
            );
            return;
          }
          completer.complete(
            TorrentParser.parseFromMap({
              'info': Map<String, dynamic>.from(info),
            }),
          );
        } catch (e) {
          completer.completeError(e);
        }
      })
      ..on<MetaDataDownloadFailed>((event) {
        if (!completer.isCompleted) {
          completer.completeError(StateError(event.error));
        }
      });
    unawaited(downloader.startDownload());
    final abort = Timer.periodic(const Duration(seconds: 1), (_) {
      if (handle.wasKilled && !completer.isCompleted) {
        completer.completeError(StateError('killed'));
      }
    });
    try {
      return await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          throw TimeoutException(
            'Could not fetch torrent metadata. If the magnet has no trackers, '
            'try again or use a magnet that includes trackers.',
          );
        },
      );
    } finally {
      abort.cancel();
      try {
        await downloader.stop();
      } catch (_) {}
    }
  }

  TorrentFileEntry? _desktopPrimaryFile(TorrentModel model, String saveDir) {
    final files = <TorrentFileEntry>[];
    for (final file in model.files) {
      if (file.isPaddingFile) continue;
      final rel = file.path.replaceAll('/', Platform.pathSeparator);
      if (rel.isEmpty) continue;
      files.add(TorrentFileEntry(
        path: '$saveDir${Platform.pathSeparator}$rel',
        size: file.length,
      ));
    }
    return pickPrimaryTorrentFile(files);
  }

  Future<Directory> _desktopSaveDir(String source) async {
    final root = await getTemporaryDirectory();
    final name = source.hashCode.toUnsigned(32).toRadixString(16);
    final dir = Directory(
      '${root.path}${Platform.pathSeparator}vidfetch_torrents'
      '${Platform.pathSeparator}$name',
    );
    await dir.create(recursive: true);
    return dir;
  }

  static bool looksLikeMagnetSource(String source) =>
      source.trim().toLowerCase().startsWith('magnet:');

  static String? _formatTorrentSpeed(
    double? bytesPerSec,
    int? peers, [
    int? dhtNodes,
  ]) {
    final speed = _formatSpeed(bytesPerSec);
    final swarm = peers == null
        ? null
        : '$peers ${peers == 1 ? 'peer' : 'peers'}';
    final dht = dhtNodes == null ? null : 'DHT $dhtNodes';
    if (speed == null) {
      if (swarm != null && dht != null) return '$swarm · $dht';
      return swarm ?? dht;
    }
    if (swarm == null) return dht == null ? speed : '$speed · $dht';
    if (peers == 0 && dht != null) return '$speed · $swarm · $dht';
    return '$speed · $swarm';
  }

  static String? _formatSpeed(double? bytesPerSec) {
    if (bytesPerSec == null || bytesPerSec <= 0) return null;
    const units = ['B/s', 'KiB/s', 'MiB/s', 'GiB/s'];
    var value = bytesPerSec;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(1)}${units[unit]}';
  }

  static String? _formatEta(int? seconds) {
    if (seconds == null || seconds < 0) return null;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m >= 60) {
      return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:'
          '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
