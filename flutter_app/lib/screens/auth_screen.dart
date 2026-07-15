import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/crypto_service.dart';
import '../models/models.dart';
import 'home_screen.dart';

class AuthScreen extends StatefulWidget {
  final ApiService api;
  final bool isAddingAccount;

  const AuthScreen({super.key, required this.api, this.isAddingAccount = false});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLogin = true;
  bool _registerWithEmail = false;
  bool _isLoading = false;
  String? _error;

  // Валидация
  bool _usernameValid = false;
  bool _passwordValid = false;
  bool _emailValid = false;
  String _usernameError = '';
  String _passwordError = '';
  String _emailError = '';

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_validateUsername);
    _emailController.addListener(_validateEmail);
    _passwordController.addListener(_validatePassword);
  }

  void _validateUsername() {
    final username = _usernameController.text.trim();
    setState(() {
      if (username.isEmpty) {
        _usernameValid = false;
        _usernameError = '';
      } else if (username.length < 3) {
        _usernameValid = false;
        _usernameError = 'Минимум 3 символа';
      } else if (username.length > 32) {
        _usernameValid = false;
        _usernameError = 'Максимум 32 символа';
      } else if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(username)) {
        _usernameValid = false;
        _usernameError = 'Только буквы, цифры и _';
      } else {
        _usernameValid = true;
        _usernameError = '';
      }
    });
  }

  void _validateEmail() {
    final email = _emailController.text.trim();
    setState(() {
      if (email.isEmpty) {
        _emailValid = false;
        _emailError = '';
      } else if (!email.contains('@') || !email.contains('.')) {
        _emailValid = false;
        _emailError = 'Введите корректный email';
      } else {
        _emailValid = true;
        _emailError = '';
      }
    });
  }

  int _getPasswordStrength() {
    final password = _passwordController.text;
    int strength = 0;

    if (password.length >= 8) strength++;
    if (password.length >= 12) strength++;
    if (RegExp(r'[a-z]').hasMatch(password)) strength++;
    if (RegExp(r'[A-Z]').hasMatch(password)) strength++;
    if (RegExp(r'[0-9]').hasMatch(password)) strength++;
    if (RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(password)) strength++;

    return strength;
  }

  Color _getStrengthColor(int strength) {
    if (strength <= 2) return Colors.red;
    if (strength <= 4) return Colors.orange;
    return Colors.green;
  }

  String _getStrengthText(int strength) {
    if (strength <= 2) return 'Слабый';
    if (strength <= 4) return 'Средний';
    return 'Надёжный';
  }

  void _validatePassword() {
    final password = _passwordController.text;
    setState(() {
      if (password.isEmpty) {
        _passwordValid = false;
        _passwordError = '';
      } else if (password.length < 8) {
        _passwordValid = false;
        _passwordError = 'Минимум 8 символов';
      } else if (!RegExp(r'[a-z]').hasMatch(password)) {
        _passwordValid = false;
        _passwordError = 'Нужна строчная буква (a-z)';
      } else if (!RegExp(r'[A-Z]').hasMatch(password)) {
        _passwordValid = false;
        _passwordError = 'Нужна заглавная буква (A-Z)';
      } else if (!RegExp(r'[0-9]').hasMatch(password)) {
        _passwordValid = false;
        _passwordError = 'Нужна цифра (0-9)';
      } else if (!RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(password)) {
        _passwordValid = false;
        _passwordError = 'Нужен спецсимвол';
      } else {
        _passwordValid = true;
        _passwordError = '';
      }
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordController.text;

    if (_isLogin) {
      final loginValue = _usernameController.text.trim();
      if (loginValue.isEmpty || password.isEmpty) {
        setState(() => _error = 'Заполните все поля');
        return;
      }
      setState(() { _isLoading = true; _error = null; });
      final result = await widget.api.login(loginValue, password);
      setState(() => _isLoading = false);
      if (result['token'] != null) {
        await CryptoService.initWithPassword(password, widget.api.userId!);
        if (mounted) await CryptoService.uploadPublicKey(widget.api);
      }
      _handleAuthResult(result);
    } else if (_registerWithEmail) {
      _validateEmail();
      _validatePassword();
      if (!_emailValid || !_passwordValid) {
        setState(() => _error = 'Проверьте требования к полям');
        return;
      }
      final email = _emailController.text.trim();
      if (email.isEmpty || password.isEmpty) {
        setState(() => _error = 'Заполните все поля');
        return;
      }
      setState(() { _isLoading = true; _error = null; });
      final result = await widget.api.registerWithEmail(email, password);
      setState(() => _isLoading = false);
      if (result['token'] != null) {
        await CryptoService.initWithPassword(password, widget.api.userId!);
        if (mounted) await CryptoService.uploadPublicKey(widget.api);
      }
      _handleAuthResult(result);
    } else {
      _validateUsername();
      _validatePassword();
      if (!_usernameValid || !_passwordValid) {
        setState(() => _error = 'Проверьте требования к полям');
        return;
      }
      final username = _usernameController.text.trim();
      if (username.isEmpty || password.isEmpty) {
        setState(() => _error = 'Заполните все поля');
        return;
      }
      setState(() { _isLoading = true; _error = null; });
      final result = await widget.api.register(username, password);
      setState(() => _isLoading = false);
      if (result['token'] != null) {
        await CryptoService.initWithPassword(password, widget.api.userId!);
        if (mounted) await CryptoService.uploadPublicKey(widget.api);
      }
      _handleAuthResult(result);
    }
  }

  Future<void> _handleAuthResult(Map<String, dynamic> result) async {
    if (result['status'] == 'success' || result['token'] != null) {
      final hasEmail = (result['email'] as String?)?.isNotEmpty == true;
      if (widget.isAddingAccount) {
        final profile = await widget.api.getProfile();
        if (profile != null) {
          await widget.api.addAccount(
            result['token'],
            result['userId'] ?? widget.api.userId ?? '',
            profile.username,
            avatarUrl: profile.avatarUrl,
            displayName: profile.displayName,
          );
          await widget.api.registerSavedDevice();
        }
        if (mounted) Navigator.pop(context);
      } else {
        if (mounted) {
          if (!hasEmail) {
            await _showSetEmailDialog();
          }
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => HomeScreen(api: widget.api)),
            );
          }
        }
      }
    } else {
      setState(() {
        final msg = result['message'] as String? ?? 'Ошибка';
        if (msg == 'Invalid username or password') {
          _error = 'Пользователь не найден.\nЕсли у вас нет аккаунта — сначала зарегистрируйтесь.';
        } else if (msg.startsWith('Invalid username or password')) {
          final match = RegExp(r'\d+').firstMatch(msg);
          final attempts = match?.group(0) ?? '?';
          _error = 'Неверный пароль. Осталось попыток: $attempts';
        } else if (msg.startsWith('Account locked')) {
          final match = RegExp(r'(\d+)').firstMatch(msg);
          final secs = match?.group(1) ?? '?';
          _error = 'Аккаунт заблокирован. Попробуйте через $secs секунд.';
        } else if (msg.startsWith('Too many failed attempts')) {
          _error = 'Слишком много неудачных попыток. Аккаунт заблокирован на 15 минут.';
        } else if (msg.contains('Google Sign-In')) {
          _error = 'Этот аккаунт использует Google. Войдите через Google.';
        } else {
          _error = msg;
        }
      });
    }
  }

  Future<bool?> _showSetEmailDialog() async {
    final controller = TextEditingController();
    String? emailError;
    bool saving = false;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Укажите email'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Для использования аккаунта необходимо указать email-адрес.'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: 'Email',
                  hintText: 'example@mail.com',
                  prefixIcon: const Icon(Icons.email_outlined),
                  errorText: emailError,
                ),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx, false),
              child: const Text('Пропустить'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final email = controller.text.trim();
                      if (!email.contains('@')) {
                        setDialogState(() => emailError = 'Некорректный email');
                        return;
                      }
                      setDialogState(() { saving = true; emailError = null; });
                      try {
                        await widget.api.updateProfile(email: email);
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        setDialogState(() {
                          saving = false;
                          emailError = '$e';
                        });
                      }
                    },
              child: saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Column(
            children: [
              // Logo
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(Icons.forum_rounded, size: 36, color: cs.onPrimaryContainer),
              ),
              const SizedBox(height: 16),
              Text(
                'Vorti Messenger',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: cs.onBackground,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _isLogin ? 'Войдите в свой аккаунт' : 'Создайте новый аккаунт',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),

              // Form card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Username (login mode) or email (email register mode) or username (register mode)
                    if (_isLogin)
                      TextField(
                        controller: _usernameController,
                        decoration: InputDecoration(
                          labelText: 'Логин или email',
                          hintText: 'Введите логин или email',
                          prefixIcon: const Icon(Icons.person_outline),
                          errorText: _usernameError.isEmpty ? null : _usernameError,
                          counterText: '${_usernameController.text.length}/64',
                        ),
                        maxLength: 64,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        keyboardType: TextInputType.text,
                      )
                    else if (_registerWithEmail)
                      TextField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: 'Email',
                          hintText: 'example@mail.com',
                          prefixIcon: const Icon(Icons.email_outlined),
                          errorText: _emailError.isEmpty ? null : _emailError,
                          suffixIcon: _emailValid
                              ? const Icon(Icons.check_circle, color: Colors.green)
                              : null,
                        ),
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                      )
                    else
                      TextField(
                        controller: _usernameController,
                        decoration: InputDecoration(
                          labelText: 'Логин',
                          hintText: '3-32 символа: буквы, цифры, _',
                          prefixIcon: const Icon(Icons.person_outline),
                          errorText: _usernameError.isEmpty ? null : _usernameError,
                          suffixIcon: _usernameValid
                              ? const Icon(Icons.check_circle, color: Colors.green)
                              : null,
                          counterText: '${_usernameController.text.length}/32',
                        ),
                        maxLength: 32,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                      ),
                    const SizedBox(height: 16),

                    // Password
                    TextField(
                      controller: _passwordController,
                      decoration: InputDecoration(
                        labelText: 'Пароль',
                        hintText: '8-128 символов',
                        prefixIcon: const Icon(Icons.lock_outline),
                        errorText: _passwordError.isEmpty ? null : _passwordError,
                        suffixIcon: _passwordValid
                            ? const Icon(Icons.check_circle, color: Colors.green)
                            : null,
                        counterText: '${_passwordController.text.length}/128',
                      ),
                      maxLength: 128,
                      obscureText: true,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                    ),

                    // Password strength + requirements (only in register mode)
                    if (!_isLogin) ...[
                      if (_passwordController.text.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: _getPasswordStrength() / 6,
                                  backgroundColor: cs.surfaceContainerHighest,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _getStrengthColor(_getPasswordStrength()),
                                  ),
                                  minHeight: 6,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _getStrengthText(_getPasswordStrength()),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: _getStrengthColor(_getPasswordStrength()),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Требования к паролю:',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 6),
                            _buildRequirement(
                              '8-128 символов',
                              _passwordController.text.length >= 8 && _passwordController.text.length <= 128,
                            ),
                            _buildRequirement(
                              'Строчная буква (a-z)',
                              RegExp(r'[a-z]').hasMatch(_passwordController.text),
                            ),
                            _buildRequirement(
                              'Заглавная буква (A-Z)',
                              RegExp(r'[A-Z]').hasMatch(_passwordController.text),
                            ),
                            _buildRequirement(
                              'Цифра (0-9)',
                              RegExp(r'[0-9]').hasMatch(_passwordController.text),
                            ),
                            _buildRequirement(
                              'Спецсимвол (!@#\$%^&*...)',
                              RegExp(r'[!@#$%^&*(),.?":{}|<>]').hasMatch(_passwordController.text),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Error
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // Submit button
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _submit,
                        child: _isLoading
                            ? const SizedBox(
                                width: 22, height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                              )
                            : Text(_isLogin ? 'Войти' : 'Создать аккаунт', style: const TextStyle(fontSize: 16)),
                      ),
                    ),
                  ],
                ),
              ),

              // Google sign-in
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'или',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _isLoading
                      ? null
                      : () async {
                          setState(() {
                            _isLoading = true;
                            _error = null;
                          });
                          final result = await widget.api.signInWithGoogle();
                          setState(() => _isLoading = false);
                          if (result['status'] == 'success' || result['token'] != null) {
                            final isNew = result['isNew'] == true;
                            if (widget.api.userId != null) {
                              await CryptoService.initRandomKey(widget.api.userId!);
                              if (mounted) await CryptoService.uploadPublicKey(widget.api);
                            }
                            if (isNew && !widget.isAddingAccount && mounted) {
                              final chosen = await _showUsernameDialog(result['username'] as String? ?? '');
                              if (chosen != null && mounted) {
                                try {
                                  await widget.api.updateProfile(username: chosen);
                                } catch (_) {}
                              }
                            }
                            if (widget.isAddingAccount) {
                              if (mounted) Navigator.pop(context);
                            } else {
                              if (mounted) {
                                Navigator.of(context).pushReplacement(
                                  MaterialPageRoute(builder: (_) => HomeScreen(api: widget.api)),
                                );
                              }
                            }
                          } else {
                            setState(() {
                              final msg = result['message'] as String? ?? 'Ошибка';
                              _error = msg;
                            });
                          }
                        },
                  icon: const Icon(Icons.g_mobiledata_rounded, size: 28),
                  label: const Text('Google'),
                ),
              ),
              const SizedBox(height: 20),

              // Toggle login/register
              TextButton(
                onPressed: () {
                  setState(() {
                    _isLogin = !_isLogin;
                    _registerWithEmail = false;
                    _error = null;
                  });
                },
                child: Text(
                  _isLogin ? 'Нет аккаунта? Зарегистрироваться' : 'Уже есть аккаунт? Войти',
                  style: TextStyle(color: cs.primary, fontWeight: FontWeight.w500),
                ),
              ),

              if (!_isLogin) ...[
                TextButton(
                  onPressed: () => setState(() {
                    _registerWithEmail = !_registerWithEmail;
                    _error = null;
                  }),
                  child: Text(
                    _registerWithEmail ? 'Регистрация по логину' : 'Регистрация по email',
                    style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w400, fontSize: 13),
                  ),
                ),
              ],

              // Forgot password
              if (_isLogin)
                TextButton(
                  onPressed: () => _showForgotPasswordDialog(),
                  child: Text(
                    'Забыли пароль?',
                    style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w400, fontSize: 13),
                  ),
                ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  void _showForgotPasswordDialog() {
    final emailController = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String? error;
        bool sending = false;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Восстановление пароля'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Введите email, к которому привязан аккаунт'),
                const SizedBox(height: 16),
                TextField(
                  controller: emailController,
                  decoration: InputDecoration(
                    labelText: 'Email',
                    hintText: 'example@mail.com',
                    prefixIcon: const Icon(Icons.email_outlined),
                    errorText: error,
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: sending ? null : () { emailController.dispose(); Navigator.pop(ctx); },
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: sending
                    ? null
                    : () async {
                        final email = emailController.text.trim();
                        if (!email.contains('@')) {
                          setState(() => error = 'Некорректный email');
                          return;
                        }
                        setState(() { sending = true; error = null; });
                        final result = await widget.api.forgotPassword(email);
                        if (result['status'] == 'success') {
                          Navigator.pop(ctx);
                          _showResetPasswordDialog(email, result['token'] as String?);
                        } else {
                          setState(() => error = result['message'] as String? ?? 'Ошибка');
                        }
                      },
                child: sending
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Отправить код'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showResetPasswordDialog(String email, String? prefillToken) {
    showResetPasswordDialog(context, widget.api, email, prefillToken, onSuccess: () {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Пароль изменён. Войдите с новым паролем.')),
        );
      }
    });
  }

  Future<String?> _showUsernameDialog(String suggested) async {
    final controller = TextEditingController(text: suggested);
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Выберите имя пользователя'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Логин',
              hintText: '3-32 символа: буквы, цифры, _',
              prefixText: '@',
            ),
            maxLength: 32,
            validator: (v) {
              if (v == null || v.trim().length < 3) return 'Минимум 3 символа';
              if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(v.trim())) return 'Только буквы, цифры и _';
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: const Text('Готово'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Widget _buildRequirement(String text, bool met) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : Icons.circle_outlined,
            size: 14,
            color: met ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: met ? Colors.green : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResetPasswordDialog extends StatefulWidget {
  final ApiService api;
  final String email;
  final String? prefillToken;
  final VoidCallback? onSuccess;
  const _ResetPasswordDialog({required this.api, required this.email, this.prefillToken, this.onSuccess});
  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  late final TextEditingController _codeController;
  late final TextEditingController _passwordController;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController(text: widget.prefillToken ?? '');
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _codeController.text.trim();
    final password = _passwordController.text;
    if (code.isEmpty) { setState(() => _error = 'Введите код'); return; }
    if (password.length < 8) { setState(() => _error = 'Пароль минимум 8 символов'); return; }
    setState(() { _sending = true; _error = null; });
    final result = await widget.api.resetPassword(code, password);
    if (!mounted) return;
    if (result['status'] == 'success') {
      widget.onSuccess?.call();
      Navigator.pop(context);
    } else {
      setState(() => _error = result['message'] as String? ?? 'Ошибка');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Новый пароль'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Код отправлен на ${widget.email}'),
          const SizedBox(height: 16),
          TextField(
            controller: _codeController,
            decoration: InputDecoration(
              labelText: 'Код сброса',
              hintText: 'Вставьте код из письма',
              prefixIcon: const Icon(Icons.vpn_key_outlined),
              errorText: _error,
            ),
            maxLength: 64,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(
              labelText: 'Новый пароль',
              hintText: '8-128 символов',
              prefixIcon: Icon(Icons.lock_outline),
            ),
            obscureText: true,
            maxLength: 128,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _sending ? null : _submit,
          child: _sending
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Сбросить'),
        ),
      ],
    );
  }
}

void showResetPasswordDialog(BuildContext context, ApiService api, String email, String? prefillToken, {VoidCallback? onSuccess}) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ResetPasswordDialog(api: api, email: email, prefillToken: prefillToken, onSuccess: onSuccess),
  );
}
