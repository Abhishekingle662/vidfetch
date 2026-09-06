import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/url_normalizer.dart';
import 'download_engine.dart';

class YtDlpNotFoundException implements Exception {
  const YtDlpNotFoundException(this.message);
  final String message;

  @override
  String toString() => message;
}

class _ProcessDownloadHandle implements DownloadHandle {
  _ProcessDownloadHandle(this._process);

  final Process _process;
  bool _killed = false;

  @override
  bool get wasKilled => _killed;

  @override
  void kill() {
    _killed = true;
    _process.kill();
  }
}

/// Runs yt-dlp as an external process and parses its progress output.
///
/// Used on desktop platforms (Windows/Linux/macOS), where yt-dlp is located
/// on PATH, next to the app executable, or via an explicit override from
/// settings.
class YtDlpEngine implements DownloadEngine {
  YtDlpEngine({this.executableOverride = ''});

  /// User-configured absolute path to yt-dlp (may be empty).
  String executableOverride;

  @override
  bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static final _progressRe = RegExp(
      r'\[download\]\s+(\d+(?:\.\d+)?)%(?:.*?at\s+(\S+))?(?:.*?ETA\s+(\S+))?');
  static final _destinationRe = RegExp(r'\[download\] Destination:\s+(.+)$');
  static final _mergerRe = RegExp(r'\[Merger\] Merging formats into "(.+)"');
  static final _alreadyRe =
      RegExp(r'\[download\]\s+(.+?) has already been downloaded');
  static final _titleRe = RegExp(r'\[download\] Destination:\s+.*[\\/](.+)\.\w+$');
  static final _playlistItemRe =
      RegExp(r'\[download\] Downloading item (\d+) of (\d+)');

  String? _cachedExecutable;

  /// Locates the yt-dlp executable, throwing [YtDlpNotFoundException] when
  /// it cannot be found.
  Future<String> _resolveExecutable() async {
    if (executableOverride.trim().isNotEmpty) {
      if (await File(executableOverride.trim()).exists()) {
        return executableOverride.trim();
      }
      throw YtDlpNotFoundException(
          'yt-dlp not found at the configured path:\n$executableOverride');
    }

    if (_cachedExecutable != null) return _cachedExecutable!;

    final exeName = Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';

    // 1. Next to the app executable (bundled).
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = '$appDir${Platform.pathSeparator}$exeName';
    if (await File(bundled).exists()) {
      _cachedExecutable = bundled;
      return bundled;
    }

    // 2. On PATH.
    try {
      final probe = await Process.run(exeName, ['--version']);
      if (probe.exitCode == 0) {
        _cachedExecutable = exeName;
        return exeName;
      }
    } on ProcessException {
      // fall through
    }

    throw const YtDlpNotFoundException(
        'yt-dlp was not found. Install it (winget install yt-dlp, or '
        'pip install yt-dlp), place yt-dlp.exe next to VidFetch.exe, or set '
        'its path in Settings.');
  }

  /// Directory passed to `--plugin-dirs` (contains `vidfetch/yt_dlp_plugins/…`).
  /// Walks up from the executable so Debug builds find the repo `plugins/` folder.
  String? _resolvePluginDirs() {
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 10; i++) {
      final candidate =
          Directory('${dir.path}${Platform.pathSeparator}plugins');
      final marker = File(
        '${candidate.path}${Platform.pathSeparator}vidfetch'
        '${Platform.pathSeparator}yt_dlp_plugins'
        '${Platform.pathSeparator}extractor'
        '${Platform.pathSeparator}vidfetch_instagram_user.py',
      );
      if (marker.existsSync()) return candidate.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
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
    final String exe;
    try {
      exe = await _resolveExecutable();
    } on YtDlpNotFoundException catch (e) {
      return DownloadResult(success: false, error: e.message);
    }

    await Directory(outputFolder).create(recursive: true);

    final pluginDirs = _resolvePluginDirs();
    final isIgProfile = isInstagramProfileInput(url);
    final isIgStory = isInstagramStoryOrHighlightInput(url);

    final args = <String>[
      '--newline',
      '--no-mtime',
      if (ignoreSslErrors) '--no-check-certificate',
      if (cookieFilePath != null) ...['--cookies', cookieFilePath],
      if (pluginDirs != null) ...['--plugin-dirs', pluginDirs],
      // Posts are capped inside the profile plugin so highlight albums
      // are not truncated by --playlist-end.
      if (isIgProfile || isIgStory) '--ignore-errors',
      '--continue', // resume partially downloaded files
      '--no-overwrites',
      '--restrict-filenames',
      '-f', formatSelector,
      // Include id so playlist/carousel items with the same title don't clash.
      '-o',
      '$outputFolder${Platform.pathSeparator}%(title)s_%(id)s.%(ext)s',
      url,
    ];

    final Process process;
    try {
      process = await Process.start(exe, args);
    } on ProcessException catch (e) {
      return DownloadResult(
          success: false, error: 'Could not start yt-dlp: ${e.message}');
    }

    final handle = _ProcessDownloadHandle(process);
    onHandle(handle);

    String? filePath;
    final errBuffer = StringBuffer();

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final progress = _progressRe.firstMatch(line);
      if (progress != null) {
        final pct = double.tryParse(progress.group(1) ?? '');
        onProgress(
          pct != null ? pct / 100.0 : null,
          progress.group(2),
          progress.group(3),
        );
        return;
      }

      final playlistItem = _playlistItemRe.firstMatch(line);
      if (playlistItem != null) {
        final cur = playlistItem.group(1);
        final total = playlistItem.group(2);
        onTitle('Profile download ($cur/$total)');
      }

      final dest = _destinationRe.firstMatch(line);
      if (dest != null) {
        filePath = dest.group(1)!.trim();
        final title = _titleRe.firstMatch(line)?.group(1);
        if (title != null) onTitle(title);
        return;
      }

      final merged = _mergerRe.firstMatch(line);
      if (merged != null) {
        filePath = merged.group(1)!.trim();
        return;
      }

      final already = _alreadyRe.firstMatch(line);
      if (already != null) {
        filePath = already.group(1)!.trim();
        onProgress(1.0, null, null);
      }
    }).asFuture<void>();

    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.startsWith('ERROR')) errBuffer.writeln(line);
    }).asFuture<void>();

    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);

    if (handle.wasKilled) {
      // Caller decides whether this was a pause or a cancel.
      return DownloadResult(success: false, filePath: filePath);
    }

    if (exitCode == 0) {
      return DownloadResult(success: true, filePath: filePath);
    }

    var error = errBuffer.toString().trim();
    if (error.isEmpty) error = 'yt-dlp exited with code $exitCode';
    return DownloadResult(success: false, filePath: filePath, error: error);
  }
}
