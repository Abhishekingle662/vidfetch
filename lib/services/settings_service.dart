import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VideoQuality {
  static const best = 'Best';
  static const p1080 = '1080p';
  static const p720 = '720p';

  static const all = [best, p1080, p720];

  /// Maps a quality label to a yt-dlp format selector (desktop: ffmpeg is
  /// assumed available, so split video+audio formats can be merged).
  static String formatFor(String quality) {
    switch (quality) {
      case p1080:
        return 'bestvideo[height<=1080]+bestaudio/best[height<=1080]/best';
      case p720:
        return 'bestvideo[height<=720]+bestaudio/best[height<=720]/best';
      case best:
      default:
        return 'bestvideo+bestaudio/best';
    }
  }

  /// Prefer progressive A+V so Instagram/TikTok work without a merge.
  /// YouTube adaptive merge (`bestvideo+bestaudio`) is appended only in
  /// Python when a working ffmpeg is detected.
  static String androidFormatFor(String quality) {
    switch (quality) {
      case p1080:
        return 'best[height<=1080][vcodec!=none][acodec!=none]/'
            'best[vcodec!=none][acodec!=none]/best';
      case p720:
        return 'best[height<=720][vcodec!=none][acodec!=none]/'
            'best[vcodec!=none][acodec!=none]/best';
      case best:
      default:
        return 'best[vcodec!=none][acodec!=none]/best';
    }
  }
}

class SettingsService extends ChangeNotifier {
  SettingsService(this._prefs) {
    _downloadFolder = _prefs.getString(_kFolder) ?? _defaultFolder();
    _quality = _prefs.getString(_kQuality) ?? VideoQuality.best;
    _notificationsEnabled = _prefs.getBool(_kNotifications) ?? true;
    _ytDlpPath = _prefs.getString(_kYtDlpPath) ?? '';
    _ignoreSslErrors = _prefs.getBool(_kIgnoreSsl) ?? false;
    _cookieFilePath = _prefs.getString(_kCookieFile) ?? '';
    _onboardingDone = _prefs.getBool(_kOnboardingDone) ?? false;
  }

  static const _kFolder = 'download_folder';
  static const _kQuality = 'quality';
  static const _kNotifications = 'notifications_enabled';
  static const _kYtDlpPath = 'ytdlp_path';
  static const _kIgnoreSsl = 'ignore_ssl_errors';
  static const _kCookieFile = 'cookie_file_path';
  static const _kOnboardingDone = 'accounts_onboarding_done';

  final SharedPreferences _prefs;

  late String _downloadFolder;
  late String _quality;
  late bool _notificationsEnabled;
  late String _ytDlpPath;
  late bool _ignoreSslErrors;
  late String _cookieFilePath;
  late bool _onboardingDone;

  String get downloadFolder => _downloadFolder;
  String get quality => _quality;
  bool get notificationsEnabled => _notificationsEnabled;

  /// Optional user-provided path to the yt-dlp executable.
  String get ytDlpPath => _ytDlpPath;

  /// Skip TLS certificate verification. Needed when antivirus/proxy software
  /// (e.g. Norton) intercepts HTTPS with its own certificate.
  bool get ignoreSslErrors => _ignoreSslErrors;

  /// Netscape cookies.txt passed to yt-dlp for private/age-restricted
  /// content (e.g. Instagram / YouTube login). Empty = no cookies.
  String get cookieFilePath => _cookieFilePath;

  /// First-run accounts onboarding has been completed or skipped.
  bool get onboardingDone => _onboardingDone;

  /// Cookie file actually used for downloads: the configured path if it
  /// exists, otherwise a cookies file found next to the download folder
  /// (`cookies.txt` preferred, then `cookies_ins.txt`). Empty = none available.
  /// A single Netscape cookies.txt can hold Instagram + YouTube domains.
  String get resolvedCookieFilePath {
    if (_cookieFilePath.isNotEmpty && File(_cookieFilePath).existsSync()) {
      return _cookieFilePath;
    }
    for (final name in const ['cookies.txt', 'cookies_ins.txt']) {
      final candidate =
          '$_downloadFolder${Platform.pathSeparator}$name';
      if (File(candidate).existsSync()) return candidate;
    }
    return '';
  }

  bool get hasCookies => resolvedCookieFilePath.isNotEmpty;

  /// True when the active cookie jar has Instagram domain rows.
  bool get hasInstagramCookies =>
      _cookieFileContainsDomain(const ['.instagram.com', 'instagram.com']);

  /// True when the active cookie jar has YouTube / Google domain rows.
  bool get hasYouTubeCookies => _cookieFileContainsDomain(const [
        '.youtube.com',
        'youtube.com',
        '.google.com',
        'google.com',
      ]);

  bool _cookieFileContainsDomain(List<String> domains) {
    final path = resolvedCookieFilePath;
    if (path.isEmpty) return false;
    try {
      final text = File(path).readAsStringSync().toLowerCase();
      for (final d in domains) {
        if (text.contains(d.toLowerCase())) return true;
      }
    } catch (_) {}
    return false;
  }

  static String _defaultFolder() {
    if (Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? 'C:\\';
      return '$home\\Downloads\\VidFetch';
    }
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Download/VidFetch';
    }
    final home = Platform.environment['HOME'] ?? '/tmp';
    return '$home/Downloads/VidFetch';
  }

  Future<void> setDownloadFolder(String folder) async {
    _downloadFolder = folder;
    await _prefs.setString(_kFolder, folder);
    notifyListeners();
  }

  Future<void> setQuality(String quality) async {
    _quality = quality;
    await _prefs.setString(_kQuality, quality);
    notifyListeners();
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    _notificationsEnabled = enabled;
    await _prefs.setBool(_kNotifications, enabled);
    notifyListeners();
  }

  Future<void> setYtDlpPath(String path) async {
    _ytDlpPath = path;
    await _prefs.setString(_kYtDlpPath, path);
    notifyListeners();
  }

  Future<void> setIgnoreSslErrors(bool value) async {
    _ignoreSslErrors = value;
    await _prefs.setBool(_kIgnoreSsl, value);
    notifyListeners();
  }

  Future<void> setCookieFilePath(String path) async {
    _cookieFilePath = path;
    await _prefs.setString(_kCookieFile, path);
    notifyListeners();
  }

  Future<void> setOnboardingDone(bool done) async {
    _onboardingDone = done;
    await _prefs.setBool(_kOnboardingDone, done);
    notifyListeners();
  }
}
