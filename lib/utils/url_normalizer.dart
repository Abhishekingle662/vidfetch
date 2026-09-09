import 'dart:convert';

/// Normalizes user paste input into a downloadable URL.
///
/// Accepts `magnet:?xt=urn:btih:` (hex or base32 infohash), full http(s)
/// URLs as-is, prepends `https://` for common bare host pastes (TikTok /
/// Snapchat / YouTube / Instagram), and turns Instagram usernames
/// (`mariaxzhang_`, `@mariaxzhang_`) into profile URLs.
/// Instagram `/s/` highlight share links become `/stories/highlights/<id>/`.
String? normalizeDownloadInput(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  if (looksLikeMagnetInput(trimmed)) {
    return _normalizeMagnet(trimmed);
  }

  final asUri = Uri.tryParse(trimmed);
  if (asUri != null &&
      asUri.hasScheme &&
      (asUri.scheme == 'http' || asUri.scheme == 'https')) {
    return _normalizeInstagramUrl(asUri) ?? trimmed;
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

/// Highlight albums (`/stories/highlights/<id>`) and 24h stories, including
/// `/s/` share links after [normalizeDownloadInput].
bool isInstagramStoryOrHighlightInput(String input) {
  final normalized = normalizeDownloadInput(input) ?? input.trim();
  final uri = Uri.tryParse(normalized);
  if (uri == null || !uri.hasScheme) return false;
  final host = uri.host.toLowerCase();
  if (!host.contains('instagram.com') && host != 'instagr.am') {
    return false;
  }
  final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return false;
  final first = parts.first.toLowerCase();
  return first == 'stories' || first == 's';
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

/// True when [input] starts with the magnet scheme (valid or not).
bool looksLikeMagnetInput(String input) =>
    input.trim().toLowerCase().startsWith('magnet:');

/// True when [input] is (or normalizes to) a magnet with a btih infohash.
bool isMagnetUri(String input) {
  final normalized = normalizeDownloadInput(input);
  return normalized != null && looksLikeMagnetInput(normalized);
}

/// `dn` display name from a magnet, if present.
String? magnetDisplayName(String magnet) {
  final dn = Uri.tryParse(magnet.trim())?.queryParameters['dn']?.trim();
  if (dn == null || dn.isEmpty) return null;
  return dn;
}

/// `magnet:?xt=urn:btih:<40 hex | 32 base32>` plus optional extra params.
final _btihXtRe = RegExp(
  r'^urn:btih:([A-Fa-f0-9]{40}|[A-Za-z2-7]{32})$',
  caseSensitive: false,
);

String? _normalizeMagnet(String input) {
  final uri = Uri.tryParse(input);
  if (uri == null || uri.scheme.toLowerCase() != 'magnet') return null;
  for (final entry in uri.queryParametersAll.entries) {
    final key = entry.key.toLowerCase();
    if (key != 'xt' && !key.startsWith('xt.')) continue;
    for (final value in entry.value) {
      if (_btihXtRe.hasMatch(value.trim())) return input;
    }
  }
  return null;
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
  return _normalizeInstagramUrl(uri) ?? candidate;
}

/// Instagram share links append `?igsh=…`. `/s/<base64>` highlight shares
/// decode to `highlight:<id>` and are rewritten to `/stories/highlights/<id>/`.
String? _normalizeInstagramUrl(Uri uri) {
  final host = uri.host.toLowerCase();
  if (!host.contains('instagram.com') && host != 'instagr.am') {
    return null;
  }
  final highlight = _rewriteInstagramHighlightShare(uri);
  if (highlight != null) return highlight;
  if (uri.hasQuery || uri.hasFragment) {
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      path: uri.path,
    ).toString();
  }
  return null;
}

/// `https://www.instagram.com/s/aGlnaGxpZ2h0OjE4MDkwOTQ2MDQ4MTIzOTc4`
/// is Instagram's share form of `/stories/highlights/18090946048123978/`.
String? _rewriteInstagramHighlightShare(Uri uri) {
  final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (parts.length < 2 || parts.first.toLowerCase() != 's') {
    return null;
  }
  final highlightId = decodeInstagramHighlightShareId(parts[1]);
  if (highlightId == null) return null;
  return 'https://www.instagram.com/stories/highlights/$highlightId/';
}

/// Decodes an Instagram `/s/` share token. Returns the numeric highlight id
/// when the payload is `highlight:<id>`, otherwise null.
String? decodeInstagramHighlightShareId(String raw) {
  var token = raw.split('?').first.trim();
  if (token.isEmpty) return null;
  token = token.replaceAll('-', '+').replaceAll('_', '/');
  final pad = (4 - token.length % 4) % 4;
  token = token.padRight(token.length + pad, '=');
  try {
    final text = utf8.decode(base64.decode(token), allowMalformed: false);
    final match = RegExp(r'^highlight:(\d+)$').firstMatch(text);
    return match?.group(1);
  } on FormatException {
    return null;
  }
}

final _instagramUsernameRe = RegExp(r'^@?([A-Za-z0-9._]{1,30})$');

const _instagramReservedPaths = {
  'p',
  'tv',
  'reel',
  'reels',
  'stories',
  's',
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
