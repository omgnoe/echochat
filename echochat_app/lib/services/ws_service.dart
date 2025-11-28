import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'package:cryptography/cryptography.dart';

import 'identity_service.dart';
import 'crypto_service.dart';

class EchoChatWebSocketService {
  final String url;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Identity? _identity;
  SimpleKeyPair? _identityKeyPair;
  late final CryptoService cryptoService;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _connectionCheckTimer;

  // Anonyme Session-Tokens (pro Session ein zufälliger Token)
  final Map<String, String> _sessionTokens = {};

  // Participant-Info (Token -> Nickname/PublicKey)
  final Map<String, Map<String, ParticipantInfo>> _sessionParticipants = {};

  // Callbacks
  void Function(Map<String, dynamic>)? onMessage;
  void Function(String token, String nickname, bool isOnline)?
      onParticipantJoined;
  void Function(String token)? onParticipantLeft;
  void Function(String senderName, String sessionId, String? passcodeHash)?
      onPingReceived;
  void Function()? onCryptoReady;
  void Function(String sessionId)? onSessionExpired;
  void Function()? onConnected;
  void Function()? onDisconnected;
  void Function(String error)? onConnectionError;

  // Session Callbacks
  void Function(String sessionId)? onSessionCreated;
  void Function(String sessionId)? onSessionJoined;
  void Function(String sessionId, String reason)? onSessionJoinFailed;
  void Function(String sessionId)? onSessionNotFound;
  void Function(String sessionId)? onSessionInvalidPasscode;

  bool _connected = false;
  bool get isConnected => _connected;

  bool _isConnecting = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;

  EchoChatWebSocketService({
    this.url = 'wss://your-server.com', // Change this to your server
  }) {
    cryptoService = CryptoService();
  }

  String? get currentUserId => _identity?.oderId;

  /// Generiert einen anonymen Token für eine Session
  String _getOrCreateSessionToken(String sessionId) {
    if (!_sessionTokens.containsKey(sessionId)) {
      final random = Random.secure();
      final bytes = List.generate(16, (_) => random.nextInt(256));
      _sessionTokens[sessionId] = base64Encode(bytes);
    }
    return _sessionTokens[sessionId]!;
  }

  /// Gibt den eigenen Token für eine Session zurück
  String? getMyToken(String sessionId) => _sessionTokens[sessionId];

  /// Hasht einen Passcode
  static String hashPasscode(String passcode) {
    if (passcode.isEmpty) return '';
    var hash = 0;
    final input = passcode.toUpperCase();
    for (var i = 0; i < input.length; i++) {
      hash = ((hash << 5) - hash) + input.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).toUpperCase().padLeft(16, '0');
  }

  /// Setzt die Identity und initialisiert das Crypto KeyPair
  Future<void> setIdentity(Identity identity) async {
    _identity = identity;

    // KeyPair aus Identity laden
    final identityService = IdentityService();
    _identityKeyPair = await identityService.getKeyPair();

    // Crypto Service mit dem Identity KeyPair initialisieren
    cryptoService.setKeyPair(_identityKeyPair!);

    debugPrint('[WS] Identity set: ${identity.nickname} (${identity.oderId})');
  }

  Future<void> connect() async {
    if (_channel != null || _isConnecting) {
      debugPrint('[WS] Already connected or connecting');
      return;
    }

    _isConnecting = true;
    _connected = false;

    try {
      debugPrint('[WS] Connecting to: $url');

      if (Platform.isAndroid || Platform.isIOS) {
        final socket = await WebSocket.connect(
          url,
          headers: {
            'Origin': 'echochat-app',
            'User-Agent': 'EchoChat-Flutter/${Platform.operatingSystem}',
          },
        ).timeout(const Duration(seconds: 15));

        _channel = IOWebSocketChannel(socket);
      } else {
        _channel = WebSocketChannel.connect(Uri.parse(url));
        await _channel!.ready.timeout(const Duration(seconds: 15));
      }

      _isConnecting = false;
      _reconnectAttempts = 0;

      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (e) {
          debugPrint('[WS] Stream Error: $e');
          _setDisconnected();
          onConnectionError?.call('Connection error: $e');
        },
        onDone: () {
          debugPrint('[WS] Connection closed');
          _setDisconnected();
        },
        cancelOnError: false,
      );

      _send({'type': 'ping'});

      _connectionCheckTimer?.cancel();
      _connectionCheckTimer = Timer(const Duration(seconds: 5), () {
        if (!_connected) {
          _setDisconnected();
          onConnectionError?.call('Server not responding');
        }
      });
    } on SocketException catch (e) {
      debugPrint('[WS] SocketException: $e');
      _resetConnectionState();
      onConnectionError?.call('Server unreachable');
      _scheduleReconnect();
    } on TimeoutException {
      debugPrint('[WS] TimeoutException');
      _resetConnectionState();
      onConnectionError?.call('Connection timeout');
      _scheduleReconnect();
    } catch (e) {
      debugPrint('[WS] Error: $e');
      _resetConnectionState();
      onConnectionError?.call('Connection failed');
      _scheduleReconnect();
    }
  }

  void _resetConnectionState() {
    _isConnecting = false;
    _connected = false;
    _connectionCheckTimer?.cancel();
    _channel = null;
    _subscription = null;
  }

  void _setDisconnected() {
    final wasConnected = _connected;
    _connected = false;
    _isConnecting = false;
    _stopPingTimer();
    _connectionCheckTimer?.cancel();

    if (wasConnected) {
      onDisconnected?.call();
    }
    _scheduleReconnect();
  }

  void _setConnected() {
    if (!_connected) {
      _connected = true;
      _connectionCheckTimer?.cancel();
      debugPrint('[WS] ✅ Connected (Zero-Knowledge Mode)');

      // Beim Server registrieren für Ping-Empfang
      _registerForPings();

      onConnected?.call();
      _startPingTimer();
    }
  }

  void _registerForPings() {
    if (_identity == null) return;

    _send({
      'type': 'register',
      'oderId': _identity!.oderId,
    });
    debugPrint(
        '[WS] 📝 Registriert für Pings: ${_identity!.oderId.substring(0, 12)}...');
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('[WS] Max reconnect attempts reached');
      onConnectionError?.call('Max attempts reached. Please restart.');
      return;
    }

    _reconnectTimer?.cancel();
    final delaySeconds = (2 * (1 << _reconnectAttempts)).clamp(2, 30);

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _reconnectAttempts++;
      connect();
    });
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_connected) serverPing();
    });
  }

  void _stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _handleMessage(dynamic event) {
    try {
      final data = jsonDecode(event as String) as Map<String, dynamic>;
      final type = data['type'] as String?;

      debugPrint('[WS] Received: $type');

      if (!_connected && type == 'pong') {
        _setConnected();
        return;
      }

      switch (type) {
        case 'pong':
          break;

        case 'session_created':
          final sessionId = data['sessionId'] as String? ?? '';
          debugPrint('[WS] ✅ Session created: $sessionId');
          onSessionCreated?.call(sessionId);
          break;

        case 'session_joined':
          _handleSessionJoined(data);
          break;

        case 'session_not_found':
          final sessionId = data['sessionId'] as String? ?? '';
          debugPrint('[WS] ❌ Session not found: $sessionId');
          onSessionNotFound?.call(sessionId);
          break;

        case 'session_invalid_passcode':
          final sessionId = data['sessionId'] as String? ?? '';
          debugPrint('[WS] ❌ Invalid passcode for: $sessionId');
          onSessionInvalidPasscode?.call(sessionId);
          break;

        case 'session_participants':
          _handleSessionParticipants(data);
          break;

        case 'participant_joined':
          _handleParticipantJoined(data);
          break;

        case 'participant_left':
          _handleParticipantLeft(data);
          break;

        case 'session_message':
          _handleSessionMessage(data);
          break;

        case 'session_expired':
          final sessionId = data['sessionId'] as String? ?? '';
          debugPrint('[WS] Session expired: $sessionId');
          onSessionExpired?.call(sessionId);
          break;

        case 'ping_notification':
          _handlePingNotification(data);
          break;

        case 'session_invite':
          _handleSessionInvite(data);
          break;

        case 'ping_failed':
        case 'invite_failed':
          final reason = data['reason'] as String? ?? 'unknown';
          debugPrint('[WS] Ping/Invite failed: $reason');
          break;

        case 'ping_sent':
          debugPrint('[WS] ✅ Ping sent successfully');
          break;

        case 'registered':
          debugPrint('[WS] ✅ Registered for pings');
          break;

        case 'error':
          final errorMsg = data['message'] as String? ?? 'Unknown error';
          debugPrint('[WS] Server error: $errorMsg');
          break;
      }
    } catch (e) {
      debugPrint('[WS] Error handling message: $e');
    }
  }

  void _handlePingNotification(Map<String, dynamic> data) {
    final senderName = data['senderName'] as String? ?? 'Someone';
    final sessionId = data['sessionId'] as String? ?? '';
    final passcodeHash = data['passcodeHash'] as String?;

    debugPrint('[WS] 📩 Ping received from $senderName for session $sessionId');
    onPingReceived?.call(senderName, sessionId, passcodeHash);
  }

  void _handleSessionInvite(Map<String, dynamic> data) {
    final senderName = data['senderNickname'] as String? ?? 'Someone';
    final sessionId = data['sessionId'] as String? ?? '';

    debugPrint(
        '[WS] 📩 Session invite from $senderName for session $sessionId');
    onPingReceived?.call(senderName, sessionId, null);
  }

  void _handleSessionJoined(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String? ?? '';
    final participants = data['participants'] as List<dynamic>? ?? [];
    final myToken = _sessionTokens[sessionId];

    debugPrint(
        '[WS] ✅ Joined session: $sessionId with ${participants.length} existing participants');
    debugPrint('[WS] My token: ${myToken?.substring(0, 8)}...');

    _sessionParticipants[sessionId] = {};

    for (final p in participants) {
      final token = p['token'] as String? ?? '';
      final nickname = p['nickname'] as String? ?? 'Unknown';
      final publicKey = p['publicKey'] as String?;

      if (token.isEmpty) continue;

      // WICHTIG: Eigenen Token überspringen!
      if (token == myToken) {
        debugPrint('[WS] Skipping own token');
        continue;
      }

      _sessionParticipants[sessionId]![token] = ParticipantInfo(
        token: token,
        nickname: nickname,
        publicKey: publicKey,
      );

      debugPrint(
          '[WS] Existing participant: $nickname (${token.substring(0, 8)}...)');

      onParticipantJoined?.call(token, nickname, true);

      // Crypto initialisieren mit dem Public Key des ANDEREN
      if (publicKey != null && publicKey.isNotEmpty) {
        _initCryptoWithKey(publicKey, nickname);
      }
    }

    onSessionJoined?.call(sessionId);
  }

  void _handleSessionParticipants(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String? ?? '';
    final participants = data['participants'] as List<dynamic>? ?? [];
    final myToken = _sessionTokens[sessionId];

    debugPrint(
        '[WS] Session participants update: ${participants.length}, my token: ${myToken?.substring(0, 8)}...');

    for (final p in participants) {
      final token = p['token'] as String? ?? '';
      final nickname = p['nickname'] as String? ?? 'Unknown';
      final publicKey = p['publicKey'] as String?;

      // WICHTIG: Eigenen Token überspringen!
      if (token.isEmpty || token == myToken) {
        debugPrint('[WS] Skipping token: ${token.isEmpty ? "empty" : "own"}');
        continue;
      }

      // Schon bekannt? Dann überspringen
      if (_sessionParticipants[sessionId]?.containsKey(token) == true) {
        debugPrint('[WS] Already known: $nickname');
        continue;
      }

      _sessionParticipants[sessionId] ??= {};
      _sessionParticipants[sessionId]![token] = ParticipantInfo(
        token: token,
        nickname: nickname,
        publicKey: publicKey,
      );

      debugPrint(
          '[WS] New participant from list: $nickname (${token.substring(0, 8)}...)');

      onParticipantJoined?.call(token, nickname, true);

      if (publicKey != null && publicKey.isNotEmpty) {
        _initCryptoWithKey(publicKey, nickname);
      }
    }
  }

  void _handleParticipantJoined(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String? ?? '';
    final token = data['token'] as String? ?? '';
    final nickname = data['nickname'] as String? ?? 'Unknown';
    final publicKey = data['publicKey'] as String?;
    final myToken = _sessionTokens[sessionId];

    // WICHTIG: Eigenen Token überspringen!
    if (token.isEmpty || token == myToken) {
      debugPrint('[WS] Skipping participant_joined for own token');
      return;
    }

    debugPrint(
        '[WS] 🟢 Participant joined: $nickname (${token.substring(0, 8)}...)');

    _sessionParticipants[sessionId] ??= {};
    _sessionParticipants[sessionId]![token] = ParticipantInfo(
      token: token,
      nickname: nickname,
      publicKey: publicKey,
    );

    onParticipantJoined?.call(token, nickname, true);

    if (publicKey != null && publicKey.isNotEmpty) {
      _initCryptoWithKey(publicKey, nickname);
    }
  }

  void _handleParticipantLeft(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String? ?? '';
    final token = data['token'] as String? ?? '';

    if (token.isEmpty) return;

    debugPrint('[WS] 🔴 Participant left: ${token.substring(0, 8)}...');

    _sessionParticipants[sessionId]?.remove(token);
    onParticipantLeft?.call(token);
  }

  Future<void> _handleSessionMessage(Map<String, dynamic> data) async {
    final sessionId = data['sessionId'] as String? ?? '';
    final fromToken = data['fromToken'] as String? ?? '';
    final payload = data['payload'] as Map<String, dynamic>?;

    if (payload == null) return;

    final senderInfo = _sessionParticipants[sessionId]?[fromToken];
    final senderName = senderInfo?.nickname ?? 'Unknown';

    debugPrint('[WS] 💬 Message from $senderName');

    final enrichedData = {
      ...data,
      'senderId': fromToken,
      'senderName': senderName,
    };

    onMessage?.call(enrichedData);
  }

  Future<void> _initCryptoWithKey(
      String publicKeyBase64, String nickname) async {
    // Nur initialisieren wenn noch nicht ready
    if (cryptoService.isReady) {
      debugPrint('[WS] Crypto already initialized, skipping');
      return;
    }

    try {
      final keyBytes = base64Decode(publicKeyBase64);
      final remotePublicKey =
          SimplePublicKey(keyBytes, type: KeyPairType.x25519);
      await cryptoService.initSessionWithPeer(remotePublicKey);
      debugPrint('[WS] ✅ Crypto initialized with $nickname');
      onCryptoReady?.call();
    } catch (e) {
      debugPrint('[WS] ❌ Failed to init crypto: $e');
    }
  }

  // ==================== PUBLIC API ====================

  /// Gibt die Participants einer Session zurück
  Map<String, ParticipantInfo> getSessionParticipants(String sessionId) {
    return Map.unmodifiable(_sessionParticipants[sessionId] ?? {});
  }

  void createSession(String sessionId, String passcode) {
    if (!_connected || _identity == null) {
      debugPrint('[WS] Cannot create session - not connected');
      return;
    }

    final token = _getOrCreateSessionToken(sessionId);
    final passcodeHash = hashPasscode(passcode);

    debugPrint(
        '[WS] Creating session: $sessionId (Token: ${token.substring(0, 8)}...)');

    // Nur Session-Secret resetten, nicht das KeyPair!
    cryptoService.resetSession();

    _send({
      'type': 'create_session',
      'sessionId': sessionId,
      'passcodeHash': passcodeHash,
      'token': token,
      'nickname': _identity!.nickname,
      'publicKey': base64Encode(_identity!.publicKey.bytes),
    });
  }

  Future<void> joinSession(String sessionId, {String? passcode}) async {
    if (!_connected || _identity == null) {
      debugPrint('[WS] Cannot join session - not connected');
      return;
    }

    final token = _getOrCreateSessionToken(sessionId);
    final passcodeHash =
        passcode != null && passcode.isNotEmpty ? hashPasscode(passcode) : null;

    debugPrint(
        '[WS] Joining session: $sessionId (Token: ${token.substring(0, 8)}...)');

    // Nur Session-Secret resetten, nicht das KeyPair!
    cryptoService.resetSession();

    _send({
      'type': 'join_session',
      'sessionId': sessionId,
      if (passcodeHash != null) 'passcodeHash': passcodeHash,
      'token': token,
      'nickname': _identity!.nickname,
      'publicKey': base64Encode(_identity!.publicKey.bytes),
    });
  }

  /// Joined eine Session mit bereits gehashtem Passcode (für Ping-Einladungen)
  Future<void> joinSessionWithHash(String sessionId,
      {String? passcodeHash}) async {
    if (!_connected || _identity == null) {
      debugPrint('[WS] Cannot join session - not connected');
      return;
    }

    final token = _getOrCreateSessionToken(sessionId);

    debugPrint(
        '[WS] Joining session with hash: $sessionId (Token: ${token.substring(0, 8)}...)');

    // Nur Session-Secret resetten, nicht das KeyPair!
    cryptoService.resetSession();

    _send({
      'type': 'join_session',
      'sessionId': sessionId,
      if (passcodeHash != null && passcodeHash.isNotEmpty)
        'passcodeHash': passcodeHash,
      'token': token,
      'nickname': _identity!.nickname,
      'publicKey': base64Encode(_identity!.publicKey.bytes),
    });
  }

  void leaveSession(String sessionId) {
    final token = _sessionTokens[sessionId];

    if (token != null) {
      _send({
        'type': 'leave_session',
        'sessionId': sessionId,
        'token': token,
      });
    }

    _sessionTokens.remove(sessionId);
    _sessionParticipants.remove(sessionId);
    cryptoService.resetSession();

    debugPrint('[WS] Left session: $sessionId');
  }

  Future<void> sendMessage(String sessionId, String text) async {
    if (!_connected) throw StateError('Not connected');
    if (!cryptoService.isReady) throw StateError('E2E not ready');

    final token = _sessionTokens[sessionId];
    if (token == null) throw StateError('Not in session');

    final payload = await cryptoService.encrypt(text);

    _send({
      'type': 'session_message',
      'sessionId': sessionId,
      'token': token,
      'payload': payload,
    });

    debugPrint('[WS] 📤 Message sent (encrypted)');
  }

  /// Sendet einen Ping/Einladung an einen anderen User via oderId
  void sendPing(String sessionId, String recipientId, {String? passcode}) {
    if (!_connected || _identity == null) {
      debugPrint('[WS] Cannot send ping - not connected');
      return;
    }

    final passcodeHash =
        passcode != null && passcode.isNotEmpty ? hashPasscode(passcode) : null;

    debugPrint('[WS] 📤 Sending ping for session: $sessionId to $recipientId');

    _send({
      'type': 'ping_user',
      'sessionId': sessionId,
      'recipientId': recipientId,
      'senderName': _identity!.nickname,
      if (passcodeHash != null) 'passcodeHash': passcodeHash,
    });
  }

  /// Server-Ping für Keep-Alive
  void serverPing() {
    _send({'type': 'ping'});
  }

  void _send(Map<String, dynamic> data) {
    if (_channel == null) return;
    try {
      _channel!.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('[WS] Send error: $e');
    }
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _connectionCheckTimer?.cancel();
    _stopPingTimer();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _resetConnectionState();
    _sessionTokens.clear();
    _sessionParticipants.clear();
  }

  Future<void> reconnect() async {
    _reconnectAttempts = 0;
    await disconnect();
    await Future.delayed(const Duration(milliseconds: 500));
    await connect();
  }

  String get connectionStatusText {
    if (_connected) return 'Connected (ZK)';
    if (_isConnecting) return 'Connecting...';
    if (_reconnectAttempts > 0) {
      return 'Reconnect $_reconnectAttempts/$_maxReconnectAttempts';
    }
    return 'Disconnected';
  }

  /// Gibt die Anzahl der anderen Teilnehmer in einer Session zurück
  int getParticipantCount(String sessionId) {
    return _sessionParticipants[sessionId]?.length ?? 0;
  }

  void dispose() {
    disconnect();
  }
}

/// Info über einen Participant (nur Token-basiert!)
class ParticipantInfo {
  final String token;
  final String nickname;
  final String? publicKey;

  ParticipantInfo({
    required this.token,
    required this.nickname,
    this.publicKey,
  });
}
