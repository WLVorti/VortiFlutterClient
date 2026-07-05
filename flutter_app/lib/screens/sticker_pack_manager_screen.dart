import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_cropper_widget/image_cropper_widget.dart';
import 'package:path_provider/path_provider.dart';
import '../services/api_service.dart';
import '../models/models.dart';

class StickerPackManagerScreen extends StatefulWidget {
  final ApiService api;

  const StickerPackManagerScreen({super.key, required this.api});

  @override
  State<StickerPackManagerScreen> createState() => _StickerPackManagerScreenState();
}

class _StickerPackManagerScreenState extends State<StickerPackManagerScreen> {
  List<StickerPack> _packs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPacks();
  }

  Future<void> _loadPacks() async {
    setState(() => _isLoading = true);
    final all = await widget.api.getStickerPacks();
    if (mounted) {
      setState(() {
        _packs = all.where((p) => p.authorId == widget.api.userId).toList();
        _isLoading = false;
      });
    }
  }

  Future<void> _createPack() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Sticker Pack'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 64,
          decoration: const InputDecoration(
            hintText: 'Pack name',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final pack = await widget.api.createStickerPack(name);
      if (pack != null) {
        _packs.insert(0, pack);
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _editPack(StickerPack pack) async {
    final detail = await widget.api.getStickerPack(pack.id);
    if (!mounted || detail == null) return;

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _StickerPackEditScreen(api: widget.api, pack: detail),
      ),
    );
    if (result == true) _loadPacks();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Sticker Packs'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createPack,
        child: const Icon(Icons.add),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _packs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 64, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      Text('No sticker packs yet', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: _createPack,
                        icon: const Icon(Icons.add),
                        label: const Text('Create Pack'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadPacks,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                    itemCount: _packs.length,
                    itemBuilder: (_, i) {
                      final p = _packs[i];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: p.coverUrl != null
                                ? CachedNetworkImage(
                                    imageUrl: '${ApiService.baseUrl}${p.coverUrl}',
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    width: 48,
                                    height: 48,
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    child: Icon(Icons.auto_awesome, color: theme.colorScheme.onSurfaceVariant),
                                  ),
                          ),
                          title: Text(p.name),
                          subtitle: Text('${p.stickerCount} stickers'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Delete Pack'),
                                  content: Text('Delete "${p.name}" and all its stickers?'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok == true) {
                                await widget.api.deleteStickerPack(p.id);
                                _packs.removeAt(i);
                                if (mounted) setState(() {});
                              }
                            },
                          ),
                          onTap: () => _editPack(p),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

class _StickerPackEditScreen extends StatefulWidget {
  final ApiService api;
  final StickerPack pack;

  const _StickerPackEditScreen({required this.api, required this.pack});

  @override
  State<_StickerPackEditScreen> createState() => _StickerPackEditScreenState();
}

class _StickerPackEditScreenState extends State<_StickerPackEditScreen> {
  late List<Sticker> _stickers;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _stickers = widget.pack.stickers ?? [];
    _isLoading = false;
  }

  Future<void> _addSticker() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    final controller = ImageCropperController();
    final cropped = await Navigator.push<Uint8List>(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('Crop Sticker'),
            actions: [
              TextButton(
                onPressed: () => controller.crop().then((b) => Navigator.pop(context, b)),
                child: const Text('Done'),
              ),
            ],
          ),
          body: ImageCropperWidget(
            image: FileImage(File(file.path)),
            aspectRatio: CropperRatio.ratio1_1,
            controller: controller,
          ),
        ),
      ),
    );
    if (cropped == null) return;

    final tempDir = await getTemporaryDirectory();
    final tempFile = File('${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}.png');
    await tempFile.writeAsBytes(cropped);

    String emoji = '';
    final picked = await showModalBottomSheet<String>(
      context: context,
      clipBehavior: Clip.antiAlias,
      builder: (ctx) => _EmojiPicker(
        onSelected: (e) => Navigator.pop(ctx, e),
      ),
    );
    if (picked == null) {
      tempFile.delete();
      return;
    }
    emoji = picked;

    final sticker = await widget.api.addSticker(widget.pack.id, tempFile.path, emoji);
    if (mounted) {
      setState(() {
        if (sticker != null) _stickers.add(sticker);
      });
    }
    tempFile.delete();
  }

  Future<void> _removeSticker(Sticker sticker, int index) async {
    await widget.api.removeSticker(widget.pack.id, sticker.id);
    if (mounted) {
      setState(() => _stickers.removeAt(index));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pack.name),
        actions: [
          TextButton.icon(
            onPressed: _addSticker,
            icon: const Icon(Icons.add),
            label: const Text('Add'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _stickers.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 64, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      Text('No stickers yet', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: _addSticker,
                        icon: const Icon(Icons.add),
                        label: const Text('Add Sticker'),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                  ),
                  itemCount: _stickers.length,
                  itemBuilder: (_, i) {
                    final s = _stickers[i];
                    return GestureDetector(
                      onLongPress: () => _removeSticker(s, i),
                      child: Stack(
                        children: [
                          Container(
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
                          ),
                          if (s.emoji.isNotEmpty)
                            Positioned(
                              bottom: 2,
                              right: 2,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(s.emoji, style: const TextStyle(fontSize: 14)),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
    );
  }
}

class _EmojiPicker extends StatefulWidget {
  final void Function(String) onSelected;
  const _EmojiPicker({required this.onSelected});

  @override
  State<_EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<_EmojiPicker> {
  int _tabIndex = 0;

  static const _categories = <(String, String, List<String>)>[
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentCat = _categories[_tabIndex];
    return SizedBox(
      height: 350,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              itemCount: _categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 4),
              itemBuilder: (_, i) {
                final isActive = _tabIndex == i;
                return GestureDetector(
                  onTap: () => setState(() => _tabIndex = i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: isActive ? theme.colorScheme.secondaryContainer : Colors.transparent,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(_categories[i].$1, style: const TextStyle(fontSize: 18)),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 1,
                crossAxisSpacing: 1,
              ),
              itemCount: currentCat.$3.length,
              itemBuilder: (_, i) {
                final emoji = currentCat.$3[i];
                return GestureDetector(
                  onTap: () => widget.onSelected(emoji),
                  child: Container(
                    alignment: Alignment.center,
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
