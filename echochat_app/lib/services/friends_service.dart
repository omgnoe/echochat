import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'secure_storage_service.dart';

class Friend {
  final String oderId;
  String nickname;
  String? publicKeyHash;
  final DateTime addedAt;
  String? verificationCode;

  Friend({
    required this.oderId,
    required this.nickname,
    this.publicKeyHash,
    required this.addedAt,
    this.verificationCode,
  });

  bool get hasPublicKey => publicKeyHash != null && publicKeyHash!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'oderId': oderId,
        'nickname': nickname,
        'publicKeyHash': publicKeyHash,
        'addedAt': addedAt.toIso8601String(),
        'verificationCode': verificationCode,
      };

  factory Friend.fromJson(Map<String, dynamic> json) => Friend(
        oderId: json['oderId'] as String,
        nickname: json['nickname'] as String,
        publicKeyHash: json['publicKeyHash'] as String?,
        addedAt: DateTime.parse(json['addedAt'] as String),
        verificationCode: json['verificationCode'] as String?,
      );
}

class FriendsService {
  static final FriendsService _instance = FriendsService._internal();
  factory FriendsService() => _instance;
  FriendsService._internal();

  final _secureStorage = SecureStorageService();
  static const _friendsKey = 'echochat_friends_v2';

  /// Generiert einen Verification Code für Key-Exchange
  static String generateVerificationCode() {
    final random = Random.secure();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();
  }

  Future<List<Friend>> loadFriends() async {
    try {
      final dataList = await _secureStorage.loadEncryptedList(_friendsKey);
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

  bool isValidFriendCode(String code) {
    final regex = RegExp(r'^ECHO-[A-Z0-9]{8}$');
    return regex.hasMatch(code.toUpperCase());
  }

  /// Generiert QR-Daten OHNE Public Key
  String generateQrData({
    required String oderId,
    required String nickname,
  }) {
    final verificationCode = generateVerificationCode();
    final data = {
      'id': oderId,
      'n': nickname,
      'vc': verificationCode,
      'v': 2,
    };
    return jsonEncode(data);
  }

  /// Parst QR-Daten
  Friend? parseQrData(String qrData) {
    try {
      final json = jsonDecode(qrData) as Map<String, dynamic>;
      final id = json['id'];
      final nickname = json['n'];
      if (id == null || nickname == null) return null;

      return Friend(
        oderId: id as String,
        nickname: nickname as String,
        publicKeyHash: null,
        addedAt: DateTime.now(),
        verificationCode: json['vc'] as String?,
      );
    } catch (e) {
      return null;
    }
  }
}
