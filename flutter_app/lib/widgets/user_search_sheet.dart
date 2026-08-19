import 'dart:async';
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../l10n/app_localizations.dart';
import '../utils/avatar_utils.dart';
import 'package:cached_network_image/cached_network_image.dart';

class UserSearchSheetConfig {
  final String title;
  final bool multiSelect;
  final Set<String> excludeIds;
  final Set<String> onlineUsers;
  final String Function(User user)? getSubtitle;
  final Widget Function(User user)? getTrailing;

  const UserSearchSheetConfig({
    required this.title,
    this.multiSelect = false,
    this.excludeIds = const {},
    this.onlineUsers = const {},
    this.getSubtitle,
    this.getTrailing,
  });
}

class UserSearchSheet extends StatefulWidget {
  final ApiService api;
  final UserSearchSheetConfig config;
  final void Function(List<User> selected) onSubmitted;

  const UserSearchSheet({
    super.key,
    required this.api,
    required this.config,
    required this.onSubmitted,
  });

  static Future<void> show({
    required BuildContext context,
    required ApiService api,
    required UserSearchSheetConfig config,
    required void Function(List<User> selected) onSubmitted,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => UserSearchSheet(
        api: api,
        config: config,
        onSubmitted: onSubmitted,
      ),
    );
  }

  @override
  State<UserSearchSheet> createState() => _UserSearchSheetState();
}

class _UserSearchSheetState extends State<UserSearchSheet> {
  final _searchController = TextEditingController();
  final _users = <User>[];
  Timer? _debounce;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final value = _searchController.text;
    _debounce?.cancel();
    if (value.length < 2) {
      setState(() {
        _users.clear();
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    try {
      final results = await widget.api.searchUsers(query);
      if (_searchController.text == query) {
        setState(() {
          _users
            ..clear()
            ..addAll(results.where((u) => !widget.config.excludeIds.contains(u.id)));
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final hasQuery = _searchController.text.length >= 2;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.config.title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: l10n.searchUsers,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _users.clear();
                          });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              ),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
            )
          else if (_users.isEmpty && hasQuery)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  Icon(Icons.person_search, size: 48,
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                  const SizedBox(height: 12),
                  Text(
                    l10n.usersNotFound,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          else if (_users.isEmpty && !hasQuery)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  Icon(Icons.search, size: 48,
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
                  const SizedBox(height: 8),
                  Text(
                    'Type at least 2 characters to search',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: _buildResultsList(context),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildResultsList(BuildContext context) {
    if (!widget.config.multiSelect) {
      return ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: _users.length,
        itemBuilder: (_, i) => _buildUserTile(_users[i]),
      );
    }
    return _MultiSelectList(
      users: _users,
      onSubmitted: widget.onSubmitted,
      config: widget.config,
      builder: (user, isSelected, onTap) => _buildUserTile(user,
        selected: isSelected,
        onTap: onTap,
      ),
    );
  }

  Widget _buildUserTile(User user, {bool selected = false, VoidCallback? onTap}) {
    final theme = Theme.of(context);
    final isOnline = widget.config.onlineUsers.contains(user.id);
    final displayName = user.displayName ?? user.username;
    final subtitle = widget.config.getSubtitle?.call(user)
        ?? (isOnline
            ? 'Online'
            : 'Offline');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      elevation: 0,
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(color: theme.colorScheme.primary, width: 1.5)
            : BorderSide.none,
      ),
      child: ListTile(
        leading: _buildAvatar(user, isOnline),
        title: Text(
          displayName,
          style: const TextStyle(fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '@${user.username}  ·  $subtitle',
          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: widget.config.getTrailing?.call(user)
            ?? (widget.config.multiSelect
                ? Icon(
                    selected ? Icons.check_circle : Icons.add_circle_outline,
                    color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                  )
                : Icon(Icons.arrow_forward_ios, size: 14,
                    color: theme.colorScheme.onSurfaceVariant)),
        onTap: onTap ?? () {
          widget.onSubmitted([user]);
          Navigator.pop(context);
        },
      ),
    );
  }

  Widget _buildAvatar(User user, bool isOnline) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: colorFromId(user.id),
          backgroundImage: user.avatarUrl != null
              ? CachedNetworkImageProvider('${ApiService.baseUrl}${user.avatarUrl}')
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
                border: Border.all(color: theme.colorScheme.surface, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

class _MultiSelectList extends StatefulWidget {
  final List<User> users;
  final void Function(List<User> selected) onSubmitted;
  final UserSearchSheetConfig config;
  final Widget Function(User user, bool isSelected, VoidCallback onTap) builder;

  const _MultiSelectList({
    required this.users,
    required this.onSubmitted,
    required this.config,
    required this.builder,
  });

  @override
  State<_MultiSelectList> createState() => _MultiSelectListState();
}

class _MultiSelectListState extends State<_MultiSelectList> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  '${_selected.length} selected',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: () {
                    final selectedUsers = widget.users
                        .where((u) => _selected.contains(u.id))
                        .toList();
                    widget.onSubmitted(selectedUsers);
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Done'),
                ),
              ],
            ),
          ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: widget.users.length,
            itemBuilder: (_, i) {
              final user = widget.users[i];
              final isSelected = _selected.contains(user.id);
              return widget.builder(user, isSelected, () {
                setState(() {
                  if (isSelected) {
                    _selected.remove(user.id);
                  } else {
                    _selected.add(user.id);
                  }
                });
              });
            },
          ),
        ),
      ],
    );
  }
}
