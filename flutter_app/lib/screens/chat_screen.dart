import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import '../widgets/attachment_picker_widget.dart';
import 'sticker_pack_manager_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/avatar_utils.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/message_cache.dart';
import '../services/mute_service.dart';
import '../services/crypto_service.dart';
import '../services/wallpaper_service.dart';
import '../services/notification_service.dart';
import '../models/models.dart';
import 'user_profile_screen.dart';
import 'group_info_screen.dart';
import 'image_viewer_screen.dart';

const int _maxMessageLength = 10000;

class ChatScreen extends StatefulWidget {
  final ApiService api;
  final String chatId;
  final String chatName;
  final String? avatarUrl;
  final String? otherUserId;
  final String chatType;
  final bool initialOnline;
  final VoidCallback? onMessagesRead;

  const ChatScreen({
    super.key,
    required this.api,
    required this.chatId,
    required this.chatName,
    this.avatarUrl,
    this.otherUserId,
    this.chatType = 'direct',
    this.initialOnline = false,
    this.onMessagesRead,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _editController = TextEditingController();
  List<Message> _messages = [];
  bool _isLoading = true;
  bool _messagesLoaded = false;
  bool _hasOlderMessages = false;
  bool _isLoadingMore = false;
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String _uploadStatus = '';
  bool _isEditing = false;
  bool _isOtherTyping = false;
  bool _isOtherOnline = false;
  String? _editingMessageId;
  String? _replyToMessageId;
  Message? _replyToMessage;
  late final String _currentUserId;
  final Set<String> _readMessages = {};
  final Map<String, int> _decryptRetries = {};
  bool _showScrollDownButton = false;
  Timer? _draftDebounce;
  Timer? _readDebounce;
  final Set<String> _pendingReadIds = {};
  bool _isAppActive = true;
  bool _isRecording = false;
  bool _shouldCancelRecording = false;
  DateTime? _touchDownTime;
  DateTime? _recordingStartTime;
  RecorderController? _recorderController;
  String? _recordingPath;
  int _recordingSeconds = 0;
  Timer? _recordingTimer;
  final Map<String, String> _participantNames = {};
  final Map<String, AudioPlayer> _audioPlayers = {};
  final Map<String, String> _decryptedTexts = {};
  bool _isMuted = false;
  bool _showEmojiPanel = false;
  File? _pendingFile;
  String? _pendingFileName;
  String? _pendingFileMimeType;
  String? _wallpaperPath;

  final _threeDotKey = GlobalKey<State>();

  final Map<String, Map<String, Set<String>>> _messageReactions = {};
  // messageId -> { emoji -> Set<userId> }

  static const List<String> _reactionEmojis = [
    '👍', '❤️', '😂', '😮', '😢', '😡',
  ];

  String _quickReactionEmoji = '❤️';

  Future<void> _loadQuickReaction() async {
    final prefs = await SharedPreferences.getInstance();
    _quickReactionEmoji = prefs.getString('quick_reaction_${widget.chatId}') ?? '❤️';
    if (mounted) setState(() {});
  }

  Future<void> _setQuickReactionForChat(String emoji) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('quick_reaction_${widget.chatId}', emoji);
    _quickReactionEmoji = emoji;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUserId = widget.api.userId ?? '';
    _wallpaperPath = WallpaperService().wallpaperPath;
    _loadQuickReaction();
    _loadCachedMessages();
    _loadMessages();
    _loadReactions();
    _loadDraft();
    _loadMuteStatus();
    widget.api.addMessageListener(_handleMessage);
    widget.api.onReconnected = _handleReconnected;
    widget.api.setActiveChat(widget.chatId);
    NotificationService.setActiveChat(widget.chatId);
    _scrollController.addListener(_onScroll);
    if (widget.chatType == 'group') {
      _loadParticipantNames();
    }
  }

  void _handleReconnected() {
    _refreshMessageStatus();
    widget.api.setActiveChat(widget.chatId);
  }

  Future<void> _loadCachedMessages() async {
    try {
      final cached = await MessageCache.getMessages(widget.chatId);
      if (cached.isEmpty || !mounted) return;
      setState(() {
        for (final m in cached.reversed) {
          if (!_messages.any((e) => e.id == m.id)) {
            if (m.plainText != null && m.keyType == 'e2ee_v1') {
              _decryptedTexts[m.id] = m.plainText!;
            }
            _messages.add(m);
            if (m.plainText == null) _decryptMessage(m);
          }
        }
        if (!_messagesLoaded) {
          _isLoading = false;
        }
      });
    } catch (_) {}
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (!_isLoadingMore &&
        _hasOlderMessages &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200) {
      _loadMoreMessages();
    }
    if (_isNearBottom && _pendingReadIds.isNotEmpty) {
      _flushReadReceipts();
    }
    final show = !_isNearBottom;
    if (show != _showScrollDownButton) {
      setState(() => _showScrollDownButton = show);
    }
  }

  void _scheduleReadReceipts() {
    _readDebounce?.cancel();
    _readDebounce = Timer(const Duration(seconds: 1), () {
      if (!_isAppActive || !_scrollController.hasClients) return;
      if (_isNearBottom) {
        _flushReadReceipts();
      }
    });
  }

  void _flushReadReceipts() {
    if (_pendingReadIds.isEmpty) return;
    if (!_isNearBottom) return;
    for (final id in _pendingReadIds) {
      widget.api.sendRead(id);
      _readMessages.add(id);
    }
    _pendingReadIds.clear();
    widget.onMessagesRead?.call();
  }

  Future<void> _loadMuteStatus() async {
    final muted = await MuteService.isMuted(widget.chatId);
    if (mounted && _isMuted != muted) {
      setState(() {
        _isMuted = muted;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      _isAppActive = true;
      if (!widget.api.isWsActive) {
        widget.api.reconnectWebSocket();
      }
      _refreshMessageStatus();
      widget.api.setActiveChat(widget.chatId);
    }

    if (state == AppLifecycleState.paused) {
      _isAppActive = false;
      _readDebounce?.cancel();
      _pendingReadIds.clear();
      widget.api.sendPing();
      widget.api.setActiveChat(null);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.otherUserId != null) {
      setState(() {
        _isOtherOnline =
            widget.api.isUserOnline(widget.otherUserId!) ||
            widget.initialOnline;
      });
    }
  }

  Future<void> _loadDraft() async {
    final draft = await widget.api.getDraft(widget.chatId);
    if (draft != null && draft.isNotEmpty && mounted) {
      _messageController.text = draft;
    }
  }

  Future<void> _loadReactions() async {
    final reactions = await widget.api.getChatReactions(widget.chatId);
    setState(() {
      _messageReactions.clear();
      for (final entry in reactions.entries) {
        final msgId = entry.key;
        final reactionList = entry.value;
        final emojiMap = <String, Set<String>>{};
        for (final r in reactionList) {
          final emoji = r['emoji'] as String;
          final userId = r['userId'] as String;
          emojiMap.putIfAbsent(emoji, () => {}).add(userId);
        }
        _messageReactions[msgId] = emojiMap;
      }
    });
  }

  Future<void> _saveDraft() async {
    final text = _messageController.text.trim();
    if (text.isNotEmpty) {
      await widget.api.saveDraft(widget.chatId, text);
    } else {
      await widget.api.clearDraft(widget.chatId);
    }
  }

  Future<void> _clearDraft() async {
    await widget.api.clearDraft(widget.chatId);
  }

  Future<void> _startRecording() async {
    _recorderController = RecorderController()
      ..androidEncoder = AndroidEncoder.aac
      ..androidOutputFormat = AndroidOutputFormat.mpeg4
      ..iosEncoder = IosEncoder.kAudioFormatMPEG4AAC
      ..bitRate = 128000
      ..sampleRate = 44100;

    setState(() {
      _isRecording = true;
      _recordingStartTime = DateTime.now();
      _recordingSeconds = 0;
    });

    final dir = await getTemporaryDirectory();
    _recordingPath =
        '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';

    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showSnackBar(AppLocalizations.of(context).microphonePermissionDenied);
      setState(() => _isRecording = false);
      _recorderController = null;
      return;
    }

    try {
      await _recorderController!.record(path: _recordingPath);

      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted && _isRecording) {
          setState(() {
            _recordingSeconds++;
          });
        }
      });
    } catch (e) {
      ApiService.addLog('_startRecording: error=$e');
      _showSnackBar(AppLocalizations.of(context).failedToStartRecording);
      setState(() => _isRecording = false);
    }
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    if (_recorderController == null || !_isRecording) return;

    _recordingTimer?.cancel();
    _recordingTimer = null;

    // Stop the recorder if it was started
    try {
      await _recorderController!.stop();
    } catch (_) {
      // recorder might not have begun recording yet – that's fine
    }

    setState(() {
      _isRecording = false;
      _recordingSeconds = 0;
    });

    final path = _recordingPath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        if (cancel) {
          await file.delete();
          _recorderController = null;
          return;
        }

        setState(() => _isUploading = true);

        try {
          final uploadResult = await widget.api.uploadFile(file);
          if (uploadResult != null) {
            widget.api.sendFile(
              widget.chatId,
              uploadResult['fileId']!,
              mimeType: uploadResult['mimeType'],
            );
          } else {
            _showSnackBar('Upload failed');
          }
        } catch (e) {
          if (e is FileTooLargeException) {
            _showSnackBar(AppLocalizations.of(context).fileTooLarge);
          } else {
            _showSnackBar('Upload failed');
          }
        }

        setState(() => _isUploading = false);
      }
    }

    _recorderController = null;
  }

  void _finishRecording() {
    if (_shouldCancelRecording) {
      _stopRecording(cancel: true);
    } else {
      _stopRecording();
    }
    _shouldCancelRecording = false;
  }

  Timer? _holdTimer;

  void _handleMicDown() {
    _touchDownTime = DateTime.now();
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: 100), () {
      _shouldCancelRecording = false;
      _startRecording();
    });
  }

  void _handleMicUp() {
    _holdTimer?.cancel();
    _holdTimer = null;
    final dt = _touchDownTime;
    _touchDownTime = null;
    if (dt == null) return;
    if (DateTime.now().difference(dt) < const Duration(milliseconds: 100)) {
      // quick tap – do nothing
    } else {
      _finishRecording();
    }
  }

  void _decryptMessage(Message msg) {
    if (msg.keyType != 'e2ee_v1' ||
        msg.text.isEmpty ||
        _decryptedTexts.containsKey(msg.id) ||
        msg.plainText != null)
      return;
    try {
      final otherId =
          widget.otherUserId ??
          (widget.chatType == 'group' ? msg.userId : null);
      if (otherId == null || otherId == _currentUserId) return;
      CryptoService.getBox(otherId, widget.api).then((box) {
        if (box == null) {
          _scheduleDecryptRetry(msg);
          return;
        }
        final plain = CryptoService.decryptMessage(msg.text, box);
        if (plain != null && mounted) {
          setState(() {
            _decryptedTexts[msg.id] = plain;
            final idx = _messages.indexWhere((m) => m.id == msg.id);
            if (idx != -1) {
              _messages[idx] = _messages[idx].copyWith(plainText: plain);
              MessageCache.saveMessage(_messages[idx]);
            }
          });
        }
      });
    } catch (_) {}
  }

  void _scheduleDecryptRetry(Message msg) {
    final retries = _decryptRetries[msg.id] ?? 0;
    if (retries >= 3) return;
    _decryptRetries[msg.id] = retries + 1;
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      _decryptMessage(msg);
      if (_decryptedTexts.containsKey(msg.id)) {
        _decryptRetries.remove(msg.id);
      }
    });
  }

  void _handleMessage(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'message':
        if (msg['chatId'] == widget.chatId) _handleNewMessage(msg);
        break;
      case 'message_edited':
        if (msg['chatId'] == widget.chatId) _handleMessageEdit(msg);
        break;
      case 'message_deleted':
        if (msg['chatId'] == widget.chatId) _handleMessageDelete(msg);
        break;
      case 'error':
        _handleErrorMessage(msg);
        break;
      case 'online':
        _handleOnlineStatus(msg);
        break;
      case 'online_users':
        if (widget.otherUserId != null) {
          setState(
            () => _isOtherOnline = widget.api.isUserOnline(widget.otherUserId!),
          );
        }
        break;
      case 'delivered':
        _handleDelivered(msg);
        break;
      case 'read':
        if (msg['userId'] != _currentUserId) _handleReadReceipt(msg);
        break;
      case 'typing':
        if (msg['chatId'] == widget.chatId && msg['userId'] != _currentUserId)
          _handleTyping(msg);
        break;
      case 'reaction_update':
        if (msg['chatId'] == widget.chatId) _handleReactionUpdate(msg);
        break;
    }
  }

  void _insertMessageSorted(Message message) {
    var lo = 0;
    var hi = _messages.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_messages[mid].createdAt <= message.createdAt) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _messages.insert(lo, message);
  }

  void _handleNewMessage(Map<String, dynamic> msg) {
    final messageId = msg['id'] as String;
    final tempId = msg['tempId'] as String?;
    final userId = msg['userId'] as String;

    final replyData = msg['reply'] as Map<String, dynamic>?;
    final message = Message.fromJson({
      'id': messageId,
      'chat_id': msg['chatId'],
      'user_id': userId,
      'text': msg['text'],
      'file_id': msg['fileId'],
      'stickerId': msg['stickerId'],
      'stickerImageUrl': msg['stickerImageUrl'],
      'stickerEmoji': msg['stickerEmoji'],
      'stickerPackId': msg['stickerPackId'],
      'reply': replyData,
      'created_at': msg['timestamp'],
      'key_type': msg['keyType'],
    });

    _decryptMessage(message);

    if (!mounted) return;

    debugPrint(
      '[_handleNewMessage] ABOUT TO setState messageId=$messageId tempId=$tempId messages.len=${_messages.length}',
    );
    setState(() {
      // 1) Remove any existing copy by tempId OR real messageId (dedup)
      if (tempId != null) {
        _messages.removeWhere((m) => m.id == tempId);
      }
      _messages.removeWhere((m) => m.id == messageId);

      // 2) If own message without tempId (e.g. offline sync), find + remove pending optimistic
      if (userId == _currentUserId && tempId == null) {
        final optimisticIdx = _messages.indexWhere(
          (m) =>
              m.userId == _currentUserId &&
              m.status == MessageStatus.sending &&
              (message.createdAt - m.createdAt).abs() < 15000,
        );
        if (optimisticIdx != -1) {
          if (_decryptedTexts.containsKey(_messages[optimisticIdx].id)) {
            _decryptedTexts[messageId] =
                _decryptedTexts[_messages[optimisticIdx].id]!;
            _decryptedTexts.remove(_messages[optimisticIdx].id);
          }
          _messages.removeAt(optimisticIdx);
        }
      }

      // 3) Transfer decrypted text from tempId to real id
      if (tempId != null && _decryptedTexts.containsKey(tempId)) {
        _decryptedTexts[messageId] = _decryptedTexts[tempId]!;
        _decryptedTexts.remove(tempId);
      }

      // 4) Add the real message once
      _insertMessageSorted(message);
      MessageCache.saveMessage(message);

      // 5) Mark for read receipts
      if (userId != _currentUserId) {
        _pendingReadIds.add(message.id);
      }
    });

    if (userId != _currentUserId) {
      _scheduleReadReceipts();
      widget.onMessagesRead?.call();
    }

    if (_isNearBottom) _scrollToBottom(force: true);
  }

  void _handleMessageEdit(Map<String, dynamic> msg) {
    setState(() {
      final index = _messages.indexWhere((m) => m.id == msg['messageId']);
      if (index != -1) {
        _messages[index] = _messages[index].copyWith(
          text: msg['newText'] ?? _messages[index].text,
          isEdited: true,
        );
      }
    });
  }

  void _handleMessageDelete(Map<String, dynamic> msg) {
    final deletedId = msg['messageId'] as String;
    setState(() {
      final index = _messages.indexWhere((m) => m.id == deletedId);
      if (index != -1) {
        _messages[index] = _messages[index].copyWith(text: '[deleted]');
        MessageCache.saveMessage(_messages[index]);
      }
      for (int i = 0; i < _messages.length; i++) {
        if (_messages[i].replyTo == deletedId) {
          _messages[i] = _messages[i].copyWith(replyText: '[deleted]');
          MessageCache.saveMessage(_messages[i]);
        }
      }
    });
  }

  void _handleErrorMessage(Map<String, dynamic> msg) {
    final errorMsg = msg['message'] as String? ?? 'Ошибка отправки';
    final failedTempId = msg['tempId'] as String?;

    ApiService.addLog(
      '_handleErrorMessage: chatId=${widget.chatId} tempId=$failedTempId error=$errorMsg',
    );

    if (failedTempId != null && mounted) {
      // Remove failed optimistic message from UI
      setState(() => _messages.removeWhere((m) => m.id == failedTempId));
      _decryptedTexts.remove(failedTempId);

      // Restore text for retry
      final failedText = msg['text'] as String?;
      if (failedText != null) {
        _messageController.text = failedText;
        final failedReplyTo = msg['replyTo'] as String?;
        if (failedReplyTo != null) {
          setState(() {
            _replyToMessageId = failedReplyTo;
            final reply = _messages.firstWhere(
              (m) => m.id == failedReplyTo,
              orElse: () => Message(
                id: '',
                chatId: '',
                userId: '',
                text: '',
                createdAt: 0,
              ),
            );
            _replyToMessage = reply.id.isNotEmpty ? reply : null;
          });
        }
      }
    }

    _showSnackBar('${AppLocalizations.of(context).failedToSend}: $errorMsg');
  }

  void _handleOnlineStatus(Map<String, dynamic> msg) {
    if (msg['userId'] == widget.otherUserId) {
      setState(() => _isOtherOnline = msg['status'] == 'online');
    }
  }

  void _handleDelivered(Map<String, dynamic> msg) {
    final messageId = msg['messageId'];
    final index = _messages.indexWhere(
      (m) => m.id == messageId && m.userId == _currentUserId,
    );
    if (index != -1) {
      setState(() {
        _messages[index] = _messages[index].copyWith(
          status: MessageStatus.delivered,
        );
      });
      MessageCache.saveMessage(_messages[index]);
    }
  }

  void _handleReadReceipt(Map<String, dynamic> msg) {
    final messageId = msg['messageId'];
    final index = _messages.indexWhere(
      (m) => m.id == messageId && m.userId == _currentUserId,
    );
    if (index != -1) {
      setState(() {
        _messages[index] = _messages[index].copyWith(
          status: MessageStatus.read,
        );
      });
      MessageCache.saveMessage(_messages[index]);
    }
    setState(() => _readMessages.add(messageId));
  }

  void _handleTyping(Map<String, dynamic> msg) {
    setState(() => _isOtherTyping = msg['isTyping'] == true);
    if (msg['isTyping'] == true) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _isOtherTyping = false);
      });
    }
  }

  void _handleReactionUpdate(Map<String, dynamic> msg) {
    final messageId = msg['messageId'] as String;
    final userId = msg['userId'] as String;
    final emoji = msg['emoji'] as String;
    final action = msg['action'] as String;

    setState(() {
      final emojiMap = _messageReactions.putIfAbsent(messageId, () => {});
      if (action == 'add') {
        emojiMap.putIfAbsent(emoji, () => {}).add(userId);
      } else {
        final users = emojiMap[emoji];
        if (users != null) {
          users.remove(userId);
          if (users.isEmpty) emojiMap.remove(emoji);
          if (emojiMap.isEmpty) _messageReactions.remove(messageId);
        }
      }
    });
  }

  Future<void> _loadMessages() async {
    if (_messagesLoaded) return;
    try {
      // Догружаем с сервера только сообщения новее последнего из кэша,
      // чтобы чат открывался мгновенно из памяти, а сеть тратилась лишь на дельту.
      final latestCached =
          _messages.isNotEmpty ? _messages.last.createdAt : null;
      final messages = latestCached != null
          ? await widget.api.getMessages(
              widget.chatId,
              after: latestCached,
              limit: 100,
            )
          : await widget.api.getMessages(widget.chatId);
      if (mounted) {
        setState(() {
          final now = DateTime.now().millisecondsSinceEpoch;
          for (final m in messages) {
            // Skip own messages that still have a pending optimistic counterpart
            if (m.userId == _currentUserId &&
                _messages.any(
                  (o) =>
                      o.userId == _currentUserId &&
                      o.status == MessageStatus.sending &&
                      o.text == m.text &&
                      (now - o.createdAt).abs() < 10000,
                ))
              continue;

            final index = _messages.indexWhere(
              (existing) => existing.id == m.id,
            );
            if (index != -1) {
              if (m.status.index > _messages[index].status.index) {
                _messages[index] = _messages[index].copyWith(status: m.status);
              }
            } else {
              _messages.add(m);
            }
          }
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          _isLoading = false;
          _messagesLoaded = true;
          if (latestCached == null) {
            _hasOlderMessages = messages.length >= 50;
          } else {
            _hasOlderMessages = true;
          }

          for (final m in messages) {
            if (m.userId != _currentUserId && !_readMessages.contains(m.id)) {
              _pendingReadIds.add(m.id);
            }
          }
          final hasUnread = _pendingReadIds.isNotEmpty;
          if (hasUnread) {
            widget.onMessagesRead?.call();
          }
        });

        for (final m in messages) {
          _decryptMessage(m);
        }

        MessageCache.saveMessages(widget.chatId, messages);
        _scrollToBottom(force: true);
        if (_pendingReadIds.isNotEmpty) {
          _scheduleReadReceipts();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _refreshMessageStatus() async {
    try {
      final messages = await widget.api.getMessages(widget.chatId, limit: 50);
      if (!mounted) return;
      final toAdd = <Message>[];
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final m in messages) {
        // Skip own messages that still have a pending optimistic counterpart
        if (m.userId == _currentUserId &&
            _messages.any(
              (o) =>
                  o.userId == _currentUserId &&
                  o.status == MessageStatus.sending &&
                  o.text == m.text &&
                  (now - o.createdAt).abs() < 10000,
            ))
          continue;

        final index = _messages.indexWhere((existing) => existing.id == m.id);
        if (index != -1) {
          if (m.status.index > _messages[index].status.index) {
            _messages[index] = _messages[index].copyWith(status: m.status);
            MessageCache.saveMessage(_messages[index]);
          }
        } else {
          toAdd.add(m);
        }
      }
      if (toAdd.isEmpty) return;
      final actuallyAdded = <Message>[];
      setState(() {
        for (final m in toAdd) {
          if (!_messages.any((existing) => existing.id == m.id)) {
            _messages.add(m);
            actuallyAdded.add(m);
          }
        }
        if (actuallyAdded.isNotEmpty) {
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        }
      });
      if (actuallyAdded.isEmpty) return;
      for (final m in actuallyAdded) {
        _decryptMessage(m);
        if (m.userId != _currentUserId) {
          _pendingReadIds.add(m.id);
        }
      }
      if (actuallyAdded.any((m) => m.userId != _currentUserId)) {
        widget.onMessagesRead?.call();
      }
      MessageCache.saveMessages(widget.chatId, actuallyAdded);
      if (_isNearBottom) _scrollToBottom(force: true);
    } catch (_) {}
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasOlderMessages) return;
    _isLoadingMore = true;
    final oldest = _messages.isEmpty ? null : _messages.first.createdAt;
    try {
      final messages = await widget.api.getMessages(
        widget.chatId,
        before: oldest,
        limit: 50,
      );
      final toInsert = <Message>[];
      for (final m in messages) {
        if (!_messages.any((existing) => existing.id == m.id)) {
          toInsert.add(m);
        }
      }
      if (mounted) {
        setState(() {
          _hasOlderMessages = messages.length >= 50;
          if (toInsert.isNotEmpty) {
            toInsert.sort((a, b) => a.createdAt.compareTo(b.createdAt));
            _messages.insertAll(0, toInsert);
          }
          _isLoadingMore = false;
        });
      }
      for (final m in toInsert) {
        _decryptMessage(m);
      }
      MessageCache.saveMessages(widget.chatId, toInsert);
    } catch (e) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _loadParticipantNames() async {
    try {
      final participants = await widget.api.getParticipants(widget.chatId);
      if (mounted) {
        for (final p in participants) {
          _participantNames[p['user_id'] as String] =
              p['username'] as String? ?? 'Unknown';
        }
        setState(() {});
      }
    } catch (_) {}
  }

  void _scrollToBottom({bool force = false}) {
    if (!force && !_isNearBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(0.0);
    });
  }

  void _navigateToProfileOrGroup() {
    if (widget.otherUserId != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              UserProfileScreen(api: widget.api, userId: widget.otherUserId!),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              GroupInfoScreen(api: widget.api, chatId: widget.chatId),
        ),
      );
    }
  }

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return false;
    final pos = _scrollController.position;
    return pos.pixels <= 100;
  }

  Future<void> _sendMessage() async {
    if (_isEditing) {
      _saveEdit();
      return;
    }
    if (_isUploading) return;

    final text = _messageController.text.trim();
    final hasPendingFile = _pendingFile != null;
    if (text.isEmpty && !hasPendingFile) return;

    if (text.length > _maxMessageLength) {
      _showSnackBar(AppLocalizations.of(context).messageTooLong);
      return;
    }

    final replyTo = _replyToMessageId;

    // Upload and send pending file first
    if (hasPendingFile) {
      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
        _uploadStatus = AppLocalizations.of(context).starting;
      });
      try {
        final fileSize = await _pendingFile!.length();
        final sizeMb = (fileSize / (1024 * 1024)).toStringAsFixed(1);
        if (fileSize > 1024 * 1024 * 1024) {
          _showSnackBar(AppLocalizations.of(context).fileTooLarge);
          setState(() => _isUploading = false);
          return;
        }
        final useChunked =
            _pendingFileMimeType != null &&
            _pendingFileMimeType!.startsWith('video/') &&
            fileSize > 5 * 1024 * 1024;
        final l = AppLocalizations.of(context);
        final uploadResult = useChunked
            ? await widget.api.uploadFileChunked(
                _pendingFile!,
                onProgress: (p) => setState(() {
                  _uploadProgress = p;
                  _uploadStatus = l.uploadProgress(
                    (p * 100).toStringAsFixed(0),
                    sizeMb,
                  );
                }),
              )
            : await widget.api.uploadFile(_pendingFile!);
        if (uploadResult != null) {
          setState(() => _uploadStatus = l.sending);
          widget.api.sendFile(
            widget.chatId,
            uploadResult['fileId']!,
            replyTo: replyTo,
            mimeType: uploadResult['mimeType'],
          );
        } else {
          _showSnackBar(AppLocalizations.of(context).uploadFailed);
          setState(() => _isUploading = false);
          return;
        }
      } catch (e) {
        if (e is FileTooLargeException) {
          _showSnackBar(AppLocalizations.of(context).fileTooLarge);
        } else {
          _showSnackBar(AppLocalizations.of(context).uploadFailed);
        }
        setState(() => _isUploading = false);
        return;
      }
      setState(() => _isUploading = false);
      _cancelPendingFile();

      // If no text to send separately, done
      if (text.isEmpty) return;
    }

    final tempId = DateTime.now().millisecondsSinceEpoch.toString();

    // Encrypt for direct chats
    String sendText = text;
    String? keyType;
    if (widget.chatType == 'direct' &&
        widget.otherUserId != null &&
        text.isNotEmpty) {
      try {
        final box = await CryptoService.getBox(widget.otherUserId!, widget.api);
        if (box != null) {
          sendText = CryptoService.encryptMessage(text, box);
          keyType = 'e2ee_v1';
        }
      } catch (_) {}
    }

    // Store plaintext for E2EE messages
    if (keyType == 'e2ee_v1') {
      _decryptedTexts[tempId] = text;
    }

    // Add optimistic message to UI
    setState(() {
      _messages.add(
        Message(
          id: tempId,
          chatId: widget.chatId,
          userId: _currentUserId,
          text: keyType == 'e2ee_v1' ? text : sendText,
          replyTo: replyTo,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          status: MessageStatus.sending,
          keyType: keyType,
        ),
      );
    });
    _scrollToBottom(force: true);

    // Send via WebSocket with tempId
    widget.api.sendMessage(
      widget.chatId,
      sendText,
      replyTo: replyTo,
      tempId: tempId,
      keyType: keyType,
    );

    // Clear input
    _draftDebounce?.cancel();
    _messageController.clear();
    _cancelReply();
    _clearDraft();
  }

  void _sendSticker(Sticker sticker) {
    final tempId = DateTime.now().millisecondsSinceEpoch.toString();

    setState(() {
      _messages.add(Message(
        id: tempId,
        chatId: widget.chatId,
        userId: _currentUserId,
        text: '[Sticker]',
        stickerId: sticker.id,
        stickerImageUrl: sticker.imageUrl,
        stickerEmoji: sticker.emoji,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.sending,
      ));
    });

    widget.api.sendSticker(widget.chatId, sticker.id, tempId: tempId);
    _scrollToBottom(force: true);
  }

  void _viewStickerPack(String packId) async {
    final pack = await widget.api.getStickerPack(packId);
    if (!mounted || pack == null) return;

    showDialog(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Row(
            children: [
              Expanded(child: Text(pack.name, overflow: TextOverflow.ellipsis)),
              if (pack.authorId != widget.api.userId)
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'Add Pack',
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _addStickerPack(packId);
                  },
                ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: pack.stickers != null && pack.stickers!.isNotEmpty
                ? GridView.builder(
                    shrinkWrap: true,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemCount: pack.stickers!.length,
                    itemBuilder: (_, i) {
                      final s = pack.stickers![i];
                      return Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CachedNetworkImage(
                            imageUrl: '${ApiService.baseUrl}${s.imageUrl}',
                            fit: BoxFit.contain,
                            placeholder: (_, __) => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                            errorWidget: (_, __, ___) => Icon(Icons.broken_image, color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      );
                    },
                  )
                : Center(
                    child: Text('No stickers', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  void _addStickerPack(String packId) async {
    final result = await widget.api.copyStickerPack(packId);
    if (!mounted) return;

    if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Pack "${result.name}" added'),
          duration: const Duration(seconds: 2),
        ),
      );
      _loadStickerPacks();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to add pack'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _startReply(Message msg) {
    setState(() {
      _replyToMessageId = msg.id;
      _replyToMessage = msg;
    });
  }

  void _cancelReply() {
    setState(() {
      _replyToMessageId = null;
      _replyToMessage = null;
    });
  }

  void _startEdit(Message msg) {
    setState(() {
      _isEditing = true;
      _editingMessageId = msg.id;
      _editController.text = msg.text;
      _messageController.text = msg.text;
    });
  }

  void _saveEdit() async {
    final newText = _messageController.text.trim();
    if (newText.isEmpty || _editingMessageId == null) return;

    if (newText.length > _maxMessageLength) {
      _showSnackBar(AppLocalizations.of(context).messageTooLong);
      return;
    }

    final success = await widget.api.editMessage(_editingMessageId!, newText);
    if (success) {
      setState(() {
        final index = _messages.indexWhere((m) => m.id == _editingMessageId);
        if (index != -1) {
          _messages[index] = _messages[index].copyWith(
            text: newText,
            isEdited: true,
          );
        }
      });
    }

    _cancelEdit();
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _editingMessageId = null;
      _messageController.clear();
      _editController.clear();
    });
  }

  void _deleteMessage(Message msg) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).deleteMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              AppLocalizations.of(context).delete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await widget.api.deleteMessage(msg.id);
      if (success) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == msg.id);
          if (index != -1) {
            _messages[index] = _messages[index].copyWith(text: '[deleted]');
            MessageCache.saveMessage(_messages[index]);
          }
        });
      }
    }
  }

  void _showAttachmentOptions() async {
    final results = await AttachmentPickerWidget.show(context);
    if (results == null || !mounted) return;
    for (final media in results) {
      if (!mounted) break;
      try {
        final fileSize = await media.file.length();
        if (fileSize > 1024 * 1024 * 1024) {
          _showSnackBar(AppLocalizations.of(context).fileTooLarge);
          continue;
        }
        final useChunked =
            media.mimeType.startsWith('video/') && fileSize > 5 * 1024 * 1024;
        final api = widget.api;
        final uploadResult = useChunked
            ? await api.uploadFileChunked(media.file, onProgress: (p) {})
            : await api.uploadFile(media.file);
        if (uploadResult != null) {
          api.sendFile(
            widget.chatId,
            uploadResult['fileId']!,
            mimeType: uploadResult['mimeType'],
          );
        }
      } catch (e) {
        if (e is FileTooLargeException) {
          _showSnackBar(AppLocalizations.of(context).fileTooLarge);
        } else {
          _showSnackBar(AppLocalizations.of(context).uploadFailed);
        }
      }
    }
  }

  Future<void> _pickVideoFromGallery() async {
    try {
      if (await _requestGalleryPermission() == false) return;
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (picked != null) {
        final file = File(picked.path);
        setState(() {
          _pendingFile = file;
          _pendingFileName = picked.name;
          _pendingFileMimeType =
              'video/${picked.path.split('.').last.toLowerCase()}';
        });
      }
    } catch (e) {
      _showSnackBar(AppLocalizations.of(context).errorPickingVideo);
    }
  }

  Future<void> _recordVideo() async {
    try {
      final status = await Permission.camera.request();
      if (status.isDenied || status.isPermanentlyDenied) {
        _showSnackBar(AppLocalizations.of(context).cameraPermissionRequired);
        return;
      }
      final picked = await ImagePicker().pickVideo(source: ImageSource.camera);
      if (picked != null) {
        final file = File(picked.path);
        setState(() {
          _pendingFile = file;
          _pendingFileName = picked.name;
          _pendingFileMimeType =
              'video/${picked.path.split('.').last.toLowerCase()}';
        });
      }
    } catch (e) {
      _showSnackBar(AppLocalizations.of(context).errorRecordingVideo);
    }
  }

  Future<void> _pickMedia(ImageSource source) async {
    try {
      if (source == ImageSource.gallery &&
          await _requestGalleryPermission() == false)
        return;
      if (source == ImageSource.camera) {
        final status = await Permission.camera.request();
        if (status.isDenied || status.isPermanentlyDenied) {
          _showSnackBar(AppLocalizations.of(context).cameraPermissionRequired);
          return;
        }
      }
      final picked = await ImagePicker().pickImage(
        source: source,
        imageQuality: 85,
      );
      if (picked != null) {
        final file = File(picked.path);
        final ext = picked.path.split('.').last.toLowerCase();
        final compressed = await _compressImage(file);
        setState(() {
          _pendingFile = compressed ?? file;
          _pendingFileName = picked.name;
          _pendingFileMimeType = 'image/$ext';
        });
      }
    } catch (e) {
      _showSnackBar(
        source == ImageSource.camera
            ? AppLocalizations.of(context).errorTakingPhoto
            : AppLocalizations.of(context).errorPickingGallery,
      );
    }
  }

  Future<bool> _requestGalleryPermission() async {
    try {
      if (await Permission.storage.isGranted) return true;
      final status = await Permission.storage.request();
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) {
        _showSnackBar(AppLocalizations.of(context).storagePermissionRequired);
        return false;
      }
    } catch (_) {
      // On Android 13+ Permission.storage may not be available;
      // image_picker uses the system photo picker which needs no permission.
    }
    return true;
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final ext = result.files.single.path!.split('.').last.toLowerCase();
        final mimeType = _getPreviewMimeType(ext);
        final compressed = mimeType.startsWith('image/')
            ? await _compressImage(file)
            : null;
        setState(() {
          _pendingFile = compressed ?? file;
          _pendingFileName = result.files.single.name;
          _pendingFileMimeType = mimeType;
        });
      }
    } catch (e) {
      _showSnackBar(AppLocalizations.of(context).errorSelectingFile);
    }
  }

  String _getPreviewMimeType(String ext) {
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
        return 'video/$ext';
      default:
        return 'application/octet-stream';
    }
  }

  Future<File?> _compressImage(File file) async {
    try {
      final ext = file.path.split('.').last.toLowerCase();
      if (ext == 'gif' || ext == 'webp') return null;
      final dir = await getTemporaryDirectory();
      final outPath =
          '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final xfile = await FlutterImageCompress.compressAndGetFile(
        file.absolute.path,
        outPath,
        quality: 80,
        minWidth: 1920,
        minHeight: 1920,
      );
      if (xfile != null && await xfile.length() < await file.length())
        return File(xfile.path);
    } catch (_) {}
    return null;
  }

  void _cancelPendingFile() {
    setState(() {
      _pendingFile = null;
      _pendingFileName = null;
      _pendingFileMimeType = null;
      _uploadProgress = 0.0;
      _uploadStatus = '';
    });
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _draftDebounce = null;
    _readDebounce?.cancel();
    _readDebounce = null;
    widget.api.clearDraft(widget.chatId);
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _editController.dispose();
    _scrollController.dispose();
    widget.api.removeMessageListener(_handleMessage);
    widget.api.setActiveChat(null);
    if (NotificationService.activeChatId == widget.chatId) {
      NotificationService.setActiveChat(null);
    }
    if (widget.api.onReconnected == _handleReconnected) {
      widget.api.onReconnected = null;
    }
    for (final player in _audioPlayers.values) {
      player.dispose();
    }
    _audioPlayers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[_ChatScreenState.build] messages.len=${_messages.length}');
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(88),
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(color: Colors.transparent),
                ),
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Theme.of(context).colorScheme.surface.withValues(alpha: 0.7),
                      Theme.of(context).colorScheme.surface.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4),
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                Row(
                children: [
                  // Back button in circle
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.pop(context),
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Bubble: avatar + name + status
                  Expanded(
                    child: GestureDetector(
                      onTap: _navigateToProfileOrGroup,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Row(
                          children: [
                            Stack(
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: colorFromId(widget.chatId),
                                  child: Text(widget.chatName[0].toUpperCase()),
                                ),
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: Colors.transparent,
                                  backgroundImage:
                                      widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty
                                      ? CachedNetworkImageProvider(
                                          '${ApiService.baseUrl}${widget.avatarUrl}',
                                        )
                                      : null,
                                  onBackgroundImageError:
                                      widget.avatarUrl != null && widget.avatarUrl!.isNotEmpty
                                      ? (_, __) {}
                                      : null,
                                ),
                                if (widget.otherUserId != null)
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        color: _isOtherOnline ? Colors.green : Colors.grey,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 1.5),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    widget.chatName,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(context).colorScheme.onSurface,
                                    ),
                                  ),
                                  Builder(
                                    builder: (context) {
                                      if (_isOtherTyping) {
                                        return Text(
                                          AppLocalizations.of(context).typing,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
                                          ),
                                        );
                                      }
                                      if (widget.otherUserId != null) {
                                        if (_isOtherOnline) {
                                          return Text(
                                            AppLocalizations.of(context).online,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.green.withOpacity(0.9),
                                            ),
                                          );
                                        } else {
                                          return Text(
                                            AppLocalizations.of(context).offline,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                                            ),
                                          );
                                        }
                                      }
                                      return const SizedBox.shrink();
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Three dots in circle
                  Container(
                    key: _threeDotKey,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: IconButton(
                      icon: Icon(Icons.more_vert, color: Theme.of(context).colorScheme.onSurface),
                      onPressed: _showThreeDotMenu,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ],
  ),
  ),
      body: Stack(
        children: [
          if (_wallpaperPath != null && File(_wallpaperPath!).existsSync())
            Positioned.fill(
              child: Image.file(File(_wallpaperPath!), fit: BoxFit.cover),
            ),
          GestureDetector(
            onTap: () {
              FocusScope.of(context).unfocus();
              if (_showEmojiPanel) setState(() => _showEmojiPanel = false);
            },
            behavior: HitTestBehavior.translucent,
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      _isLoading
                          ? const Center(child: CircularProgressIndicator())
                          : (_messages.isEmpty
                                ? Center(
                                    child: Text(
                                      AppLocalizations.of(
                                        context,
                                      ).noMessagesYet,
                                    ),
                                  )
                                : ListView.builder(
                                    key: PageStorageKey(
                                      'chat_${widget.chatId}',
                                    ),
                                    controller: _scrollController,
                                    reverse: true,
                                    padding: const EdgeInsets.all(8),
                                    itemCount: _displayItems.length,
                                    itemBuilder: (_, i) {
                                      final item =
                                          _displayItems[_displayItems.length -
                                              1 -
                                              i];
                                      if (item is String) {
                                        return _buildDateSeparator(item);
                                      }
                                      final msg = item as Message;
                                      final child = _buildMessage(msg);
                                      final reactionRow = _buildReactionRow(msg);
                                      final messageWidget = reactionRow != null
                                          ? Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment: msg.userId == _currentUserId
                                                  ? CrossAxisAlignment.end
                                                  : CrossAxisAlignment.start,
                                              children: [child, reactionRow],
                                            )
                                          : child;
                                      if (msg.isDeleted ||
                                          msg.text == '[deleted]') {
                                        return KeyedSubtree(
                                          key: ValueKey(msg.id),
                                          child: messageWidget,
                                        );
                                      }
                                      return KeyedSubtree(
                                        key: ValueKey('swipe_${msg.id}'),
                                        child: _buildSwipeableMessage(
                                          msg,
                                          messageWidget,
                                        ),
                                      );
                                    },
                                  )),
                      if (_showScrollDownButton)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: FloatingActionButton.small(
                            heroTag: 'scrollDown',
                            onPressed: () {
                              _scrollToBottom(force: true);
                              setState(() => _showScrollDownButton = false);
                            },
                            child: const Icon(Icons.arrow_downward),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_isEditing)
                  Container(
                    color: Colors.amber[100],
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.edit, size: 16),
                        const SizedBox(width: 8),
                        Text(AppLocalizations.of(context).editingMessage),
                        const Spacer(),
                        TextButton(
                          onPressed: _cancelEdit,
                          child: Text(AppLocalizations.of(context).cancel),
                        ),
                      ],
                    ),
                  ),
                if (_pendingFile != null && !_isEditing)
                  _buildPendingFilePreview(),
                if (_replyToMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 8,
                            offset: const Offset(0, -2),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Row(
                        children: [
                          Container(
                            width: 4,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _replyToMessage!.userId == _currentUserId
                                      ? AppLocalizations.of(context).replyToYourself
                                      : '${AppLocalizations.of(context).replyTo} ${_replyToMessage!.replyUsername ?? ''}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  _replyToMessage!.text,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: _cancelReply,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_showEmojiPanel)
                  _buildEmojiModeToggle(),
                Padding(
                  padding: EdgeInsets.fromLTRB(12, _showEmojiPanel ? 0 : 4, 12, 12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(32),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.06),
                          blurRadius: 16,
                          spreadRadius: -4,
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_showEmojiPanel)
                          _buildEmojiPanel(),
                        SafeArea(
                          top: false,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              IconButton(
                                onPressed: () => setState(() => _showEmojiPanel = !_showEmojiPanel),
                                icon: const Icon(Icons.emoji_emotions_outlined),
                              ),
                          Expanded(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 120),
                              child: TextField(
                                controller: _messageController,
                                maxLines: null,
                                minLines: 1,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                inputFormatters: [
                                  LengthLimitingTextInputFormatter(
                                    _maxMessageLength,
                                  ),
                                ],
                                decoration: InputDecoration(
                                  hintText: _isEditing
                                      ? AppLocalizations.of(
                                          context,
                                        ).editMessageHint
                                      : AppLocalizations.of(
                                          context,
                                        ).typeMessage,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                  isDense: true,
                                ),
                                textInputAction: TextInputAction.newline,
                                onChanged: (value) {
                                  setState(() {});
                                  _draftDebounce?.cancel();
                                  _draftDebounce = Timer(
                                    const Duration(milliseconds: 300),
                                    _saveDraft,
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          if (_isRecording)
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _shouldCancelRecording ? Colors.grey : Colors.red,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _shouldCancelRecording ? Icons.close : Icons.mic,
                                        color: Colors.white,
                                        size: 16,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        _shouldCancelRecording
                                            ? 'Cancel'
                                            : _getRecordingDuration(),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (!_shouldCancelRecording) ...[
                                  const SizedBox(width: 8),
                                  IconButton.filled(
                                    onPressed: _stopRecording,
                                    style: IconButton.styleFrom(
                                      backgroundColor: Colors.red,
                                    ),
                                    icon: const Icon(Icons.stop),
                                  ),
                                ],
                              ],
                            )
                          else
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: _isUploading
                                      ? null
                                      : _showAttachmentOptions,
                                  icon: _isUploading
                                      ? const SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.attach_file),
                                ),
                                const SizedBox(width: 4),
                                _messageController.text.trim().isNotEmpty || _pendingFile != null
                                  ? IconButton.filled(
                                      onPressed: _isUploading ? null : _sendMessage,
                                      icon: Icon(
                                        _isEditing ? Icons.check : Icons.send,
                                      ),
                                    )
                                  : Listener(
                                      onPointerDown: (_) => _handleMicDown(),
                                      onPointerMove: (details) {
                                        if (details.localPosition.dx > 120) {
                                          _shouldCancelRecording = true;
                                        }
                                      },
                                      onPointerUp: (_) => _handleMicUp(),
                                      child: IconButton.filled(
                                        onPressed: () {},
                                        icon: const Icon(Icons.mic),
                                      ),
                                    ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(Message msg) {
    final svc = WallpaperService();
    final bool adaptive = svc.adaptiveTheme && svc.lastAnalysis != null;
    final WallpaperAnalysis? wa = svc.lastAnalysis;

    Color myBubbleColor;
    Color myTextColor;
    Color mySecTextColor;
    Color theirBubbleColor;
    Color theirTextColor;
    Color theirSecTextColor;

    if (adaptive) {
      myBubbleColor = wa!.accentColor;
      myTextColor = wa.textOnAccent;
      mySecTextColor = wa.textOnAccent.withValues(alpha: 0.7);
      theirBubbleColor = wa.surfaceColor;
      theirTextColor = wa.textMain;
      theirSecTextColor = wa.textSecondary;
    } else {
      myBubbleColor = Theme.of(context).colorScheme.primary;
      myTextColor = Theme.of(context).colorScheme.onPrimary;
      mySecTextColor = Theme.of(
        context,
      ).colorScheme.onPrimary.withValues(alpha: 0.7);
      theirBubbleColor = Theme.of(context).colorScheme.surfaceContainerHigh;
      theirTextColor = Theme.of(context).colorScheme.onSurface;
      theirSecTextColor = Theme.of(context).colorScheme.onSurfaceVariant;
    }

    if (msg.isDeleted || msg.text == '[deleted]') {
      final isMe = msg.userId == _currentUserId;
      final bubbleColor = isMe
          ? myBubbleColor
          : Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
      final textColor = isMe
          ? mySecTextColor
          : Theme.of(context).colorScheme.onSurfaceVariant;
      return Padding(
        padding: EdgeInsets.only(
          left: isMe ? 64 : 12,
          right: isMe ? 12 : 64,
          top: 2,
          bottom: 2,
        ),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.delete_outline, size: 16, color: textColor),
                const SizedBox(width: 6),
                Text(
                  AppLocalizations.of(context).messageDeleted,
                  style: TextStyle(
                    color: textColor,
                    fontStyle: FontStyle.italic,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isMe = msg.userId == _currentUserId;

    if (msg.stickerId != null) {
      final imageUrl = msg.stickerImageUrl != null
          ? '${ApiService.baseUrl}${msg.stickerImageUrl}'
          : null;
      return GestureDetector(
        onLongPressStart: (d) => _showMessageMenu(msg, d.globalPosition),
        onDoubleTap: () => _sendQuickReaction(msg),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.45,
              maxHeight: MediaQuery.of(context).size.height * 0.3,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: imageUrl != null
                      ? CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.contain,
                          placeholder: (_, __) => Container(
                            height: 120,
                            color: isMe ? myBubbleColor : theirBubbleColor,
                            child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            height: 120,
                            color: isMe ? myBubbleColor : theirBubbleColor,
                            child: Icon(Icons.broken_image, color: isMe ? mySecTextColor : theirSecTextColor),
                          ),
                        )
                      : Container(
                          height: 120,
                          color: isMe ? myBubbleColor : theirBubbleColor,
                          child: Icon(Icons.auto_awesome, color: isMe ? mySecTextColor : theirSecTextColor),
                        ),
                ),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(msg.createdAt),
                        style: const TextStyle(fontSize: 10, color: Colors.white70),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        _buildStatusIcon(msg.status),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final hasFile = msg.fileId != null;
    final fileName = hasFile ? msg.text.replaceFirst('[File] ', '') : '';
    final ext = fileName.split('.').last.toLowerCase();
    final isImage =
        hasFile && ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext);
    final isVideo =
        hasFile && ['mp4', 'webm', 'mov', 'avi', 'mkv'].contains(ext);
    final isAudio =
        hasFile && ['mp3', 'wav', 'ogg', 'm4a', 'aac', 'flac'].contains(ext);

    if (hasFile && isImage) {
      final imageUrl =
          '${ApiService.baseUrl}/download/${msg.fileId}?token=${widget.api.token}';
      return GestureDetector(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ImageViewerScreen(
                imageUrl: imageUrl,
                heroTag: 'image_${msg.id}',
              ),
            ),
          );
        },
        onLongPressStart: (d) => _showMessageMenu(msg, d.globalPosition),
        onDoubleTap: () => _sendQuickReaction(msg),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.6,
              maxHeight: MediaQuery.of(context).size.height * 0.4,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: CachedNetworkImage(
                      imageUrl:
                          '${ApiService.baseUrl}/download/${msg.fileId}?token=${widget.api.token}',
                  fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isMe
                              ? myBubbleColor
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.broken_image,
                              size: 20,
                              color: isMe ? mySecTextColor : theirSecTextColor,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                fileName,
                                style: TextStyle(
                                  color: isMe ? myTextColor : theirTextColor,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (msg.isEdited)
                        Text(
                          '${AppLocalizations.of(context).editedLabel} ',
                          style: TextStyle(
                            fontSize: 10,
                            fontStyle: FontStyle.italic,
                            color: Colors.white70,
                          ),
                        ),
                      Text(
                        _formatTime(msg.createdAt),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white70,
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        _buildStatusIcon(msg.status),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (hasFile && isVideo) {
      final videoThumb = Flexible(
        fit: FlexFit.loose,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _VideoThumbnail(
            videoUrl:
                '${ApiService.baseUrl}/download/${msg.fileId}?token=${widget.api.token}',
            fileName: fileName,
          ),
        ),
      );

      return GestureDetector(
        onTap: () => _openVideoFullscreen(
          '${ApiService.baseUrl}/download/${msg.fileId}?token=${widget.api.token}',
        ),
        onLongPressStart: (d) => _showMessageMenu(msg, d.globalPosition),
        onDoubleTap: () => _sendQuickReaction(msg),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.6,
              maxHeight: MediaQuery.of(context).size.height * 0.4,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                videoThumb,
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (msg.isEdited)
                        Text(
                          '${AppLocalizations.of(context).editedLabel} ',
                          style: TextStyle(
                            fontSize: 10,
                            fontStyle: FontStyle.italic,
                            color: Colors.white70,
                          ),
                        ),
                      Text(
                        _formatTime(msg.createdAt),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white70,
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        _buildStatusIcon(msg.status),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (hasFile && isAudio) {
      debugPrint(
        '[_buildMessage.audio] msgId=${msg.id} deleted=${msg.isDeleted} fileId=${msg.fileId} playerExists=${_audioPlayers.containsKey(msg.id)}',
      );
      final audioPlayer = _audioPlayers.putIfAbsent(
        msg.id,
        () => AudioPlayer(
          handleInterruptions: false,
          androidApplyAudioAttributes: false,
        ),
      );
      return GestureDetector(
        onLongPressStart: (d) => _showMessageMenu(msg, d.globalPosition),
        onDoubleTap: () => _sendQuickReaction(msg),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            child: IntrinsicWidth(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 2),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                decoration: BoxDecoration(
                  color: isMe
                      ? myBubbleColor
                      : Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AudioPlayerWidget(
                      key: ValueKey('audio_${msg.id}'),
                      audioPlayer: audioPlayer,
                      audioUrl:
                          '${ApiService.baseUrl}/download/${msg.fileId}?token=${widget.api.token}',
                      fileName: fileName,
                      isMe: isMe,
                      showFileName: ext != 'm4a',
                      onComplete: () => _onAudioComplete(msg.id),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (msg.isEdited)
                            Text(
                              '${AppLocalizations.of(context).editedLabel} ',
                              style: TextStyle(
                                fontSize: 10,
                                fontStyle: FontStyle.italic,
                                color: isMe
                                    ? mySecTextColor
                                    : theirSecTextColor,
                              ),
                            ),
                          Text(
                            _formatTime(msg.createdAt),
                            style: TextStyle(
                              fontSize: 10,
                              color: isMe ? mySecTextColor : theirSecTextColor,
                            ),
                          ),
                          if (isMe) ...[
                            const SizedBox(width: 4),
                            _buildStatusIcon(msg.status),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onLongPressStart: (d) => _showMessageMenu(msg, d.globalPosition),
        onDoubleTap: () => _sendQuickReaction(msg),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          child: IntrinsicWidth(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              decoration: BoxDecoration(
                color: isMe ? myBubbleColor : theirBubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (msg.replyTo != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.only(left: 6),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: isMe
                                ? mySecTextColor
                                : Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        msg.replyUsername != null && msg.replyText != null
                            ? '${msg.replyUsername}: ${msg.replyText}'
                            : _getReplyPreview(msg.replyTo!),
                        style: TextStyle(
                          fontSize: 10,
                          fontStyle: FontStyle.italic,
                          color: isMe ? mySecTextColor : theirSecTextColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (hasFile)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.attach_file,
                          size: 20,
                          color: isMe ? mySecTextColor : theirSecTextColor,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            fileName,
                            style: TextStyle(
                              color: isMe
                                  ? Theme.of(context).colorScheme.onSurface
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.chatType == 'group' && !isMe)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              _participantNames[msg.userId] ??
                                  AppLocalizations.of(context).unknown,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: adaptive
                                    ? theirSecTextColor
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        _buildMessageText(
                          _decryptedTexts[msg.id] ??
                              msg.plainText ??
                              (msg.keyType == 'e2ee_v1'
                                  ? AppLocalizations.of(context).e2eeLabel
                                  : msg.text),
                          isMe ? myTextColor : theirTextColor,
                        ),
                      ],
                    ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (msg.isEdited)
                          Text(
                            '${AppLocalizations.of(context).editedLabel} ',
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: isMe ? mySecTextColor : theirSecTextColor,
                            ),
                          ),
                        Text(
                          _formatTime(msg.createdAt),
                          style: TextStyle(
                            fontSize: 10,
                            color: isMe ? mySecTextColor : theirSecTextColor,
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          _buildStatusIcon(msg.status),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _buildReactionRow(Message msg) {
    final reactions = _messageReactions[msg.id];
    if (reactions == null || reactions.isEmpty) return null;
    final isMe = msg.userId == _currentUserId;

    return Padding(
      padding: EdgeInsets.only(
        left: isMe ? 64 : 12,
        right: isMe ? 12 : 64,
        top: 0,
      ),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Wrap(
            spacing: 2,
            runSpacing: 2,
            children: reactions.entries.map((e) {
              final emoji = e.key;
              final count = e.value.length;
              final iReacted = e.value.contains(_currentUserId);
              return GestureDetector(
                onTap: () {
                  final action = iReacted ? 'remove' : 'add';
                  widget.api.sendReaction(msg.id, emoji, action);
                  setState(() {
                    final emojiMap = _messageReactions.putIfAbsent(msg.id, () => {});
                    if (iReacted) {
                      emojiMap[emoji]?.remove(_currentUserId);
                      if (emojiMap[emoji]?.isEmpty == true) emojiMap.remove(emoji);
                      if (emojiMap.isEmpty) _messageReactions.remove(msg.id);
                    } else {
                      emojiMap.putIfAbsent(emoji, () => {}).add(_currentUserId);
                    }
                  });
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: iReacted
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$emoji $count',
                    style: TextStyle(
                      fontSize: 13,
                      color: iReacted
                          ? Theme.of(context).colorScheme.onPrimaryContainer
                          : null,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  void _sendQuickReaction(Message msg) {
    if (msg.isDeleted || msg.text == '[deleted]') return;
    final emoji = _quickReactionEmoji;
    final reacted = _messageReactions[msg.id]
            ?.containsKey(emoji) == true &&
        _messageReactions[msg.id]![emoji]!.contains(_currentUserId);
    final action = reacted ? 'remove' : 'add';
    widget.api.sendReaction(msg.id, emoji, action);
    setState(() {
      final emojiMap = _messageReactions.putIfAbsent(msg.id, () => {});
      if (reacted) {
        emojiMap[emoji]?.remove(_currentUserId);
        if (emojiMap[emoji]?.isEmpty == true) emojiMap.remove(emoji);
        if (emojiMap.isEmpty) _messageReactions.remove(msg.id);
      } else {
        emojiMap.putIfAbsent(emoji, () => {}).add(_currentUserId);
      }
    });
  }

  void _showThreeDotMenu() {
    final renderBox = _threeDotKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final position = renderBox.localToGlobal(Offset.zero);
    final screenSize = MediaQuery.of(context).size;
    const double popupWidth = 220;
    const double itemHeight = 44;
    const double items = 3;
    const double popupHeight = itemHeight * items + 8;

    double left = position.dx - popupWidth + renderBox.size.width;
    double top = position.dy + renderBox.size.height + 4;

    if (left < 8) left = 8;
    if (left + popupWidth + 8 > screenSize.width) left = screenSize.width - popupWidth - 8;
    if (top + popupHeight + 8 > screenSize.height) top = position.dy - popupHeight - 4;
    if (top < 8) top = 8;

    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          GestureDetector(onTap: () => entry.remove(), child: Container(color: Colors.transparent)),
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: Colors.transparent,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    width: popupWidth,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _threeDotAction(
                          icon: Icons.info_outline,
                          label: l10n.information,
                          onTap: () { entry.remove(); _navigateToProfileOrGroup(); },
                        ),
                        _threeDotAction(
                          icon: _isMuted ? Icons.notifications : Icons.notifications_off,
                          label: _isMuted ? l10n.unmute : l10n.mute,
                          onTap: () async {
                            entry.remove();
                            await MuteService.toggle(widget.chatId);
                            await _loadMuteStatus();
                          },
                        ),
                        _threeDotAction(
                          icon: Icons.emoji_emotions_outlined,
                          label: l10n.quickReaction,
                          trailing: Text(_quickReactionEmoji, style: const TextStyle(fontSize: 20)),
                          onTap: () { entry.remove(); _showQuickReactionPicker(); },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(entry);
  }

  Widget _threeDotAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurface.withValues(alpha: 0.8)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: theme.colorScheme.onSurface.withValues(alpha: 0.9)),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  int _emojiTabIndex = 0;
  bool _showStickers = false;
  List<StickerPack> _stickerPacks = [];
  int _selectedStickerPackIndex = 0;
  bool _stickerPacksLoading = false;

  Future<void> _loadStickerPacks() async {
    print('[STICKERS] _loadStickerPacks called');
    setState(() => _stickerPacksLoading = true);
    try {
      final packs = await widget.api.getStickerPacks();
      print('[STICKERS] got packs: ${packs.length} count=${packs.isNotEmpty ? packs[0].name : "none"}');
      if (mounted) {
        setState(() {
          _stickerPacks = packs;
          _selectedStickerPackIndex = 0;
          _stickerPacksLoading = false;
        });
        print('[STICKERS] setState done, packs=${_stickerPacks.length}');
      }
    } catch (e) {
      print('[STICKERS] error: $e');
      if (mounted) setState(() => _stickerPacksLoading = false);
    }
  }

  Widget _buildEmojiModeToggle() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 200,
            child: Container(
              height: 34,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _showStickers = false),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: 30,
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: _showStickers ? Colors.transparent : theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.emoji_emotions, size: 16,
                              color: _showStickers ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onPrimaryContainer),
                            const SizedBox(width: 4),
                            Text(
                              'Emoji',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _showStickers ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        setState(() => _showStickers = true);
                        _loadStickerPacks();
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: 30,
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: _showStickers ? theme.colorScheme.primaryContainer : Colors.transparent,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.auto_awesome, size: 16,
                              color: _showStickers ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(
                              'Stickers',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _showStickers ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_showStickers)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 34,
                height: 34,
                child: IconButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StickerPackManagerScreen(api: widget.api),
                      ),
                    );
                    _loadStickerPacks();
                  },
                  icon: const Icon(Icons.add, size: 20),
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    foregroundColor: theme.colorScheme.onPrimaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmojiPanel() {
    const categories = <(String, String, List<String>)>[
      ('😀', 'Smileys', [
        '😀', '😃', '😄', '😁', '😅', '😂', '🤣', '😊', '😇', '🙂', '😉', '😌',
        '😍', '🥰', '😘', '😗', '😙', '😚', '😋', '😛', '😜', '🤪', '😝', '🤑',
        '🤗', '🤭', '🤫', '🤔', '🤐', '🤨', '😐', '😑', '😶', '😏', '😒', '🙄',
        '😬', '😮', '😲', '😴', '🤤', '😪', '😵', '🤯', '🥳', '🤩', '😎', '🤓',
        '🧐', '😕', '😟', '🙁', '😢', '😭', '😤', '😠', '😡', '🤬',
      ]),
      ('✌️', 'Gestures', [
        '👍', '👎', '👊', '✊', '🤛', '🤜', '👏', '🙌', '👐', '🤝', '✌️', '🤞',
        '🤟', '🤘', '🤙', '👆', '👇', '👈', '👉', '✋', '💪', '🦵', '👀', '👅', '👄',
      ]),
      ('❤️', 'Hearts', [
        '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💕', '💞', '💓',
        '💗', '💖', '💘', '💝', '💟', '💋',
      ]),
      ('🐱', 'Animals', [
        '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮',
        '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🐤', '🦆', '🦅', '🦉', '🐺', '🐴',
        '🦄', '🐝', '🐛', '🦋', '🐌', '🐞', '🐜', '🦟', '🦂', '🐢', '🐍', '🦎',
        '🐙', '🦑', '🦐', '🦀', '🐟', '🐠', '🐬', '🐳', '🐋',
      ]),
      ('🍔', 'Food', [
        '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🍒', '🍑', '🥭',
        '🍍', '🥝', '🍅', '🥑', '🥦', '🥒', '🌽', '🥕', '🥔', '🍞', '🥐', '🧀',
        '🥚', '🍳', '🥞', '🥓', '🍗', '🍖', '🍔', '🍟', '🍕', '🥪', '🌮', '🌯',
        '🥘', '🍝', '🍜', '🍲', '🍛', '🍣', '🍤', '🥟', '🍦', '🍧', '🍩', '🍪',
        '🎂', '🍰',
      ]),
      ('🎮', 'Objects', [
        '⌚', '📱', '💻', '🖥️', '🖨️', '🕹️', '💾', '💿', '📷', '📸', '📹', '🎥',
        '📞', '☎️', '📺', '📻', '⏰', '💡', '🔦', '🔋', '🔌', '💵', '💰', '💳',
        '🛒', '🔧', '🔨', '🎁', '🎈', '🎉', '🎊', '🏆', '🥇', '🥈', '🥉', '🏅',
        '🎯', '🎮', '🎲', '🎭', '🎨',
      ]),
    ];

    final theme = Theme.of(context);
    final currentCat = categories[_emojiTabIndex];

    return Container(
      height: 290,
      decoration: BoxDecoration(
        color: theme.cardColor,
      ),
      child: Column(
        children: [
          if (_showStickers)
            Column(
              children: [
                if (_stickerPacks.isNotEmpty)
                  SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _stickerPacks.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 6),
                      itemBuilder: (_, i) {
                        final isActive = _selectedStickerPackIndex == i;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: GestureDetector(
                            onTap: () => setState(() => _selectedStickerPackIndex = i),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                              decoration: BoxDecoration(
                                color: isActive ? theme.colorScheme.secondaryContainer : Colors.transparent,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Text(
                                _stickerPacks[i].name,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: isActive ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                SizedBox(
                  height: _stickerPacks.isNotEmpty ? 250 : 290,
                  child: _stickerPacksLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _stickerPacks.isEmpty
                          ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.auto_awesome, size: 48, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                              const SizedBox(height: 8),
                              Text('No sticker packs available', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                            ],
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisSpacing: 4,
                            crossAxisSpacing: 4,
                            childAspectRatio: 1,
                          ),
                          itemCount: _stickerPacks[_selectedStickerPackIndex].stickers?.length ?? 0,
                          itemBuilder: (_, i) {
                            final sticker = _stickerPacks[_selectedStickerPackIndex].stickers![i];
                            return GestureDetector(
                              onTap: () {
                                _sendSticker(sticker);
                                _showEmojiPanel = false;
                                setState(() {});
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: CachedNetworkImage(
                                    imageUrl: '${ApiService.baseUrl}${sticker.imageUrl}',
                                    fit: BoxFit.contain,
                                    placeholder: (_, __) => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                                    errorWidget: (_, __, ___) => Icon(Icons.broken_image, color: theme.colorScheme.onSurfaceVariant),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            )
          else ...[
            SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 4),
                itemBuilder: (_, i) {
                  final isActive = _emojiTabIndex == i;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: GestureDetector(
                      onTap: () => setState(() => _emojiTabIndex = i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        decoration: BoxDecoration(
                          color: isActive
                              ? theme.colorScheme.secondaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(categories[i].$1,
                          style: const TextStyle(fontSize: 18)),
                      ),
                    ),
                  );
                },
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: GridView.builder(
                  key: ValueKey(_emojiTabIndex),
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 8,
                    mainAxisSpacing: 1,
                    crossAxisSpacing: 1,
                  ),
                  itemCount: currentCat.$3.length,
                  itemBuilder: (_, i) {
                    final emoji = currentCat.$3[i];
                    return GestureDetector(
                      onTap: () {
                        final text = _messageController.text;
                        final sel = _messageController.selection;
                        final pos = sel.isValid ? sel.start : text.length;
                        final newText = text.substring(0, pos) + emoji + text.substring(pos);
                        _messageController.text = newText;
                        _messageController.selection = TextSelection.collapsed(offset: pos + emoji.length);
                        setState(() {});
                      },
                      child: Container(
                        alignment: Alignment.center,
                        child: Text(emoji, style: const TextStyle(fontSize: 24)),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showQuickReactionPicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                AppLocalizations.of(context).quickReaction,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: _reactionEmojis.map((emoji) {
                  final isActive = _quickReactionEmoji == emoji;
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _setQuickReactionForChat(emoji);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isActive
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                        border: isActive
                            ? Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 2,
                              )
                            : null,
                      ),
                      child: Text(emoji, style: const TextStyle(fontSize: 32)),
                    ),
                  );
                }).toList(),
              ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSwipeableMessage(Message msg, Widget child) {
    final isMe = msg.userId == _currentUserId;
    return Dismissible(
      key: ValueKey('dismiss_${msg.id}'),
      direction: isMe
          ? DismissDirection.startToEnd
          : DismissDirection.endToStart,
      dismissThresholds: {
        isMe ? DismissDirection.startToEnd : DismissDirection.endToStart: 0.18,
      },
      movementDuration: const Duration(milliseconds: 200),
      confirmDismiss: (direction) async {
        _startReply(msg);
        return false;
      },
      background: Container(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: Colors.blue.withAlpha(50),
        child: const Icon(Icons.reply, color: Colors.blue),
      ),
      child: child,
    );
  }

  Widget _buildPendingFilePreview() {
    final isImage = _pendingFileMimeType?.startsWith('image/') ?? false;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: isImage && _pendingFile != null
                      ? Image.file(
                          _pendingFile!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _fileIcon(),
                        )
                      : _fileIcon(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _pendingFileName ?? AppLocalizations.of(context).file,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_isUploading)
                Text(
                  _uploadStatus,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _cancelPendingFile,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
          if (_isUploading) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: _uploadProgress > 0 ? _uploadProgress : null,
            ),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _fileIcon() {
    final isVideo = _pendingFileMimeType?.startsWith('video/') ?? false;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Icon(isVideo ? Icons.videocam : Icons.insert_drive_file, size: 28),
    );
  }

  Widget _buildStatusIcon(MessageStatus status) {
    switch (status) {
      case MessageStatus.sending:
        return SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.outline,
          ),
        );
      case MessageStatus.read:
        return Icon(Icons.done_all, size: 14, color: Colors.blue[200]);
      case MessageStatus.delivered:
        return Icon(
          Icons.done_all,
          size: 14,
          color: Theme.of(context).colorScheme.outline,
        );
      case MessageStatus.sent:
        return Icon(
          Icons.check,
          size: 14,
          color: Theme.of(context).colorScheme.outline,
        );
    }
  }

  String _getReplyPreview(String replyId) {
    final replyMsg = _messages.firstWhere(
      (m) => m.id == replyId,
      orElse: () => Message(
        id: '',
        chatId: '',
        userId: '',
        text: AppLocalizations.of(context).messageNotFound,
        createdAt: 0,
      ),
    );
    if (replyMsg.replyUsername != null && replyMsg.replyText != null) {
      return '${replyMsg.replyUsername}: ${replyMsg.replyText}';
    }
    return replyMsg.text;
  }

  void _openVideoFullscreen(String videoUrl) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _VideoFullscreenPlayer(videoUrl: videoUrl),
      ),
    );
  }

  Widget _buildMessageText(String text, Color textColor) {
    final urlRegExp = RegExp(r'https?://[^\s]+');
    final matches = urlRegExp.allMatches(text).toList();

    if (matches.isEmpty) {
      return Text(text, style: TextStyle(color: textColor));
    }

    String stripTrailingPunctuation(String url) {
      return url.replaceAll(RegExp(r'[.,!?;:)]+$'), '');
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final m in matches) {
      if (m.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, m.start)));
      }
      final rawUrl = text.substring(m.start, m.end);
      final cleanUrl = stripTrailingPunctuation(rawUrl);
      spans.add(
        TextSpan(
          text: rawUrl,
          style: const TextStyle(
            color: Colors.blue,
            decoration: TextDecoration.underline,
          ),
          recognizer: TapGestureRecognizer()..onTap = () => _openUrl(cleanUrl),
        ),
      );
      lastEnd = m.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return RichText(
      text: TextSpan(
        style: TextStyle(color: textColor),
        children: spans,
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return;
    try {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    } catch (e) {
      debugPrint('=== URL LAUNCH ERROR: $e ===');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _showMessageMenu(Message msg, Offset position) {
    final overlay = Overlay.of(context);
    final screenSize = MediaQuery.of(context).size;

    const double popupWidth = 220;
    const double emojiRowHeight = 52;
    const double actionItemHeight = 44;
    int actionCount = 2;
    if (msg.userId == _currentUserId) actionCount += 2;
    final double popupHeight = emojiRowHeight + 1 + actionCount * actionItemHeight + 12;

    double left = position.dx;
    double top = position.dy + 12;

    if (left + popupWidth + 12 > screenSize.width) {
      left = screenSize.width - popupWidth - 12;
    }
    if (left < 12) left = 12;

    if (top + popupHeight + 12 > screenSize.height) {
      top = position.dy - popupHeight - 12;
    }
    if (top < 12) top = 12;

    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          GestureDetector(
            onTap: () => entry.remove(),
            child: Container(color: Colors.transparent),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              color: Colors.transparent,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    width: popupWidth,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 4),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: _reactionEmojis.map((emoji) {
                            final reacted = _messageReactions[msg.id]
                                    ?.containsKey(emoji) == true &&
                                _messageReactions[msg.id]![emoji]!.contains(_currentUserId);
                            return GestureDetector(
                              onTap: () {
                                entry.remove();
                                final action = reacted ? 'remove' : 'add';
                                widget.api.sendReaction(msg.id, emoji, action);
                                setState(() {
                                  final emojiMap = _messageReactions.putIfAbsent(msg.id, () => {});
                                  if (reacted) {
                                    emojiMap[emoji]?.remove(_currentUserId);
                                    if (emojiMap[emoji]?.isEmpty == true) emojiMap.remove(emoji);
                                    if (emojiMap.isEmpty) _messageReactions.remove(msg.id);
                                  } else {
                                    emojiMap.putIfAbsent(emoji, () => {}).add(_currentUserId);
                                  }
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: reacted
                                      ? theme.colorScheme.primaryContainer.withValues(alpha: 0.7)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(emoji, style: const TextStyle(fontSize: 24)),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                      Divider(
                          height: 1,
                          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                        ),
                        _menuAction(
                          icon: Icons.content_copy,
                          label: l10n.copy,
                          onTap: () {
                            entry.remove();
                            final msgText = _decryptedTexts[msg.id] ?? msg.text;
                            if (msgText.isNotEmpty) {
                              Clipboard.setData(ClipboardData(text: msgText));
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Скопировано'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                        _menuAction(
                          icon: Icons.reply,
                          label: l10n.reply,
                          onTap: () {
                            entry.remove();
                            _startReply(msg);
                          },
                        ),
                        if (msg.stickerId != null) ...[
                          _menuAction(
                            icon: Icons.collections,
                            label: 'View Pack',
                            onTap: () {
                              entry.remove();
                              if (msg.stickerPackId != null) {
                                _viewStickerPack(msg.stickerPackId!);
                              }
                            },
                          ),
                          _menuAction(
                            icon: Icons.add_circle_outline,
                            label: 'Add Pack',
                            onTap: () {
                              entry.remove();
                              if (msg.stickerPackId != null) {
                                _addStickerPack(msg.stickerPackId!);
                              }
                            },
                          ),
                        ],
                        if (msg.userId == _currentUserId) ...[
                          _menuAction(
                            icon: Icons.edit,
                            label: l10n.edit,
                            onTap: () {
                              entry.remove();
                              _startEdit(msg);
                            },
                          ),
                          _menuAction(
                            icon: Icons.delete,
                            label: l10n.delete,
                            isDestructive: true,
                            onTap: () {
                              entry.remove();
                              _deleteMessage(msg);
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(entry);
  }

  Widget _menuAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: isDestructive
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  color: isDestructive
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurface.withValues(alpha: 0.9),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onAudioComplete(String completedId) {
    final completed = _messages.where((m) => m.id == completedId).firstOrNull;
    if (completed == null) return;
    const audioExts = ['mp3', 'wav', 'ogg', 'm4a', 'aac', 'flac'];
    bool isAudioFile(Message m) {
      if (m.fileId == null) return false;
      final fileName = m.text.replaceFirst('[File] ', '');
      final ext = fileName.split('.').last.toLowerCase();
      return audioExts.contains(ext);
    }

    final next = _messages
        .where((m) => m.createdAt > completed.createdAt && isAudioFile(m))
        .fold<Message?>(
          null,
          (min, m) => min == null || m.createdAt < min.createdAt ? m : min,
        );
    if (next == null) return;
    for (final entry in _audioPlayers.entries) {
      if (entry.key != next.id) entry.value.pause();
    }
    _audioPlayers[next.id]?.play();
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _getRecordingDuration() {
    final min = (_recordingSeconds ~/ 60).toString().padLeft(2, '0');
    final sec = (_recordingSeconds % 60).toString().padLeft(2, '0');
    return '$min:$sec';
  }

  List<Object> get _displayItems {
    final items = <Object>[];
    String? lastDate;
    for (final msg in _messages) {
      final d = _messageDateStr(msg.createdAt);
      if (d != lastDate) {
        items.add(d);
        lastDate = d;
      }
      items.add(msg);
    }
    return items;
  }

  String _messageDateStr(int ts) {
    final now = DateTime.now();
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      final l10n = AppLocalizations.of(context);
      return l10n.today;
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (date.year == yesterday.year &&
        date.month == yesterday.month &&
        date.day == yesterday.day) {
      final l10n = AppLocalizations.of(context);
      return l10n.yesterday;
    }
    final l10n = AppLocalizations.of(context);
    return l10n.formatDate(ts);
  }

  Widget _buildDateSeparator(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.8,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _AudioPlayerWidget extends StatefulWidget {
  final String audioUrl;
  final AudioPlayer audioPlayer;
  final String fileName;
  final bool isMe;
  final bool showFileName;
  final VoidCallback? onComplete;

  const _AudioPlayerWidget({
    super.key,
    required this.audioPlayer,
    required this.audioUrl,
    required this.fileName,
    required this.isMe,
    this.showFileName = true,
    this.onComplete,
  });

  @override
  State<_AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<_AudioPlayerWidget> {
  static int _instanceCounter = 0;
  static final Map<AudioPlayer, String> _playerUrls = {};
  final int _instanceId = _instanceCounter++;
  late AudioPlayer _audioPlayer;
  bool _isInitialized = false;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription? _positionSub;
  StreamSubscription? _playerStateSub;

  @override
  void initState() {
    super.initState();
    debugPrint(
      '[_AudioPlayerWidgetState#$runtimeType.initState] instance=$_instanceId url=${widget.audioUrl}',
    );
    _audioPlayer = widget.audioPlayer;
    _setupStreams();
    _initAudio();
  }

  void _setupStreams() {
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _positionSub = _audioPlayer.positionStream.listen((pos) {
      if (mounted && pos.inSeconds >= 0) {
        if (_position > Duration.zero && pos == Duration.zero) {
          debugPrint(
            '[_AudioWidget#${_instanceId}.positionStream] RESET TO ZERO _isPlaying=$_isPlaying',
          );
        }
        setState(() => _position = pos);
      }
    });
    _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        if (_isPlaying && !state.playing) {
          debugPrint(
            '[_AudioWidget#${_instanceId}.playerStateStream] PLAYING→STOPPED processingState=${state.processingState}',
          );
        }
        setState(() {
          _isPlaying = state.playing;
          if (state.processingState == ProcessingState.completed) {
            _audioPlayer.seek(Duration.zero);
            _audioPlayer.pause();
          }
        });
        if (state.processingState == ProcessingState.completed) {
          widget.onComplete?.call();
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant _AudioPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    debugPrint(
      '[_AudioWidget#${_instanceId}.didUpdateWidget] url=${widget.audioUrl} sameUrl=${oldWidget.audioUrl == widget.audioUrl}',
    );
    if (oldWidget.audioUrl != widget.audioUrl) {
      debugPrint(
        '[_AudioWidget#${_instanceId}.didUpdateWidget] URL CHANGED, reloading',
      );
      _playerUrls.remove(_audioPlayer);
      _initAudio();
    }
  }

  Future<void> _initAudio() async {
    final cachedUrl = _playerUrls[_audioPlayer];
    debugPrint(
      '[_AudioWidget#${_instanceId}._initAudio] cachedUrl=$cachedUrl widgetUrl=${widget.audioUrl} skip=${cachedUrl == widget.audioUrl}',
    );
    if (cachedUrl == widget.audioUrl) {
      final duration = _audioPlayer.duration;
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _duration = duration ?? Duration.zero;
        });
      }
      return;
    }
    try {
      debugPrint(
        '[_AudioWidget#${_instanceId}._initAudio] CALLING setUrl url=${widget.audioUrl}',
      );
      await _audioPlayer.setUrl(widget.audioUrl);
      _playerUrls[_audioPlayer] = widget.audioUrl;
      debugPrint('[_AudioWidget#${_instanceId}._initAudio] setUrl OK');
      final duration = _audioPlayer.duration;
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _duration = duration ?? Duration.zero;
        });
      }
    } catch (e) {
      debugPrint('Audio init failed: $e');
    }
  }

  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  String _formatDuration(Duration d) {
    final min = d.inMinutes.remainder(60);
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$min:$sec';
  }

  @override
  void dispose() {
    debugPrint(
      '[_AudioPlayerWidgetState#$runtimeType.dispose] instance=$_instanceId',
    );
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textColor = widget.isMe
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSurface;
    final dimColor = textColor.withValues(alpha: 0.6);
    final accentColor = widget.isMe
        ? dimColor
        : Theme.of(context).colorScheme.primary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _isInitialized ? _togglePlayPause : null,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: textColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              color: textColor,
              size: 24,
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 160,
          child: _isInitialized
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.showFileName)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          widget.fileName,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) {
                        if (!_isInitialized) return;
                        final ratio = (details.localPosition.dx / 160.0).clamp(
                          0.0,
                          1.0,
                        );
                        _audioPlayer.seek(
                          Duration(
                            milliseconds: (_duration.inMilliseconds * ratio)
                                .toInt(),
                          ),
                        );
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: _duration.inMilliseconds > 0
                              ? (_position.inMilliseconds /
                                        _duration.inMilliseconds)
                                    .clamp(0.0, 1.0)
                              : 0,
                          backgroundColor: dimColor.withValues(alpha: 0.25),
                          color: accentColor,
                          minHeight: 8,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          _formatDuration(_position),
                          style: TextStyle(fontSize: 10, color: dimColor),
                        ),
                        Text(
                          ' / ',
                          style: TextStyle(fontSize: 10, color: dimColor),
                        ),
                        Text(
                          _formatDuration(_duration),
                          style: TextStyle(fontSize: 10, color: dimColor),
                        ),
                      ],
                    ),
                  ],
                )
              : const SizedBox(height: 4, child: LinearProgressIndicator()),
        ),
      ],
    );
  }
}

class _VideoThumbnail extends StatefulWidget {
  final String videoUrl;
  final String fileName;

  const _VideoThumbnail({required this.videoUrl, required this.fileName});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  Uint8List? _thumbnailBytes;

  @override
  void initState() {
    super.initState();
    _generateThumbnail();
  }

  Future<void> _generateThumbnail() async {
    try {
      final thumbnail = await VideoThumbnail.thumbnailData(
        video: widget.videoUrl,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 400,
        quality: 75,
        timeMs: 1000,
      );
      if (mounted) {
        setState(() {
          _thumbnailBytes = thumbnail;
        });
      }
    } catch (e) {
      debugPrint('Thumbnail generation failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      height: 150,
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_thumbnailBytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                _thumbnailBytes!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Container(color: Colors.grey[800]),
              ),
            ),
          Center(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(8),
              child: const Icon(
                Icons.play_arrow,
                color: Colors.white,
                size: 40,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SafeVideoPlayer extends StatefulWidget {
  final String videoUrl;

  const _SafeVideoPlayer({required this.videoUrl});

  @override
  State<_SafeVideoPlayer> createState() => _SafeVideoPlayerState();
}

class _SafeVideoPlayerState extends State<_SafeVideoPlayer> {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl),
      );
      await controller.initialize();

      if (mounted) {
        setState(() {
          _controller = controller;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Video initialization failed: $e');
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        height: 150,
        width: 200,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    if (_hasError || _controller == null) {
      return Container(
        height: 150,
        width: 200,
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white54, size: 40),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context).videoNotSupported,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return AspectRatio(
      aspectRatio: _controller!.value.aspectRatio,
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(_controller!),
          GestureDetector(
            onTap: () {
              setState(() {
                if (_controller!.value.isPlaying) {
                  _controller!.pause();
                } else {
                  _controller!.play();
                }
              });
            },
            child: AnimatedOpacity(
              opacity: _controller!.value.isPlaying ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(12),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 40,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoFullscreenPlayer extends StatefulWidget {
  final String videoUrl;

  const _VideoFullscreenPlayer({required this.videoUrl});

  @override
  State<_VideoFullscreenPlayer> createState() => _VideoFullscreenPlayerState();
}

class _VideoFullscreenPlayerState extends State<_VideoFullscreenPlayer> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _hasError = false;
  bool _showControls = true;
  bool _isPlaying = false;
  double _currentPosition = 0;
  double _maxPosition = 1;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initVideo();
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controller.removeListener(_onVideoUpdate);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initVideo() async {
    try {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl),
      );
      await _controller.initialize();
      _controller.addListener(_onVideoUpdate);
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _maxPosition = _controller.value.duration.inMilliseconds.toDouble();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _hasError = true);
      }
    }
  }

  void _onVideoUpdate() {
    if (!mounted) return;
    final isPlaying = _controller.value.isPlaying;
    final position = _controller.value.position.inMilliseconds.toDouble();
    final duration = _controller.value.duration.inMilliseconds.toDouble();

    if (_isPlaying != isPlaying ||
        (_currentPosition - position).abs() > 500 ||
        _maxPosition != duration) {
      setState(() {
        _isPlaying = isPlaying;
        _currentPosition = position;
        _maxPosition = duration > 0 ? duration : 1;
      });
    }
  }

  void _togglePlayPause() {
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: _hasError
                  ? Text(
                      AppLocalizations.of(context).videoNotSupported,
                      style: const TextStyle(color: Colors.white),
                    )
                  : !_isInitialized
                  ? const CircularProgressIndicator(color: Colors.white)
                  : AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
            ),
            if (_isInitialized && _showControls)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.3),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (_controller.value.isPlaying)
                          const SizedBox(height: 60),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Text(
                                _formatDuration(
                                  Duration(
                                    milliseconds: _currentPosition.toInt(),
                                  ),
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              Expanded(
                                child: Slider(
                                  value: _currentPosition.clamp(0, _maxPosition),
                                  min: 0,
                                  max: _maxPosition > 0 ? _maxPosition : 1,
                                  onChanged: (value) {
                                    _controller.seekTo(
                                      Duration(milliseconds: value.toInt()),
                                    );
                                    setState(() {
                                      _currentPosition = value;
                                    });
                                  },
                                ),
                              ),
                              Text(
                                _formatDuration(
                                  Duration(milliseconds: _maxPosition.toInt()),
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              onPressed: () {
                                final newPosition =
                                    _controller.value.position -
                                    const Duration(seconds: 10);
                                _controller.seekTo(newPosition);
                              },
                              icon: const Icon(
                                Icons.replay_10,
                                color: Colors.white,
                                size: 36,
                              ),
                            ),
                            const SizedBox(width: 24),
                            IconButton(
                              onPressed: _togglePlayPause,
                              icon: Icon(
                                _controller.value.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                color: Colors.white,
                                size: 48,
                              ),
                            ),
                            const SizedBox(width: 24),
                            IconButton(
                              onPressed: () {
                                final newPosition =
                                    _controller.value.position +
                                    const Duration(seconds: 10);
                                _controller.seekTo(newPosition);
                              },
                              icon: const Icon(
                                Icons.forward_10,
                                color: Colors.white,
                                size: 36,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
