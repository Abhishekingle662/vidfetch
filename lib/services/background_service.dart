import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';

/// Keeps the app alive on Android while downloads are running by holding a
/// foreground service with a persistent notification. On desktop this is a
/// no-op: yt-dlp child processes keep running as long as the app is open,
/// including when minimized.
class BackgroundKeeper {
  static final BackgroundKeeper instance = BackgroundKeeper._();
  BackgroundKeeper._();

  final _service = FlutterBackgroundService();
  bool _configured = false;

  Future<void> init() async {
    if (!Platform.isAndroid || _configured) return;
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: backgroundServiceEntry,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'vidfetch_service',
        initialNotificationTitle: 'VidFetch',
        initialNotificationContent: 'Downloads running in background',
        foregroundServiceNotificationId: 900,
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );
    _configured = true;
  }

  Future<void> onDownloadsActive(int activeCount) async {
    if (!Platform.isAndroid || !_configured) return;
    if (!await _service.isRunning()) {
      await _service.startService();
    }
    _service.invoke('update', {'active': activeCount});
  }

  Future<void> onDownloadsIdle() async {
    if (!Platform.isAndroid || !_configured) return;
    if (await _service.isRunning()) {
      _service.invoke('stop');
    }
  }
}

@pragma('vm:entry-point')
Future<void> backgroundServiceEntry(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('update').listen((event) {
      final active = event?['active'] ?? 0;
      service.setForegroundNotificationInfo(
        title: 'VidFetch',
        content: '$active download(s) in progress',
      );
    });
  }

  service.on('stop').listen((_) {
    service.stopSelf();
  });
}
