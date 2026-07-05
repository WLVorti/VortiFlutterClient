import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart' hide User;
import 'package:google_sign_in/google_sign_in.dart';
import '../models/models.dart';
import '../models/account.dart';
import 'theme_provider.dart';
import 'crypto_service.dart';
import 'wallpaper_service.dart';

class ApiService {
  static const String baseUrl = 'https://wlvorti.ru:3000';
  static const String wsUrl = 'wss://wlvorti.ru:3000';
  static final List<String> logs = [];

  static void init() {
    addLog('App started');
    addLog('Server: $baseUrl');
    addLog('WS: $wsUrl');
  }

  static void addLog(String message) {
    final timestamp = DateTime.now().toIso8601String();
    logs.add('[$timestamp] $message');
    if (logs.length > 500) {
      logs.removeAt(0);
    }
  }

  static String getLogs() => logs.join('\n');

  final _storage = const FlutterSecureStorage();
  final _client = http.Client();
  String? _token;
  String? _userId;
  String? _fcmToken;
  WebSocketChannel? _wsChannel;
  final List<Function(Map<String, dynamic>)> _messageListeners = [];
  VoidCallback? onDisconnected;
  VoidCallback? onReconnecting;
  VoidCallback? onReconnected;
  VoidCallback? onOnlineUsersChanged;
  VoidCallback? onAuthExpired;
  final Set<String> _onlineUsers = {};
  
  void addMessageListener(Function(Map<String, dynamic>) listener) {
    _messageListeners.add(listener);
  }
  
  void removeMessageListener(Function(Map<String, dynamic>) listener) {
    _messageListeners.remove(listener);
  }
  
  @Deprecated('Use addMessageListener/removeMessageListener instead')
  Function(Map<String, dynamic>)? get onMessage => null;
  
  @Deprecated('Use addMessageListener/removeMessageListener instead')
  set onMessage(Function(Map<String, dynamic>)? listener) {
    if (listener != null) {
      _messageListeners.clear();
      _messageListeners.add(listener);
    }
  }

  bool _isReconnecting = false;
  bool _isConnecting = false;
  bool _isIntentionalDisconnect = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  Timer? _reconnectTimer;
  StreamSubscription<dynamic>? _wsStreamSubscription;

  String? get token => _token;
  String? get userId => _userId;
  Set<String> get onlineUsers => Set.unmodifiable(_onlineUsers);
  bool isUserOnline(String userId) => _onlineUsers.contains(userId);

  Future<void> saveCredentials(String token, String userId) async {
    _token = token;
    _userId = userId;
    await _storage.write(key: 'token', value: token);
    await _storage.write(key: 'userId', value: userId);
  }

  Future<void> loadCredentials() async {
    _token = await _storage.read(key: 'token');
    _userId = await _storage.read(key: 'userId');
    _fcmToken = await _storage.read(key: 'fcm_token');
    ApiService.addLog('Credentials loaded: token=${_token != null}, userId=$_userId');
  }

  Future<void> saveFcmToken(String token) async {
    _fcmToken = token;
    await _storage.write(key: 'fcm_token', value: token);
  }

  Future<void> clearCredentials() async {
    _token = null;
    _userId = null;
    _fcmToken = null;
    await _storage.delete(key: 'token');
    await _storage.delete(key: 'userId');
    await _storage.delete(key: 'fcm_token');
  }

  // ==================== Account switcher ====================

  static const String _accountsKey = 'accounts_list';
  static const String _currentAccountKey = 'current_account_id';
  static const String _lastActiveKey = 'last_active';

  Future<bool> _tryRefreshToken() async {
    if (_token == null) return false;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/auth/refresh'),
        headers: _headers,
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        _token = data['token'];
        _userId = data['userId'];
        await _storage.write(key: 'token', value: _token);
        await _storage.write(key: 'userId', value: _userId);
        ApiService.addLog('Token refreshed successfully');
        return true;
      }
      ApiService.addLog('Token refresh failed: ${res.statusCode} ${res.body}');
    } catch (e) {
      ApiService.addLog('Token refresh error: $e');
    }
    return false;
  }

  Future<http.Response> _requestWithRefresh(Future<http.Response> Function() request) async {
    var res = await request();
    if (res.statusCode == 401) {
      final refreshed = await _tryRefreshToken();
      if (refreshed) {
        res = await request();
        if (res.statusCode == 401) {
          _handleAuthExpired();
        }
      } else {
        _handleAuthExpired();
      }
    }
    return res;
  }

  void _handleAuthExpired() {
    clearCredentials();
    onAuthExpired?.call();
  }

  Future<void> updateLastActive() async {
    await _storage.write(key: _lastActiveKey, value: DateTime.now().millisecondsSinceEpoch.toString());
  }

  Future<bool> isSessionExpired() async {
    final lastActive = await _storage.read(key: _lastActiveKey);
    if (lastActive == null) return false;
    final lastActiveMs = int.tryParse(lastActive);
    if (lastActiveMs == null) return false;
    final weekAgo = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    return lastActiveMs < weekAgo;
  }

  Future<List<Account>> getAccounts() async {
    final accountsJson = await _storage.read(key: _accountsKey);
    if (accountsJson == null) return [];
    final List<dynamic> decoded = jsonDecode(accountsJson);
    List<Account> accounts = decoded.map((a) => Account.fromJson(a)).toList();
    
    // Enrich accounts with data from separate keys if missing
    bool needsUpdate = false;
    for (int i = 0; i < accounts.length; i++) {
      Account acc = accounts[i];
      final username = await _storage.read(key: 'account_${acc.id}_username');
      final avatarUrl = await _storage.read(key: 'account_${acc.id}_avatar');
      final displayName = await _storage.read(key: 'account_${acc.id}_displayName');
      
      // Update if we have better data from storage
      if (username != null && (acc.username.isEmpty || acc.username == acc.id)) {
        accounts[i] = Account(
          id: acc.id,
          username: username,
          avatarUrl: avatarUrl ?? acc.avatarUrl,
          displayName: displayName ?? acc.displayName,
        );
        needsUpdate = true;
      }
    }
    
    // Save updated accounts list if we enriched any
    if (needsUpdate) {
      await _saveAccountsList(accounts);
    }
    
    return accounts;
  }

  Future<void> _saveAccountsList(List<Account> accounts) async {
    final encoded = jsonEncode(accounts.map((a) => a.toJson()).toList());
    await _storage.write(key: _accountsKey, value: encoded);
  }

  Future<String?> getCurrentAccountId() async {
    return await _storage.read(key: _currentAccountKey);
  }

  Future<void> _setCurrentAccountId(String accountId) async {
    await _storage.write(key: _currentAccountKey, value: accountId);
  }

  Future<void> addAccount(String token, String userId, String username, {String? avatarUrl, String? displayName}) async {
    final accounts = await getAccounts();
    final existing = accounts.indexWhere((a) => a.id == userId);
    final newAccount = Account(id: userId, username: username, avatarUrl: avatarUrl, displayName: displayName);

    if (existing >= 0) {
      accounts[existing] = newAccount;
    } else {
      accounts.add(newAccount);
    }

    await _saveAccountsList(accounts);
    await _storage.write(key: 'account_${userId}_token', value: token);
    await _storage.write(key: 'account_${userId}_username', value: username);
    if (avatarUrl != null) {
      await _storage.write(key: 'account_${userId}_avatar', value: avatarUrl);
    }
    if (displayName != null) {
      await _storage.write(key: 'account_${userId}_displayName', value: displayName);
    }
    await _setCurrentAccountId(userId);
    _token = token;
    _userId = userId;
  }

  Future<void> registerSavedDevice() async {
    if (_fcmToken != null && _token != null) {
      await registerDevice(_fcmToken!, 'android');
    }
  }

  Future<void> switchAccount(String accountId) async {
    final token = await _storage.read(key: 'account_${accountId}_token');
    if (token == null) return;

    _token = token;
    _userId = accountId;
    await _storage.write(key: 'token', value: token);
    await _storage.write(key: 'userId', value: accountId);
    await _setCurrentAccountId(accountId);
    disconnect();
    connectWebSocket();
    
    // Update account info if missing
    await updateAccountInfo(accountId);
    
    // Re-register FCM token for the new account
    if (_fcmToken != null) {
      await registerDevice(_fcmToken!, 'android');
    }
  }
  
  Future<void> updateAccountInfo(String accountId) async {
    try {
      final profile = await getProfile();
      if (profile != null) {
        final accounts = await getAccounts();
        final index = accounts.indexWhere((a) => a.id == accountId);
        if (index >= 0) {
          accounts[index] = Account(
            id: accountId,
            username: profile.username,
            avatarUrl: profile.avatarUrl ?? accounts[index].avatarUrl,
            displayName: profile.displayName,
          );
          await _saveAccountsList(accounts);
          // Also update separate keys
          await _storage.write(key: 'account_${accountId}_username', value: profile.username);
          await _storage.write(key: 'account_${accountId}_avatar', value: profile.avatarUrl ?? '');
          await _storage.write(key: 'account_${accountId}_displayName', value: profile.displayName);
        }
      }
    } catch (e) {
      print('Update account info error: $e');
    }
  }

  Future<bool> hasAccounts() async {
    final accounts = await getAccounts();
    return accounts.isNotEmpty;
  }

  Future<void> removeAccount(String accountId) async {
    final accounts = await getAccounts();
    accounts.removeWhere((a) => a.id == accountId);
    await _saveAccountsList(accounts);
    await _storage.delete(key: 'account_${accountId}_token');
    await _storage.delete(key: 'account_${accountId}_username');
    await _storage.delete(key: 'account_${accountId}_avatar');
    await _storage.delete(key: 'account_${accountId}_displayName');

    if (accountId == _userId) {
      _token = null;
      _userId = null;
      await _storage.delete(key: 'token');
      await _storage.delete(key: 'userId');
      if (accounts.isNotEmpty) {
        await switchAccount(accounts.first.id);
      }
    }
  }

  Future<Account?> getCurrentAccount() async {
    final currentId = await getCurrentAccountId();
    if (currentId == null) return null;
    final accounts = await getAccounts();
    return accounts.firstWhere((a) => a.id == currentId, orElse: () => accounts.first);
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  // ==================== Черновики ====================

  Future<void> saveDraft(String chatId, String text) async {
    try {
      await _client.post(
        Uri.parse('$baseUrl/drafts'),
        headers: _headers,
        body: jsonEncode({'chatId': chatId, 'text': text}),
      );
    } catch (e) {
      print('Save draft error: $e');
    }
  }

  Future<String?> getDraft(String chatId) async {
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/drafts/$chatId'),
        headers: _headers,
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['draft'] != null) {
          return data['draft']['text'] as String;
        }
      }
    } catch (e) {
      print('Get draft error: $e');
    }
    return null;
  }

  Future<void> clearDraft(String chatId) async {
    try {
      await _client.delete(
        Uri.parse('$baseUrl/drafts/$chatId'),
        headers: _headers,
      );
    } catch (e) {
      print('Clear draft error: $e');
    }
  }

  // ==================== Auth ====================

  Future<Map<String, dynamic>> registerWithEmail(String email, String password) async {
    ApiService.addLog('Register with email: $email to $baseUrl/register/email');
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/register/email'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      ApiService.addLog('Register/email response: ${res.statusCode}');
      final data = jsonDecode(res.body);
      if (res.statusCode == 201) {
        final username = data['username'] as String? ?? email.split('@').first;
        await _saveAccountFromResponse(data, username);
        ApiService.addLog('Register/email success: ${data['userId']}');
        connectWebSocket();
        return data;
      } else {
        ApiService.addLog('Register/email failed: ${data['message']}');
        return data;
      }
    } catch (e) {
      ApiService.addLog('Register/email EXCEPTION: $e');
      return {'status': 'error', 'message': '$e'};
    }
  }

  Future<Map<String, dynamic>> register(
    String username,
    String password,
  ) async {
    ApiService.addLog('Register attempt: $username to $baseUrl/register');
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      ApiService.addLog('Register response: ${res.statusCode}');
      final data = jsonDecode(res.body);
      if (res.statusCode == 201) {
        await _saveAccountFromResponse(data, username);
        ApiService.addLog('Register success: ${data['userId']}');
        connectWebSocket();
        return data;
      } else {
        ApiService.addLog('Register failed: ${data['message']}');
        return data;
      }
    } catch (e) {
      ApiService.addLog('Register EXCEPTION: $e');
      return {'status': 'error', 'message': '$e'};
    }
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    ApiService.addLog('Login attempt: $username to $baseUrl/login');
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      ApiService.addLog('Login response: ${res.statusCode}');
      final data = jsonDecode(res.body);
      if (res.statusCode == 200) {
        await _saveAccountFromResponse(data, username);
        ApiService.addLog('Login success: ${data['userId']}');
        connectWebSocket();
      } else {
        ApiService.addLog('Login failed: ${data['message']}');
      }
      return data;
    } catch (e) {
      ApiService.addLog('Login EXCEPTION: $e');
      return {'status': 'error', 'message': '$e'};
    }
  }

  Future<Map<String, dynamic>> signInWithGoogle() async {
    ApiService.addLog('Google sign-in starting...');
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        ApiService.addLog('Google sign-in cancelled by user');
        return {'status': 'error', 'message': 'Sign in cancelled'};
      }

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
      final String? idToken = await userCredential.user?.getIdToken();

      if (idToken == null) {
        ApiService.addLog('Failed to get Firebase ID token');
        return {'status': 'error', 'message': 'Failed to authenticate'};
      }

      ApiService.addLog('Sending Google token to server...');
      final res = await _client.post(
        Uri.parse('$baseUrl/auth/google'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'idToken': idToken}),
      );

      ApiService.addLog('Google auth response: ${res.statusCode}');
      final data = jsonDecode(res.body);

      if (res.statusCode == 200 || res.statusCode == 201) {
        final username = data['username'] as String? ?? 'user';
        await _saveAccountFromResponse(data, username);
        ApiService.addLog('Google sign-in success: ${data['userId']}');
        connectWebSocket();
      } else {
        ApiService.addLog('Google auth failed: ${data['message']}');
      }
      return data;
    } catch (e) {
      ApiService.addLog('Google sign-in EXCEPTION: $e');
      return {'status': 'error', 'message': '$e'};
    }
  }

  Future<Map<String, dynamic>> forgotPassword(String email) async {
    ApiService.addLog('Forgot password request for: $email');
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/auth/forgot-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );
      final data = jsonDecode(res.body);
      return data;
    } catch (e) {
      ApiService.addLog('Forgot password EXCEPTION: $e');
      return {'status': 'error', 'message': '$e'};
    }
  }

  Future<Map<String, dynamic>> resetPassword(String token, String password) async {
    ApiService.addLog('Reset password with token: ${token.substring(0, 8)}...');
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/auth/reset-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token, 'password': password}),
      );
      final data = jsonDecode(res.body);
      return data;
    } catch (e) {
      ApiService.addLog('Reset password EXCEPTION: $e');
      return {'status': 'error', 'message': '$e'};
    }
  }

  Future<void> _saveAccountFromResponse(Map<String, dynamic> data, String username) async {
    final token = data['token'] as String;
    final userId = data['userId'] as String;
    _token = token;
    _userId = userId;
    
    await _storage.write(key: 'token', value: token);
    await _storage.write(key: 'userId', value: userId);

    ThemeProvider().setCurrentUser(userId);
    WallpaperService().setCurrentUser(userId);
    await ThemeProvider().loadTheme();
    await WallpaperService().load();
    await registerSavedDevice();
    
    // Try to get profile info
    Profile? profile;
    try {
      profile = await getProfile();
    } catch (_) {}
    
    // Add to accounts list
    await addAccount(
      token,
      userId,
      profile?.username ?? username,
      avatarUrl: profile?.avatarUrl,
      displayName: profile?.displayName,
    );
  }

  // ==================== API ====================

  Future<Profile?> getProfile() async {
    try {
      final res = await _requestWithRefresh(() => _client.get(
        Uri.parse('$baseUrl/profile'),
        headers: _headers,
      ));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        print('Get profile response: ${res.body}'); // Debug log
        if (data['profile'] != null) {
          return Profile.fromJson(data['profile']);
        } else if (data['id'] != null) {
          // Handle case where API returns profile directly
          return Profile.fromJson(data);
        } else if (data['status'] == 'success' && data['profile'] != null) {
          return Profile.fromJson(data['profile']);
        }
      }
    } catch (e) {
      print('Get profile error: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>> searchMessages(String query, {int limit = 50, int? before}) async {
    try {
      final uri = Uri.parse('$baseUrl/search/messages').replace(queryParameters: {
        'q': query,
        'limit': limit.toString(),
        if (before != null) 'before': before.toString(),
      });
      final res = await _client.get(uri, headers: _headers);
      final data = jsonDecode(res.body);
      if (data['status'] == 'success') {
        final messages = (data['messages'] as List).map((m) => MessageSearchResult.fromJson(m)).toList();
        return {'messages': messages, 'hasMore': data['hasMore'] == true};
      }
    } catch (e) {
      ApiService.addLog('searchMessages error: $e');
    }
    return {'messages': <MessageSearchResult>[], 'hasMore': false};
  }

  Future<List<User>> searchUsers(String query) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/users?search=$query'),
      headers: _headers,
    );

    final data = jsonDecode(res.body);
    return (data['users'] as List).map((u) => User.fromJson(u)).toList();
  }

  Future<List<Chat>> getChats() async {
    final res = await _requestWithRefresh(() => _client.get(
      Uri.parse('$baseUrl/chats'),
      headers: _headers,
    ));

    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body);
    ApiService.addLog('[API] getChats: ${res.statusCode}');
      print('[API] getChats response: ${res.body}');
    final chats = (data['chats'] as List).map((c) => Chat.fromJson(c)).toList();
    print(
      '[API] parsed chats: ${chats.map((c) => {'id': c.id, 'name': c.name}).toList()}',
    );
    return chats;
  }

  Future<Chat?> getChat(String chatId) async {
    final chats = await getChats();
    try {
      return chats.firstWhere((c) => c.id == chatId);
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> getChatInfo(String chatId) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/chats/$chatId'),
      headers: _headers,
    );
    final data = jsonDecode(res.body);
    if (data['status'] == 'success') {
      return data['chat'];
    }
    return null;
  }

  Future<List<dynamic>> getParticipants(String chatId) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/chats/$chatId/participants'),
      headers: _headers,
    );
    final data = jsonDecode(res.body);
    if (data['status'] == 'success') {
      return data['participants'] as List<dynamic>;
    }
    return [];
  }

  Future<void> addParticipant(String chatId, String userId) async {
    await _client.post(
      Uri.parse('$baseUrl/chats/$chatId/participants'),
      headers: _headers,
      body: jsonEncode({'userId': userId}),
    );
  }

  Future<void> removeParticipant(String chatId, String userId) async {
    await _client.delete(
      Uri.parse('$baseUrl/chats/$chatId/participants/$userId'),
      headers: _headers,
    );
  }

  Future<void> setParticipantRole(String chatId, String userId, String role) async {
    await _client.put(
      Uri.parse('$baseUrl/chats/$chatId/participants/$userId/role'),
      headers: _headers,
      body: jsonEncode({'role': role}),
    );
  }

  Future<void> updateGroupName(String chatId, String name) async {
    await _client.put(
      Uri.parse('$baseUrl/chats/$chatId/name'),
      headers: _headers,
      body: jsonEncode({'name': name}),
    );
  }

  Future<void> transferOwnership(String chatId, String userId) async {
    await _client.put(
      Uri.parse('$baseUrl/chats/$chatId/transfer'),
      headers: _headers,
      body: jsonEncode({'userId': userId}),
    );
  }

  Future<String?> leaveGroup(String chatId) async {
    try {
      final res = await _client.delete(
        Uri.parse('$baseUrl/chats/$chatId/leave'),
        headers: _headers,
      );
      if (res.statusCode == 200) return null;
      final data = jsonDecode(res.body);
      return data['message'] as String? ?? 'Failed to leave group';
    } catch (e) {
      ApiService.addLog('Leave group error: $e');
      return 'Failed to leave group';
    }
  }

  Future<String?> deleteGroup(String chatId) async {
    try {
      final res = await _client.delete(
        Uri.parse('$baseUrl/chats/$chatId'),
        headers: _headers,
      );
      if (res.statusCode == 200) return null;
      final data = jsonDecode(res.body);
      return data['message'] as String? ?? 'Failed to delete group';
    } catch (e) {
      ApiService.addLog('Delete group error: $e');
      return 'Failed to delete group';
    }
  }

  Future<String?> createChat(
    String type,
    List<String> participants, {
    String? name,
  }) async {
    final res = await _client.post(
      Uri.parse('$baseUrl/chats'),
      headers: _headers,
      body: jsonEncode({
        'type': type,
        'participants': participants,
        if (name != null) 'name': name,
      }),
    );

    final data = jsonDecode(res.body);
    return data['chatId'];
  }

  Future<int> getMessageCount(String chatId) async {
    try {
      final res = await _requestWithRefresh(() => _client.get(
        Uri.parse('$baseUrl/chats/$chatId/messages/count'),
        headers: _headers,
      ));
      final data = jsonDecode(res.body);
      return data['totalCount'] ?? 0;
    } catch (e) {
      return 0;
    }
  }

  Future<List<Message>> getMessages(String chatId, {int limit = 50, int? before}) async {
    final uri = Uri.parse('$baseUrl/chats/$chatId/messages').replace(queryParameters: {
      'limit': limit.toString(),
      if (before != null) 'before': before.toString(),
    });
    final res = await _client.get(uri, headers: _headers);

    final data = jsonDecode(res.body);
    return (data['messages'] as List).map((m) => Message.fromJson(m)).toList();
  }

  /// Public GET wrapper for external use (e.g. CryptoService)
  Future<http.Response> httpGet(String path) async {
    return _requestWithRefresh(() => _client.get(
      Uri.parse('$baseUrl$path'),
      headers: _headers,
    ));
  }

  void sendKeyExchange(String publicKey) {
    if (_wsChannel == null) return;
    _wsChannel!.sink.add(jsonEncode({
      'type': 'keyExchange',
      'publicKey': publicKey,
    }));
  }

  // ==================== WebSocket ====================

  void connectWebSocket() {
    ApiService.addLog('WS: Connecting to $wsUrl');
    if (_token == null) {
      ApiService.addLog('WS: No token, skipping connection');
      return;
    }
    if (_isConnecting) {
      ApiService.addLog('WS: Already connecting...');
      return;
    }
    if (_wsChannel != null) {
      ApiService.addLog('WS: Already connected');
      return;
    }
    if (_isReconnecting && _reconnectAttempts > _maxReconnectAttempts) {
      ApiService.addLog('WS: Max reconnect attempts reached, continuing with 15s interval');
      print('WS: Max reconnect attempts reached, continuing with 15s interval');
    }

    _isConnecting = true;
    try {
      ApiService.addLog('WS: Creating connection...');
      _wsChannel = WebSocketChannel.connect(Uri.parse(wsUrl));

      _wsStreamSubscription = _wsChannel!.stream.listen(
        (data) {
          final msg = jsonDecode(data);

          if (msg['type'] == 'connected') {
            CryptoService.uploadPublicKey(this);
          }

          if (msg['type'] == 'online') {
            final userId = msg['userId'] as String?;
            final status = msg['status'] as String?;
            if (userId != null && status != null) {
              if (status == 'online') {
                _onlineUsers.add(userId);
              } else {
                _onlineUsers.remove(userId);
              }
              onOnlineUsersChanged?.call();
            }
          }

          if (msg['type'] == 'online_users') {
            final users = msg['users'] as List<dynamic>?;
            if (users != null) {
              _onlineUsers.clear();
              _onlineUsers.addAll(users.cast<String>());
              onOnlineUsersChanged?.call();
            }
          }

          if (msg['type'] == 'incoming_call') {
            ApiService.addLog('Incoming call: ${msg['callId']} from ${msg['callerId']}');
            onIncomingCall?.call(Map<String, dynamic>.from(msg));
          }

          if (msg['type'] == 'call_accepted') {
            final callId = msg['callId'] as String?;
            if (callId != null) {
              ApiService.addLog('Call accepted: $callId');
              onCallAccepted?.call(callId);
            }
          }

          if (msg['type'] == 'call_rejected') {
            final callId = msg['callId'] as String?;
            if (callId != null) {
              ApiService.addLog('Call rejected: $callId');
              onCallRejected?.call(callId);
            }
          }

          if (msg['type'] == 'call_ended') {
            final callId = msg['callId'] as String?;
            if (callId != null) {
              ApiService.addLog('Call ended: $callId');
              onCallEnded?.call(callId);
            }
          }

          if (msg['type'] == 'call_signal') {
            ApiService.addLog('Call signal received: ${msg['signalType']}');
            onCallSignal?.call(Map<String, dynamic>.from(msg));
          }

          for (final listener in List.from(_messageListeners)) {
            listener(msg);
          }
        },
        onError: (err) {
          ApiService.addLog('WS Error: $err');
      print('WS Error: $err');
          _wsStreamSubscription = null;
          _isConnecting = false;
          _handleDisconnect();
        },
        onDone: () {
          ApiService.addLog('WS Closed');
      print('WS Closed');
          _wsStreamSubscription = null;
          _isConnecting = false;
          _handleDisconnect();
        },
      );

      // Guard: if onDone/onError fired synchronously during listen(), channel is dead
      if (_wsChannel == null) {
        _isConnecting = false;
        return;
      }

      _wsChannel!.sink.add(jsonEncode({'type': 'auth', 'token': _token}));
      _isConnecting = false;
      updateLastActive();

      if (_isReconnecting) {
        onReconnected?.call();
        Future.delayed(const Duration(seconds: 5), () {
          if (!_isReconnecting) return;
          _isReconnecting = false;
          _reconnectAttempts = 0;
        });
      }
    } catch (e) {
      ApiService.addLog('WS Connect Error: $e');
      print('WS Connect Error: $e');
      _isConnecting = false;
      _wsStreamSubscription = null;
      _wsChannel = null;
      if (_isReconnecting) {
        _isReconnecting = false;
      }
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    _isConnecting = false;
    if (_isIntentionalDisconnect) {
      _isIntentionalDisconnect = false;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      return;
    }

    // Close and discard dead channel so connectWebSocket can create a new one
    _wsStreamSubscription?.cancel();
    _wsStreamSubscription = null;
    try { _wsChannel?.sink.close(); } catch (_) {}
    _wsChannel = null;

    _isReconnecting = true;
    _reconnectAttempts++;

    onDisconnected?.call();
    onReconnecting?.call();

    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, then every 15s
    final delay = _reconnectAttempts <= _maxReconnectAttempts
        ? Duration(seconds: _reconnectAttempts)
        : const Duration(seconds: 15);
    print(
      'WS: Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts)',
    );

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_token != null) {
        connectWebSocket();
      }
    });
  }

  Future<void> sendMessageViaWs(String chatId, String text, {String? replyTo, String? tempId, String? keyType}) async {
    if (_wsChannel?.sink != null) {
      try {
        _wsChannel!.sink.add(
          jsonEncode({
            'type': 'send',
            'chatId': chatId,
            'text': text,
            if (replyTo != null) 'replyTo': replyTo,
            if (tempId != null) 'tempId': tempId,
            if (keyType != null) 'keyType': keyType,
          }),
        );
        ApiService.addLog('sendMessageViaWs: sent tempId=$tempId chatId=$chatId keyType=$keyType');
        return;
      } catch (e) {
        ApiService.addLog('sendMessageViaWs: WS send error for chatId=$chatId tempId=$tempId: $e');
      }
    } else {
      ApiService.addLog('sendMessageViaWs: WS null for chatId=$chatId tempId=$tempId, falling back to REST');
    }
    await sendMessageViaRest(chatId, text, replyTo: replyTo, tempId: tempId, keyType: keyType);
  }

  Future<void> sendMessageViaRest(String chatId, String text, {String? replyTo, String? tempId, String? keyType}) async {
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/chats/$chatId/messages'),
        headers: _headers,
        body: jsonEncode({'text': text, if (replyTo != null) 'replyTo': replyTo, if (keyType != null) 'key_type': keyType}),
      );
      if (res.statusCode == 200) {
        // Don't call onMessage here - server will broadcast it back via WebSocket
      } else {
        ApiService.addLog('sendMessageViaRest: HTTP ${res.statusCode} for chatId=$chatId tempId=$tempId: ${res.body}');
      }
    } catch (e) {
      ApiService.addLog('sendMessageViaRest: exception for chatId=$chatId tempId=$tempId: $e');
    }
  }

  void sendMessage(String chatId, String text, {String? replyTo, String? tempId, String? keyType}) {
    sendMessageViaWs(chatId, text, replyTo: replyTo, tempId: tempId, keyType: keyType);
  }

  void sendTyping(String chatId, bool isTyping) {
    _wsChannel?.sink.add(
      jsonEncode({'type': 'typing', 'chatId': chatId, 'isTyping': isTyping}),
    );
  }

  void sendPing() {
    _wsChannel?.sink.add(jsonEncode({'type': 'ping'}));
  }

  void sendRead(String messageId) {
    _wsChannel?.sink.add(jsonEncode({'type': 'read', 'messageId': messageId}));
  }

  void sendReaction(String messageId, String emoji, String action) {
    _wsChannel?.sink.add(jsonEncode({
      'type': 'react',
      'messageId': messageId,
      'emoji': emoji,
      'action': action,
    }));
  }

  Future<Map<String, List<Map<String, dynamic>>>> getChatReactions(String chatId) async {
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/chats/$chatId/reactions'),
        headers: _headers,
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 'success' && data['reactions'] != null) {
          final raw = data['reactions'] as Map<String, dynamic>;
          return raw.map((k, v) => MapEntry(k, List<Map<String, dynamic>>.from(v)));
        }
      }
    } catch (_) {}
    return {};
  }

  // ==================== Files ====================

  Future<Map<String, String>?> uploadFile(File file) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/upload'));

    request.headers.addAll({'Authorization': 'Bearer $_token'});

    final mimeType = _getMimeType(file.path);
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        contentType: MediaType.parse(mimeType),
      ),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    final data = jsonDecode(response.body);

    if (response.statusCode == 200 || response.statusCode == 201) {
      return {'fileId': data['fileId'], 'mimeType': mimeType};
    }
    return null;
  }

  Future<Map<String, String>?> uploadFileChunked(File file, {int chunkSize = 2 * 1024 * 1024, int concurrency = 3, void Function(double progress)? onProgress}) async {
    final fileName = file.path.split(Platform.pathSeparator).last;
    final mimeType = _getMimeType(file.path);
    final totalSize = await file.length();
    int completedBytes = 0;

    void reportProgress() {
      if (onProgress != null && totalSize > 0) {
        onProgress(completedBytes / totalSize);
      }
    }

    // Init session
    final initResp = await http.post(
      Uri.parse('$baseUrl/upload/init'),
      headers: {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'},
      body: jsonEncode({'name': fileName, 'mimeType': mimeType}),
    );
    if (initResp.statusCode != 200) {
      logs.add('[uploadChunked] init failed: ${initResp.statusCode} ${initResp.body}');
      return null;
    }
    final uploadId = jsonDecode(initResp.body)['uploadId'] as String;

    // Upload chunks in parallel with retry
    final raf = await file.open(mode: FileMode.read);
    final errors = <String>[];
    int chunkIndex = 0;
    final pending = <Future<void>>[];

    try {
      while (true) {
        final data = await raf.read(chunkSize);
        if (data.isEmpty) break;

        final idx = chunkIndex;
        final chunkLen = data.length;
        final future = _uploadChunkWithRetry(uploadId, idx, data, errors).then((_) {
          completedBytes += chunkLen;
          reportProgress();
        });
        pending.add(future);
        chunkIndex++;

        if (pending.length >= concurrency) {
          await Future.wait(pending);
          pending.clear();
          if (errors.isNotEmpty) break;
        }
      }
      if (pending.isNotEmpty) await Future.wait(pending);
    } finally {
      await raf.close();
    }

    if (errors.isNotEmpty) {
      for (final e in errors) logs.add('[uploadChunked] $e');
      return null;
    }

    // Complete
    final completeResp = await http.post(
      Uri.parse('$baseUrl/upload/$uploadId/complete'),
      headers: {'Authorization': 'Bearer $_token'},
    );
    if (completeResp.statusCode != 200) {
      logs.add('[uploadChunked] complete failed: ${completeResp.statusCode} ${completeResp.body}');
      return null;
    }
    final completeData = jsonDecode(completeResp.body);
    return {'fileId': completeData['fileId'], 'mimeType': completeData['mimeType']};
  }

  Future<void> _uploadChunkWithRetry(String uploadId, int chunkIndex, List<int> data, List<String> errors) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        if (attempt > 0) await Future.delayed(Duration(seconds: attempt));
        final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/upload/$uploadId/chunk/$chunkIndex'));
        req.headers['Authorization'] = 'Bearer $_token';
        req.files.add(http.MultipartFile.fromBytes('file', data, filename: '$chunkIndex'));
        final resp = await req.send().timeout(const Duration(seconds: 30));
        if (resp.statusCode == 200) return;
        errors.add('chunk $chunkIndex attempt $attempt: HTTP ${resp.statusCode}');
      } catch (e) {
        errors.add('chunk $chunkIndex attempt $attempt: $e');
      }
    }
  }

  String _getMimeType(String path) {
    final ext = path.split('.').last.toLowerCase();
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
      case 'pdf':
        return 'application/pdf';
      case 'doc':
      case 'docx':
        return 'application/msword';
      case 'txt':
        return 'text/plain';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
        return 'audio/ogg';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'mp4':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> sendFileViaWs(String chatId, String fileId, {String? replyTo, String? mimeType}) async {
    if (_wsChannel?.sink != null) {
      try {
        _wsChannel!.sink.add(
          jsonEncode({
            'type': 'sendFile',
            'chatId': chatId,
            'fileId': fileId,
            if (replyTo != null) 'replyTo': replyTo,
            if (mimeType != null) 'fileMimeType': mimeType,
          }),
        );
        ApiService.addLog('sendFileViaWs: sent fileId=$fileId chatId=$chatId');
        return;
      } catch (e) {
        ApiService.addLog('sendFileViaWs: WS send error for chatId=$chatId fileId=$fileId: $e');
      }
    } else {
      ApiService.addLog('sendFileViaWs: WS null for chatId=$chatId fileId=$fileId, falling back to REST');
    }
    await sendFileViaRest(chatId, fileId, replyTo: replyTo, mimeType: mimeType);
  }

  Future<void> sendFileViaRest(String chatId, String fileId, {String? replyTo, String? mimeType}) async {
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/chats/$chatId/messages'),
        headers: _headers,
        body: jsonEncode({
          'text': '[File]',
          'fileId': fileId,
          if (replyTo != null) 'replyTo': replyTo,
        }),
      );
      if (res.statusCode == 200) {
        // Don't call onMessage here - server will broadcast it back via WebSocket
      } else {
        ApiService.addLog('sendFileViaRest: HTTP ${res.statusCode} for chatId=$chatId fileId=$fileId: ${res.body}');
      }
    } catch (e) {
      ApiService.addLog('sendFileViaRest: exception for chatId=$chatId fileId=$fileId: $e');
    }
  }

  void sendFile(
    String chatId,
    String fileId, {
    String? replyTo,
    String? mimeType,
  }) {
    sendFileViaWs(chatId, fileId, replyTo: replyTo, mimeType: mimeType);
  }

  void sendSticker(String chatId, String stickerId, {String? tempId}) {
    _wsChannel?.sink.add(
      jsonEncode({
        'type': 'sendSticker',
        'chatId': chatId,
        'stickerId': stickerId,
        if (tempId != null) 'tempId': tempId,
      }),
    );
  }

  // ==================== Messages ====================

  Future<bool> editMessage(String messageId, String newText) async {
    try {
      final res = await _client.put(
        Uri.parse('$baseUrl/messages/$messageId'),
        headers: _headers,
        body: jsonEncode({'text': newText}),
      );
      return res.statusCode == 200;
    } catch (e) {
      print('Edit message error: $e');
      return false;
    }
  }

  Future<bool> deleteMessage(String messageId) async {
    try {
      final res = await _client.delete(
        Uri.parse('$baseUrl/messages/$messageId'),
        headers: _headers,
      );
      return res.statusCode == 200;
    } catch (e) {
      print('Delete message error: $e');
      return false;
    }
  }

  Future<Map<String, int>> getUnreadCounts() async {
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/chats/unread'),
        headers: _headers,
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return Map<String, int>.from(data['unread'] ?? {});
      }
    } catch (e) {
      print('Get unread counts error: $e');
    }
    return {};
  }

  // ==================== Profile ====================

  Future<Profile?> updateProfile({String? displayName, String? bio, String? username, String? email, String? tags}) async {
    try {
      final res = await _requestWithRefresh(() => _client.put(
        Uri.parse('$baseUrl/profile'),
        headers: _headers,
        body: jsonEncode({
          if (displayName != null) 'displayName': displayName,
          if (bio != null) 'bio': bio,
          if (username != null) 'username': username,
          if (email != null) 'email': email,
          if (tags != null) 'tags': tags,
        }),
      ));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['profile'] != null) {
          return Profile.fromJson(data['profile']);
        }
      } else {
        final data = jsonDecode(res.body);
        if (data['message'] != null) {
          throw Exception(data['message']);
        }
      }
    } catch (e) {
      print('Update profile error: $e');
      rethrow;
    }
    return null;
  }

  Future<String?> uploadAvatar(File file) async {
    try {
      final response = await _requestWithRefresh(() async {
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('$baseUrl/profile/avatar'),
        );
        request.headers.addAll({'Authorization': 'Bearer $_token'});
        request.files.add(await http.MultipartFile.fromPath('avatar', file.path));
        final streamed = await request.send();
        return http.Response.fromStream(streamed);
      });
      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return '$baseUrl${data['avatarUrl']}';
      }
    } catch (e) {
      print('Upload avatar error: $e');
    }
    return null;
  }

  Future<bool> deleteAvatar() async {
    try {
      final res = await _requestWithRefresh(() => _client.delete(
        Uri.parse('$baseUrl/profile/avatar'),
        headers: _headers,
      ));
      return res.statusCode == 200;
    } catch (e) {
      print('Delete avatar error: $e');
      return false;
    }
  }

  Future<String?> uploadGroupAvatar(String chatId, File file) async {
    try {
      final response = await _requestWithRefresh(() async {
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('$baseUrl/chats/$chatId/avatar'),
        );
        request.headers.addAll({'Authorization': 'Bearer $_token'});
        request.files.add(await http.MultipartFile.fromPath('avatar', file.path));
        final streamed = await request.send();
        return http.Response.fromStream(streamed);
      });
      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        return '$baseUrl${data['avatarUrl']}';
      }
    } catch (e) {
      print('Upload group avatar error: $e');
    }
    return null;
  }

  Future<bool> deleteGroupAvatar(String chatId) async {
    try {
      final res = await _requestWithRefresh(() => _client.delete(
        Uri.parse('$baseUrl/chats/$chatId/avatar'),
        headers: _headers,
      ));
      return res.statusCode == 200;
    } catch (e) {
      print('Delete group avatar error: $e');
      return false;
    }
  }

  Future<List<StickerPack>> getStickerPacks() async {
    print('[API] getStickerPacks called');
    try {
      final res = await _requestWithRefresh(() => _client.get(
        Uri.parse('$baseUrl/sticker-packs'),
        headers: _headers,
      ));
      print('[API] getStickerPacks status: ${res.statusCode}');
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        print('[API] getStickerPacks keys: ${data.keys} packs_len=${(data['packs'] as List?)?.length}');
        if (data['status'] == 'success' && data['packs'] != null) {
          return (data['packs'] as List).map((p) => StickerPack.fromJson(p)).toList();
        }
      }
    } catch (e) {
      print('[API] Get sticker packs error: $e');
    }
    return [];
  }

  Future<StickerPack?> getStickerPack(String id) async {
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/sticker-packs/$id'),
        headers: _headers,
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final pack = StickerPack.fromJson(data['pack']);
        final stickers = (data['stickers'] as List).map((s) => Sticker.fromJson(s)).toList();
        return StickerPack(
          id: pack.id,
          name: pack.name,
          authorId: pack.authorId,
          createdAt: pack.createdAt,
          stickers: stickers,
        );
      }
    } catch (e) {
      print('Get sticker pack error: $e');
    }
    return null;
  }

  Future<StickerPack?> createStickerPack(String name) async {
    try {
      final res = await _requestWithRefresh(() => _client.post(
        Uri.parse('$baseUrl/sticker-packs'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'name': name}),
      ));
      if (res.statusCode == 201) {
        final data = jsonDecode(res.body);
        return StickerPack.fromJson(data['pack']);
      }
    } catch (e) {
      print('Create sticker pack error: $e');
    }
    return null;
  }

  Future<bool> deleteStickerPack(String id) async {
    try {
      final res = await _requestWithRefresh(() => _client.delete(
        Uri.parse('$baseUrl/sticker-packs/$id'),
        headers: _headers,
      ));
      return res.statusCode == 200;
    } catch (e) {
      print('Delete sticker pack error: $e');
      return false;
    }
  }

  Future<Sticker?> addSticker(String packId, String imagePath, String emoji) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/sticker-packs/$packId/stickers'),
      );
      request.headers.addAll({'Authorization': 'Bearer $_token'});
      request.fields['emoji'] = emoji;
      request.files.add(await http.MultipartFile.fromPath('image', imagePath));
      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return Sticker.fromJson(data['sticker']);
      }
    } catch (e) {
      print('Add sticker error: $e');
    }
    return null;
  }

  Future<bool> removeSticker(String packId, String stickerId) async {
    try {
      final res = await _requestWithRefresh(() => _client.delete(
        Uri.parse('$baseUrl/sticker-packs/$packId/stickers/$stickerId'),
        headers: _headers,
      ));
      return res.statusCode == 200;
    } catch (e) {
      print('Remove sticker error: $e');
      return false;
    }
  }

  Future<StickerPack?> copyStickerPack(String packId) async {
    try {
      final res = await _requestWithRefresh(() => _client.post(
        Uri.parse('$baseUrl/sticker-packs/$packId/copy'),
        headers: _headers,
      ));
      if (res.statusCode == 201) {
        final data = jsonDecode(res.body);
        return StickerPack.fromJson(data['pack']);
      }
    } catch (e) {
      print('Copy sticker pack error: $e');
    }
    return null;
  }

  Future<Profile?> getUserProfile(String userId) async {
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/users/$userId/profile'),
        headers: _headers,
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['profile'] != null) {
          return Profile.fromJson(data['profile']);
        }
      }
    } catch (e) {
      print('Get user profile error: $e');
    }
    return null;
  }

  Future<String> getSearchTags() async {
    try {
      final res = await _requestWithRefresh(() => _client.get(
        Uri.parse('$baseUrl/profile/tags'),
        headers: _headers,
      ));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return data['tags'] as String? ?? '';
      }
    } catch (e) {
      print('Get search tags error: $e');
    }
    return '';
  }

  Future<bool> updateSearchTags(String tags) async {
    try {
      final res = await _requestWithRefresh(() => _client.put(
        Uri.parse('$baseUrl/profile/tags'),
        headers: _headers,
        body: jsonEncode({'tags': tags}),
      ));
      return res.statusCode == 200;
    } catch (e) {
      print('Update search tags error: $e');
      return false;
    }
  }

  void disconnect() {
    _isIntentionalDisconnect = true;
    _isReconnecting = false;
    _reconnectAttempts = 0;
    _isConnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _wsStreamSubscription?.cancel();
    _wsStreamSubscription = null;
    try { _wsChannel?.sink.close(); } catch (_) {}
    _wsChannel = null;
  }

  void reconnectWebSocket() {
    _isConnecting = false;
    _wsStreamSubscription?.cancel();
    _wsStreamSubscription = null;
    try { _wsChannel?.sink.close(); } catch (_) {}
    _wsChannel = null;
    _isReconnecting = true;
    _reconnectAttempts = 0;
    connectWebSocket();
  }

  Future<bool> registerDevice(
    String token,
    String platform, {
    String? deviceName,
  }) async {
    if (_token == null) return false;

    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/devices'),
        headers: _headers,
        body: jsonEncode({
          'token': token,
          'platform': platform,
          'deviceName': deviceName,
        }),
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (kDebugMode) {
          print('Device registered: ${data['id']}');
        }
        return true;
      }
    } catch (e) {
      if (kDebugMode) {
        print('Register device error: $e');
      }
    }
    return false;
  }

  Future<List<Map<String, dynamic>>> getDevices() async {
    if (_token == null) return [];

    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/devices'),
        headers: _headers,
      );

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return List<Map<String, dynamic>>.from(data['devices'] ?? []);
      }
    } catch (e) {
      if (kDebugMode) {
        print('Get devices error: $e');
      }
    }
    return [];
  }

  Future<bool> unregisterDevice(String deviceId) async {
    if (_token == null) return false;

    try {
      final res = await _client.delete(
        Uri.parse('$baseUrl/devices/$deviceId'),
        headers: _headers,
      );

      return res.statusCode == 200;
    } catch (e) {
      if (kDebugMode) {
        print('Unregister device error: $e');
      }
    }
    return false;
  }

  Future<bool> unregisterAllDevices() async {
    if (_token == null) return false;

    try {
      final res = await _client.delete(
        Uri.parse('$baseUrl/devices'),
        headers: _headers,
      );

      return res.statusCode == 200;
    } catch (e) {
      if (kDebugMode) {
        print('Unregister all devices error: $e');
      }
    }
    return false;
  }

  // ==================== Calls ====================

  Future<Map<String, dynamic>?> createCall(String chatId, {String callType = 'video'}) async {
    try {
      ApiService.addLog('Creating call for chat: $chatId');
      final res = await _client.post(
        Uri.parse('$baseUrl/chats/$chatId/call'),
        headers: _headers,
        body: jsonEncode({'callType': callType}),
      );
      ApiService.addLog('Create call response: ${res.statusCode}');
      if (res.statusCode == 200) {
        return jsonDecode(res.body);
      }
    } catch (e) {
      ApiService.addLog('Create call error: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> getCall(String callId) async {
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/calls/$callId'),
        headers: _headers,
      );
      if (res.statusCode == 200) {
        return jsonDecode(res.body);
      }
    } catch (e) {
      ApiService.addLog('Get call error: $e');
    }
    return null;
  }

  Future<bool> acceptCall(String callId) async {
    try {
      ApiService.addLog('Accepting call: $callId');
      final res = await _client.post(
        Uri.parse('$baseUrl/calls/$callId/accept'),
        headers: _headers,
      );
      ApiService.addLog('Accept call response: ${res.statusCode}');
      return res.statusCode == 200;
    } catch (e) {
      ApiService.addLog('Accept call error: $e');
    }
    return false;
  }

  Future<bool> rejectCall(String callId) async {
    try {
      ApiService.addLog('Rejecting call: $callId');
      final res = await _client.post(
        Uri.parse('$baseUrl/calls/$callId/reject'),
        headers: _headers,
      );
      return res.statusCode == 200;
    } catch (e) {
      ApiService.addLog('Reject call error: $e');
    }
    return false;
  }

  Future<bool> endCall(String callId) async {
    try {
      ApiService.addLog('Ending call: $callId');
      final res = await _client.delete(
        Uri.parse('$baseUrl/calls/$callId'),
        headers: _headers,
      );
      return res.statusCode == 200;
    } catch (e) {
      ApiService.addLog('End call error: $e');
    }
    return false;
  }

  // Callbacks for WebSocket call events
  Function(Map<String, dynamic>)? onIncomingCall;
  Function(String callId)? onCallAccepted;
  Function(String callId)? onCallRejected;
  Function(String callId)? onCallEnded;

  // WebRTC signaling
  void sendCallSignal(String callId, Map<String, dynamic> signal) {
    if (_wsChannel != null) {
      _wsChannel!.sink.add(jsonEncode({
        'type': 'call_signal',
        'callId': callId,
        ...signal,
      }));
    }
  }

  Function(Map<String, dynamic>)? onCallSignal;
}

typedef VoidCallback = void Function();
