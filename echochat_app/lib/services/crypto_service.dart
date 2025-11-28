import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';

class CryptoService {
  final _algo = X25519();
  final _cipher = AesGcm.with256bits();

  // Das eigene KeyPair (wird von außen gesetzt aus Identity!)
  SimpleKeyPair? _myKeyPair;
  SecretKey? _sharedSecret;
  SimplePublicKey? _peerPublicKey;

  bool get isReady => _sharedSecret != null;

  /// Setzt das eigene KeyPair (aus der Identity)
  void setKeyPair(SimpleKeyPair keyPair) {
    _myKeyPair = keyPair;
    debugPrint('[Crypto] KeyPair set from Identity');
  }

  /// Gibt den eigenen Public Key zurück
  Future<SimplePublicKey?> getPublicKey() async {
    if (_myKeyPair == null) return null;
    return await _myKeyPair!.extractPublicKey();
  }

  /// Initialisiert die Session mit dem Public Key des Peers
  Future<void> initSessionWithPeer(SimplePublicKey peerPublicKey) async {
    if (_myKeyPair == null) {
      throw StateError('KeyPair not set - call setKeyPair first');
    }

    try {
      _peerPublicKey = peerPublicKey;

      // Shared Secret berechnen mit ECDH
      final sharedSecretKey = await _algo.sharedSecretKey(
        keyPair: _myKeyPair!,
        remotePublicKey: peerPublicKey,
      );

      // Secret Key extrahieren
      final secretBytes = await sharedSecretKey.extractBytes();
      _sharedSecret = SecretKey(secretBytes);

      final myPubKey = await _myKeyPair!.extractPublicKey();
      debugPrint(
          '[Crypto] ✅ Shared secret established (${secretBytes.length} bytes)');
      debugPrint(
          '[Crypto] My public key: ${base64Encode(myPubKey.bytes).substring(0, 16)}...');
      debugPrint(
          '[Crypto] Peer public key: ${base64Encode(peerPublicKey.bytes).substring(0, 16)}...');
    } catch (e) {
      debugPrint('[Crypto] ❌ Failed to init session: $e');
      rethrow;
    }
  }

  /// Verschlüsselt eine Nachricht
  Future<Map<String, dynamic>> encrypt(String plaintext) async {
    if (_sharedSecret == null) {
      throw StateError('Crypto not initialized - no shared secret');
    }

    try {
      final plaintextBytes = utf8.encode(plaintext);
      final nonce = _cipher.newNonce();

      final secretBox = await _cipher.encrypt(
        plaintextBytes,
        secretKey: _sharedSecret!,
        nonce: nonce,
      );

      final result = {
        'ciphertext': base64Encode(secretBox.cipherText),
        'nonce': base64Encode(secretBox.nonce),
        'mac': base64Encode(secretBox.mac.bytes),
      };

      debugPrint('[Crypto] ✅ Encrypted ${plaintext.length} chars');
      return result;
    } catch (e) {
      debugPrint('[Crypto] ❌ Encryption failed: $e');
      rethrow;
    }
  }

  /// Entschlüsselt eine Nachricht
  Future<String> decrypt(Map<String, dynamic> payload) async {
    if (_sharedSecret == null) {
      throw StateError('Crypto not initialized - no shared secret');
    }

    try {
      final ciphertextBase64 = payload['ciphertext'] as String;
      final nonceBase64 = payload['nonce'] as String;
      final macBase64 = payload['mac'] as String;

      final ciphertext = base64Decode(ciphertextBase64);
      final nonce = base64Decode(nonceBase64);
      final mac = base64Decode(macBase64);

      debugPrint(
          '[Crypto] Decrypting: ct=${ciphertext.length}b, nonce=${nonce.length}b, mac=${mac.length}b');

      final secretBox = SecretBox(
        ciphertext,
        nonce: nonce,
        mac: Mac(mac),
      );

      final plaintextBytes = await _cipher.decrypt(
        secretBox,
        secretKey: _sharedSecret!,
      );

      final plaintext = utf8.decode(plaintextBytes);
      debugPrint('[Crypto] ✅ Decrypted ${plaintext.length} chars');
      return plaintext;
    } catch (e) {
      debugPrint('[Crypto] ❌ Decryption failed: $e');
      rethrow;
    }
  }

  /// Setzt nur das Shared Secret zurück (KeyPair bleibt!)
  void resetSession() {
    _sharedSecret = null;
    _peerPublicKey = null;
    debugPrint('[Crypto] Session reset (KeyPair kept)');
  }

  /// Setzt alles zurück (inkl. KeyPair)
  void reset() {
    _myKeyPair = null;
    _sharedSecret = null;
    _peerPublicKey = null;
    debugPrint('[Crypto] Full reset');
  }
}
