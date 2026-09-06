import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'download_engine.dart';

class _ChannelDownloadHandle implements DownloadHandle {
  _ChannelDownloadHandle(this._taskId);

  final String _taskId;
  bool _killed = false;

  @override
  bool get wasKilled => _killed;

  @override
  void kill() {
    _killed = true;
    AndroidYtDlpEngine._channel.invokeMethod('cancel', {'id': _taskId});
  }
}

class _ActiveDownload {
  _ActiveDownload({
    required this.onProgress,
    required this.onTitle,
    required this.completer,
  });

  final ProgressCallback onProgress;
  final void Function(String title) onTitle;
  final Completer<DownloadResult> completer;
  bool titleReported = false;
}

/// Runs yt-dlp through the Chaquopy-embedded Python interpreter via a
/// platform channel ("vidfetch/ytdlp", implemented in MainActivity.kt).
///
/// Finished files are exported by the native side into the public
/// Downloads/VidFetch folder through MediaStore.
class AndroidYtDlpEngine implements DownloadEngine {
  AndroidYtDlpEngine() {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  static const _channel = MethodChannel('vidfetch/ytdlp');

  final Map<String, _ActiveDownload> _active = {};
  int _seq = 0;

  @override
  bool get supported => true;

  /// Opens a content:// URI with the system video player/viewer.
  static Future<bool> openUri(String uri) async {
    try {
      return await _channel.invokeMethod<bool>('openUri', {'uri': uri}) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the in-app Instagram sign-in. Returns the path of the saved
  /// cookies.txt on success, null if the user backed out.
  static Future<String?> instagramLogin() async {
    try {
      return await _channel.invokeMethod<String>('instagramLogin');
    } on PlatformException {
      return null;
    }
  }

  /// Opens the in-app YouTube / Google sign-in. Returns the path of the
  /// merged cookies.txt on success, null if the user backed out.
  static Future<String?> youtubeLogin() async {
    try {
      return await _channel.invokeMethod<String>('youtubeLogin');
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<DownloadResult> download({
    required String url,
    required String outputFolder, // unmanaged on Android; staging is native
    required String formatSelector,
    required ProgressCallback onProgress,
    required void Function(String title) onTitle,
    required void Function(DownloadHandle handle) onHandle,
    bool ignoreSslErrors = false,
    String? cookieFilePath,
  }) async {
    final id = 'a${_seq++}';
    final active = _ActiveDownload(
      onProgress: onProgress,
      onTitle: onTitle,
      completer: Completer<DownloadResult>(),
    );
    _active[id] = active;

    final handle = _ChannelDownloadHandle(id);
    onHandle(handle);

    try {
      await _channel.invokeMethod('start', {
        'id': id,
        'url': url,
        'format': formatSelector,
        'insecure': ignoreSslErrors,
        'cookies': cookieFilePath,
      });
    } on PlatformException catch (e) {
      _active.remove(id);
      return DownloadResult(
          success: false, error: 'Could not start download: ${e.message}');
    }

    return active.completer.future;
  }

  Future<void> _onMethodCall(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, dynamic>();
    final id = args['id'] as String;
    final active = _active[id];
    if (active == null) return;

    final payload =
        (jsonDecode(args['payload'] as String) as Map).cast<String, dynamic>();

    switch (call.method) {
      case 'progress':
        final downloaded = (payload['downloaded'] as num?)?.toDouble();
        final total = (payload['total'] as num?)?.toDouble();
        final fraction = (downloaded != null && total != null && total > 0)
            ? (downloaded / total).clamp(0.0, 1.0)
            : null;
        final filename = payload['filename'] as String?;
        if (filename != null && !active.titleReported) {
          active.titleReported = true;
          active.onTitle(_titleFromPath(filename));
        }
        active.onProgress(
          fraction,
          _formatSpeed((payload['speed'] as num?)?.toDouble()),
          _formatEta((payload['eta'] as num?)?.toInt()),
        );
      case 'complete':
        _active.remove(id);
        final cancelled = payload['cancelled'] == true;
        active.completer.complete(DownloadResult(
          success: payload['success'] == true,
          filePath: payload['filePath'] as String?,
          uri: payload['uri'] as String?,
          title: payload['title'] as String?,
          error: cancelled ? null : payload['error'] as String?,
          fileCount: (payload['fileCount'] as num?)?.toInt(),
        ));
    }
  }

  static String _titleFromPath(String path) {
    var name = path.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name.replaceAll('_', ' ');
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
