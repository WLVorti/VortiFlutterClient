import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/chat_cache.dart';
import '../services/hidden_chats.dart';
import '../services/mute_service.dart';
import '../services/theme_provider.dart';
import '../l10n/app_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/models.dart';
import '../utils/avatar_utils.dart';
import 'chat_screen.dart';
import 'auth_screen.dart';
import 'profile_screen.dart';
import 'user_profile_screen.dart';
import 'group_info_screen.dart';
import '../widgets/user_search_sheet.dart';

class HomeScreen extends StatefulWidget {
  final ApiService api;

  const HomeScreen({super.key, required this.api});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  final PageController _pageController = PageController();
  final GlobalKey<_ChatsTabState> _chatsTabKey = GlobalKey<_ChatsTabState>();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    setState(() => _currentIndex = index);
    _pageController.jumpToPage(index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        children: [
          ChatsTab(key: _chatsTabKey, api: widget.api),
          CommunitiesTab(api: widget.api),
          ProfileTab(api: widget.api),
        ],
      ),
      bottomNavigationBar: Stack(
        children: [
          Positioned.fill(
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
                        Theme.of(context).colorScheme.surface.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          NavigationBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            elevation: 0,
            selectedIndex: _currentIndex,
            onDestinationSelected: _onTabTapped,
            destinations: [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: AppLocalizations.of(context).chats,
              ),
              NavigationDestination(
                icon: Icon(Icons.group_outlined),
                selectedIcon: Icon(Icons.group),
                label: AppLocalizations.of(context).communities,
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: AppLocalizations.of(context).account,
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: _currentIndex == 0
          ? FloatingActionButton(
              onPressed: () => _chatsTabKey.currentState?._createChat(),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}

class ChatsTab extends StatefulWidget {
  final ApiService api;

  const ChatsTab({super.key, required this.api});

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> with WidgetsBindingObserver {
  List<Chat> _chats = [];
  final Map<String, int> _unreadCounts = {};
  final Set<String> _onlineUsers = {};
  bool _isLoading = true;
  Function(Map<String, dynamic>)? _messageHandler;
  VoidCallback? _onlineHandler;
  final _searchController = TextEditingController();
  List<MessageSearchResult> _searchResults = [];
  bool _searchHasMore = false;
  bool _isSearching = false;
  Timer? _searchTimer;

  List<Chat> _filterChats(List<Chat> chats) {
    return chats.where((c) =>
      c.type == 'direct' &&
      c.lastMessage != null &&
      c.lastMessage!.isNotEmpty &&
      !HiddenChats.isHidden(c.id)
    ).toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final cached = ChatCache.getChats();
    if (cached.isNotEmpty) {
      _chats = _filterChats(cached);
      _isLoading = false;
    }
    _loadData();
    _setupWebSocket();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_messageHandler != null) {
      widget.api.removeMessageListener(_messageHandler!);
    }
    if (_onlineHandler != null) {
      widget.api.onOnlineUsersChanged = null;
    }
    _searchController.dispose();
    _searchTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      widget.api.reconnectWebSocket();
      _loadData();
    }
  }

  Future<void> _loadData() async {
    try {
      final chats = await widget.api.getChats();
      await ChatCache.saveChats(chats);
      if (mounted) {
        setState(() {
          _chats = _filterChats(chats);
          _isLoading = false;
        });

        final unread = await widget.api.getUnreadCounts();
        if (mounted) {
          setState(() {
            _unreadCounts.clear();
            _unreadCounts.addAll(unread);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _onSearchChanged(String query) {
    _searchTimer?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _isSearching = false;
        _searchResults = [];
        _searchHasMore = false;
      });
      return;
    }
    _isSearching = true;
    _searchTimer = Timer(const Duration(milliseconds: 400), () async {
      final result = await widget.api.searchMessages(query.trim());
      if (mounted) {
        setState(() {
          _searchResults = result['messages'] as List<MessageSearchResult>;
          _searchHasMore = result['hasMore'] as bool;
        });
      }
    });
  }

  Widget _buildAvatar(String? avatarUrl, String fallbackChar, {String? userId}) {
    final fallbackColor = userId != null ? colorFromId(userId) : Theme.of(context).colorScheme.primary;
    final initials = Text(fallbackChar.toUpperCase());
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      final fullUrl = 'https://wlvorti.ru:3000$avatarUrl';
      return Stack(
        children: [
          CircleAvatar(backgroundColor: fallbackColor, child: initials),
          CircleAvatar(
            backgroundColor: Colors.transparent,
            backgroundImage: CachedNetworkImageProvider(fullUrl),
            onBackgroundImageError: (_, __) {},
          ),
        ],
      );
    }
    return CircleAvatar(backgroundColor: fallbackColor, child: initials);
  }

  void _setupWebSocket() async {
    widget.api.connectWebSocket();
    
    // Sync local _onlineUsers with central onlineUsers
    _onlineUsers.clear();
    _onlineUsers.addAll(widget.api.onlineUsers);
    
    _onlineHandler = () {
      if (mounted) {
        setState(() {
          _onlineUsers.clear();
          _onlineUsers.addAll(widget.api.onlineUsers);
        });
      }
    };
    widget.api.onOnlineUsersChanged = _onlineHandler;
    
    _messageHandler = (msg) async {
      final type = msg['type'];

      if (type == 'message' && mounted) {
        final chatId = msg['chatId'];
        final senderId = msg['userId'];
        final currentUserId = widget.api.userId;

        if (senderId != currentUserId) {
          final muted = await MuteService.isMuted(chatId);
          setState(() {
            if (!muted) {
              _unreadCounts[chatId] = (_unreadCounts[chatId] ?? 0) + 1;
            }

            final index = _chats.indexWhere((c) => c.id == chatId);
            if (index != -1) {
              _chats[index] = Chat(
                id: _chats[index].id,
                name: _chats[index].name,
                type: _chats[index].type,
                createdAt: _chats[index].createdAt,
                lastMessage: msg['text'],
                lastMessageAt: msg['timestamp'],
                participants: _chats[index].participants,
                unreadCount: muted ? _chats[index].unreadCount : (_unreadCounts[chatId] ?? 0),
                avatarUrl: _chats[index].avatarUrl,
              );
            }
          });
        }
      }

      if (type == 'online' && mounted) {
        setState(() {
          _onlineUsers.clear();
          _onlineUsers.addAll(widget.api.onlineUsers);
        });
      }

      if (type == 'message_edited' || type == 'message_deleted') {
        _refreshChats();
      }
    };
    widget.api.addMessageListener(_messageHandler!);
  }

  Future<void> _refreshChats() async {
    final chats = await widget.api.getChats();
    if (mounted) {
      setState(() => _chats = chats);
    }
  }

  void _markChatAsRead(String chatId) {
    setState(() {
      _unreadCounts[chatId] = 0;
    });
  }

  Future<void> _createChat() async {
    await UserSearchSheet.show(
      context: context,
      api: widget.api,
      config: const UserSearchSheetConfig(
        title: 'New Chat',
      ),
      onSubmitted: (users) async {
        if (users.isEmpty) return;
        final user = users.first;
        final chatId = await widget.api.createChat('direct', [user.id]);
        if (chatId != null && mounted) {
          _loadData();
          _openChat(chatId, user.username,
            avatarUrl: user.avatarUrl,
            otherUserId: user.id,
          );
        }
      },
    );
  }

  void _openChat(
    String chatId,
    String name, {
    String? avatarUrl,
    String? otherUserId,
    bool initialOnline = false,
  }) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              api: widget.api,
              chatId: chatId,
              chatName: name,
              avatarUrl: avatarUrl,
              otherUserId: otherUserId,
              initialOnline: initialOnline,
              chatType: 'direct',
              onMessagesRead: () => _markChatAsRead(chatId),
            ),
          ),
        )
        .then((_) => _loadData());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).chats),
        automaticallyImplyLeading: false,
        actions: [],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: AppLocalizations.of(context).searchMessages,
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
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
                : _isSearching && _searchController.text.trim().isNotEmpty
                    ? _searchResults.isEmpty
                        ? Center(child: Text(AppLocalizations.of(context).noMessagesFound))
                        : RefreshIndicator(
                            onRefresh: () async => _onSearchChanged(_searchController.text),
                            child: ListView.builder(
                              itemCount: _searchResults.length + (_searchHasMore ? 1 : 0),
                              itemBuilder: (_, i) {
                                if (i == _searchResults.length) {
                                  return const Center(child: CircularProgressIndicator());
                                }
                                final r = _searchResults[i];
                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: colorFromId(r.chatId),
                                    child: Text(r.chatName[0].toUpperCase()),
                                  ),
                                  title: Text(
                                    r.chatName,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  subtitle: Text(
                                    '${r.senderName}: ${r.text}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  trailing: Text(
                                    _formatTime(r.createdAt),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ChatScreen(
                                          api: widget.api,
                                          chatId: r.chatId,
                                          chatName: r.chatName,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          )
                    : _chats.isEmpty
                        ? Center(child: Text(AppLocalizations.of(context).noChatsYet))
                        : RefreshIndicator(
                            onRefresh: _loadData,
                            child: ListView.builder(
                              itemCount: _chats.length,
                              itemBuilder: (_, i) {
                                final chat = _chats[i];
                                final unread = _unreadCounts[chat.id] ?? 0;
                                final currentUserId = widget.api.userId;
                                final otherUserId = chat.participants.firstWhere(
                                  (p) => p != currentUserId,
                                  orElse: () => chat.participants.first,
                                );
                                return ListTile(
                                  leading: GestureDetector(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => UserProfileScreen(
                                            api: widget.api,
                                            userId: otherUserId,
                                          ),
                                        ),
                                      );
                                    },
                                    child: Stack(
                                      children: [
                                        _buildAvatar(
                                          chat.avatarUrl,
                                          chat.name?[0].toUpperCase() ??
                                              chat.participants.first[0].toUpperCase(),
                                          userId: chat.id,
                                        ),
                                        if (chat.isOnline ||
                                            _onlineUsers.contains(otherUserId))
                                          Positioned(
                                            right: 0,
                                            bottom: 0,
                                            child: Container(
                                              width: 12,
                                              height: 12,
                                              decoration: BoxDecoration(
                                                color: Colors.green,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.white,
                                                  width: 2,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  title: Text(chat.name ?? AppLocalizations.of(context).chat),
                                  subtitle: Text(
                                    chat.lastMessage ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (chat.lastMessageAt != null)
                                        Text(
                                          _formatTime(chat.lastMessageAt!),
                                          style: Theme.of(context).textTheme.bodySmall,
                                        ),
                                      if (unread > 0) ...[
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.blue,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            unread > 99 ? '99+' : unread.toString(),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  onTap: () => _openChat(
                                    chat.id,
                                    chat.name ?? AppLocalizations.of(context).chat,
                                    avatarUrl: chat.avatarUrl,
                                    otherUserId: otherUserId,
                                    initialOnline: chat.isOnline || _onlineUsers.contains(otherUserId),
                                  ),
                                  onLongPress: () => _showChatMenu(chat, context),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  void _showChatMenu(Chat chat, BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text(l10n.deleteChat, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteChat(chat, context);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteChat(Chat chat, BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).deleteChat),
        content: Text('${AppLocalizations.of(context).deleteChatConfirm}\n\n${AppLocalizations.of(context).deleteChatLocalOnly}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppLocalizations.of(context).cancel)),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await HiddenChats.hide(chat.id);
              final cached = ChatCache.getChats();
              cached.removeWhere((c) => c.id == chat.id);
              await ChatCache.saveChats(cached);
              if (mounted) {
                setState(() {
                  _chats.removeWhere((c) => c.id == chat.id);
                });
              }
            },
            child: Text(AppLocalizations.of(context).delete, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    if (date.day == now.day) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.day}/${date.month}';
  }
}

class CommunitiesTab extends StatefulWidget {
  final ApiService api;

  const CommunitiesTab({super.key, required this.api});

  @override
  State<CommunitiesTab> createState() => _CommunitiesTabState();
}

class _CommunitiesTabState extends State<CommunitiesTab> {
  List<Chat> _groups = [];
  bool _isLoading = true;
  final Set<String> _onlineUsers = {};
  Map<String, int> _groupUnreadCounts = {};
  Function(Map<String, dynamic>)? _messageHandler;
  VoidCallback? _onlineHandler;
  final _searchController = TextEditingController();
  List<MessageSearchResult> _searchResults = [];
  bool _searchHasMore = false;
  bool _isSearching = false;
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _onlineUsers.clear();
    _onlineUsers.addAll(widget.api.onlineUsers);
    _loadGroups();
    _setupWebSocket();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchTimer?.cancel();
    if (_messageHandler != null) {
      widget.api.removeMessageListener(_messageHandler!);
    }
    if (_onlineHandler != null) {
      if (widget.api.onOnlineUsersChanged == _onlineHandler) {
        widget.api.onOnlineUsersChanged = null;
      }
    }
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _searchTimer?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _isSearching = false;
        _searchResults = [];
        _searchHasMore = false;
      });
      return;
    }
    _isSearching = true;
    _searchTimer = Timer(const Duration(milliseconds: 400), () async {
      final result = await widget.api.searchMessages(query.trim());
      if (mounted) {
        setState(() {
          _searchResults = result['messages'] as List<MessageSearchResult>;
          _searchHasMore = result['hasMore'] as bool;
        });
      }
    });
  }

  void _setupWebSocket() async {
    _onlineHandler = () {
      if (mounted) {
        setState(() {
          _onlineUsers.clear();
          _onlineUsers.addAll(widget.api.onlineUsers);
        });
      }
    };
    widget.api.onOnlineUsersChanged = _onlineHandler;
    
    _messageHandler = (msg) async {
      final type = msg['type'];
      if (type == 'message' && mounted) {
        final chatId = msg['chatId'];
        final senderId = msg['userId'];
        final currentUserId = widget.api.userId;
        final index = _groups.indexWhere((c) => c.id == chatId);

        if (index != -1 && senderId != currentUserId) {
          final muted = await MuteService.isMuted(chatId);
          if (!mounted) return;
          setState(() {
            if (!muted) {
              _groupUnreadCounts[chatId] = (_groupUnreadCounts[chatId] ?? 0) + 1;
            }
            _groups[index] = Chat(
              id: _groups[index].id,
              name: _groups[index].name,
              type: _groups[index].type,
              createdAt: _groups[index].createdAt,
              lastMessage: msg['text'],
              lastMessageAt: msg['timestamp'],
              participants: _groups[index].participants,
              unreadCount: muted ? _groups[index].unreadCount : (_groupUnreadCounts[chatId] ?? 0),
              avatarUrl: _groups[index].avatarUrl,
            );
          });
        }
      }
    };
    widget.api.addMessageListener(_messageHandler!);
  }

  Future<void> _loadGroups() async {
    try {
      final chats = await widget.api.getChats();
      if (mounted) {
        setState(() {
          _groups = chats.where((c) => c.type == 'group').toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Widget _buildAvatar(String? avatarUrl, String fallbackChar, {String? userId}) {
    final fallbackColor = userId != null ? colorFromId(userId) : Theme.of(context).colorScheme.primary;
    final initials = Text(fallbackChar.toUpperCase());
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      final fullUrl = 'https://wlvorti.ru:3000$avatarUrl';
      return Stack(
        children: [
          CircleAvatar(backgroundColor: fallbackColor, child: initials),
          CircleAvatar(
            backgroundColor: Colors.transparent,
            backgroundImage: CachedNetworkImageProvider(fullUrl),
            onBackgroundImageError: (_, __) {},
          ),
        ],
      );
    }
    return CircleAvatar(backgroundColor: fallbackColor, child: initials);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).communities),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadGroups),
          IconButton(icon: const Icon(Icons.add), onPressed: _createGroup),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: AppLocalizations.of(context).searchMessages,
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
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
                : _isSearching && _searchController.text.trim().isNotEmpty
                    ? _searchResults.isEmpty
                        ? Center(child: Text(AppLocalizations.of(context).noMessagesFound))
                        : RefreshIndicator(
                            onRefresh: () async => _onSearchChanged(_searchController.text),
                            child: ListView.builder(
                              itemCount: _searchResults.length + (_searchHasMore ? 1 : 0),
                              itemBuilder: (_, i) {
                                if (i == _searchResults.length) {
                                  return const Center(child: CircularProgressIndicator());
                                }
                                final r = _searchResults[i];
                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: colorFromId(r.chatId),
                                    child: Text(r.chatName[0].toUpperCase()),
                                  ),
                                  title: Text(
                                    r.chatName,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  subtitle: Text(
                                    '${r.senderName}: ${r.text}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  trailing: Text(
                                    _formatTime(r.createdAt),
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                  onTap: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ChatScreen(
                                          api: widget.api,
                                          chatId: r.chatId,
                                          chatName: r.chatName,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          )
                    : _groups.isEmpty
                        ? Center(child: Text(AppLocalizations.of(context).noCommunitiesYet))
                        : RefreshIndicator(
                            onRefresh: _loadGroups,
                            child: ListView.builder(
                              itemCount: _groups.length,
                              itemBuilder: (_, i) {
                                final group = _groups[i];
                                final unread = _groupUnreadCounts[group.id] ?? 0;
                                return ListTile(
                                  leading: _buildAvatar(
                                    group.avatarUrl,
                                    group.name?[0].toUpperCase() ?? 'G',
                                    userId: group.id,
                                  ),
                                  title: Text(
                                    group.name ?? AppLocalizations.of(context).group,
                                    style: TextStyle(
                                      color: Theme.of(context).colorScheme.primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    group.lastMessage ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (unread > 0)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.blue,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            unread > 99 ? '99+' : unread.toString(),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  onTap: () {
                                    setState(() {
                                      _groupUnreadCounts[group.id] = 0;
                                    });
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => ChatScreen(
                                          api: widget.api,
                                          chatId: group.id,
                                          chatName: group.name ?? AppLocalizations.of(context).group,
                                          avatarUrl: group.avatarUrl,
                                          chatType: 'group',
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Future<void> _createGroup() async {
    final nameController = TextEditingController();
    final searchController = TextEditingController();
    var users = <User>[];
    final selectedUsers = <String>{};

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context).communityName,
                    prefixIcon: const Icon(Icons.group),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  ),
                ),
              ),
              if (selectedUsers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: selectedUsers.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final id = selectedUsers.elementAt(i);
                        return Chip(
                          label: Text(
                            users.firstWhere((u) => u.id == id, orElse: () => User(id: id, username: id.substring(0, 6), createdAt: 0)).username,
                            style: const TextStyle(fontSize: 13),
                          ),
                          deleteIcon: const Icon(Icons.close, size: 16),
                          onDeleted: () => setSheetState(() => selectedUsers.remove(id)),
                          visualDensity: VisualDensity.compact,
                        );
                      },
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: TextField(
                  controller: searchController,
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context).addMembersHint,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            onPressed: () {
                              searchController.clear();
                              setSheetState(() => users = []);
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  ),
                  onChanged: (value) {
                    if (value.length < 2) {
                      setSheetState(() => users = []);
                      return;
                    }
                    widget.api.searchUsers(value).then((result) {
                      if (searchController.text == value) {
                        setSheetState(() => users = result);
                      }
                    }).catchError((_) {});
                  },
                ),
              ),
              const SizedBox(height: 8),
              if (users.isNotEmpty)
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    itemCount: users.length,
                    itemBuilder: (_, i) {
                      final user = users[i];
                      final isSelected = selectedUsers.contains(user.id);
                      final isOnline = _onlineUsers.contains(user.id);
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                        elevation: 0,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5)
                            : Theme.of(context).colorScheme.surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: isSelected
                              ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 1.5)
                              : BorderSide.none,
                        ),
                        child: ListTile(
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                radius: 22,
                                backgroundColor: colorFromId(user.id),
                                backgroundImage: user.avatarUrl != null
                                    ? CachedNetworkImageProvider(user.avatarUrl!)
                                    : null,
                                child: user.avatarUrl == null
                                    ? Text(
                                        (user.displayName ?? user.username)[0].toUpperCase(),
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                      )
                                    : null,
                              ),
                              if (isOnline)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: Colors.green,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          title: Text(
                            user.displayName ?? user.username,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '@${user.username}',
                            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Icon(
                            isSelected ? Icons.check_circle : Icons.add_circle_outline,
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          onTap: () {
                            setSheetState(() {
                              if (isSelected) {
                                selectedUsers.remove(user.id);
                              } else {
                                selectedUsers.add(user.id);
                              }
                            });
                          },
                        ),
                      );
                    },
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: [
                      Icon(Icons.search, size: 48,
                          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
                      const SizedBox(height: 8),
                      Text(
                        'Type at least 2 characters to search',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: selectedUsers.isEmpty || nameController.text.isEmpty
                        ? null
                        : () async {
                            final groupId = await widget.api.createChat(
                              'group',
                              selectedUsers.toList(),
                              name: nameController.text,
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (groupId != null && mounted) {
                              _loadGroups();
                            }
                          },
                    child: Text(AppLocalizations.of(context).createCommunity),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    if (date.day == now.day) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.day}/${date.month}';
  }
}


class ProfileTab extends StatelessWidget {
  final ApiService api;

  const ProfileTab({super.key, required this.api});

  @override
  Widget build(BuildContext context) {
    return ProfileScreen(api: api);
  }
}
