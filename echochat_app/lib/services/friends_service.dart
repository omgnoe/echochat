import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'secure_storage_service.dart';

class Friend {
  final String oderId;
  String nickname;
  String? publicKeyHash; // SHA-256 hash of public key (first 16 chars)
  String? publicKeyFull; // Full public key for verification
  final DateTime addedAt;
  String? verificationCode; // 6-char code for out-of-band verification
  bool isVerified; // True if key was verified out-of-band

  Friend({
    required this.oderId,
    required this.nickname,
    this.publicKeyHash,
    this.publicKeyFull,
    required this.addedAt,
    this.verificationCode,
    this.isVerified = false,
  });

  bool get hasPublicKey => publicKeyHash != null && publicKeyHash!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'oderId': oderId,
        'nickname': nickname,
        'publicKeyHash': publicKeyHash,
        'publicKeyFull': publicKeyFull,
        'addedAt': addedAt.toIso8601String(),
        'verificationCode': verificationCode,
        'isVerified': isVerified,
      };

  factory Friend.fromJson(Map<String, dynamic> json) => Friend(
        oderId: json['oderId'] as String,
        nickname: json['nickname'] as String,
        publicKeyHash: json['publicKeyHash'] as String?,
        publicKeyFull: json['publicKeyFull'] as String?,
        addedAt: DateTime.parse(json['addedAt'] as String),
        verificationCode: json['verificationCode'] as String?,
        isVerified: json['isVerified'] as bool? ?? false,
      );
}

class FriendsService {
  static final FriendsService _instance = FriendsService._internal();
  factory FriendsService() => _instance;
  FriendsService._internal();

  final _secureStorage = SecureStorageService();
  static const _friendsKey = 'echochat_friends_v3'; // Bumped for new format

  /// Generiert einen Verification Code für Key-Exchange
  /// Verwendet kryptografisch sichere Zufallszahlen
  static String generateVerificationCode() {
    final random = Random.secure();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// Berechnet einen kurzen Hash eines Public Keys für MITM-Schutz
  /// Verwendet FNV-1a Hash für schnelle, sichere Berechnung
  static String computePublicKeyHash(String publicKeyBase64) {
    try {
      final bytes = base64Decode(publicKeyBase64);

      // FNV-1a Hash
      var hash1 = 0x811c9dc5;
      var hash2 = 0xcbf29ce4;

      for (var i = 0; i < bytes.length; i++) {
        hash1 ^= bytes[i];
        hash1 = (hash1 * 0x01000193) & 0xFFFFFFFF;
        hash2 ^= bytes[bytes.length - 1 - i];
        hash2 = (hash2 * 0x01000193) & 0xFFFFFFFF;
      }

      // 16 Zeichen Hash Output
      return '${hash1.toRadixString(16).padLeft(8, '0')}${hash2.toRadixString(16).padLeft(8, '0')}'
          .toUpperCase();
    } catch (e) {
      debugPrint('[FriendsService] Error computing key hash: $e');
      return '';
    }
  }

  /// Generiert einen kurzen, lesbaren Fingerprint für manuelle Verifikation
  /// Format: XXXX-XXXX-XXXX (12 Zeichen)
  static String computeKeyFingerprint(String publicKeyBase64) {
    final hash = computePublicKeyHash(publicKeyBase64);
    if (hash.length < 12) return hash;
    return '${hash.substring(0, 4)}-${hash.substring(4, 8)}-${hash.substring(8, 12)}';
  }

  Future<List<Friend>> loadFriends() async {
    try {
      // Try new format first
      var dataList = await _secureStorage.loadEncryptedList(_friendsKey);

      // Migration from old format
      if (dataList.isEmpty) {
        dataList =
            await _secureStorage.loadEncryptedList('echochat_friends_v2');
      }

      return dataList.map((e) => Friend.fromJson(e)).toList();
    } catch (e) {
      debugPrint('[FriendsService] Error loading friends: $e');
      return [];
    }
  }

  Future<void> saveFriends(List<Friend> friends) async {
    final dataList = friends.map((f) => f.toJson()).toList();
    await _secureStorage.saveEncryptedList(_friendsKey, dataList);
  }

  Future<void> addFriend(Friend friend) async {
    final friends = await loadFriends();
    if (friends.any((f) => f.oderId == friend.oderId)) return;
    friends.add(friend);
    await saveFriends(friends);
  }

  Future<void> removeFriend(String oderId) async {
    final friends = await loadFriends();
    friends.removeWhere((f) => f.oderId == oderId);
    await saveFriends(friends);
  }

  Future<Friend?> findFriend(String oderId) async {
    final friends = await loadFriends();
    return friends.where((f) => f.oderId == oderId).firstOrNull;
  }

  Future<void> updateFriendPublicKey(
      String oderId, String publicKeyBase64) async {
    final friends = await loadFriends();
    final index = friends.indexWhere((f) => f.oderId == oderId);
    if (index >= 0) {
      friends[index].publicKeyHash = computePublicKeyHash(publicKeyBase64);
      friends[index].publicKeyFull = publicKeyBase64;
      await saveFriends(friends);
      debugPrint('[FriendsService] Updated public key for $oderId');
    }
  }

  /// Alias für Rückwärtskompatibilität
  Future<void> updateFriendPublicKeyHash(
      String oderId, String publicKeyHash) async {
    final friends = await loadFriends();
    final index = friends.indexWhere((f) => f.oderId == oderId);
    if (index >= 0) {
      friends[index].publicKeyHash = publicKeyHash;
      await saveFriends(friends);
    }
  }

  Future<void> updateFriendVerificationCode(String oderId, String code) async {
    final friends = await loadFriends();
    final index = friends.indexWhere((f) => f.oderId == oderId);
    if (index >= 0) {
      friends[index].verificationCode = code;
      await saveFriends(friends);
    }
  }

  /// Markiert einen Freund als verifiziert (nach out-of-band Verification)
  Future<void> markFriendVerified(String oderId) async {
    final friends = await loadFriends();
    final index = friends.indexWhere((f) => f.oderId == oderId);
    if (index >= 0) {
      friends[index].isVerified = true;
      await saveFriends(friends);
      debugPrint('[FriendsService] Marked $oderId as verified');
    }
  }

  /// Prüft ob ein empfangener Public Key mit dem gespeicherten übereinstimmt
  /// Gibt (match, isNewKey) zurück
  Future<({bool matches, bool isNewKey, String? storedHash})> verifyPublicKey(
      String oderId, String receivedPublicKeyBase64) async {
    final friend = await findFriend(oderId);
    if (friend == null) {
      return (matches: false, isNewKey: true, storedHash: null);
    }

    final receivedHash = computePublicKeyHash(receivedPublicKeyBase64);

    // Kein gespeicherter Key = neuer Key
    if (friend.publicKeyHash == null || friend.publicKeyHash!.isEmpty) {
      return (matches: true, isNewKey: true, storedHash: null);
    }

    // Vergleiche Hashes
    final matches = friend.publicKeyHash == receivedHash;
    return (
      matches: matches,
      isNewKey: false,
      storedHash: friend.publicKeyHash
    );
  }

  bool isValidFriendCode(String code) {
    final regex = RegExp(r'^ECHO-[A-Z0-9]{8}$');
    return regex.hasMatch(code.toUpperCase());
  }

  /// Generiert QR-Daten MIT Public Key Hash für MITM-Schutz (wenn verfügbar)
  /// Format v3: Enthält Public Key Hash zur Verifikation
  /// Format v2: Ohne Key Hash (für Kompatibilität)
  String generateQrData({
    required String oderId,
    required String nickname,
    String? publicKeyBase64,
  }) {
    final verificationCode = generateVerificationCode();

    if (publicKeyBase64 != null && publicKeyBase64.isNotEmpty) {
      // v3 mit Key-Verifikation
      final keyHash = computePublicKeyHash(publicKeyBase64);
      final fingerprint = computeKeyFingerprint(publicKeyBase64);

      final data = {
        'id': oderId,
        'n': nickname,
        'vc': verificationCode,
        'kh': keyHash,
        'fp': fingerprint,
        'v': 3,
      };
      return jsonEncode(data);
    } else {
      // v2 ohne Key (Kompatibilität)
      final data = {
        'id': oderId,
        'n': nickname,
        'vc': verificationCode,
        'v': 2,
      };
      return jsonEncode(data);
    }
  }

  /// Parse QR-Daten und gibt FriendQrData zurück (mit Key-Info)
  /// Für neue Features wie Key-Verifikation
  FriendQrData? parseQrDataFull(String qrData) {
    try {
      final json = jsonDecode(qrData) as Map<String, dynamic>;
      final id = json['id'];
      final nickname = json['n'];
      if (id == null || nickname == null) return null;

      final version = json['v'] as int? ?? 1;

      return FriendQrData(
        friend: Friend(
          oderId: id as String,
          nickname: nickname as String,
          publicKeyHash: json['kh'] as String?,
          addedAt: DateTime.now(),
          verificationCode: json['vc'] as String?,
        ),
        keyHash: json['kh'] as String?,
        fingerprint: json['fp'] as String?,
        version: version,
      );
    } catch (e) {
      debugPrint('[FriendsService] Error parsing QR data: $e');
      return null;
    }
  }

  /// Parse QR-Daten (Rückwärtskompatibel - gibt Friend? zurück)
  /// WICHTIG: Dies ist die Hauptmethode für friends_screen.dart
  Friend? parseQrData(String qrData) {
    final result = parseQrDataFull(qrData);
    return result?.friend;
  }

  /// Verifiziert ob ein empfangener Key zum QR-Code-Hash passt
  bool verifyKeyAgainstQr(String receivedKeyBase64, String expectedKeyHash) {
    final receivedHash = computePublicKeyHash(receivedKeyBase64);
    return receivedHash == expectedKeyHash;
  }
}

/// Parse-Ergebnis für QR-Daten
class FriendQrData {
  final Friend friend;
  final String? keyHash;
  final String? fingerprint;
  final int version;

  FriendQrData({
    required this.friend,
    this.keyHash,
    this.fingerprint,
    required this.version,
  });

  bool get hasKeyVerification => version >= 3 && keyHash != null;

  // Convenience getters für Rückwärtskompatibilität
  String get oderId => friend.oderId;
  String get nickname => friend.nickname;
  String? get verificationCode => friend.verificationCode;
}
