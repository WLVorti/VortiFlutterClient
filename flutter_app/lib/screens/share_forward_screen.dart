import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/share_receiver.dart';
import '../services/crypto_service.dart';
import '../utils/avatar_utils.dart';
import '../l10n/app_localizations.dart';
import '../widgets/user_search_sheet.dart';

class ShareForwardScreen extends StatefulWidget {
  final ApiService api;
  final SharedContent content;

  const ShareForwardScreen({
    super.key,
    required this.api,
    required this.content,
  });

  @override
  State<ShareForwardScreen> createState() => _ShareForwardScreenState();
}

class _ShareForwardScreenState extends State<ShareForwardScreen> {
  List<Chat> _chats = [];
  List<Chat> _filtered = [];
  bool _isLoading = true;
  bool _sending = false;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadChats() async {
    try {
      final chats = await widget.api.getChats();
      if (!mounted) return;
      setState(() {
        _chats = chats;
        _filtered = chats;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _onSearchChanged(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _chats
          : _chats.where((c) {
              final name = (c.name ?? '').toLowerCase();
              return name.contains(q);
            }).toList();
    });
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData _fileIcon(SharedFileInfo f) {
    if (f.isImage) return Icons.image;
    if (f.isVideo) return Icons.movie;
    if (f.isAudio) return Icons.music_note;
    return Icons.insert_drive_file;
  }

  String _chatDisplayName(Chat chat) {
    final currentUserId = widget.api.userId;
    if (chat.type == 'group') return chat.name ?? 'Group';
    final otherUserId = chat.participants.firstWhere(
      (p) => p != currentUserId,
      orElse: () => chat.participants.first,
    );
    return chat.name ?? otherUserId;
  }

  Future<void> _sendText(Chat chat, String text) async {
    String sendText = text;
    String? keyType;
    if (chat.type == 'direct' && text.isNotEmpty) {
      final currentUserId = widget.api.userId;
      final otherUserId = chat.participants.firstWhere(
        (p) => p != currentUserId,
        orElse: () => chat.participants.first,
      );
      try {
        final box = await CryptoService.getBox(otherUserId, widget.api);
        if (box != null) {
          sendText = CryptoService.encryptMessage(text, box);
          keyType = 'e2ee_v1';
        }
      } catch (_) {}
    }
    widget.api.sendMessage(chat.id, sendText, keyType: keyType);
  }

  Future<bool> _uploadAndSendFile(Chat chat, SharedFileInfo info) async {
    final file = File(info.path);
    if (!await file.exists()) return false;
    final size = await file.length();

    Map<String, String>? result;
    if (info.isVideo && size > 5 * 1024 * 1024) {
      result = await widget.api.uploadFileChunked(file, mimeType: info.mimeType);
    } else {
      result = await widget.api.uploadFile(file, mimeType: info.mimeType);
    }
    if (result == null) return false;

    widget.api.sendFile(chat.id, result['fileId']!, mimeType: result['mimeType']);
    return true;
  }

  void _cleanupFiles() {
    for (final info in widget.content.files) {
      try {
        final f = File(info.path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _sendTo(Chat chat) async {
    if (_sending) return;
    setState(() => _sending = true);
    var ok = true;
    try {
      final text = widget.content.text?.trim() ?? '';
      if (text.isNotEmpty) {
        await _sendText(chat, text);
      }
      for (final info in widget.content.files) {
        final sent = await _uploadAndSendFile(chat, info);
        if (!sent) ok = false;
      }
    } catch (e) {
      ok = false;
      if (mounted) {
        if (e is FileTooLargeException) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).fileTooLarge)),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).failedToSend)),
          );
        }
      }
    } finally {
      _cleanupFiles();
    }

    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).shareSent)),
      );
      Navigator.of(context).pop();
    } else {
      setState(() => _sending = false);
    }
  }

  Future<void> _createNewChat() async {
    if (_sending) return;
    await UserSearchSheet.show(
      context: context,
      api: widget.api,
      config: UserSearchSheetConfig(
        title: AppLocalizations.of(context).newChat,
      ),
      onSubmitted: (users) async {
        if (users.isEmpty) return;
        final user = users.first;
        final chatId = await widget.api.createChat('direct', [user.id]);
        if (chatId != null && mounted) {
          final chat = Chat(
            id: chatId,
            name: user.displayName ?? user.username,
            type: 'direct',
            createdAt: DateTime.now().millisecondsSinceEpoch,
            participants: [widget.api.userId ?? '', user.id],
          );
          await _sendTo(chat);
        }
      },
    );
  }

  Widget _buildPreview() {
    final content = widget.content;
    final hasText = (content.text?.trim().isNotEmpty ?? false);
    final hasSubject = (content.subject?.trim().isNotEmpty ?? false);
    if (!hasText && content.files.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppLocalizations.of(context).sharedContent,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            if (hasSubject)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  content.subject!,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            if (hasText)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  content.text!,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            for (final f in content.files)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(_fileIcon(f), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (f.size > 0)
                      Text(
                        _formatSize(f.size),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.forwardTo),
        actions: [
          if (_sending)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.person_add_alt),
            tooltip: l10n.newChat,
            onPressed: _createNewChat,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildPreview(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: l10n.searchMessages,
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _onSearchChanged('');
                        },
                      )
                    : null,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                    ? Center(child: Text(l10n.noChatsYet))
                    : ListView.builder(
                        itemCount: _filtered.length,
                        itemBuilder: (_, i) {
                          final chat = _filtered[i];
                          final isDirect = chat.type == 'direct';
                          final initial = isDirect
                              ? (_chatDisplayName(chat).isNotEmpty
                                  ? _chatDisplayName(chat)[0].toUpperCase()
                                  : '?')
                              : (chat.name?.isNotEmpty ?? false)
                                  ? chat.name![0].toUpperCase()
                                  : 'G';
                          return ListTile(
                            leading: Stack(
                              children: [
                                CircleAvatar(
                                  backgroundColor: colorFromId(chat.id),
                                  backgroundImage: chat.avatarUrl != null && chat.avatarUrl!.isNotEmpty
                                      ? CachedNetworkImageProvider('${ApiService.baseUrl}${chat.avatarUrl}')
                                      : null,
                                  child: Text(initial),
                                ),
                                if (chat.type == 'group')
                                  const Positioned(
                                    right: -2,
                                    bottom: -2,
                                    child: CircleAvatar(
                                      radius: 10,
                                      child: Icon(Icons.group, size: 12),
                                    ),
                                  ),
                              ],
                            ),
                            title: Text(
                              _chatDisplayName(chat),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: chat.type == 'group'
                                ? Icon(Icons.group, size: 18, color: Theme.of(context).colorScheme.primary)
                                : null,
                            onTap: () => _sendTo(chat),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
