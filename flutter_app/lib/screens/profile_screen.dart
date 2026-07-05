import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_cropper_widget/image_cropper_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/api_service.dart';
import '../utils/avatar_utils.dart';
import '../services/theme_provider.dart';
import '../services/locale_provider.dart';
import '../services/wallpaper_service.dart';
import '../services/crypto_service.dart';
import '../l10n/app_localizations.dart';
import '../widgets/falling_icons_background.dart';
import '../models/models.dart';
import '../models/account.dart';
import 'home_screen.dart';
import 'auth_screen.dart';
import 'theme_settings_screen.dart';

class ProfileScreen extends StatefulWidget {
  final ApiService api;

  const ProfileScreen({super.key, required this.api});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static Profile? _cachedProfile;
  static List<Account> _cachedAccounts = [];
  static Account? _cachedCurrentAccount;

  Profile? _profile;
  bool _isSaving = false;
  bool _isUploadingAvatar = false;
  List<Account> _accounts = [];
  Account? _currentAccount;
  String? _emailError;

  final _displayNameController = TextEditingController();
  final _bioController = TextEditingController();
  final _emailController = TextEditingController();
  final _tagsController = TextEditingController();
  final _themeProvider = ThemeProvider();

  @override
  void initState() {
    super.initState();
    _profile = _cachedProfile;
    _accounts = List.from(_cachedAccounts);
    _currentAccount = _cachedCurrentAccount;
    if (_profile != null) {
      _displayNameController.text = _profile!.displayName ?? '';
      _bioController.text = _profile!.bio ?? '';
      _emailController.text = _profile!.email ?? '';
      _tagsController.text = _profile!.tags ?? '';
    }
    _loadProfile();
    _loadAccounts();
    _emailController.addListener(_validateEmail);
  }

  void _validateEmail() {
    final email = _emailController.text.trim();
    setState(() {
      if (email.isEmpty) {
        _emailError = null;
      } else if (!email.contains('@') || !email.contains('.')) {
        _emailError = 'Некорректный email';
      } else {
        _emailError = null;
      }
    });
  }

  Future<void> _loadAccounts() async {
    try {
      final accounts = await widget.api.getAccounts();
      final current = await widget.api.getCurrentAccount();
      if (mounted) {
        setState(() {
          _accounts = accounts;
          _currentAccount = current;
          _cachedAccounts = accounts;
          _cachedCurrentAccount = current;
        });
      }
    } catch (_) {}
  }

  void _showAccountsBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      builder: (context) => _AccountsBottomSheet(
        api: widget.api,
        accounts: _accounts,
        currentAccount: _currentAccount,
        themeProvider: _themeProvider,
        onAccountSwitched: () async {
          Navigator.pop(context);
          await _loadAccounts();
          await _loadProfile();
          if (mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => HomeScreen(api: widget.api)),
              (route) => false,
            );
          }
        },
        onAccountsUpdated: () async {
          await _loadAccounts();
          final current = await widget.api.getCurrentAccount();
          if (mounted) {
            setState(() {
              _currentAccount = current;
            });
          }
          await _loadProfile();
        },
      ),
    );
  }

  String _getInitial() {
    if (_profile == null) return 'U';
    final profile = _profile!;
    String name;
    if (profile.displayName?.isNotEmpty == true) {
      name = profile.displayName!;
    } else if (profile.username?.isNotEmpty == true) {
      name = profile.username!;
    } else {
      return 'U';
    }
    name = name.trim();
    if (name.isEmpty) return 'U';
    final chars = name.characters;
    return chars.isEmpty ? 'U' : chars.first.toUpperCase();
  }

  String _getAccountInitial(Account account) {
    String name;
    if (account.displayName?.isNotEmpty == true) {
      name = account.displayName!;
    } else if (account.username?.isNotEmpty == true &&
        account.username != account.id) {
      name = account.username!;
    } else {
      // Use first 2 chars of ID as fallback
      final idStr = account.id;
      return idStr.length >= 2 ? idStr.substring(0, 2).toUpperCase() : 'U';
    }
    name = name.trim();
    if (name.isEmpty) return 'U';
    final chars = name.characters;
    return chars.isEmpty ? 'U' : chars.first.toUpperCase();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await widget.api.getProfile();
      if (mounted) {
        setState(() {
          _profile = profile;
          _cachedProfile = profile;
          _displayNameController.text = profile?.displayName ?? '';
          _bioController.text = profile?.bio ?? '';
          _emailController.text = profile?.email ?? '';
          _tagsController.text = profile?.tags ?? '';
        });
      }
    } catch (e) {
      print('Load profile error: $e');
    }
  }

  Future<void> _saveProfile() async {
    final email = _emailController.text.trim();
    if (email.isNotEmpty && (!email.contains('@') || !email.contains('.'))) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Некорректный email')));
      }
      return;
    }
    setState(() => _isSaving = true);
    try {
      final updatedProfile = await widget.api.updateProfile(
        displayName: _displayNameController.text,
        bio: _bioController.text,
        email: email.isNotEmpty ? email : null,
        tags: _tagsController.text,
      );
      if (mounted) {
        setState(() {
          if (updatedProfile != null) {
            _profile = updatedProfile;
          }
          _isSaving = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _pickImage() async {
    setState(() => _isUploadingAvatar = true);
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      try {
        // Copy to app temp dir to ensure stable access
        final tmpDir = await getTemporaryDirectory();
        final localImage = File(
          '${tmpDir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await localImage.writeAsBytes(
          await File(result.files.single.path!).readAsBytes(),
        );

        final controller = ImageCropperController();
        final file = await Navigator.push<Uint8List>(
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
                      try {
                        final bytes = await controller.crop();
                        if (context.mounted) Navigator.pop(context, bytes);
                      } catch (_) {
                        if (context.mounted) Navigator.pop(context);
                      }
                    },
                    child: Text(AppLocalizations.of(context).save),
                  ),
                ],
              ),
              body: ImageCropperWidget(
                controller: controller,
                image: FileImage(localImage),
                aspectRatio: CropperRatio.ratio1_1,
                style: CropperStyle(showGrid: true),
              ),
            ),
          ),
        );
        localImage.delete().catchError((_) {});
        if (file != null) {
          final out = File(
            '${tmpDir.path}/crop_${DateTime.now().millisecondsSinceEpoch}.png',
          );
          await out.writeAsBytes(file);
          final avatarUrl = await widget.api.uploadAvatar(out);
          out.delete().catchError((_) {});
          if (mounted) {
            setState(() {
              _profile = _profile?.copyWith(avatarUrl: avatarUrl);
            });
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to upload avatar: $e')),
          );
        }
      } finally {
        if (mounted) setState(() => _isUploadingAvatar = false);
      }
    } else {
      if (mounted) setState(() => _isUploadingAvatar = false);
    }
  }

  Future<void> _removeAvatar() async {
    final success = await widget.api.deleteAvatar();
    if (success && mounted) {
      setState(() {
        _profile = _profile?.copyWith(avatarUrl: null);
      });
    }
  }

  String _getAvatarUrl() {
    if (_profile?.avatarUrl == null) return '';
    if (_profile!.avatarUrl!.startsWith('http')) {
      return _profile!.avatarUrl!;
    }
    return 'https://wlvorti.ru:3000${_profile!.avatarUrl}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            width: constraints.maxWidth,
            child: Text(
              AppLocalizations.of(context).account,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: _accounts.length > 1,
              label: Text('${_accounts.length}'),
              child: const Icon(Icons.switch_account),
            ),
            onPressed: _showAccountsBottomSheet,
            tooltip: AppLocalizations.of(context).switchAccount,
          ),
          IconButton(
            icon: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check),
            onPressed: (_isSaving || _isUploadingAvatar) ? null : _saveProfile,
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16,
          MediaQuery.of(context).padding.bottom + kBottomNavigationBarHeight + 16,
        ),
        children: [
          if (_profile != null)
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundColor: colorFromId(widget.api.userId ?? ''),
                    backgroundImage: _profile?.avatarUrl != null
                        ? CachedNetworkImageProvider(_getAvatarUrl())
                        : null,
                    child: _profile?.avatarUrl == null
                        ? Text(
                            _getInitial(),
                            style: const TextStyle(fontSize: 36),
                          )
                        : null,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _pickImage,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _themeProvider.primaryColor,
                          shape: BoxShape.circle,
                        ),
                        child: _isUploadingAvatar
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.camera_alt,
                                size: 16,
                                color: Colors.white,
                              ),
                      ),
                    ),
                  ),
                  if (_profile?.avatarUrl != null)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: _removeAvatar,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '@${_profile?.username ?? ''}',
              style: const TextStyle(fontSize: 16),
            ),
          ),
          const SizedBox(height: 24),
          Builder(
            builder: (context) {
              final theme = Theme.of(context);
              return TextField(
                controller: _displayNameController,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).displayName,
                  labelStyle: theme.textTheme.bodyMedium?.copyWith(
                    overflow: TextOverflow.ellipsis,
                  ),
                  alignLabelWithHint: true,
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Builder(
            builder: (context) {
              final theme = Theme.of(context);
              return TextField(
                controller: _emailController,
                decoration: InputDecoration(
                  labelText: 'Email',
                  hintText: 'example@mail.com',
                  labelStyle: theme.textTheme.bodyMedium?.copyWith(
                    overflow: TextOverflow.ellipsis,
                  ),
                  alignLabelWithHint: true,
                  prefixIcon: const Icon(Icons.email_outlined),
                  errorText: _emailError,
                ),
                keyboardType: TextInputType.emailAddress,
              );
            },
          ),
          if (_emailController.text.isEmpty) ...[
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Укажите email для восстановления аккаунта',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                );
              },
            ),
          ],
          const SizedBox(height: 16),
          Builder(
            builder: (context) {
              final theme = Theme.of(context);
              return TextField(
                controller: _bioController,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).bio,
                  labelStyle: theme.textTheme.bodyMedium?.copyWith(
                    overflow: TextOverflow.ellipsis,
                  ),
                  alignLabelWithHint: true,
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Builder(
            builder: (context) {
              final theme = Theme.of(context);
              return TextField(
                controller: _tagsController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Search Tags',
                  helperText: 'hobbies, city, profession, gaming nickname',
                  labelStyle: theme.textTheme.bodyMedium?.copyWith(
                    overflow: TextOverflow.ellipsis,
                  ),
                  alignLabelWithHint: true,
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: const Icon(Icons.palette, color: Colors.white, size: 20),
              ),
              title: Text(AppLocalizations.of(context).theme),
              subtitle: Text(
                _themeProvider.themeId == 'custom'
                    ? AppLocalizations.of(context).custom
                    : _themeProvider.themeId,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ThemeSettingsScreen(themeProvider: _themeProvider),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: const Icon(
                  Icons.language,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              title: Text(AppLocalizations.of(context).language),
              subtitle: Text(
                AppLocalizations.of(
                  context,
                ).localeName(LocaleProvider().locale.languageCode),
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showLanguagePicker(),
            ),
          ),
          const SizedBox(height: 16),
          Builder(
            builder: (context) {
              final theme = Theme.of(context);
              return Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${AppLocalizations.of(context).joined}: ${_formatDate(_profile?.createdAt ?? 0)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.surface,
            child: ListTile(
              leading: Icon(
                Icons.bug_report,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(AppLocalizations.of(context).copyDebugLogs),
              subtitle: Text(
                '${ApiService.logs.length} ${AppLocalizations.of(context).entries}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onTap: () {
                Clipboard.setData(ClipboardData(text: ApiService.getLogs()));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(AppLocalizations.of(context).logsCopied),
                    duration: Duration(seconds: 3),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: Theme.of(context).colorScheme.surface,
            child: ListTile(
              leading: Icon(Icons.logout, color: Colors.red),
              title: Text(
                AppLocalizations.of(context).logout,
                style: TextStyle(color: Colors.red),
              ),
              onTap: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(AppLocalizations.of(context).logout),
                    content: Text(AppLocalizations.of(context).logOutConfirm),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(AppLocalizations.of(context).cancel),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                        child: Text(AppLocalizations.of(context).logout),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await widget.api.clearCredentials();
                  widget.api.disconnect();
                  if (mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (_) => AuthScreen(api: widget.api),
                      ),
                      (route) => false,
                    );
                  }
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showLanguagePicker() {
    final current = LocaleProvider().locale.languageCode;
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  AppLocalizations.of(context).appLanguage,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.check_circle, size: 20),
                title: const Text('English'),
                trailing: current == 'en'
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  LocaleProvider().setLocale(const Locale('en'));
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.check_circle, size: 20),
                title: const Text('Русский'),
                trailing: current == 'ru'
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  LocaleProvider().setLocale(const Locale('ru'));
                  Navigator.pop(context);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildColorRow(String label, Color color, String key) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade300, width: 1),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          GestureDetector(
            onTap: () => _showColorPicker(key, color),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: const Text('Change', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  void _showColorPicker(String key, Color currentColor) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      builder: (context) => _ColorPickerSheet(
        currentColor: currentColor,
        onColorSelected: (color) {
          _themeProvider.setCustomColor(key, color);
        },
      ),
    );
  }

  void _createCustomTheme(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      isScrollControlled: true,
      builder: (context) => _CustomThemeSheet(themeProvider: _themeProvider),
    );
  }

  String _formatDate(int timestamp) {
    return AppLocalizations.of(context).formatDate(timestamp);
  }
}

class _ColorPickerSheet extends StatefulWidget {
  final Color currentColor;
  final Function(Color) onColorSelected;

  const _ColorPickerSheet({
    required this.currentColor,
    required this.onColorSelected,
  });

  @override
  State<_ColorPickerSheet> createState() => _ColorPickerSheetState();
}

class _ColorPickerSheetState extends State<_ColorPickerSheet> {
  final _hexController = TextEditingController();
  String? _errorText;

  static const List<Color> _presetColors = [
    Color(0xFF000000),
    Color(0xFF212121),
    Color(0xFF424242),
    Color(0xFF757575),
    Color(0xFFBDBDBD),
    Color(0xFFE0E0E0),
    Color(0xFFF5F5F5),
    Color(0xFFFFFFFF),
    Color(0xFFF44336),
    Color(0xFFE91E63),
    Color(0xFF9C27B0),
    Color(0xFF673AB7),
    Color(0xFF3F51B5),
    Color(0xFF2196F3),
    Color(0xFF03A9F4),
    Color(0xFF00BCD4),
    Color(0xFF009688),
    Color(0xFF4CAF50),
    Color(0xFF8BC34A),
    Color(0xFFCDDC39),
    Color(0xFFFFEB3B),
    Color(0xFFFFC107),
    Color(0xFFFF9800),
    Color(0xFFFF5722),
    Color(0xFF795548),
    Color(0xFF607D8B),
  ];

  void _applyHexColor() {
    final hex = _hexController.text.trim();
    if (hex.isEmpty) return;

    String colorHex = hex;
    if (!hex.startsWith('#')) {
      colorHex = '#$hex';
    }

    try {
      final color = Color(int.parse(colorHex.replaceFirst('#', '0xFF')));
      widget.onColorSelected(color);
      Navigator.pop(context);
    } catch (e) {
      setState(() => _errorText = 'Invalid color code');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select Color',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _hexController,
                  decoration: InputDecoration(
                    hintText: '#FF0000',
                    labelText: 'Hex code',
                    errorText: _errorText,
                    isDense: true,
                    prefixText: '#',
                  ),
                  onChanged: (_) => setState(() => _errorText = null),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _applyHexColor,
                child: const Text('Apply'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('or pick a color:'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presetColors.map((color) {
              return GestureDetector(
                onTap: () {
                  widget.onColorSelected(color);
                  Navigator.pop(context);
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(8),
                    border: color == widget.currentColor
                        ? Border.all(color: Colors.blue, width: 3)
                        : Border.all(color: Colors.grey.shade300),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _CustomThemeSheet extends StatefulWidget {
  final ThemeProvider themeProvider;

  const _CustomThemeSheet({required this.themeProvider});

  @override
  State<_CustomThemeSheet> createState() => _CustomThemeSheetState();
}

class _CustomThemeSheetState extends State<_CustomThemeSheet> {
  Color _primary = const Color(0xFF2196F3);
  Color _secondary = const Color(0xFF03A9F4);
  Color _background = Colors.white;
  Color _surface = const Color(0xFFF5F5F5);
  Color _text = const Color(0xFF212121);
  Color _textSecondary = const Color(0xFF757575);

  static const List<Color> _colors = [
    Color(0xFF000000),
    Color(0xFF212121),
    Color(0xFF424242),
    Color(0xFF757575),
    Color(0xFFBDBDBD),
    Color(0xFFE0E0E0),
    Color(0xFFF5F5F5),
    Color(0xFFFFFFFF),
    Color(0xFFF44336),
    Color(0xFFE91E63),
    Color(0xFF9C27B0),
    Color(0xFF673AB7),
    Color(0xFF3F51B5),
    Color(0xFF2196F3),
    Color(0xFF03A9F4),
    Color(0xFF00BCD4),
    Color(0xFF009688),
    Color(0xFF4CAF50),
    Color(0xFF8BC34A),
    Color(0xFFCDDC39),
    Color(0xFFFFEB3B),
    Color(0xFFFFC107),
    Color(0xFFFF9800),
    Color(0xFFFF5722),
    Color(0xFF795548),
    Color(0xFF607D8B),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Create Custom Theme',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          _buildColorPicker(
            'Primary',
            _primary,
            (c) => setState(() => _primary = c),
          ),
          _buildColorPicker(
            'Secondary',
            _secondary,
            (c) => setState(() => _secondary = c),
          ),
          _buildColorPicker(
            'Background',
            _background,
            (c) => setState(() => _background = c),
          ),
          _buildColorPicker(
            'Surface',
            _surface,
            (c) => setState(() => _surface = c),
          ),
          _buildColorPicker('Text', _text, (c) => setState(() => _text = c)),
          _buildColorPicker(
            'Text Secondary',
            _textSecondary,
            (c) => setState(() => _textSecondary = c),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                widget.themeProvider.setCustomTheme(
                  _primary,
                  _secondary,
                  _background,
                  _surface,
                  _text,
                  _textSecondary,
                );
                Navigator.pop(context);
              },
              child: const Text('Create Theme'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildColorPicker(
    String label,
    Color color,
    Function(Color) onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _colors.map((c) {
              return GestureDetector(
                onTap: () => onChanged(c),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c,
                    borderRadius: BorderRadius.circular(4),
                    border: c == color
                        ? Border.all(color: Colors.blue, width: 3)
                        : Border.all(color: Colors.grey.shade300),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _AccountsBottomSheet extends StatefulWidget {
  final ApiService api;
  final List<Account> accounts;
  final Account? currentAccount;
  final ThemeProvider themeProvider;
  final VoidCallback onAccountSwitched;
  final VoidCallback onAccountsUpdated;

  const _AccountsBottomSheet({
    required this.api,
    required this.accounts,
    required this.currentAccount,
    required this.themeProvider,
    required this.onAccountSwitched,
    required this.onAccountsUpdated,
  });

  @override
  State<_AccountsBottomSheet> createState() => _AccountsBottomSheetState();
}

class _AccountsBottomSheetState extends State<_AccountsBottomSheet> {
  late List<Account> _accounts;

  @override
  void initState() {
    super.initState();
    _accounts = List.from(widget.accounts);
  }

  Future<void> _switchAccount(Account account) async {
    if (account.id == widget.currentAccount?.id) return;

    await widget.api.switchAccount(account.id);
    widget.themeProvider.setCurrentUser(account.id);
    await widget.themeProvider.loadTheme();
    WallpaperService().setCurrentUser(account.id);
    await WallpaperService().load();

    if (!await CryptoService.hasSeed(account.id)) {
      if (!context.mounted) return;
      final phrase = await _showPassphraseDialog(context, account.id);
      if (phrase != null) {
        await CryptoService.initWithPassphrase(phrase, account.id);
      }
    } else {
      await CryptoService.initForUser(account.id);
    }
    await CryptoService.uploadPublicKey(widget.api);

    widget.onAccountSwitched();
  }

  Future<String?> _showPassphraseDialog(BuildContext ctx, String userId) async {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    bool obscure = true;
    bool isNew = false;
    String? error;

    final result = await showDialog<String?>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final phrase = controller.text.trim();
              if (phrase.isEmpty) {
                setDialogState(() => error = 'Enter a passphrase');
                return;
              }
              if (phrase.length < 4) {
                setDialogState(() => error = 'At least 4 characters');
                return;
              }
              if (isNew && confirmController.text.trim() != phrase) {
                setDialogState(() => error = 'Passphrases do not match');
                return;
              }
              Navigator.of(context).pop(phrase);
            }

            final theme = Theme.of(context);
            return AlertDialog(
              title: Text(isNew ? 'Set recovery passphrase' : 'Enter recovery passphrase'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isNew
                          ? 'This passphrase restores your encryption keys on a new device. '
                              'Save it securely — without it, old private messages become unreadable.'
                          : 'Enter the passphrase you set on your previous device to restore encryption keys.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      obscureText: obscure,
                      decoration: const InputDecoration(
                        labelText: 'Recovery passphrase',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) {
                        if (error != null) setDialogState(() => error = null);
                      },
                    ),
                    if (isNew) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: confirmController,
                        obscureText: obscure,
                        decoration: const InputDecoration(
                          labelText: 'Confirm passphrase',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) {
                          if (error != null) setDialogState(() => error = null);
                        },
                      ),
                    ],
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(error!, style: TextStyle(color: theme.colorScheme.error)),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Checkbox(
                          value: !obscure,
                          onChanged: (v) => setDialogState(() => obscure = !(v ?? false)),
                        ),
                        GestureDetector(
                          onTap: () => setDialogState(() => obscure = !obscure),
                          child: const Text('Show passphrase'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                if (!isNew)
                  TextButton(
                    onPressed: () => setDialogState(() => isNew = true),
                    child: const Text('First time — set new'),
                  ),
                TextButton(
                  onPressed: () => isNew ? setDialogState(() => isNew = false) : submit(),
                  child: Text(isNew ? 'Back' : 'Continue'),
                ),
                if (isNew)
                  FilledButton(onPressed: submit, child: const Text('Set & Continue')),
              ],
            );
          },
        );
      },
    );
    return result;
  }

  Future<void> _addAccount() async {
    Navigator.pop(context);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuthScreen(api: widget.api, isAddingAccount: true),
      ),
    );
    widget.onAccountsUpdated();
  }

  Future<void> _removeAccount(Account account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить аккаунт'),
        content: Text(
          'Удалить ${account.displayName ?? account.username} с этого устройства?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.api.removeAccount(account.id);
      setState(() {
        _accounts.removeWhere((a) => a.id == account.id);
      });
      widget.onAccountsUpdated();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Accounts', style: theme.textTheme.titleLarge),
              IconButton(
                icon: const Icon(Icons.add),
                onPressed: _addAccount,
                tooltip: 'Add account',
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_accounts.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'No accounts added',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _accounts.length,
                itemBuilder: (context, index) {
                  final account = _accounts[index];
                  final isCurrent = account.id == widget.currentAccount?.id;

                  return Card(
                    color: isCurrent
                        ? theme.colorScheme.primary.withValues(alpha: 0.1)
                        : theme.colorScheme.surface,
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: colorFromId(account.id),
                        backgroundImage: account.avatarUrl != null
                            ? CachedNetworkImageProvider(
                                'https://wlvorti.ru:3000${account.avatarUrl}',
                              )
                            : null,
                        child: account.avatarUrl == null
                            ? Text(_getAccountInitial(account))
                            : null,
                      ),
                      title: Text(
                        account.displayName?.isNotEmpty == true
                            ? account.displayName!
                            : account.username?.isNotEmpty == true
                            ? account.username!
                            : 'Account ${account.id.substring(0, account.id.length > 8 ? 8 : account.id.length)}',
                      ),
                      subtitle: Text(
                        account.username?.isNotEmpty == true
                            ? '@${account.username}'
                            : 'ID: ${account.id.substring(0, account.id.length > 12 ? 12 : account.id.length)}...',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isCurrent)
                            Icon(
                              Icons.check_circle,
                              color: theme.colorScheme.primary,
                            ),
                          if (!isCurrent)
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _removeAccount(account),
                              color: Colors.red,
                            ),
                        ],
                      ),
                      onTap: () => _switchAccount(account),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  String _getAccountInitial(Account account) {
    String name;
    if (account.displayName?.isNotEmpty == true) {
      name = account.displayName!;
    } else if (account.username?.isNotEmpty == true &&
        account.username != account.id) {
      name = account.username!;
    } else {
      final idStr = account.id;
      return idStr.length >= 2 ? idStr.substring(0, 2).toUpperCase() : 'U';
    }
    name = name.trim();
    if (name.isEmpty) return 'U';
    final chars = name.characters;
    return chars.isEmpty ? 'U' : chars.first.toUpperCase();
  }
}
