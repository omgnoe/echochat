import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'secure_storage_service.dart';

class StoredMessage {
  final String id;
  final String text;
  final String senderId;
  final String senderName;
  final DateTime timestamp;
  final bool isMe;

  StoredMessage({
    required this.id,
    required this.text,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
    required this.isMe,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'senderId': senderId,
        'senderName': senderName,
        'timestamp': timestamp.toIso8601String(),
        'isMe': isMe,
      };

  factory StoredMessage.fromJson(Map<String, dynamic> json) => StoredMessage(
        id: json['id'] as String,
        text: json['text'] as String,
        senderId: json['senderId'] as String,
        senderName: json['senderName'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        isMe: json['isMe'] as bool,
      );
}

class Session {
  final String sessionId;
  final String passcode;
  final String passcodeHash;
  final String? passcodeHashLegacy; // Für Rückwärtskompatibilität
  final String name;
  final DateTime createdAt;
  final DateTime? expiresAt;
  int unreadCount;
  String? recipientId;
  String? recipientNickname;
  bool isActive;
  bool isCreator;
  String? ephemeralPublicKey;

  Session({
    required this.sessionId,
    required this.passcode,
    String? passcodeHash,
    String? passcodeHashLegacy,
    required this.name,
    required this.createdAt,
    this.expiresAt,
    this.unreadCount = 0,
    this.recipientId,
    this.recipientNickname,
    this.isActive = true,
    this.isCreator = false,
    this.ephemeralPublicKey,
  })  : passcodeHash = passcodeHash ?? _computeHash(passcode),
        passcodeHashLegacy = passcodeHashLegacy ?? _computeHashLegacy(passcode);

  /// NEUER Hash (v1.2.0+) - FNV-1a mit Salt
  static String _computeHash(String input) {
    if (input.isEmpty) return '';

    final normalized = input.toUpperCase().trim();
    final bytes = utf8.encode('echochat-salt-v2:$normalized');

    var hash1 = 0x811c9dc5; // FNV offset basis
    var hash2 = 0;

    for (var i = 0; i < bytes.length; i++) {
      hash1 ^= bytes[i];
      hash1 = (hash1 * 0x01000193) & 0xFFFFFFFF; // FNV prime
      hash2 = ((hash2 << 5) - hash2 + bytes[i]) & 0xFFFFFFFF;
    }

    // Kombiniere beide Hashes für 16 Zeichen Output
    final combined =
        '${hash1.toRadixString(16).padLeft(8, '0')}${hash2.toRadixString(16).padLeft(8, '0')}';
    return combined.toUpperCase();
  }

  /// ALTER Hash (v1.0.x - v1.1.x) - Simpler DJB2-ähnlicher Hash
  /// Wird für Rückwärtskompatibilität mitgesendet
  static String _computeHashLegacy(String input) {
    if (input.isEmpty) return '';

    final normalized = input.toUpperCase().trim();
    var hash = 0;
    for (var i = 0; i < normalized.length; i++) {
      hash = ((hash << 5) - hash) + normalized.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF; // Convert to 32bit integer
    }
    return hash.abs().toString();
  }

  static const sessionDuration = Duration(days: 3);

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  bool get isExpiringSoon {
    if (expiresAt == null) return false;
    final remaining = expiresAt!.difference(DateTime.now());
    return remaining.inHours < 24 && remaining.inSeconds > 0;
  }

  Duration? get remainingTime {
    if (expiresAt == null) return null;
    final remaining = expiresAt!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String get fullJoinCode => '$sessionId-$passcode';

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'passcode': passcode,
        'passcodeHash': passcodeHash,
        'passcodeHashLegacy': passcodeHashLegacy,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'expiresAt': expiresAt?.toIso8601String(),
        'unreadCount': unreadCount,
        'recipientId': recipientId,
        'recipientNickname': recipientNickname,
        'isActive': isActive,
        'isCreator': isCreator,
        'ephemeralPublicKey': ephemeralPublicKey,
      };

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        sessionId: json['sessionId'] as String,
        passcode: json['passcode'] as String? ?? '',
        passcodeHash: json['passcodeHash'] as String?,
        passcodeHashLegacy: json['passcodeHashLegacy'] as String?,
        name: json['name'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        expiresAt: json['expiresAt'] != null
            ? DateTime.parse(json['expiresAt'] as String)
            : null,
        unreadCount: json['unreadCount'] as int? ?? 0,
        recipientId: json['recipientId'] as String?,
        recipientNickname: json['recipientNickname'] as String?,
        isActive: json['isActive'] as bool? ?? true,
        isCreator: json['isCreator'] as bool? ?? false,
        ephemeralPublicKey: json['ephemeralPublicKey'] as String?,
      );
}

class SessionService {
  static final SessionService _instance = SessionService._internal();
  factory SessionService() => _instance;
  SessionService._internal();

  final _secureStorage = SecureStorageService();

  static const _sessionsKey =
      'echochat_sessions_v3'; // Bumped version for new hash
  static const _messagesKeyPrefix = 'echochat_messages_v2_';
  static const _sessionIdChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const _passcodeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  String _generateSessionId() {
    final random = Random.secure();
    return List.generate(
            6, (_) => _sessionIdChars[random.nextInt(_sessionIdChars.length)])
        .join();
  }

  String _generatePasscode() {
    final random = Random.secure();
    return List.generate(
        4, (_) => _passcodeChars[random.nextInt(_passcodeChars.length)]).join();
  }

  /// Hasht einen Passcode mit kryptografischem Hash
  static String hashPasscode(String passcode) {
    return Session._computeHash(passcode);
  }

  static ({String sessionId, String? passcode, String? passcodeHash})
      parseJoinCode(String code) {
    final normalized = code.toUpperCase().trim();

    if (normalized.contains('-') && normalized.length >= 11) {
      final parts = normalized.split('-');
      if (parts.length == 2 && parts[0].length == 6 && parts[1].length == 4) {
        return (
          sessionId: parts[0],
          passcode: parts[1],
          passcodeHash: hashPasscode(parts[1]),
        );
      }
    }

    if (normalized.length == 6) {
      return (sessionId: normalized, passcode: null, passcodeHash: null);
    }

    if (normalized.length == 10) {
      final passcode = normalized.substring(6);
      return (
        sessionId: normalized.substring(0, 6),
        passcode: passcode,
        passcodeHash: hashPasscode(passcode),
      );
    }

    return (sessionId: normalized, passcode: null, passcodeHash: null);
  }

  static bool isValidJoinCode(String code) {
    final normalized = code.toUpperCase().trim();
    final regex = RegExp(r'^[A-Z0-9]{6}(-[A-Z0-9]{4})?$');
    return regex.hasMatch(normalized) ||
        (normalized.length == 10 &&
            RegExp(r'^[A-Z0-9]+$').hasMatch(normalized));
  }

  // ==================== SESSION METHODS ====================

  Future<List<Session>> loadSessions() async {
    try {
      // Try new format first
      var dataList = await _secureStorage.loadEncryptedList(_sessionsKey);

      // Migration: also check old key
      if (dataList.isEmpty) {
        dataList =
            await _secureStorage.loadEncryptedList('echochat_sessions_v2');
      }

      final sessions = dataList
          .map((e) => Session.fromJson(e))
          .where((s) => !s.isExpired)
          .toList();

      await _saveSessions(sessions);
      return sessions;
    } catch (e) {
      debugPrint('[SessionService] Error loading sessions: $e');
      return [];
    }
  }

  Future<void> _saveSessions(List<Session> sessions) async {
    final dataList = sessions.map((s) => s.toJson()).toList();
    await _secureStorage.saveEncryptedList(_sessionsKey, dataList);
  }

  Future<Session> createSession(String name) async {
    final sessions = await loadSessions();
    final now = DateTime.now();
    final passcode = _generatePasscode();

    final session = Session(
      sessionId: _generateSessionId(),
      passcode: passcode,
      name: name,
      createdAt: now,
      expiresAt: now.add(Session.sessionDuration),
      isActive: true,
      isCreator: true,
    );

    sessions.insert(0, session);
    await _saveSessions(sessions);

    debugPrint('[SessionService] Created session: ${session.sessionId}');
    return session;
  }

  Future<Session> joinSession(String sessionId, String passcode) async {
    final sessions = await loadSessions();
    final normalized = sessionId.toUpperCase().trim();
    final normalizedPasscode = passcode.toUpperCase().trim();

    final existing =
        sessions.where((s) => s.sessionId == normalized).firstOrNull;
    if (existing != null) {
      existing.isActive = true;
      await _saveSessions(sessions);
      return existing;
    }

    final now = DateTime.now();
    final session = Session(
      sessionId: normalized,
      passcode: normalizedPasscode,
      name: 'Chat $normalized',
      createdAt: now,
      expiresAt: now.add(Session.sessionDuration),
      isActive: true,
      isCreator: false,
    );

    sessions.insert(0, session);
    await _saveSessions(sessions);

    debugPrint('[SessionService] Joined session: $normalized');
    return session;
  }

  Future<void> deleteSession(String sessionId) async {
    final sessions = await loadSessions();
    sessions.removeWhere((s) => s.sessionId == sessionId);
    await _saveSessions(sessions);
    await clearMessages(sessionId);
    debugPrint('[SessionService] Deleted session: $sessionId');
  }

  Future<void> updateSessionRecipient(
    String sessionId,
    String recipientId,
    String recipientNickname,
  ) async {
    final sessions = await loadSessions();
    final index = sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index >= 0) {
      sessions[index].recipientId = recipientId;
      sessions[index].recipientNickname = recipientNickname;
      await _saveSessions(sessions);
    }
  }

  Future<void> updateSessionEphemeralKey(
      String sessionId, String ephemeralKey) async {
    final sessions = await loadSessions();
    final index = sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index >= 0) {
      sessions[index].ephemeralPublicKey = ephemeralKey;
      await _saveSessions(sessions);
    }
  }

  Future<void> incrementUnread(String sessionId) async {
    final sessions = await loadSessions();
    final index = sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index >= 0) {
      sessions[index].unreadCount++;
      await _saveSessions(sessions);
    }
  }

  Future<void> clearUnreadCount(String sessionId) async {
    final sessions = await loadSessions();
    final index = sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index >= 0) {
      sessions[index].unreadCount = 0;
      await _saveSessions(sessions);
    }
  }

  Future<void> refreshSessionExpiry(String sessionId) async {
    final sessions = await loadSessions();
    final index = sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index >= 0) {
      final old = sessions[index];
      sessions[index] = Session(
        sessionId: old.sessionId,
        passcode: old.passcode,
        passcodeHash: old.passcodeHash,
        name: old.name,
        createdAt: old.createdAt,
        expiresAt: DateTime.now().add(Session.sessionDuration),
        unreadCount: old.unreadCount,
        recipientId: old.recipientId,
        recipientNickname: old.recipientNickname,
        isActive: true,
        isCreator: old.isCreator,
        ephemeralPublicKey: old.ephemeralPublicKey,
      );
      await _saveSessions(sessions);
    }
  }

  Future<Session?> getSession(String sessionId) async {
    final sessions = await loadSessions();
    return sessions.where((s) => s.sessionId == sessionId).firstOrNull;
  }

  Future<void> handleSessionExpired(String sessionId) async {
    final sessions = await loadSessions();
    final index = sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index >= 0) {
      sessions[index].isActive = false;
      await _saveSessions(sessions);
    }
  }

  // ==================== MESSAGE METHODS ====================

  Future<List<StoredMessage>> loadMessages(String sessionId) async {
    try {
      final key = '$_messagesKeyPrefix$sessionId';
      final dataList = await _secureStorage.loadEncryptedList(key);
      return dataList.map((e) => StoredMessage.fromJson(e)).toList();
    } catch (e) {
      debugPrint('[SessionService] Error loading messages: $e');
      return [];
    }
  }

  Future<void> addMessage(String sessionId, StoredMessage message) async {
    final key = '$_messagesKeyPrefix$sessionId';
    final messages = await loadMessages(sessionId);
    messages.add(message);

    final trimmed = messages.length > 500
        ? messages.sublist(messages.length - 500)
        : messages;
    final dataList = trimmed.map((m) => m.toJson()).toList();
    await _secureStorage.saveEncryptedList(key, dataList);
  }

  Future<void> clearMessages(String sessionId) async {
    final key = '$_messagesKeyPrefix$sessionId';
    await _secureStorage.delete(key);
    debugPrint('[SessionService] Cleared messages for: $sessionId');
  }
}
