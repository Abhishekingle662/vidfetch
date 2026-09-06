import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../services/android_ytdlp_engine.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _pickFolder(BuildContext context) async {
    final settings = context.read<SettingsService>();
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose download folder',
    );
    if (path != null) {
      await settings.setDownloadFolder(path);
    }
  }

  Future<void> _pickYtDlp(BuildContext context) async {
    final settings = context.read<SettingsService>();
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Locate the yt-dlp executable',
    );
    final path = result?.files.single.path;
    if (path != null) {
      await settings.setYtDlpPath(path);
    }
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _instagramLogin(BuildContext context) async {
    final settings = context.read<SettingsService>();
    final path = await AndroidYtDlpEngine.instagramLogin();
    if (!context.mounted) return;
    if (path != null) {
      await settings.setCookieFilePath(path);
      if (context.mounted) {
        _showMessage(context, 'Signed in — Instagram cookies saved');
      }
    } else {
      _showMessage(context, 'Sign-in was canceled');
    }
  }

  Future<void> _youtubeLogin(BuildContext context) async {
    final settings = context.read<SettingsService>();
    final path = await AndroidYtDlpEngine.youtubeLogin();
    if (!context.mounted) return;
    if (path != null) {
      await settings.setCookieFilePath(path);
      if (context.mounted) {
        _showMessage(context, 'Signed in — YouTube cookies saved');
      }
    } else {
      _showMessage(context, 'Sign-in was canceled');
    }
  }

  Future<void> _importCookiesFile(BuildContext context) async {
    final settings = context.read<SettingsService>();
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select a Netscape cookies.txt file',
    );
    final picked = result?.files.single.path;
    if (picked == null || !context.mounted) return;
    try {
      // Copy into app storage so the original can be deleted safely.
      final dir = await getApplicationSupportDirectory();
      final dest = File('${dir.path}${Platform.pathSeparator}cookies.txt');
      await File(picked).copy(dest.path);
      await settings.setCookieFilePath(dest.path);
      if (context.mounted) _showMessage(context, 'Cookies imported');
    } catch (e) {
      if (context.mounted) _showMessage(context, 'Could not import: $e');
    }
  }

  Future<void> _clearCookies(BuildContext context) async {
    final settings = context.read<SettingsService>();
    final path = settings.cookieFilePath;
    if (path.isNotEmpty) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    await settings.setCookieFilePath('');
    if (context.mounted) _showMessage(context, 'Cookies cleared');
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), centerTitle: false),
      body: ListView(
        children: [
          const _SectionHeader('Downloads'),
          if (Platform.isAndroid)
            const ListTile(
              leading: Icon(Icons.folder_outlined),
              title: Text('Download folder'),
              subtitle: Text('Downloads/VidFetch (public Downloads folder)'),
            )
          else
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Download folder'),
              subtitle: Text(settings.downloadFolder),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickFolder(context),
            ),
          ListTile(
            leading: const Icon(Icons.high_quality_outlined),
            title: const Text('Video quality'),
            subtitle: Text(Platform.isAndroid
                ? '${settings.quality} · ffmpeg merge enabled'
                : settings.quality),
            trailing: DropdownButton<String>(
              value: settings.quality,
              underline: const SizedBox.shrink(),
              items: VideoQuality.all
                  .map((q) => DropdownMenuItem(value: q, child: Text(q)))
                  .toList(),
              onChanged: (q) {
                if (q != null) settings.setQuality(q);
              },
            ),
          ),
          const _SectionHeader('Notifications'),
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('Download notifications'),
            subtitle: const Text('Show progress and completion alerts'),
            value: settings.notificationsEnabled,
            onChanged: settings.setNotificationsEnabled,
          ),
          const _SectionHeader('Accounts & cookies'),
          if (Platform.isAndroid) ...[
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Sign in to Instagram'),
              subtitle: Text(
                settings.hasInstagramCookies
                    ? 'Connected — private posts should work'
                    : 'Needed for private or login-required posts',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _instagramLogin(context),
            ),
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: const Text('Sign in to YouTube'),
              subtitle: Text(
                settings.hasYouTubeCookies
                    ? 'Connected — age-restricted videos should work'
                    : 'Helps with age-restricted and members-only videos',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _youtubeLogin(context),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.cookie_outlined),
            title: const Text('Import cookies.txt'),
            subtitle: Text(
              settings.hasCookies
                  ? 'Using ${settings.resolvedCookieFilePath.split(Platform.pathSeparator).last}'
                  : 'Netscape-format cookies exported from your browser '
                      '(covers Instagram, YouTube and other logins)',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _importCookiesFile(context),
          ),
          if (settings.cookieFilePath.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Clear saved cookies'),
              onTap: () => _clearCookies(context),
            ),
          const _SectionHeader('Advanced'),
          SwitchListTile(
            secondary: const Icon(Icons.gpp_maybe_outlined),
            title: const Text('Ignore SSL certificate errors'),
            subtitle: const Text(
              'Turn on if downloads fail with SSL/certificate errors '
              '(common with antivirus or proxy software that inspects '
              'HTTPS). Less secure.',
            ),
            value: settings.ignoreSslErrors,
            onChanged: settings.setIgnoreSslErrors,
          ),
          if (!Platform.isAndroid) ...[
          ListTile(
            leading: const Icon(Icons.terminal_outlined),
            title: const Text('yt-dlp path'),
            subtitle: Text(
              settings.ytDlpPath.isEmpty
                  ? 'Auto-detect (bundled or on PATH)'
                  : settings.ytDlpPath,
            ),
            trailing: settings.ytDlpPath.isEmpty
                ? const Icon(Icons.chevron_right)
                : IconButton(
                    tooltip: 'Reset to auto-detect',
                    icon: const Icon(Icons.close),
                    onPressed: () => settings.setYtDlpPath(''),
                  ),
            onTap: () => _pickYtDlp(context),
          ),
          ],
          const _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('VidFetch'),
            subtitle: Text(
              'Downloads videos with yt-dlp from YouTube, Instagram, TikTok, '
              'Snapchat Spotlight, X, Facebook, Vimeo and many more sites.\n\n'
              'Only download content you have the right to save.',
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
