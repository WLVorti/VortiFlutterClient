import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const String _channelId = 'vorti_messages';
const String _channelName = 'Messages';

final FlutterLocalNotificationsPlugin _localPlugin =
    FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Когда приложение в фоне, уведомление с полем 'notification' Android
  // показывает сам по себе — здесь его не дублируем, иначе будет два уведа.
  if (message.notification != null) return;
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  ));
  _showNotification(plugin, message);
}

void _showNotification(
    FlutterLocalNotificationsPlugin plugin, RemoteMessage message) {
  final data = message.data;
  final title = message.notification?.title ??
      data['title'] ??
      'New message';
  final body = message.notification?.body ??
      data['body'] ??
      data['text'] ??
      '';
  final chatId = data['chatId'] ?? '';
  final payload = jsonEncode({'chatId': chatId, 'type': data['type'] ?? 'message'});

  plugin.show(
    chatId.hashCode,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        enableVibration: true,
        playSound: true,
      ),
    ),
    payload: payload,
  );
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// ID чата, открытого сейчас на экране (null — ни один не открыт).
  /// Используется, чтобы не показывать уведомление о сообщении,
  /// когда пользователь уже видит этот чат.
  static String? activeChatId;

  static void setActiveChat(String? chatId) => activeChatId = chatId;

  Function(String, Map<String, dynamic>)? onNavigateToChat;

  Future<void> initialize() async {
    await _requestPermission();
    await _initLocalNotifications();
    await _setupMessageHandlers();
  }

  Future<void> _requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      if (kDebugMode) print('Push permission denied — notifications disabled');
    }
  }

  Future<void> _initLocalNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _localPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );
    final androidPlugin = _localPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: 'New message notifications',
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        ),
      );
    }
  }

  void _onNotificationTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final chatId = data['chatId'] as String?;
      if (chatId != null) {
        onNavigateToChat?.call(chatId, data);
      }
    } catch (_) {}
  }

  Future<void> _setupMessageHandlers() async {
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  void _handleForegroundMessage(RemoteMessage message) {
    if (kDebugMode) {
      print('Foreground message: ${message.notification?.title}');
    }
    final chatId = message.data['chatId'];
    if (chatId != null && chatId != '' && chatId == activeChatId) return;
    _showNotification(_localPlugin, message);
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    if (kDebugMode) {
      print('Opened from notification: ${message.notification?.title}');
    }
    final data = message.data;
    final chatId = data['chatId'];
    if (chatId != null) {
      onNavigateToChat?.call(chatId, data);
    }
  }

  Future<Map<String, dynamic>?> getInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    if (message != null) {
      return message.data;
    }
    return null;
  }

  Future<String?> _getToken() async {
    try {
      final token = await _messaging.getToken();
      if (kDebugMode) print('FCM token: $token');
      return token;
    } catch (e) {
      if (kDebugMode) print('FCM token error: $e');
      return null;
    }
  }

  Future<String?> getToken() async {
    try {
      return await _messaging.getToken();
    } catch (e) {
      if (kDebugMode) print('FCM getToken error: $e');
      return null;
    }
  }

  Stream<String?> get onTokenRefresh => _messaging.onTokenRefresh;
}
