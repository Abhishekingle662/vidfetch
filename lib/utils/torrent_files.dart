/// True when a magnet lists at least one `tr` / `tr.N` tracker.
bool magnetHasTrackers(String magnet) {
  final uri = Uri.tryParse(magnet.trim());
  if (uri == null) return false;
  for (final entry in uri.queryParametersAll.entries) {
    final key = entry.key.toLowerCase();
    if (key != 'tr' && !key.startsWith('tr.')) continue;
    if (entry.value.any((v) => v.trim().isNotEmpty)) return true;
  }
  return false;
}

class TorrentFileEntry {
  const TorrentFileEntry({required this.path, required this.size});

  final String path;
  final int size;
}

const _videoExtensions = {
  '.mp4',
  '.mkv',
  '.webm',
  '.avi',
  '.mov',
  '.m4v',
  '.ts',
  '.wmv',
  '.flv',
  '.mpeg',
  '.mpg',
  '.m2ts',
};

bool isLikelyVideoPath(String path) {
  final name = path.split(RegExp(r'[\\/]')).last.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return _videoExtensions.contains(name.substring(dot));
}

/// Largest video, else the sole file, else the largest file.
TorrentFileEntry? pickPrimaryTorrentFile(Iterable<TorrentFileEntry> files) {
  final usable = files.where((f) => f.size > 0 && f.path.isNotEmpty).toList();
  if (usable.isEmpty) return null;
  if (usable.length == 1) return usable.first;
  final videos = usable.where((f) => isLikelyVideoPath(f.path)).toList();
  final pool = videos.isNotEmpty ? videos : usable;
  pool.sort((a, b) => b.size.compareTo(a.size));
  return pool.first;
}

/// True when bencoded torrent bytes include an announce list/URL.
bool torrentBytesHaveAnnounce(List<int> bytes) {
  return String.fromCharCodes(bytes).contains('announce');
}

String safeFileName(String raw) {
  var name = raw.split(RegExp(r'[\\/]')).last.trim();
  name = name.replaceAll(RegExp(r'[\x00-\x1f]'), '');
  if (name.isEmpty || name == '.' || name == '..') return 'download';
  return name;
}
