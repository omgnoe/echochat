<div align="center">

# 🔐 EchoChat

### Zero-Knowledge Encrypted Messenger

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Node.js](https://img.shields.io/badge/Node.js-18+-339933?logo=node.js)](https://nodejs.org)
[![License](https://img.shields.io/badge/License-Source%20Available-orange.svg)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-blue.svg)]()

**Secure. Private. Simple.**

A truly private messaging app with end-to-end encryption where even the server cannot read your messages.

</div>

> ⚠️ **Note:** This project uses a **Source Available License**. You can view, study, and contribute to the code, but redistribution and publishing derivative works is not permitted. See [LICENSE](LICENSE) for details.

---

## ✨ Features

### 🔒 Privacy First
- **End-to-End Encryption** - All messages encrypted using X25519 + AES-256-GCM
- **Zero-Knowledge Server** - Server only sees encrypted blobs, never plaintext
- **No Phone/Email Required** - Just pick a nickname and start chatting
- **Anonymous Sessions** - Random tokens instead of user tracking

### ⏱️ Ephemeral by Design
- **Auto-Expiring Sessions** - Chat sessions expire after 3 days
- **No Message Storage** - Messages exist only on your device
- **Session Cleanup** - Server automatically purges inactive sessions

### 👥 Easy Connection
- **QR Code Sharing** - Scan to add friends instantly
- **Friend Codes** - Share your unique `ECHO-XXXXXXXX` code
- **Ping Notifications** - Invite friends to chat with a single tap

### 📱 Modern Experience
- **Beautiful Dark UI** - Sleek, modern interface
- **Cross-Platform** - iOS, Android (Desktop coming soon)
- **Offline Message Queue** - Messages sync when connection restores

---

## 🏗️ Architecture

```
EchoChat/
├── echochat_app/          # Flutter mobile application
│   ├── lib/
│   │   ├── screens/       # UI screens
│   │   ├── services/      # Business logic & crypto
│   │   └── theme/         # App theming
│   └── ...
│
└── echochat-backend/      # Node.js WebSocket server
    ├── server.ts          # Main server (Zero-Knowledge)
    ├── session_manager.ts # Session lifecycle
    └── group_manager.ts   # Group chat support
```

### Security Model

```
┌─────────────┐                    ┌─────────────┐
│   Client A  │                    │   Client B  │
│             │                    │             │
│ ┌─────────┐ │    Encrypted       │ ┌─────────┐ │
│ │PrivKey A│ │◄──────────────────►│ │PrivKey B│ │
│ └─────────┘ │      Payload       │ └─────────┘ │
│      │      │         │          │      │      │
│      ▼      │         │          │      ▼      │
│ SharedSecret│         │          │ SharedSecret│
│ (X25519)    │         │          │ (X25519)    │
└─────────────┘         │          └─────────────┘
                        │
                        ▼
              ┌─────────────────┐
              │  EchoChat Server │
              │                  │
              │  ❌ No plaintext │
              │  ❌ No user data │
              │  ✅ Only tokens  │
              │  ✅ Encrypted    │
              │     payloads     │
              └─────────────────┘
```

---

## 🚀 Getting Started

### Prerequisites

- **Flutter SDK** 3.x or higher
- **Node.js** 18+ (for backend)
- **Dart** 3.x

### Backend Setup

```bash
cd echochat-backend

# Install dependencies
npm install

# Start the server
npm start

# Or with custom port
PORT=8080 npm start
```

The server runs on `ws://localhost:8080` by default.

### App Setup

```bash
cd echochat_app

# Get dependencies
flutter pub get

# Run on device/emulator
flutter run

# Build for release
flutter build apk --release      # Android
flutter build ios --release      # iOS
```

### Configuration

Update the WebSocket URL in `lib/services/ws_service.dart`:

```dart
EchoChatWebSocketService({
  this.url = 'wss://your-server.com',  // Your server URL
})
```

---

## 📦 Dependencies

### Flutter App
| Package | Purpose |
|---------|---------|
| `cryptography` | X25519 & AES-GCM encryption |
| `flutter_secure_storage` | Secure key storage |
| `web_socket_channel` | WebSocket communication |
| `qr_flutter` | QR code generation |
| `mobile_scanner` | QR code scanning |
| `flutter_local_notifications` | Push notifications |

### Backend
| Package | Purpose |
|---------|---------|
| `ws` | WebSocket server |
| `crypto` | Passcode hashing |

---

## 🔐 Cryptography Details

### Key Exchange
- **Algorithm**: X25519 (Curve25519 ECDH)
- **Key Size**: 256-bit
- Each user generates a permanent identity keypair stored securely on-device

### Message Encryption
- **Algorithm**: AES-256-GCM
- **Nonce**: 96-bit random per message
- **MAC**: 128-bit authentication tag

### Message Format
```json
{
  "ciphertext": "base64...",
  "nonce": "base64...",
  "mac": "base64..."
}
```

---

## 📱 Screenshots

<div align="center">

| Home | Chat | Friends |
|:----:|:----:|:-------:|
| Sessions list | E2E encrypted | QR & codes |

</div>

---

## 🛣️ Roadmap

- [x] End-to-end encryption
- [x] Session management
- [x] QR code friend adding
- [x] Ping notifications
- [ ] Group chats (encrypted)
- [ ] Desktop support
- [ ] File/image sharing
- [ ] Voice messages
- [ ] Push notifications (FCM/APNs)

---

## 🤝 Contributing

**We welcome contributions!** This project is open for collaboration to build a better private messenger together.

### How You Can Help

- 🐛 **Report Bugs** - Found something broken? Open an issue!
- 🔐 **Security Research** - Review the crypto implementation, find vulnerabilities
- 💡 **Feature Ideas** - Suggest improvements via issues
- 🛠️ **Code Contributions** - Submit pull requests for bug fixes and features
- 📖 **Documentation** - Help improve docs and translations

### Getting Started

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

### Guidelines

- Follow the existing code style
- Write meaningful commit messages
- Test your changes before submitting
- Be respectful in discussions

> 📜 By contributing, you agree to the terms in our [LICENSE](LICENSE).

---

## 📄 License

This project is **Source Available** - not Open Source.

### ✅ You CAN:
- View and study the code
- Run it privately for personal use
- Contribute improvements via pull requests
- Perform security research
- Fork for contributing back

### ❌ You CANNOT:
- Publish or distribute the app
- Create derivative products
- Use in commercial projects
- Remove attribution

See [LICENSE](LICENSE) for full terms.

---

## 🙏 Acknowledgments

- Built with [Flutter](https://flutter.dev)
- Cryptography powered by [cryptography](https://pub.dev/packages/cryptography)
- Inspired by Signal's encryption protocol

---

<div align="center">

**Made with ❤️ by TTA**

[Report Bug](../../issues) · [Request Feature](../../issues)

</div>