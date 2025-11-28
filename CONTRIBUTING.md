# Contributing to EchoChat

First off, thanks for taking the time to contribute! 🎉

EchoChat is a collaborative project aimed at building a truly private messenger. Your contributions help make secure communication accessible to everyone.

## 📜 Important: License Agreement

By contributing to this project, you agree that:

1. Your contributions will be licensed under the same [Source Available License](LICENSE)
2. You grant TTA the right to use your contributions in future versions
3. You have the right to submit the contribution

## 🐛 Reporting Bugs

Found a bug? Please open an issue with:

- **Title**: Clear, concise description
- **Environment**: OS, Flutter version, device
- **Steps to Reproduce**: How can we recreate the bug?
- **Expected Behavior**: What should happen?
- **Actual Behavior**: What actually happens?
- **Screenshots**: If applicable

## 🔐 Security Vulnerabilities

**Please do NOT open public issues for security vulnerabilities!**

Instead:
1. See [SECURITY.md](SECURITY.md) for our security policy
2. Report via GitHub's private security reporting
3. Or contact us directly

We take security seriously and will respond promptly.

## 💡 Feature Requests

Have an idea? Open an issue with:

- **Problem**: What problem does this solve?
- **Solution**: How would you implement it?
- **Alternatives**: Other approaches considered?

## 🛠️ Pull Requests

### Before You Start

1. Check existing issues/PRs to avoid duplicates
2. For large changes, open an issue first to discuss
3. Fork the repo and create your branch from `main`

### Code Style

**Flutter/Dart:**
- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart)
- Use `dart format` before committing
- Run `flutter analyze` - no warnings allowed

**TypeScript (Backend):**
- Use TypeScript strict mode
- Follow existing code patterns
- Add types, avoid `any`

### Commit Messages

Use clear, descriptive commit messages:

```
✨ Add group chat encryption
🐛 Fix message ordering bug
📝 Update API documentation
🔒 Improve key derivation
♻️ Refactor WebSocket handler
```

### PR Process

1. Update documentation if needed
2. Test your changes thoroughly
3. Ensure CI passes (if configured)
4. Request review from maintainers
5. Address feedback promptly

## 🏗️ Development Setup

### Flutter App

```bash
cd echochat_app
flutter pub get
flutter run
```

### Backend

```bash
cd echochat-backend
npm install
npm run dev
```

### Testing

```bash
# Flutter tests
flutter test

# Backend tests
npm test
```

## 📂 Project Structure

```
EchoChat/
├── echochat_app/           # Flutter mobile app
│   ├── lib/
│   │   ├── screens/        # UI screens
│   │   ├── services/       # Business logic
│   │   └── theme/          # Theming
│   └── test/               # Tests
│
└── echochat-backend/       # Node.js server
    ├── server.ts           # Main server
    └── *.ts                # Modules
```

## 🎯 Areas We Need Help

- [ ] **Testing**: Unit tests, integration tests
- [ ] **Security Audit**: Review crypto implementation
- [ ] **Documentation**: Code comments, guides
- [ ] **Accessibility**: Screen reader support
- [ ] **Localization**: Translations
- [ ] **Desktop**: macOS/Windows/Linux support

## 💬 Questions?

- Open a GitHub Discussion
- Tag your issue with `question`

Thank you for helping make EchoChat better! 🔐
