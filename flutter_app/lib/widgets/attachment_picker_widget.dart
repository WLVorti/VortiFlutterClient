import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import '../l10n/app_localizations.dart';

class SelectedMedia {
  final File file;
  final String name;
  final String mimeType;

  SelectedMedia({required this.file, required this.name, required this.mimeType});
}

class AttachmentPickerWidget extends StatefulWidget {
  const AttachmentPickerWidget({super.key});

  static Future<List<SelectedMedia>?> show(BuildContext context) {
    return showModalBottomSheet<List<SelectedMedia>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AttachmentPickerWidget(),
    );
  }

  @override
  State<AttachmentPickerWidget> createState() => _AttachmentPickerWidgetState();
}

class _AttachmentPickerWidgetState extends State<AttachmentPickerWidget>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Set<AssetEntity> _selectedAssets = {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_selectedAssets.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final result = <SelectedMedia>[];
      for (final asset in _selectedAssets) {
        final file = await asset.file;
        if (file == null) continue;
        final title = asset.title ?? 'unknown';
        final ext = title.split('.').last.toLowerCase();
        final type = asset.type == AssetType.video ? 'video' : asset.type == AssetType.audio ? 'audio' : 'image';
        result.add(SelectedMedia(file: file, name: title, mimeType: '$type/$ext'));
      }
      if (!mounted) return;
      Navigator.pop(context, result);
    } catch (_) {
      setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      height: _selectedAssets.isNotEmpty ? screenHeight * 0.62 : screenHeight * 0.55,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                labelColor: theme.colorScheme.onPrimaryContainer,
                unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
                tabs: [
                  Tab(icon: const Icon(Icons.photo_library, size: 20), text: l10n.media),
                  Tab(icon: const Icon(Icons.insert_drive_file, size: 20), text: l10n.files),
                  Tab(icon: const Icon(Icons.music_note, size: 20), text: l10n.music),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _MediaTab(
                  selectedAssets: _selectedAssets,
                  onSelectionChanged: (_) => setState(() {}),
                ),
                _FilesTab(),
                _MusicTab(
                  selectedAssets: _selectedAssets,
                  onSelectionChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
          if (_selectedAssets.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Text(
                      '${_selectedAssets.length} ${l10n.selected}',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.send, size: 18),
                      label: Text(l10n.send),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MediaTab extends StatefulWidget {
  final Set<AssetEntity> selectedAssets;
  final ValueChanged<Set<AssetEntity>> onSelectionChanged;

  const _MediaTab({
    required this.selectedAssets,
    required this.onSelectionChanged,
  });

  @override
  State<_MediaTab> createState() => _MediaTabState();
}

class _MediaTabState extends State<_MediaTab> {
  List<AssetEntity>? _assets;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadMedia();
  }

  Future<void> _loadMedia() async {
    try {
      final result = await PhotoManager.requestPermissionExtend();
      if (!result.isAuth) {
        setState(() => _loading = false);
        return;
      }

      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        filterOption: FilterOptionGroup(
          orders: [OrderOption(type: OrderOptionType.createDate)],
        ),
      );

      if (albums.isEmpty) {
        setState(() => _loading = false);
        return;
      }

      final recent = await albums.first.getAssetListPaged(page: 0, size: 60);
      setState(() {
        _assets = recent;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _toggleAsset(AssetEntity asset) {
    if (widget.selectedAssets.contains(asset)) {
      widget.selectedAssets.remove(asset);
    } else {
      widget.selectedAssets.add(asset);
    }
    widget.onSelectionChanged(Set.of(widget.selectedAssets));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_assets == null || _assets!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.photo_library_outlined, size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context).noMedia,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _assets!.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return GestureDetector(
            onTap: _openCamera,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[850],
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_alt, size: 32,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 4),
                  Text(
                    'Camera',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final asset = _assets![i - 1];
        final isSelected = widget.selectedAssets.contains(asset);
        return GestureDetector(
          onTap: () => _toggleAsset(asset),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: _AssetThumbnail(asset: asset),
              ),
              if (asset.type == AssetType.video)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _formatDuration(asset.duration),
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              if (isSelected)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                        size: 24,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openCamera() async {
    final picker = ImagePicker();
    final photo = await picker.pickImage(source: ImageSource.camera);
    if (photo != null && mounted) {
      final ext = photo.path.split('.').last.toLowerCase();
      Navigator.pop(context, [
        SelectedMedia(
          file: File(photo.path),
          name: 'camera_${DateTime.now().millisecondsSinceEpoch}.$ext',
          mimeType: 'image/$ext',
        ),
      ]);
    }
  }

  String _formatDuration(int seconds) {
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

class _FilesTab extends StatefulWidget {
  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  List<FileSystemEntity>? _files;
  bool _loading = true;
  bool _permissionDenied = false;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _requestPermission();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _requestPermission() async {
    if (Platform.isAndroid) {
      PermissionStatus status;
      if (await Permission.manageExternalStorage.isGranted) {
        status = PermissionStatus.granted;
      } else {
        status = await Permission.manageExternalStorage.request();
      }
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      if (!status.isGranted && status.isPermanentlyDenied) {
        setState(() { _permissionDenied = true; _loading = false; });
        return;
      }
    }
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    try {
      final allFiles = <FileSystemEntity>[];
      final rootDir = Directory('/storage/emulated/0');
      Directory startDir;
      if (await rootDir.exists()) {
        startDir = rootDir;
      } else {
        final appDir = await getExternalStorageDirectory();
        if (appDir == null) { setState(() => _loading = false); return; }
        startDir = appDir.parent;
        if (!await startDir.exists()) { setState(() => _loading = false); return; }
      }
      await _scanDir(startDir, 0, allFiles);
      setState(() { _files = allFiles; _loading = false; });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  bool _isDocumentFile(FileSystemEntity e) {
    final name = e.path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    if (dot == -1) return false;
    final ext = name.substring(dot + 1).toLowerCase();
    const docs = {
      'pdf', 'doc', 'docx', 'odt', 'rtf',
      'xls', 'xlsx', 'ods', 'csv',
      'ppt', 'pptx', 'odp',
      'txt', 'log', 'md',
      'zip', 'rar', '7z', 'tar', 'gz', 'bz2',
      'html', 'htm', 'css', 'js', 'ts', 'dart', 'py', 'java', 'cpp', 'c', 'h',
      'json', 'xml', 'yaml', 'yml', 'toml', 'ini', 'cfg',
      'sh', 'bat', 'ps1',
      'apk', 'msi', 'iso',
      'ttf', 'otf',
    };
    return docs.contains(ext);
  }

  Future<void> _scanDir(Directory dir, int depth, List<FileSystemEntity> results) async {
    if (depth > 2) return;
    try {
      final entities = await dir.list().toList();
      for (final e in entities) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;
        if (name == 'Android' || name == 'data' || name == 'obb' || name == 'cache') continue;
        if (e is File) {
          if (_isDocumentFile(e)) results.add(e);
        } else if (e is Directory) {
          await _scanDir(e, depth + 1, results);
        }
      }
    } catch (_) {}
  }

  List<FileSystemEntity> get _filtered {
    if (_searchQuery.isEmpty) return _files ?? [];
    return _files!.where((e) {
      final name = e.path.split(Platform.pathSeparator).last.toLowerCase();
      return name.contains(_searchQuery.toLowerCase());
    }).toList();
  }

  String _mimeFromExt(String ext) {
    switch (ext) {
      case 'pdf': return 'application/pdf';
      case 'doc': case 'docx': return 'application/msword';
      case 'xls': case 'xlsx': return 'application/vnd.ms-excel';
      case 'ppt': case 'pptx': return 'application/vnd.ms-powerpoint';
      case 'txt': return 'text/plain';
      case 'zip': case 'rar': case '7z': return 'application/zip';
      default: return 'application/octet-stream';
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _sendFile(FileSystemEntity e) async {
    final file = File(e.path);
    final name = file.path.split(Platform.pathSeparator).last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (!mounted) return;
    Navigator.pop(context, [SelectedMedia(file: file, name: name, mimeType: _mimeFromExt(ext))]);
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;
      final f = result.files.first;
      final file = File(f.path!);
      if (!mounted) return;
      Navigator.pop(context, [SelectedMedia(file: file, name: f.name, mimeType: _mimeFromExt(f.extension ?? ''))]);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).errorSelectingFile)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_permissionDenied) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Storage permission denied', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Browse files'),
            ),
          ],
        ),
      );
    }

    if (_files == null || _files!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No files found', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Browse files'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: 'Search files...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            ),
          ),
        ),
        Expanded(
          child: _filtered.isEmpty
              ? Center(
                  child: Text('Nothing found',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _filtered.length,
                  itemBuilder: (_, i) {
                    final e = _filtered[i];
                    final file = File(e.path);
                    final name = file.path.split(Platform.pathSeparator).last;
                    final stat = file.statSync();
                    final ext = name.contains('.') ? name.split('.').last.toUpperCase() : '?';
                    return ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(ext.substring(0, ext.length > 3 ? 3 : ext.length),
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: theme.colorScheme.onPrimaryContainer),
                          ),
                        ),
                      ),
                      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(_formatSize(stat.size),
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                      ),
                      onTap: () => _sendFile(e),
                    );
                  },
                ),
        ),
      ],
    );
  }
}



class _MusicTab extends StatefulWidget {
  final Set<AssetEntity> selectedAssets;
  final ValueChanged<Set<AssetEntity>> onSelectionChanged;

  const _MusicTab({
    required this.selectedAssets,
    required this.onSelectionChanged,
  });

  @override
  State<_MusicTab> createState() => _MusicTabState();
}

class _MusicTabState extends State<_MusicTab> {
  List<AssetEntity>? _tracks;
  bool _loading = true;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<AssetEntity> get _filteredTracks {
    if (_tracks == null) return [];
    if (_searchQuery.isEmpty) return _tracks!;
    return _tracks!.where((t) =>
      t.title?.toLowerCase().contains(_searchQuery.toLowerCase()) == true
    ).toList();
  }

  Future<void> _loadTracks() async {
    try {
      final result = await PhotoManager.requestPermissionExtend();
      if (!result.isAuth) {
        setState(() => _loading = false);
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.audio,
        filterOption: FilterOptionGroup(
          orders: [OrderOption(type: OrderOptionType.createDate)],
        ),
      );
      if (albums.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final tracks = await albums.first.getAssetListPaged(page: 0, size: 100);
      setState(() {
        _tracks = tracks;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _toggleTrack(AssetEntity track) {
    if (widget.selectedAssets.contains(track)) {
      widget.selectedAssets.remove(track);
    } else {
      widget.selectedAssets.add(track);
    }
    widget.onSelectionChanged(Set.of(widget.selectedAssets));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_tracks == null || _tracks!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty ? 'Nothing found' : AppLocalizations.of(context).noMedia,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchController,
            onChanged: (v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: 'Search tracks...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            ),
          ),
        ),
        Expanded(
          child: _filteredTracks.isEmpty
              ? Center(
                  child: Text('Nothing found',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _filteredTracks.length,
                  itemBuilder: (_, i) {
                    final track = _filteredTracks[i];
                    final isSelected = widget.selectedAssets.contains(track);
                    return ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.audiotrack, color: theme.colorScheme.onPrimaryContainer, size: 22),
                      ),
                      title: Text(
                        track.title ?? 'Unknown',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                      trailing: isSelected
                          ? Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 24)
                          : Icon(Icons.radio_button_unchecked, color: theme.colorScheme.onSurfaceVariant, size: 24),
                      onTap: () => _toggleTrack(track),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _AssetThumbnail extends StatefulWidget {
  final AssetEntity asset;
  const _AssetThumbnail({required this.asset});

  @override
  State<_AssetThumbnail> createState() => _AssetThumbnailState();
}

class _AssetThumbnailState extends State<_AssetThumbnail> {
  Uint8List? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(300));
      if (mounted) setState(() => _data = data);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_data != null) {
      return Image.memory(_data!, fit: BoxFit.cover, errorBuilder: (_, _, _) => _placeholder());
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Icon(Icons.broken_image, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}
