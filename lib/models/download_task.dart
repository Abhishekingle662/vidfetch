enum DownloadKind { video, torrent }

enum DownloadStatus {
  queued,
  fetching,
  downloading,
  paused,
  completed,
  failed,
  canceled,
}

extension DownloadStatusX on DownloadStatus {
  bool get isActive =>
      this == DownloadStatus.fetching || this == DownloadStatus.downloading;

  bool get isFinished =>
      this == DownloadStatus.completed ||
      this == DownloadStatus.failed ||
      this == DownloadStatus.canceled;

  String get label {
    switch (this) {
      case DownloadStatus.queued:
        return 'Queued';
      case DownloadStatus.fetching:
        return 'Starting…';
      case DownloadStatus.downloading:
        return 'Downloading';
      case DownloadStatus.paused:
        return 'Paused';
      case DownloadStatus.completed:
        return 'Completed';
      case DownloadStatus.failed:
        return 'Failed';
      case DownloadStatus.canceled:
        return 'Canceled';
    }
  }
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.url,
    required this.quality,
    required this.destinationFolder,
    this.kind = DownloadKind.video,
    this.torrentFilePath,
  });

  final String id;
  final String url;
  final String quality;
  final String destinationFolder;
  final DownloadKind kind;

  /// Local path of a picked `.torrent` file, when [kind] is torrent.
  final String? torrentFilePath;

  String get torrentSource => torrentFilePath ?? url;

  DownloadStatus status = DownloadStatus.queued;

  /// 0.0 – 1.0, or null when unknown.
  double? progress;
  String? speed;
  String? eta;

  /// Title extracted from yt-dlp output (falls back to the URL).
  String? title;

  /// Absolute path of the resulting file once known (Downloads-relative
  /// display path on Android).
  String? filePath;

  /// Android content:// URI of the exported file, when available.
  String? uri;

  String? error;

  String get displayName {
    if (title != null && title!.isNotEmpty) return title!;
    if (filePath != null) {
      final name = filePath!.split(RegExp(r'[\\/]')).last;
      if (name.isNotEmpty) return name;
    }
    return url;
  }
}
