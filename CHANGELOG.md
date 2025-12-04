# Changelog

All notable changes to EchoChat will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.2.0] - 2024-12

### 🔒 Security

#### Zero-Knowledge Architecture
- Server no longer stores nicknames - exchanged encrypted between clients only
- User IDs are anonymized (SHA-256 hash) before reaching the server
- Passcode hash strengthened (FNV-1a with salt instead of simple DJB2)
- Server only sees: encrypted blobs, anonymous tokens, timing metadata

#### MITM Protection
- QR codes now include public key hash for verification
- New QR format v3 with security fingerprint
- Friends can be marked as "verified" after out-of-band confirmation
- Fingerprint display per friend (format: `XXXX-XXXX-XXXX`)

#### Connection Security
- WSS (TLS) automatically enforced for production URLs
- Only localhost/ngrok allowed unencrypted (development mode)

### ✨ Added

#### Friends Screen
- New fingerprint button for each friend
- Verification dialog when scanning QR codes
- Verified badge (✓) for verified contacts
- Security fingerprint displayed in own QR code

#### Info Screen
- Redesigned with Zero-Knowledge explanations
- "What the Server Cannot See" overview
- Version 1.2.0 badge with long-press to copy

### 🐛 Fixed

- `ECHO-ECHO-XXX` bug in Home Screen (double prefix)
- Compilation errors in friends_screen.dart
- `parseQrData` now returns `Friend?` for backwards compatibility

### 🔄 Backwards Compatibility

- Server accepts both old AND new passcode hash formats
- Clients send both hash formats (`passcodeHash` + `passcodeHashLegacy`)
- Supports both `publicKey` (v1.0.x) and `keyExchangeBlob` (v1.1.0+)
- Existing users can continue chatting without immediate app update

### 📁 Changed Files

**Backend:**
- `src/server.ts` - Zero-Knowledge + backwards compatibility

**Flutter Services:**
- `lib/services/ws_service.dart` - Dual-hash, WSS enforcement
- `lib/services/session_service.dart` - Legacy hash support
- `lib/services/friends_service.dart` - Key verification, fingerprints

**Flutter Screens:**
- `lib/screens/friends_screen.dart` - MITM protection UI
- `lib/screens/home_screen.dart` - ECHO-ID fix
- `lib/screens/info_screen.dart` - New design, v1.2.0

### 📊 Compatibility Matrix

| Client A | Client B | Server | Status |
|----------|----------|--------|--------|
| v1.0.x   | v1.0.x   | v1.2.0 | ✅ Works |
| v1.0.x   | v1.2.0   | v1.2.0 | ✅ Works |
| v1.2.0   | v1.2.0   | v1.2.0 | ✅ Works |

---

## [1.1.0] - 2024-11

### 🔒 Security

- Encrypted nickname exchange between clients
- Removed `senderName` from ping messages
- Anonymous session tokens

### ✨ Added

- Waiting indicator during encryption setup
- Refresh functionality for sessions
- Improved reconnection handling

### 🐛 Fixed

- Session rejoin issues
- Crypto initialization race conditions

---

## [1.0.0] - 2024-11

### 🎉 Initial Release

- End-to-end encryption (X25519 + AES-256-GCM)
- Session-based chat system
- QR code friend adding
- Friend codes (`ECHO-XXXXXXXX`)
- Ping notifications
- Auto-expiring sessions (3 days)
- Dark theme UI
- iOS and Android support

---

## Version History

| Version | Date | Highlights |
|---------|------|------------|
| 1.2.0 | Dec 2024 | Zero-Knowledge, MITM Protection |
| 1.1.0 | Nov 2024 | Encrypted Nicknames |
| 1.0.0 | Nov 2024 | Initial Release |
