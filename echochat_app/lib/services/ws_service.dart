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
  void Function(String token, String nickname)? onParticipantRejoined;
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

  // Ping Callbacks (v1.0.1)
  void Function(String recipientId)? onPingSent;
  void Function(String recipientId, String reason)? onPingFailed;
  void Function(int? cooldownRemaining, String? reason)? onPingRateLimited;

  // Typing Callback (v1.0.2)
  void Function(String sessionId, String token)? onTypingReceived;

  bool _connected = false;
  bool get isConnected => _connected;

  bool _isConnecting = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;

  EchoChatWebSocketService({
    String url = 'wss://YOURSERVER', // Production URL
  }) : url = _enforceSecureUrl(url) {
    cryptoService = CryptoService();
  }

  /// Erzwingt WSS statt WS für sichere Verbindungen
  /// Erlaubt WS für: localhost, 127.0.0.1, ngrok (Development)
  static String _enforceSecureUrl(String inputUrl) {
    if (inputUrl.startsWith('ws://')) {
      // Development URLs erlauben (localhost, ngrok)
      final isDevelopment = inputUrl.contains('localhost') ||
          inputUrl.contains('127.0.0.1') ||
          inputUrl.contains('ngrok');

      if (!isDevelopment) {
        final secureUrl = inputUrl.replaceFirst('ws://', 'wss://');
        debugPrint('[WS] ⚠️ Upgraded insecure WS to WSS: $secureUrl');
        return secureUrl;
      }
    }
    return inputUrl;
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

  /// NEUER Hash (v1.2.0+) - FNV-1a mit Salt
  /// Muss mit server.ts und session_service.dart übereinstimmen!
  static String hashPasscode(String passcode) {
    if (passcode.isEmpty) return '';

    // Normalisieren und salzen
    final normalized = passcode.toUpperCase().trim();
    final bytes = utf8.encode('echochat-salt-v2:$normalized');

    // FNV-1a Hash (gleich wie session_service.dart)
    var hash1 = 0x811c9dc5;
    var hash2 = 0;

    for (var i = 0; i < bytes.length; i++) {
      hash1 ^= bytes[i];
      hash1 = (hash1 * 0x01000193) & 0xFFFFFFFF;
      hash2 = ((hash2 << 5) - hash2 + bytes[i]) & 0xFFFFFFFF;
    }

    return '${hash1.toRadixString(16).padLeft(8, '0')}${hash2.toRadixString(16).padLeft(8, '0')}'
        .toUpperCase();
  }

  /// ALTER Hash (v1.0.x - v1.1.x) - Simpler DJB2-ähnlicher Hash
  /// Wird für Rückwärtskompatibilität mitgesendet
  static String hashPasscodeLegacy(String passcode) {
    if (passcode.isEmpty) return '';

    final normalized = passcode.toUpperCase().trim();
    var hash = 0;
    for (var i = 0; i < normalized.length; i++) {
      hash = ((hash << 5) - hash) + normalized.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF; // Convert to 32bit integer
    }
    return hash.abs().toString();
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
      debugPrint('[WS] ✅ Connected (Zero-Knowledge Mode v1.0.1)');

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

        case 'participant_rejoined':
          _handleParticipantRejoined(data);
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

        case 'ping_sent':
          final recipientId = data['recipientId'] as String? ?? '';
          debugPrint('[WS] ✅ Ping sent successfully to $recipientId');
          onPingSent?.call(recipientId);
          break;

        case 'ping_failed':
          final recipientId = data['recipientId'] as String? ?? '';
          final reason = data['reason'] as String? ?? 'unknown';
          debugPrint('[WS] ❌ Ping failed: $reason');
          onPingFailed?.call(recipientId, reason);
          break;

        case 'ping_rate_limited':
          final reason = data['reason'] as String?;
          final cooldown = data['cooldownRemaining'] as int?;
          debugPrint('[WS] ⏳ Ping rate limited: $reason, cooldown: $cooldown');
          onPingRateLimited?.call(cooldown, reason);
          break;

        case 'registered':
          debugPrint('[WS] ✅ Registered for pings');
          break;

        case 'typing':
          final sessionId = data['sessionId'] as String? ?? '';
          final token = data['fromToken'] as String? ?? '';
          onTypingReceived?.call(sessionId, token);
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
    // ZERO-KNOWLEDGE: Server sends NO sender name
    // Client must resolve session name locally from saved sessions
    final sessionId = data['sessionId'] as String? ?? '';
    final passcodeHash = data['passcodeHash'] as String?;

    debugPrint('[WS] 📩 Ping received for session: $sessionId');
    // Pass empty string for senderName - UI should look up session name locally
    onPingReceived?.call('', sessionId, passcodeHash);
  }

  void _handleSessionInvite(Map<String, dynamic> data) {
    // ZERO-KNOWLEDGE: No sender name from server
    final sessionId = data['sessionId'] as String? ?? '';

    debugPrint('[WS] 📩 Session invite for session: $sessionId');
    onPingReceived?.call('', sessionId, null);
  }

  void _handleSessionJoined(Map<String, dynamic> data) {
    debugPrint('[WS] RAW session_joined data: $data');

    final sessionId = data['sessionId'] as String? ?? '';
    final participants = data['participants'] as List<dynamic>? ?? [];
    final isRejoin = data['isRejoin'] as bool? ?? false;
    final myToken = _sessionTokens[sessionId];

    debugPrint(
        '[WS] ✅ ${isRejoin ? "Rejoined" : "Joined"} session: $sessionId with ${participants.length} existing participants');
    debugPrint('[WS] My token: ${myToken?.substring(0, 8)}...');

    _sessionParticipants[sessionId] = {};

    for (final p in participants) {
      debugPrint('[WS] RAW participant: $p');

      final token = p['token'] as String? ?? '';
      // ZERO-KNOWLEDGE: No nickname from server - use token prefix as temporary name
      final nickname =
          'User-${token.length >= 6 ? token.substring(0, 6) : token}';
      // Server sends keyExchangeBlob (v1.1.0) or publicKey (v1.0.x) - accept both
      final publicKey =
          p['keyExchangeBlob'] as String? ?? p['publicKey'] as String?;

      debugPrint(
          '[WS] Parsed participant: token=$token, publicKey=${publicKey != null ? "present (${publicKey.length} chars)" : "NULL"}');

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
          '[WS] Existing participant: $nickname (${token.substring(0, 8)}...) publicKey: ${publicKey != null ? "yes" : "no"}');

      onParticipantJoined?.call(token, nickname, true);

      // Crypto initialisieren mit dem Public Key des ANDEREN
      if (publicKey != null && publicKey.isNotEmpty) {
        _initCryptoWithKey(publicKey, nickname);
      } else {
        debugPrint('[WS] ⚠️ No publicKey for existing participant!');
      }
    }

    onSessionJoined?.call(sessionId);
  }

  void _handleSessionParticipants(Map<String, dynamic> data) {
    debugPrint('[WS] RAW session_participants data: $data');

    final sessionId = data['sessionId'] as String? ?? '';
    final participants = data['participants'] as List<dynamic>? ?? [];
    final myToken = _sessionTokens[sessionId];

    debugPrint(
        '[WS] Session participants update: ${participants.length}, my token: ${myToken?.substring(0, 8)}...');

    for (final p in participants) {
      debugPrint('[WS] RAW participant in list: $p');

      final token = p['token'] as String? ?? '';
      // ZERO-KNOWLEDGE: No nickname from server
      final nickname =
          'User-${token.length >= 6 ? token.substring(0, 6) : token}';
      // Accept both keyExchangeBlob (v1.1.0) and publicKey (v1.0.x)
      final publicKey =
          p['keyExchangeBlob'] as String? ?? p['publicKey'] as String?;

      // WICHTIG: Eigenen Token überspringen!
      if (token.isEmpty || token == myToken) {
        debugPrint('[WS] Skipping token: ${token.isEmpty ? "empty" : "own"}');
        continue;
      }

      // Schon bekannt? Dann nur ggf. Public Key updaten
      final existing = _sessionParticipants[sessionId]?[token];
      if (existing != null) {
        // Update public key if we didn't have it before
        if (existing.publicKey == null && publicKey != null) {
          debugPrint('[WS] Updating missing publicKey for $nickname');
          _sessionParticipants[sessionId]![token] = ParticipantInfo(
            token: token,
            nickname: existing.nickname,
            publicKey: publicKey,
          );
          _initCryptoWithKey(publicKey, existing.nickname);
        } else {
          debugPrint('[WS] Already known: $nickname');
        }
        continue;
      }

      _sessionParticipants[sessionId] ??= {};
      _sessionParticipants[sessionId]![token] = ParticipantInfo(
        token: token,
        nickname: nickname,
        publicKey: publicKey,
      );

      debugPrint(
          '[WS] New participant from list: $nickname (${token.substring(0, 8)}...) publicKey: ${publicKey != null ? "yes" : "no"}');

      onParticipantJoined?.call(token, nickname, true);

      if (publicKey != null && publicKey.isNotEmpty) {
        _initCryptoWithKey(publicKey, nickname);
      } else {
        debugPrint('[WS] ⚠️ No publicKey for participant in list!');
      }
    }
  }

  void _handleParticipantJoined(Map<String, dynamic> data) {
    debugPrint('[WS] RAW participant_joined data: $data');

    final sessionId = data['sessionId'] as String? ?? '';
    final token = data['token'] as String? ?? '';
    // ZERO-KNOWLEDGE: No nickname from server - use token prefix
    final nickname =
        'User-${token.length >= 6 ? token.substring(0, 6) : token}';
    // Server sends keyExchangeBlob (v1.1.0) or publicKey (v1.0.x) - accept both
    final publicKey =
        data['keyExchangeBlob'] as String? ?? data['publicKey'] as String?;
    final myToken = _sessionTokens[sessionId];

    debugPrint(
        '[WS] Parsed: token=$token, publicKey=${publicKey != null ? "present (${publicKey.length} chars)" : "NULL"}');

    // WICHTIG: Eigenen Token überspringen!
    if (token.isEmpty || token == myToken) {
      debugPrint('[WS] Skipping participant_joined for own token');
      return;
    }

    debugPrint(
        '[WS] 🟢 Participant joined: $nickname (${token.substring(0, 8)}...) publicKey: ${publicKey != null ? "yes" : "no"}');

    _sessionParticipants[sessionId] ??= {};
    _sessionParticipants[sessionId]![token] = ParticipantInfo(
      token: token,
      nickname: nickname,
      publicKey: publicKey,
    );

    onParticipantJoined?.call(token, nickname, true);

    if (publicKey != null && publicKey.isNotEmpty) {
      _initCryptoWithKey(publicKey, nickname);
    } else {
      debugPrint('[WS] ⚠️ No publicKey received for participant!');
    }
  }

  void _handleParticipantRejoined(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String? ?? '';
    final token = data['token'] as String? ?? '';
    // ZERO-KNOWLEDGE: No nickname from server
    final nickname =
        'User-${token.length >= 6 ? token.substring(0, 6) : token}';
    // Accept both keyExchangeBlob (v1.1.0) and publicKey (v1.0.x)
    final publicKey =
        data['keyExchangeBlob'] as String? ?? data['publicKey'] as String?;
    final myToken = _sessionTokens[sessionId];

    // WICHTIG: Eigenen Token überspringen!
    if (token.isEmpty || token == myToken) {
      debugPrint('[WS] Skipping participant_rejoined for own token');
      return;
    }

    debugPrint(
        '[WS] 🔄 Participant rejoined: $nickname (${token.substring(0, 8)}...) publicKey: ${publicKey != null ? "yes" : "no"}');

    _sessionParticipants[sessionId] ??= {};
    _sessionParticipants[sessionId]![token] = ParticipantInfo(
      token: token,
      nickname: nickname,
      publicKey: publicKey,
    );

    onParticipantRejoined?.call(token, nickname);

    // Re-initialize crypto with their public key - force reinit on rejoin
    if (publicKey != null && publicKey.isNotEmpty) {
      // Reset crypto first to force re-establishment
      cryptoService.resetSession();
      _initCryptoWithKey(publicKey, nickname, forceReinit: true);
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
    var senderName = senderInfo?.nickname ?? 'Unknown';

    // Decrypt the message
    String? decryptedText;
    try {
      decryptedText = await cryptoService.decrypt(payload);
      debugPrint('[WS] 💬 Decrypted message from $senderName');
    } catch (e) {
      debugPrint('[WS] ❌ Failed to decrypt message: $e');
      return;
    }

    // ZERO-KNOWLEDGE: Handle encrypted nickname exchange
    if (decryptedText != null && decryptedText.startsWith('__NICKNAME__:')) {
      final newNickname = decryptedText.substring('__NICKNAME__:'.length);
      updateParticipantNickname(sessionId, fromToken, newNickname);
      debugPrint('[WS] 🏷️ Received encrypted nickname: $newNickname');
      return; // Don't pass to UI as regular message
    }

    // Update senderName in case it was just updated
    senderName =
        _sessionParticipants[sessionId]?[fromToken]?.nickname ?? senderName;

    final enrichedData = {
      ...data,
      'senderId': fromToken,
      'senderName': senderName,
      'text': decryptedText,
    };

    onMessage?.call(enrichedData);
  }

  Future<void> _initCryptoWithKey(String publicKeyBase64, String nickname,
      {bool forceReinit = false}) async {
    // Skip if already ready and not forcing reinit
    if (cryptoService.isReady && !forceReinit) {
      debugPrint('[WS] Crypto already initialized, sending nickname');
      // Still send our nickname even if crypto was already ready
      _sendEncryptedNickname();
      return;
    }

    try {
      debugPrint(
          '[WS] 🔐 Initializing crypto with key from $nickname (${publicKeyBase64.substring(0, 20)}...)');
      final keyBytes = base64Decode(publicKeyBase64);
      final remotePublicKey =
          SimplePublicKey(keyBytes, type: KeyPairType.x25519);
      await cryptoService.initSessionWithPeer(remotePublicKey);
      debugPrint('[WS] ✅ Crypto initialized with $nickname');
      onCryptoReady?.call();

      // ZERO-KNOWLEDGE: Exchange nickname via encrypted message
      // Server only sees encrypted blob, not the actual nickname!
      _sendEncryptedNickname();
    } catch (e) {
      debugPrint('[WS] ❌ Failed to init crypto: $e');
    }
  }

  /// ZERO-KNOWLEDGE: Send own nickname via encrypted message
  /// This allows participants to identify each other without server knowing
  Future<void> _sendEncryptedNickname() async {
    if (_identity == null || !cryptoService.isReady) return;

    // Find the first active session to send nickname through
    for (final sessionId in _sessionTokens.keys) {
      final token = _sessionTokens[sessionId];
      if (token == null) continue;

      try {
        final nicknameMessage = '__NICKNAME__:${_identity!.nickname}';
        final payload = await cryptoService.encrypt(nicknameMessage);

        _send({
          'type': 'session_message',
          'sessionId': sessionId,
          'token': token,
          'payload': payload,
        });

        debugPrint('[WS] 📤 Sent encrypted nickname to session $sessionId');
        break; // Only need to send once
      } catch (e) {
        debugPrint('[WS] Failed to send nickname: $e');
      }
    }
  }

  /// Update participant nickname (called when receiving __NICKNAME__ message)
  void updateParticipantNickname(
      String sessionId, String token, String nickname) {
    final participant = _sessionParticipants[sessionId]?[token];
    if (participant != null) {
      _sessionParticipants[sessionId]![token] = ParticipantInfo(
        token: participant.token,
        nickname: nickname,
        publicKey: participant.publicKey,
      );
      debugPrint('[WS] Updated nickname for $token to $nickname');

      // Notify UI of nickname update
      onParticipantJoined?.call(token, nickname, true);
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
    final passcodeHashLegacy = hashPasscodeLegacy(passcode);

    debugPrint(
        '[WS] Creating session: $sessionId (Token: ${token.substring(0, 8)}...)');

    // Nur Session-Secret resetten, nicht das KeyPair!
    cryptoService.resetSession();

    final publicKeyBase64 = base64Encode(_identity!.publicKey.bytes);

    // Send both hash formats and both key field names for max compatibility
    _send({
      'type': 'create_session',
      'sessionId': sessionId,
      'passcodeHash': passcodeHash,
      'passcodeHashLegacy': passcodeHashLegacy, // For backwards compatibility
      'token': token,
      'publicKey': publicKeyBase64, // For v1.0.x servers
      'keyExchangeBlob': publicKeyBase64, // For v1.1.0+ servers
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
    final passcodeHashLegacy = passcode != null && passcode.isNotEmpty
        ? hashPasscodeLegacy(passcode)
        : null;

    debugPrint(
        '[WS] Joining session: $sessionId (Token: ${token.substring(0, 8)}...)');

    // Nur Session-Secret resetten, nicht das KeyPair!
    cryptoService.resetSession();

    final publicKeyBase64 = base64Encode(_identity!.publicKey.bytes);

    // Send both hash formats and both key field names for max compatibility
    _send({
      'type': 'join_session',
      'sessionId': sessionId,
      if (passcodeHash != null) 'passcodeHash': passcodeHash,
      if (passcodeHashLegacy != null) 'passcodeHashLegacy': passcodeHashLegacy,
      'token': token,
      'publicKey': publicKeyBase64, // For v1.0.x servers
      'keyExchangeBlob': publicKeyBase64, // For v1.1.0+ servers
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

    final publicKeyBase64 = base64Encode(_identity!.publicKey.bytes);

    // Send both publicKey (v1.0.x) and keyExchangeBlob (v1.1.0) for backwards compatibility
    _send({
      'type': 'join_session',
      'sessionId': sessionId,
      if (passcodeHash != null && passcodeHash.isNotEmpty)
        'passcodeHash': passcodeHash,
      'token': token,
      'publicKey': publicKeyBase64, // For v1.0.x servers
      'keyExchangeBlob': publicKeyBase64, // For v1.1.0+ servers
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

    // WICHTIG: Token NICHT löschen!
    // Der Token wird für spätere Rejoins benötigt.
    // Server erkennt Rejoin anhand des Tokens und überspringt Passcode-Check.
    // _sessionTokens.remove(sessionId);  // ← ENTFERNT für Rejoin-Support

    _sessionParticipants.remove(sessionId);
    cryptoService.resetSession();

    debugPrint('[WS] Left session: $sessionId (token preserved for rejoin)');
  }

  /// Löscht den Token für eine Session permanent (z.B. bei Session-Löschung)
  void forgetSession(String sessionId) {
    _sessionTokens.remove(sessionId);
    _sessionParticipants.remove(sessionId);
    debugPrint('[WS] Session forgotten: $sessionId');
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
  /// ZERO-KNOWLEDGE: Server sieht keinen Namen, nur Session ID
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
      // Note: senderName REMOVED for Zero-Knowledge - recipient resolves locally
      if (passcodeHash != null) 'passcodeHash': passcodeHash,
    });
  }

  /// Sendet Typing-Indicator (Zero-Knowledge - verschlüsselt als normale Message)
  Future<void> sendTypingIndicator(String sessionId, bool isTyping) async {
    if (!_connected || !cryptoService.isReady) return;

    final token = _sessionTokens[sessionId];
    if (token == null) return;

    // Typing als verschlüsselte Payload mit speziellem Prefix senden
    // Server sieht nur verschlüsselten Blob!
    final typingText = '__TYPING__:$isTyping';
    final payload = await cryptoService.encrypt(typingText);

    _send({
      'type': 'session_message',
      'sessionId': sessionId,
      'token': token,
      'payload': payload,
    });
  }

  /// Legacy sendTyping (nicht verschlüsselt - nicht verwenden!)
  @Deprecated('Use sendTypingIndicator instead')
  void sendTyping(String sessionId) {
    if (!_connected) return;

    final token = _sessionTokens[sessionId];
    if (token == null) return;

    _send({
      'type': 'typing',
      'sessionId': sessionId,
      'token': token,
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
