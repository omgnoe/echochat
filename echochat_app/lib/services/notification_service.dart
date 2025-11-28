import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const Color _accentColor = Color(0xFF00E5FF);

  Future<void> init() async {
    if (_initialized) {
      debugPrint('[Notifications] Already initialized');
      return;
    }

    debugPrint('[Notifications] Initializing...');

    // Nutze mipmap/ic_launcher als Fallback (existiert immer)
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    try {
      final success = await _plugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationTap,
      );
      debugPrint('[Notifications] Plugin initialized: $success');
    } catch (e) {
      debugPrint('[Notifications] ❌ Init error: $e');
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      await _requestAndroidPermission();
    }

    _initialized = true;
    debugPrint('[Notifications] ✅ Fully initialized');
  }

  Future<void> _requestAndroidPermission() async {
    final status = await Permission.notification.status;
    debugPrint('[Notifications] Android permission status: $status');

    if (!status.isGranted) {
      final result = await Permission.notification.request();
      debugPrint('[Notifications] Android permission result: $result');
    }
  }

  void _onNotificationTap(NotificationResponse response) {
    debugPrint('[Notifications] Tapped: ${response.payload}');
  }

  Future<void> showPingNotification(String senderName, String sessionId) async {
    debugPrint(
        '[Notifications] showPingNotification called - initialized: $_initialized');

    if (!_initialized) {
      debugPrint(
          '[Notifications] ⚠️ Not initialized, trying to initialize now...');
      await init();
    }

    if (!_initialized) {
      debugPrint('[Notifications] ❌ Still not initialized, skipping');
      return;
    }

    try {
      final androidDetails = AndroidNotificationDetails(
        'echochat_pings',
        'Chat Invitations',
        channelDescription: 'Notifications when someone wants to chat with you',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        color: _accentColor,
        enableVibration: true,
        playSound: true,
        showWhen: true,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      final notificationId = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      await _plugin.show(
        notificationId,
        '📢 Ping from $senderName',
        '$senderName wants to chat with you!',
        details,
        payload: sessionId,
      );

      debugPrint(
          '[Notifications] ✅ Notification shown with ID: $notificationId');
    } catch (e, stack) {
      debugPrint('[Notifications] ❌ Error showing notification: $e');
      debugPrint('[Notifications] Stack: $stack');
    }
  }

  Future<void> showMessageNotification({
    required String senderName,
    required String message,
    required String sessionId,
  }) async {
    if (!_initialized) {
      await init();
    }

    if (!_initialized) return;

    try {
      final androidDetails = AndroidNotificationDetails(
        'echochat_messages',
        'Messages',
        channelDescription: 'New message notifications',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        color: _accentColor,
        enableVibration: true,
        playSound: true,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      final shortMessage =
          message.length > 100 ? '${message.substring(0, 100)}...' : message;

      await _plugin.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        '💬 $senderName',
        shortMessage,
        details,
        payload: sessionId,
      );
    } catch (e) {
      debugPrint('[Notifications] Error: $e');
    }
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }

  Future<void> cancel(int id) async {
    await _plugin.cancel(id);
  }

  bool get isInitialized => _initialized;
}
