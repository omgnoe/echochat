import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'identity_service.dart';

/// Service für verschlüsselte lokale Datenspeicherung
class SecureStorageService {
  static final SecureStorageService _instance =
      SecureStorageService._internal();
  factory SecureStorageService() => _instance;
  SecureStorageService._internal();

  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  final _cipher = AesGcm.with256bits();
  final _identityService = IdentityService();

  /// Speichert Daten verschlüsselt
  Future<void> saveEncrypted(String key, Map<String, dynamic> data) async {
    try {
      final encryptionKey = await _identityService.getLocalEncryptionKey();
      final secretKey = SecretKey(encryptionKey);

      final plaintext = jsonEncode(data);
      final nonce = _cipher.newNonce();

      final secretBox = await _cipher.encrypt(
        utf8.encode(plaintext),
        secretKey: secretKey,
        nonce: nonce,
      );

      final encrypted = {
        'c': base64Encode(secretBox.cipherText),
        'n': base64Encode(secretBox.nonce),
        'm': base64Encode(secretBox.mac.bytes),
      };

      await _secureStorage.write(key: key, value: jsonEncode(encrypted));
      debugPrint('[SecureStorage] Saved encrypted: $key');
    } catch (e) {
      debugPrint('[SecureStorage] Error saving: $e');
      rethrow;
    }
  }

  /// Lädt und entschlüsselt Daten
  Future<Map<String, dynamic>?> loadEncrypted(String key) async {
    try {
      final stored = await _secureStorage.read(key: key);
      if (stored == null) return null;

      final encrypted = jsonDecode(stored) as Map<String, dynamic>;

      final encryptionKey = await _identityService.getLocalEncryptionKey();
      final secretKey = SecretKey(encryptionKey);

      final secretBox = SecretBox(
        base64Decode(encrypted['c'] as String),
        nonce: base64Decode(encrypted['n'] as String),
        mac: Mac(base64Decode(encrypted['m'] as String)),
      );

      final decrypted = await _cipher.decrypt(secretBox, secretKey: secretKey);

      return jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[SecureStorage] Error loading $key: $e');
      return null;
    }
  }

  /// Speichert eine Liste verschlüsselt
  Future<void> saveEncryptedList(
      String key, List<Map<String, dynamic>> data) async {
    await saveEncrypted(key, {'list': data});
  }

  /// Lädt eine verschlüsselte Liste
  Future<List<Map<String, dynamic>>> loadEncryptedList(String key) async {
    final data = await loadEncrypted(key);
    if (data == null) return [];

    final list = data['list'] as List<dynamic>?;
    if (list == null) return [];

    return list.map((e) => e as Map<String, dynamic>).toList();
  }

  /// Löscht verschlüsselte Daten
  Future<void> delete(String key) async {
    await _secureStorage.delete(key: key);
    debugPrint('[SecureStorage] Deleted: $key');
  }

  /// Prüft ob Daten existieren
  Future<bool> exists(String key) async {
    final value = await _secureStorage.read(key: key);
    return value != null;
  }
}
