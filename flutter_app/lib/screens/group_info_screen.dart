import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_cropper_widget/image_cropper_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import '../utils/avatar_utils.dart';
import '../l10n/app_localizations.dart';
import '../widgets/user_search_sheet.dart';

class GroupInfoScreen extends StatefulWidget {
  final ApiService api;
  final String chatId;

  const GroupInfoScreen({
    super.key,
    required this.api,
    required this.chatId,
  });

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  Map<String, dynamic>? _chatInfo;
  List<dynamic> _participants = [];
  bool _isLoading = true;
  String? _currentUserRole;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      print('Loading chat info for: ${widget.chatId}');
      final chatInfo = await widget.api.getChatInfo(widget.chatId);
      print('Chat info result: $chatInfo');
      final participants = await widget.api.getParticipants(widget.chatId);
      print('Participants result: $participants');
      if (mounted) {
        setState(() {
          _chatInfo = chatInfo;
          _participants = participants;
          _currentUserRole = chatInfo?['role'];
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error loading group info: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool get _isAdmin => _currentUserRole == 'admin' || _currentUserRole == 'owner';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_chatInfo?['name'] ?? AppLocalizations.of(context).group),
        actions: [
          if (_isAdmin)
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'rename') {
                  _showRenameDialog();
                } else if (value == 'delete') {
                  _showDeleteDialog();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'rename',
                  child: Text(AppLocalizations.of(context).rename),
                ),
                if (_currentUserRole == 'owner')
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(AppLocalizations.of(context).deleteGroup),
                  ),
              ],
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _buildHeader(),
                const Divider(),
                _buildParticipantsSection(),
              ],
            ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          GestureDetector(
            onTap: _isAdmin ? _changeAvatar : null,
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  backgroundImage: _chatInfo?['avatarUrl'] != null
                      ? CachedNetworkImageProvider('${ApiService.baseUrl}${_chatInfo!['avatarUrl']}')
                      : null,
                  child: _chatInfo?['avatarUrl'] == null
                      ? Text(
                          (_chatInfo?['name'] ?? 'G')[0].toUpperCase(),
                          style: const TextStyle(fontSize: 32),
                        )
                      : null,
                ),
                if (_isAdmin)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.edit, size: 16, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _chatInfo?['name'] ?? AppLocalizations.of(context).group,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context).membersCount(_participants.length),
            style: TextStyle(color: Colors.grey[600]),
          ),
          if (_currentUserRole != null) ...[
            const SizedBox(height: 8),
            Chip(
              label: Text(_currentUserRole!.toUpperCase()),
              backgroundColor: _currentUserRole == 'owner'
                  ? Colors.amber
                  : _currentUserRole == 'admin'
                      ? Colors.blue
                      : Colors.grey,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildParticipantsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                AppLocalizations.of(context).members,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              if (_isAdmin)
                IconButton(
                  icon: const Icon(Icons.person_add),
                  onPressed: _showAddParticipantDialog,
                ),
            ],
          ),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _participants.length,
          itemBuilder: (context, index) {
            final participant = _participants[index];
            final userId = participant['user_id'];
            final role = participant['role'];
            final username = participant['username'] ?? AppLocalizations.of(context).unknown;

            return ListTile(
              leading: CircleAvatar(
                backgroundColor: colorFromId(userId),
                child: Text(username[0].toUpperCase()),
              ),
              title: Text(username),
              subtitle: role != 'member' ? Text(role) : null,
              trailing: _isAdmin && role != 'owner'
                  ? PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'remove') {
                          await _removeParticipant(userId);
                        } else if (value == 'admin' || value == 'member') {
                          await _setRole(userId, value);
                        } else if (value == 'transfer') {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(AppLocalizations.of(context).transferOwnershipConfirm),
                              content: Text(AppLocalizations.of(context).transferOwnershipBody),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppLocalizations.of(context).cancel)),
                                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(AppLocalizations.of(context).transferOwnership)),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            await widget.api.transferOwnership(widget.chatId, userId);
                            if (mounted) Navigator.pop(context);
                          }
                        }
                      },
                      itemBuilder: (_) => [
                        if (_currentUserRole == 'owner') ...[
                          if (role != 'admin')
                            PopupMenuItem(
                              value: 'admin',
                              child: Text(AppLocalizations.of(context).makeAdmin),
                            ),
                          if (role == 'admin')
                            PopupMenuItem(
                              value: 'member',
                              child: Text(AppLocalizations.of(context).removeAdmin),
                            ),
                          PopupMenuItem(
                            value: 'transfer',
                            child: Text(AppLocalizations.of(context).transferOwnership),
                          ),
                        ],
                        PopupMenuItem(
                          value: 'remove',
                          child: Text(AppLocalizations.of(context).remove),
                        ),
                      ],
                    )
                  : null,
            );
          },
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.exit_to_app, color: Colors.red),
          title: Text(AppLocalizations.of(context).leaveGroup, style: TextStyle(color: Colors.red)),
          onTap: _leaveGroup,
        ),
      ],
    );
  }

  void _showRenameDialog() {
    final controller = TextEditingController(text: _chatInfo?['name']);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).renameGroup),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context).groupName,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          FilledButton(
            onPressed: () async {
              await widget.api.updateGroupName(widget.chatId, controller.text);
              if (mounted) {
                Navigator.pop(ctx);
                _loadData();
              }
            },
            child: Text(AppLocalizations.of(context).save),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).deleteGroup),
        content: Text(AppLocalizations.of(context).deleteGroupConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          FilledButton(
            onPressed: () async {
              final errorMsg = await widget.api.deleteGroup(widget.chatId);
              if (mounted) {
                Navigator.pop(ctx);
                if (errorMsg == null) {
                  Navigator.pop(context);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(errorMsg),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: Text(AppLocalizations.of(context).delete),
          ),
        ],
      ),
    );
  }

  void _changeAvatar() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(AppLocalizations.of(context).chooseFromGallery),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            if (_chatInfo?['avatarUrl'] != null)
              ListTile(
                leading: const Icon(Icons.delete),
                title: Text(AppLocalizations.of(context).removePhoto),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );

    if (result == null) return;

    if (result == 'remove') {
      await widget.api.deleteGroupAvatar(widget.chatId);
      if (mounted) {
        _loadData();
      }
      return;
    }

    final file = await _pickImage();
    if (file != null) {
      final avatarUrl = await widget.api.uploadGroupAvatar(widget.chatId, file);
      file.delete().catchError((_) {});
      if (avatarUrl != null && mounted) {
        _loadData();
      }
    }
  }

  Future<File?> _pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result != null && result.files.single.path != null) {
      try {
        final controller = ImageCropperController();
        final bytes = await Navigator.push<Uint8List>(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.rotate_right),
                    onPressed: () => controller.rotateRight(),
                  ),
                  TextButton(
                    onPressed: () async {
                      final b = await controller.crop();
                      if (b != null) Navigator.pop(context, b);
                    },
                    child: Text(AppLocalizations.of(context).save),
                  ),
                ],
              ),
              body: ImageCropperWidget(
                controller: controller,
                image: FileImage(File(result.files.single.path!)),
                aspectRatio: CropperRatio.ratio1_1,
                style: CropperStyle(showGrid: true),
              ),
            ),
          ),
        );
        if (bytes == null) return null;
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/crop_${DateTime.now().millisecondsSinceEpoch}.png');
        await file.writeAsBytes(bytes);
        return file;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void _showAddParticipantDialog() async {
    final currentIds = (_participants ?? []).map<String>((p) => p.id as String).toSet();
    await UserSearchSheet.show(
      context: context,
      api: widget.api,
      config: UserSearchSheetConfig(
        title: AppLocalizations.of(context).addParticipant,
        excludeIds: currentIds,
      ),
      onSubmitted: (users) async {
        if (users.isEmpty) return;
        await widget.api.addParticipant(widget.chatId, users.first.id);
        _loadData();
      },
    );
  }

  Future<void> _removeParticipant(String userId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).removeParticipant),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(context).remove),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.api.removeParticipant(widget.chatId, userId);
      _loadData();
    }
  }

  Future<void> _setRole(String userId, String role) async {
    await widget.api.setParticipantRole(widget.chatId, userId, role);
    _loadData();
  }

  Future<void> _leaveGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context).leaveGroupConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(context).leave),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final errorMsg = await widget.api.leaveGroup(widget.chatId);
      if (mounted) {
        if (errorMsg == null) {
          Navigator.pop(context);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMsg),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }
}