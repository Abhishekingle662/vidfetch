import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper over flutter_local_notifications with per-download progress
/// notifications on Android and simple toasts on Windows.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const windows = WindowsInitializationSettings(
        appName: 'VidFetch',
        appUserModelId: 'dev.abhishek.vidfetch',
        guid: 'a2c5f3de-8b1e-4f6a-9c3d-7e2b48d15f90',
      );
      const settings =
          InitializationSettings(android: android, windows: windows);
      _initialized = await _plugin.initialize(settings: settings) ?? false;

      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await android?.requestNotificationsPermission();
        // flutter_background_service posts its foreground notification on
        // this channel and crashes if it does not exist.
        await android?.createNotificationChannel(
          const AndroidNotificationChannel(
            'vidfetch_service',
            'Background downloads',
            description: 'Keeps downloads running in the background',
            importance: Importance.low,
          ),
        );
      }
    } catch (_) {
      _initialized = false;
    }
  }

  Future<void> showProgress({
    required int id,
    required String title,
    required double? progress,
  }) async {
    if (!_initialized || !Platform.isAndroid) return;
    final pct = progress != null ? (progress * 100).round() : 0;
    final android = AndroidNotificationDetails(
      'vidfetch_downloads',
      'Downloads',
      channelDescription: 'Download progress',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      showProgress: true,
      maxProgress: 100,
      progress: pct,
      indeterminate: progress == null,
      ongoing: true,
    );
    try {
      await _plugin.show(
        id: id,
        title: 'Downloading',
        body: title,
        notificationDetails: NotificationDetails(android: android),
      );
    } catch (_) {}
  }

  Future<void> showDone({
    required int id,
    required String title,
    required bool success,
  }) async {
    if (!_initialized) return;
    const android = AndroidNotificationDetails(
      'vidfetch_done',
      'Completed downloads',
      channelDescription: 'Finished download alerts',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    try {
      await _plugin.show(
        id: id,
        title: success ? 'Download complete' : 'Download failed',
        body: title,
        notificationDetails: const NotificationDetails(
          android: android,
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (_) {}
  }

  Future<void> cancel(int id) async {
    if (!_initialized) return;
    try {
      await _plugin.cancel(id: id);
    } catch (_) {}
  }
}
