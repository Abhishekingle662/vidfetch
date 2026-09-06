/// Normalizes user paste input into a downloadable URL.
///
/// Accepts full http(s) URLs as-is, prepends `https://` for common bare
/// host pastes (TikTok / Snapchat / YouTube / Instagram), and turns
/// Instagram usernames (`mariaxzhang_`, `@mariaxzhang_`) into profile URLs.
String? normalizeDownloadInput(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  final asUri = Uri.tryParse(trimmed);
  if (asUri != null &&
      asUri.hasScheme &&
      (asUri.scheme == 'http' || asUri.scheme == 'https')) {
    return _stripInstagramShareParams(asUri) ?? trimmed;
  }

  final withHttps = _httpsForBareHost(trimmed);
  if (withHttps != null) return withHttps;

  final username = _instagramUsername(trimmed);
  if (username != null) {
    return 'https://www.instagram.com/$username/';
  }

  return null;
}

/// True when [input] is (or normalizes to) an Instagram profile URL / username,
/// not a single post/reel/story link.
bool isInstagramProfileInput(String input) {
  final normalized = normalizeDownloadInput(input) ?? input.trim();
  final uri = Uri.tryParse(normalized);
  if (uri == null || !uri.hasScheme) {
    return _instagramUsername(input.trim()) != null;
  }
  final host = uri.host.toLowerCase();
  if (!host.contains('instagram.com') && host != 'instagr.am') {
    return false;
  }
  final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (parts.length != 1) return false;
  return !_instagramReservedPaths.contains(parts.first.toLowerCase());
}

bool looksLikeInstagramInput(String input) {
  final trimmed = input.trim();
  if (_instagramUsername(trimmed) != null) return true;
  final host = _hostOf(trimmed);
  return host.contains('instagram.com') || host == 'instagr.am';
}

bool looksLikeYouTubeInput(String input) {
  final host = _hostOf(input);
  return host.contains('youtube.com') ||
      host == 'youtu.be' ||
      host.contains('youtube-nocookie.com') ||
      host == 'm.youtube.com';
}

bool looksLikeTikTokInput(String input) {
  final host = _hostOf(input);
  return host == 'tiktok.com' ||
      host.endsWith('.tiktok.com') ||
      host == 'vm.tiktok.com' ||
      host == 'vt.tiktok.com';
}

/// Snapchat Spotlight (the only Snapchat form yt-dlp supports).
bool looksLikeSnapchatInput(String input) {
  final host = _hostOf(input);
  return host == 'snapchat.com' || host.endsWith('.snapchat.com');
}

String _hostOf(String input) {
  final normalized = normalizeDownloadInput(input) ?? input.trim();
  return Uri.tryParse(normalized)?.host.toLowerCase() ?? '';
}

/// `vm.tiktok.com/ABC` / `www.snapchat.com/spotlight/…` pasted without a scheme.
String? _httpsForBareHost(String input) {
  final lower = input.toLowerCase();
  const prefixes = <String>[
    'tiktok.com',
    'www.tiktok.com',
    'm.tiktok.com',
    'vm.tiktok.com',
    'vt.tiktok.com',
    'snapchat.com',
    'www.snapchat.com',
    't.snapchat.com',
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtu.be',
    'instagram.com',
    'www.instagram.com',
    'instagr.am',
  ];
  final matched = prefixes.any(
    (h) => lower == h || lower.startsWith('$h/') || lower.startsWith('$h?'),
  );
  if (!matched) return null;
  final candidate = 'https://$input';
  final uri = Uri.tryParse(candidate);
  if (uri == null || uri.host.isEmpty) return null;
  return _stripInstagramShareParams(uri) ?? candidate;
}

/// Instagram share links append `?igsh=…` (and similar). yt-dlp's
/// InstagramUserIE regex treats `[^/]+` as the username, so the query string
/// gets baked into the id and profile resolve fails / 429s.
String? _stripInstagramShareParams(Uri uri) {
  final host = uri.host.toLowerCase();
  if (!host.contains('instagram.com') && host != 'instagr.am') {
    return null;
  }
  if (uri.hasQuery || uri.hasFragment) {
    return uri.replace(query: '', fragment: '').toString();
  }
  return null;
}

final _instagramUsernameRe = RegExp(r'^@?([A-Za-z0-9._]{1,30})$');

const _instagramReservedPaths = {
  'p',
  'tv',
  'reel',
  'reels',
  'stories',
  'explore',
  'accounts',
  'about',
  'legal',
  'direct',
  'share',
  'developer',
  'ids',
  'following',
  'followers',
  'tagged',
  'guide',
  'guides',
  'live',
};

String? _instagramUsername(String input) {
  final match = _instagramUsernameRe.firstMatch(input);
  if (match == null) return null;
  final name = match.group(1)!;
  if (_instagramReservedPaths.contains(name.toLowerCase())) return null;
  // Avoid treating obvious non-handles (e.g. pure numbers that are unlikely
  // paste targets) — Instagram allows them, so keep permissive.
  return name;
}
