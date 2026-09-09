import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/android_ytdlp_engine.dart';
import '../services/download_manager.dart';
import '../services/settings_service.dart';
import '../utils/url_normalizer.dart';
import '../widgets/download_tile.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Returns false if the user canceled; true to proceed with download.
  Future<bool> _ensureCookiesForUrl(String url) async {
    final settings = context.read<SettingsService>();

    if (looksLikeInstagramInput(url) && !settings.hasInstagramCookies) {
      final isProfile = isInstagramProfileInput(url);
      final isHighlight = isInstagramStoryOrHighlightInput(url);
      return _promptPlatformLogin(
        title: isHighlight
            ? 'Instagram login needed for highlights'
            : isProfile
                ? 'Instagram login needed for profiles'
                : 'Instagram login needed',
        androidBody: isHighlight
            ? 'Highlighted stories and 24h stories need Instagram cookies. '
                'Sign in now so VidFetch can save the videos in that album.'
            : isProfile
                ? 'Downloading a whole profile needs Instagram cookies. '
                    'VidFetch saves highlight albums plus the latest 50 posts. '
                    'Sign in now so VidFetch can save them.'
                : 'This post may require Instagram cookies. Sign in now so '
                    'VidFetch can save them and download private or '
                    'login-required videos.',
        desktopBody: isHighlight
            ? 'Highlighted stories and 24h stories need Instagram cookies. '
                'Import a Netscape cookies.txt from Settings, then try again.'
            : isProfile
                ? 'Downloading a whole profile needs Instagram cookies. '
                    'VidFetch saves highlight albums plus the latest 50 posts. '
                    'Import a Netscape cookies.txt (e.g. cookies_ins.txt '
                    'in your VidFetch download folder) from Settings.'
                : 'This post may require Instagram cookies. Import a '
                    'Netscape cookies.txt (e.g. cookies_ins.txt in your '
                    'VidFetch download folder) from Settings, then try again.',
        onAndroidSignIn: () async {
          final path = await AndroidYtDlpEngine.instagramLogin();
          if (!mounted) return false;
          if (path != null) {
            await settings.setCookieFilePath(path);
            _showMessage('Signed in — Instagram cookies saved');
            return true;
          }
          _showMessage('Sign-in was canceled');
          return false;
        },
      );
    }

    if (looksLikeYouTubeInput(url) && !settings.hasYouTubeCookies) {
      return _promptPlatformLogin(
        title: 'YouTube login recommended',
        androidBody:
            'Age-restricted or members-only YouTube videos need a signed-in '
            'session. Sign in now so VidFetch can save cookies, or download '
            'anyway if the video is public.',
        desktopBody:
            'Age-restricted or members-only YouTube videos need cookies. '
            'Import a Netscape cookies.txt from Settings, then try again.',
        onAndroidSignIn: () async {
          final path = await AndroidYtDlpEngine.youtubeLogin();
          if (!mounted) return false;
          if (path != null) {
            await settings.setCookieFilePath(path);
            _showMessage('Signed in — YouTube cookies saved');
            return true;
          }
          _showMessage('Sign-in was canceled');
          return false;
        },
      );
    }

    return true;
  }

  /// Dialog: Download anyway / Sign in (Android) or Open Settings (desktop).
  /// Returns whether to continue queuing the download.
  Future<bool> _promptPlatformLogin({
    required String title,
    required String androidBody,
    required String desktopBody,
    required Future<bool> Function() onAndroidSignIn,
  }) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(Platform.isAndroid ? androidBody : desktopBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download anyway'),
          ),
          if (Platform.isAndroid)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Sign in'),
            )
          else
            FilledButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Open Settings'),
            ),
        ],
      ),
    );
    if (!mounted) return false;
    if (proceed == true) return true;
    if (proceed == null) return false;

    if (Platform.isAndroid) {
      return onAndroidSignIn();
    }
    _showMessage('Import cookies.txt from Settings → Accounts & cookies');
    return false;
  }

  Future<void> _startDownload() async {
    final url = _urlController.text.trim();
    final manager = context.read<DownloadManager>();

    if (looksLikeMagnetInput(url)) {
      if (normalizeDownloadInput(url) == null) {
        _showMessage('That magnet link is missing a valid BitTorrent infohash.');
        return;
      }
    } else if (!await _ensureCookiesForUrl(url)) {
      return;
    }
    if (!mounted) return;

    final error = manager.addUrl(_urlController.text);
    if (error != null) {
      _showMessage(error);
    } else {
      _urlController.clear();
      _showMessage('Added to queue');
    }
  }

  Future<void> _pickTorrentFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['torrent'],
      dialogTitle: 'Select a .torrent file',
    );
    final path = result?.files.single.path;
    if (path == null) return;
    if (!mounted) return;
    final error = context.read<DownloadManager>().addTorrentFile(path);
    _showMessage(error ?? 'Added to queue');
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      _urlController.text = data.text!.trim();
    }
  }

  Future<void> _pickBatchFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
      dialogTitle: 'Select a .txt file with one URL per line',
    );
    final path = result?.files.single.path;
    if (path == null) return;
    if (!mounted) return;
    try {
      final added =
          await context.read<DownloadManager>().addBatchFromFile(path);
      _showMessage(added > 0
          ? 'Added $added link(s) to the queue'
          : 'No valid links found in that file');
    } catch (e) {
      _showMessage('Could not read file: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<DownloadManager>();
    final settings = context.watch<SettingsService>();
    final active = manager.activeTasks;

    return Scaffold(
      appBar: AppBar(
        title: const Text('VidFetch'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!manager.engineSupported)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Downloads are not supported on this platform yet.',
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    hintText: 'Paste a URL, magnet, or Instagram @username',
                    prefixIcon: const Icon(Icons.link),
                    suffixIcon: IconButton(
                      tooltip: 'Paste from clipboard',
                      icon: const Icon(Icons.content_paste),
                      onPressed: _pasteFromClipboard,
                    ),
                  ),
                  onSubmitted: (_) => _startDownload(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _startDownload,
                        icon: const Icon(Icons.download),
                        label: const Text('Download'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _pickBatchFile,
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('Batch (.txt)'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 16),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _pickTorrentFile,
                    icon: const Icon(Icons.attachment),
                    label: const Text('Add .torrent file'),
                  ),
                ),
                Text(
                  'Quality: ${settings.quality}  ·  Saving to '
                  '${Platform.isAndroid ? 'Downloads/VidFetch' : settings.downloadFolder}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ],
            ),
          ),
          if (active.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                'Active downloads',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...active.map((t) => DownloadTile(task: t)),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Column(
                children: [
                  Icon(
                    Icons.movie_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Paste a link from YouTube, Instagram, TikTok,\n'
                    'Snapchat Spotlight, X, Facebook…\n'
                    'an Instagram highlight, @username, or a magnet.\n'
                    'Use Add .torrent file for torrent files.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
