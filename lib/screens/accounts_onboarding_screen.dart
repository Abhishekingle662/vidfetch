import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/android_ytdlp_engine.dart';
import '../services/settings_service.dart';

/// First-run prompt to connect Instagram and/or YouTube via in-app WebView
/// sign-in. Skip is always allowed — cookies can be added later from Settings
/// or when a download needs them.
class AccountsOnboardingScreen extends StatefulWidget {
  const AccountsOnboardingScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<AccountsOnboardingScreen> createState() =>
      _AccountsOnboardingScreenState();
}

class _AccountsOnboardingScreenState extends State<AccountsOnboardingScreen> {
  bool _busy = false;

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _finish() async {
    await context.read<SettingsService>().setOnboardingDone(true);
    if (!mounted) return;
    widget.onFinished();
  }

  Future<void> _connectInstagram() async {
    if (!Platform.isAndroid || _busy) return;
    setState(() => _busy = true);
    final path = await AndroidYtDlpEngine.instagramLogin();
    if (!mounted) return;
    setState(() => _busy = false);
    if (path != null) {
      await context.read<SettingsService>().setCookieFilePath(path);
      if (mounted) _showMessage('Instagram connected');
    } else {
      _showMessage('Instagram sign-in canceled');
    }
  }

  Future<void> _connectYouTube() async {
    if (!Platform.isAndroid || _busy) return;
    setState(() => _busy = true);
    final path = await AndroidYtDlpEngine.youtubeLogin();
    if (!mounted) return;
    setState(() => _busy = false);
    if (path != null) {
      await context.read<SettingsService>().setCookieFilePath(path);
      if (mounted) _showMessage('YouTube connected');
    } else {
      _showMessage('YouTube sign-in canceled');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Connect accounts',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Sign in inside VidFetch so private Instagram posts and '
                'age-restricted YouTube videos can download. Your browser '
                'and other apps stay untouched — cookies stay in this app only.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 28),
              _AccountTile(
                icon: Icons.camera_alt_outlined,
                title: 'Instagram',
                subtitle: settings.hasInstagramCookies
                    ? 'Connected'
                    : 'Needed for private posts and profiles',
                connected: settings.hasInstagramCookies,
                enabled: !_busy && Platform.isAndroid,
                onPressed: _connectInstagram,
              ),
              const SizedBox(height: 12),
              _AccountTile(
                icon: Icons.play_circle_outline,
                title: 'YouTube',
                subtitle: settings.hasYouTubeCookies
                    ? 'Connected'
                    : 'Helps with age-restricted and member videos',
                connected: settings.hasYouTubeCookies,
                enabled: !_busy && Platform.isAndroid,
                onPressed: _connectYouTube,
              ),
              const Spacer(),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              FilledButton(
                onPressed: _busy ? null : _finish,
                child: Text(
                  settings.hasInstagramCookies || settings.hasYouTubeCookies
                      ? 'Continue'
                      : 'Skip for now',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You can connect later in Settings → Accounts & cookies.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.outline,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.connected,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool connected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: connected
            ? Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary)
            : FilledButton.tonal(
                onPressed: enabled ? onPressed : null,
                child: const Text('Sign in'),
              ),
      ),
    );
  }
}
