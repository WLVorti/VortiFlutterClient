import 'dart:convert';
import 'package:flutter/services.dart';
import 'api_service.dart';

class SharedFileInfo {
  final String path;
  final String mimeType;
  final String name;
  final int size;

  const SharedFileInfo({
    required this.path,
    required this.mimeType,
    required this.name,
    this.size = 0,
  });

  bool get isVideo => mimeType.startsWith('video/');
  bool get isImage => mimeType.startsWith('image/');
  bool get isAudio => mimeType.startsWith('audio/');

  factory SharedFileInfo.fromJson(Map<String, dynamic> json) => SharedFileInfo(
        path: json['path'] ?? '',
        mimeType: json['mimeType'] ?? '*/*',
        name: json['name'] ?? 'file',
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

class SharedContent {
  final String? text;
  final String? subject;
  final String mimeType;
  final List<SharedFileInfo> files;

  const SharedContent({
    this.text,
    this.subject,
    this.mimeType = '*/*',
    this.files = const [],
  });

  bool get isEmpty => (text == null || text!.trim().isEmpty) && files.isEmpty;

  factory SharedContent.fromJson(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    final rawFiles = (json['files'] as List?) ?? const [];
    return SharedContent(
      text: json['text'] as String?,
      subject: json['subject'] as String?,
      mimeType: json['mimeType'] as String? ?? '*/*',
      files: rawFiles
          .map((f) => SharedFileInfo.fromJson(f as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ShareReceiver {
  static const MethodChannel _channel =
      MethodChannel('com.wlvorti.vorti_messenger/share');

  static SharedContent? _pending;
  static void Function(SharedContent)? _onShare;

  /// Возвращает данные, полученные при холодном старте (приложение открыли
  /// через "Поделиться"), либо null.
  static SharedContent? takeInitial() {
    final pending = _pending;
    _pending = null;
    return pending;
  }

  static Future<void> init(void Function(SharedContent content) onShare) async {
    _onShare = onShare;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedData') {
        final source = call.arguments as String?;
        if (source == null) return;
        try {
          final content = SharedContent.fromJson(source);
          if (!content.isEmpty) _onShare?.call(content);
        } catch (e) {
          ApiService.addLog('ShareReceiver parse error: $e');
        }
      }
    });

    try {
      final initial = await _channel.invokeMethod<String>('getSharedData');
      if (initial != null && initial.isNotEmpty) {
        _pending = SharedContent.fromJson(initial);
      }
    } catch (e) {
      ApiService.addLog('ShareReceiver init error: $e');
    }
  }

  static Future<void> clear() async {
    _pending = null;
    try {
      await _channel.invokeMethod('clearSharedData');
    } catch (_) {}
  }
}
