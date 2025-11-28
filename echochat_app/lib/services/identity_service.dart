import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Identity {
  final String oderId;
  final String nickname;
  final SimplePublicKey publicKey;

  Identity({
    required this.oderId,
    required this.nickname,
    required this.publicKey,
  });
}

class IdentityService {
  static final IdentityService _instance = IdentityService._internal();
  factory IdentityService() => _instance;
  IdentityService._internal();

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  final _algo = X25519();

  static const _keyPrivateKey = 'identity_private_key';
  static const _keyNickname = 'identity_nickname';
  static const _keyUserId = 'identity_user_id';
  static const _keyEncryptionKey = 'local_encryption_key';

  Future<Uint8List> getLocalEncryptionKey() async {
    var keyHex = await _storage.read(key: _keyEncryptionKey);

    if (keyHex == null) {
      final random = Random.secure();
      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = random.nextInt(256);
      }
      keyHex = _bytesToHex(key);
      await _storage.write(key: _keyEncryptionKey, value: keyHex);
    }

    return _hexToBytes(keyHex);
  }

  Future<bool> hasIdentity() async {
    final nickname = await _storage.read(key: _keyNickname);
    return nickname != null && nickname.isNotEmpty;
  }

  Future<Identity?> loadIdentity() async {
    final nickname = await _storage.read(key: _keyNickname);
    final oderId = await _storage.read(key: _keyUserId);
    final privateKeyHex = await _storage.read(key: _keyPrivateKey);

    if (nickname == null || oderId == null || privateKeyHex == null) {
      return null;
    }

    final privateKeyBytes = _hexToBytes(privateKeyHex);
    final keyPair = await _algo.newKeyPairFromSeed(privateKeyBytes);
    final publicKey = await keyPair.extractPublicKey();

    return Identity(
      oderId: oderId,
      nickname: nickname,
      publicKey: publicKey,
    );
  }

  Future<Identity> createIdentity(String nickname) async {
    final random = Random.secure();
    final seed = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      seed[i] = random.nextInt(256);
    }

    final keyPair = await _algo.newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();

    final oderId = _generateUserId();

    await _storage.write(key: _keyPrivateKey, value: _bytesToHex(seed));
    await _storage.write(key: _keyNickname, value: nickname);
    await _storage.write(key: _keyUserId, value: oderId);

    await getLocalEncryptionKey();

    return Identity(
      oderId: oderId,
      nickname: nickname,
      publicKey: publicKey,
    );
  }

  String _generateUserId() {
    final random = Random.secure();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final id =
        List.generate(8, (index) => chars[random.nextInt(chars.length)]).join();
    return 'ECHO-$id';
  }

  Future<SimpleKeyPair> getKeyPair() async {
    final privateKeyHex = await _storage.read(key: _keyPrivateKey);
    if (privateKeyHex == null) {
      throw StateError("Keine Identity vorhanden");
    }
    final privateKeyBytes = _hexToBytes(privateKeyHex);
    return _algo.newKeyPairFromSeed(privateKeyBytes);
  }

  Future<void> resetIdentity() async {
    await _storage.delete(key: _keyPrivateKey);
    await _storage.delete(key: _keyNickname);
    await _storage.delete(key: _keyUserId);
    await _storage.delete(key: _keyEncryptionKey);
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
