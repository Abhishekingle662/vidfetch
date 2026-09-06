/// Progress callback: [fraction] is 0.0–1.0 or null when unknown.
typedef ProgressCallback = void Function(
    double? fraction, String? speed, String? eta);

/// A handle to a running download that can be killed (pause/cancel).
abstract class DownloadHandle {
  bool get wasKilled;
  void kill();
}

/// Result of a finished download.
class DownloadResult {
  DownloadResult({
    required this.success,
    this.filePath,
    this.uri,
    this.title,
    this.error,
    this.fileCount,
  });

  final bool success;

  /// Display path of the resulting file (absolute on desktop, a
  /// Downloads-relative path on Android). For playlists, the first file.
  final String? filePath;

  /// Android content:// URI of the exported file, when available.
  /// For playlists, the first file.
  final String? uri;

  final String? title;
  final String? error;

  /// Number of files saved (profile/playlist downloads may be > 1).
  final int? fileCount;
}

/// A backend capable of downloading a URL with yt-dlp semantics.
abstract class DownloadEngine {
  bool get supported;

  /// Starts a download. [onHandle] fires as soon as the download starts so
  /// the caller can pause/cancel it. Returns when the download finishes.
  Future<DownloadResult> download({
    required String url,
    required String outputFolder,
    required String formatSelector,
    required ProgressCallback onProgress,
    required void Function(String title) onTitle,
    required void Function(DownloadHandle handle) onHandle,
    bool ignoreSslErrors = false,
    String? cookieFilePath,
  });
}
