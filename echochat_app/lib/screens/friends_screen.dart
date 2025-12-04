import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/echochat_theme.dart';
import '../services/identity_service.dart';
import '../services/friends_service.dart';
import '../services/session_service.dart';
import '../services/ws_service.dart';
import 'chat_screen.dart';

class RateLimiter {
  final Map<String, DateTime> _lastActions = {};
  final Map<String, int> _actionCounts = {};
  final Map<String, DateTime> _windowStarts = {};

  bool canPerformAction(
    String actionType, {
    int cooldownSeconds = 5,
    int maxActionsPerWindow = 10,
    int windowSeconds = 60,
  }) {
    final now = DateTime.now();

    final lastAction = _lastActions[actionType];
    if (lastAction != null) {
      if (now.difference(lastAction).inSeconds < cooldownSeconds) {
        return false;
      }
    }

    final windowStart = _windowStarts[actionType];
    if (windowStart == null ||
        now.difference(windowStart).inSeconds >= windowSeconds) {
      _windowStarts[actionType] = now;
      _actionCounts[actionType] = 0;
    }

    if ((_actionCounts[actionType] ?? 0) >= maxActionsPerWindow) {
      return false;
    }

    return true;
  }

  void recordAction(String actionType) {
    _lastActions[actionType] = DateTime.now();
    _actionCounts[actionType] = (_actionCounts[actionType] ?? 0) + 1;
  }

  int getCooldownRemaining(String actionType, {int cooldownSeconds = 5}) {
    final lastAction = _lastActions[actionType];
    if (lastAction == null) return 0;
    final remaining =
        cooldownSeconds - DateTime.now().difference(lastAction).inSeconds;
    return remaining > 0 ? remaining : 0;
  }
}

class FriendsScreen extends StatefulWidget {
  final Identity identity;
  final EchoChatWebSocketService wsService;
  final void Function(String sessionId)? onStartChat;

  const FriendsScreen({
    super.key,
    required this.identity,
    required this.wsService,
    this.onStartChat,
  });

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final _friendsService = FriendsService();
  final _sessionService = SessionService();
  final _rateLimiter = RateLimiter();
  List<Friend> _friends = [];
  bool _isStartingChat = false;
  String? _myPublicKeyBase64;

  static const int _pingCooldownSeconds = 60;
  static const int _pingMaxPerWindow = 1;
  static const int _pingWindowSeconds = 60;

  @override
  void initState() {
    super.initState();
    _loadFriends();
    _loadMyPublicKey();
  }

  Future<void> _loadFriends() async {
    final friends = await _friendsService.loadFriends();
    if (mounted) setState(() => _friends = friends);
  }

  Future<void> _loadMyPublicKey() async {
    try {
      final publicKey = await widget.wsService.cryptoService.getPublicKey();
      if (publicKey != null && mounted) {
        setState(() {
          _myPublicKeyBase64 = base64Encode(publicKey.bytes);
        });
      }
    } catch (e) {
      debugPrint('[Friends] Could not load public key: $e');
    }
  }

  void _showMyQrCode() {
    // Generate QR with public key for MITM protection
    final qrData = _friendsService.generateQrData(
      oderId: widget.identity.oderId,
      nickname: widget.identity.nickname,
      publicKeyBase64: _myPublicKeyBase64,
    );

    // Calculate fingerprint for display
    final fingerprint = _myPublicKeyBase64 != null
        ? FriendsService.computeKeyFingerprint(_myPublicKeyBase64!)
        : null;

    showModalBottomSheet(
      context: context,
      backgroundColor: EchoChatTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: EchoChatTheme.surfaceHighlight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              const Text('My QR Code',
                  style: TextStyle(
                      color: EchoChatTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Let others scan this code',
                  style: TextStyle(
                      color: EchoChatTheme.textSecondary, fontSize: 14)),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Color(0xFF1A1A2E),
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Show fingerprint for verification
              if (fingerprint != null) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: EchoChatTheme.surfaceLight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: EchoChatTheme.surfaceHighlight),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.fingerprint,
                              size: 16, color: EchoChatTheme.online),
                          const SizedBox(width: 8),
                          const Text('Security Fingerprint',
                              style: TextStyle(
                                  color: EchoChatTheme.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(fingerprint,
                          style: const TextStyle(
                              color: EchoChatTheme.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              letterSpacing: 2)),
                      const SizedBox(height: 4),
                      const Text(
                          'Compare this with your friend to verify identity',
                          style: TextStyle(
                              color: EchoChatTheme.textMuted, fontSize: 11),
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(widget.identity.nickname,
                  style: const TextStyle(
                      color: EchoChatTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: EchoChatTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.identity.oderId,
                        style: const TextStyle(
                            color: EchoChatTheme.primary,
                            fontSize: 14,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(
                            ClipboardData(text: widget.identity.oderId));
                        HapticFeedback.lightImpact();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Friend code copied!'),
                              duration: Duration(seconds: 1)),
                        );
                      },
                      child: const Icon(Icons.copy,
                          size: 16, color: EchoChatTheme.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: _QrActionButton(
                      icon: Icons.share,
                      label: 'Share Code',
                      onTap: () {
                        Clipboard.setData(
                            ClipboardData(text: widget.identity.oderId));
                        HapticFeedback.mediumImpact();
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Friend code copied!')));
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _QrActionButton(
                      icon: Icons.qr_code_scanner,
                      label: 'Scan QR',
                      onTap: () {
                        Navigator.pop(ctx);
                        _scanQrCode();
                      },
                      isPrimary: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _scanQrCode() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => _QrScannerScreen(
          onScanned: (qrData) {
            Navigator.of(ctx).pop();
            _handleScannedQr(qrData);
          },
          myOderId: widget.identity.oderId,
        ),
      ),
    );
  }

  void _addByFriendCode() {
    final controller = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: EchoChatTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceHighlight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Add by Friend Code',
                style: TextStyle(
                    color: EchoChatTheme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Enter your friend\'s ECHO code',
                style: TextStyle(
                    color: EchoChatTheme.textSecondary, fontSize: 14)),
            const SizedBox(height: 24),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [_UpperCaseTextFormatter()],
              style: const TextStyle(
                  color: EchoChatTheme.textPrimary,
                  fontSize: 18,
                  fontFamily: 'monospace',
                  letterSpacing: 2),
              decoration: InputDecoration(
                hintText: 'ECHO-XXXXXXXX',
                hintStyle: TextStyle(
                    color: EchoChatTheme.textMuted.withAlpha(100),
                    fontSize: 18,
                    fontFamily: 'monospace'),
                filled: true,
                fillColor: EchoChatTheme.surfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                prefixIcon: const Icon(Icons.person_add_outlined,
                    color: EchoChatTheme.primary),
              ),
              onSubmitted: (value) {
                if (_friendsService.isValidFriendCode(value)) {
                  Navigator.pop(ctx);
                  _addFriendByCode(value.toUpperCase());
                }
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  final code = controller.text.toUpperCase();
                  if (_friendsService.isValidFriendCode(code)) {
                    Navigator.pop(ctx);
                    _addFriendByCode(code);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Invalid friend code format'),
                          backgroundColor: EchoChatTheme.error),
                    );
                  }
                },
                child: const Text('Add Friend'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addFriendByCode(String code) async {
    if (code == widget.identity.oderId) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That\'s your own code!'),
          backgroundColor: EchoChatTheme.warning));
      return;
    }

    final existing = await _friendsService.findFriend(code);
    if (existing != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${existing.nickname} is already your friend'),
          backgroundColor: EchoChatTheme.primary));
      return;
    }

    final nickname = await _askForNickname(code);
    if (nickname == null || nickname.isEmpty) return;

    final friend = Friend(
      oderId: code,
      nickname: nickname,
      addedAt: DateTime.now(),
    );

    await _friendsService.addFriend(friend);
    await _loadFriends();

    if (!mounted) return;
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$nickname added! 🎉'),
        backgroundColor: EchoChatTheme.online));
  }

  Future<String?> _askForNickname(String oderId) async {
    final controller = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        title: const Text('Give a nickname',
            style: TextStyle(color: EchoChatTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('For $oderId',
                style: const TextStyle(
                    color: EchoChatTheme.textMuted,
                    fontSize: 12,
                    fontFamily: 'monospace')),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: EchoChatTheme.textPrimary),
              decoration: InputDecoration(
                hintText: 'e.g. Alice',
                hintStyle:
                    TextStyle(color: EchoChatTheme.textMuted.withAlpha(150)),
                filled: true,
                fillColor: EchoChatTheme.surfaceLight,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none),
              ),
              onSubmitted: (value) {
                if (value.isNotEmpty) Navigator.of(ctx).pop(value);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                Navigator.of(ctx).pop(controller.text);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleScannedQr(String qrData) async {
    // Use parseQrDataFull to get key verification info
    final qrResult = _friendsService.parseQrDataFull(qrData);
    if (qrResult == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Invalid QR code'),
          backgroundColor: EchoChatTheme.error));
      return;
    }

    final friend = qrResult.friend;

    if (friend.oderId == widget.identity.oderId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That\'s yourself!'),
          backgroundColor: EchoChatTheme.warning));
      return;
    }

    final existing = await _friendsService.findFriend(friend.oderId);
    if (existing != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${friend.nickname} is already your friend'),
          backgroundColor: EchoChatTheme.primary));
      return;
    }

    // Show verification dialog if QR contains key hash
    if (qrResult.hasKeyVerification && qrResult.fingerprint != null) {
      final verified = await _showKeyVerificationDialog(
        friend.nickname,
        qrResult.fingerprint!,
      );
      if (verified == true) {
        friend.isVerified = true;
        friend.publicKeyHash = qrResult.keyHash;
      }
    }

    await _friendsService.addFriend(friend);
    await _loadFriends();

    if (!mounted) return;
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${friend.nickname} added! 🎉'),
        backgroundColor: EchoChatTheme.online));
  }

  /// Shows dialog to verify key fingerprint
  Future<bool?> _showKeyVerificationDialog(
      String nickname, String fingerprint) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        title: Row(
          children: [
            Icon(Icons.verified_user, color: EchoChatTheme.online, size: 24),
            const SizedBox(width: 8),
            const Text('Verify Identity',
                style: TextStyle(color: EchoChatTheme.textPrimary)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$nickname\'s security fingerprint:',
                style: const TextStyle(
                    color: EchoChatTheme.textSecondary, fontSize: 14)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: EchoChatTheme.surfaceHighlight),
              ),
              child: Text(fingerprint,
                  style: const TextStyle(
                      color: EchoChatTheme.primary,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      letterSpacing: 3)),
            ),
            const SizedBox(height: 16),
            const Text(
              'Ask your friend to show their fingerprint and compare.\n'
              'If they match, tap "Verified" for extra security.',
              style: TextStyle(color: EchoChatTheme.textMuted, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Skip'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Verified'),
            style: ElevatedButton.styleFrom(
              backgroundColor: EchoChatTheme.online,
            ),
          ),
        ],
      ),
    );
  }

  /// Shows fingerprint for an existing friend
  void _showFriendFingerprint(Friend friend) {
    final fingerprint = friend.publicKeyHash != null
        ? '${friend.publicKeyHash!.substring(0, 4)}-${friend.publicKeyHash!.substring(4, 8)}-${friend.publicKeyHash!.substring(8, 12)}'
        : null;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        title: Row(
          children: [
            Icon(
              friend.isVerified ? Icons.verified : Icons.fingerprint,
              color: friend.isVerified
                  ? EchoChatTheme.online
                  : EchoChatTheme.primary,
              size: 24,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(friend.nickname,
                  style: const TextStyle(color: EchoChatTheme.textPrimary)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (fingerprint != null) ...[
              const Text('Security Fingerprint',
                  style: TextStyle(
                      color: EchoChatTheme.textSecondary, fontSize: 12)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: EchoChatTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(fingerprint,
                    style: const TextStyle(
                        color: EchoChatTheme.primary,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        letterSpacing: 2)),
              ),
              const SizedBox(height: 12),
              if (friend.isVerified)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: EchoChatTheme.online.withAlpha(30),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle,
                          size: 16, color: EchoChatTheme.online),
                      SizedBox(width: 6),
                      Text('Verified',
                          style: TextStyle(
                              color: EchoChatTheme.online,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                )
              else
                TextButton.icon(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    final verified = await _showKeyVerificationDialog(
                      friend.nickname,
                      fingerprint,
                    );
                    if (verified == true) {
                      await _friendsService.markFriendVerified(friend.oderId);
                      await _loadFriends();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${friend.nickname} verified! ✓'),
                            backgroundColor: EchoChatTheme.online,
                          ),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.verified_user, size: 16),
                  label: const Text('Mark as Verified'),
                ),
            ] else ...[
              Icon(Icons.warning_amber,
                  size: 48, color: EchoChatTheme.warning.withAlpha(150)),
              const SizedBox(height: 12),
              const Text(
                'No security fingerprint available.\n'
                'Start a chat to establish encryption.',
                style: TextStyle(color: EchoChatTheme.textMuted, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeFriend(Friend friend) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove friend?'),
        content: Text('${friend.nickname} will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style:
                ElevatedButton.styleFrom(backgroundColor: EchoChatTheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _friendsService.removeFriend(friend.oderId);
    await _loadFriends();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Friend removed')));
  }

  Future<void> _startChatWithFriend(Friend friend) async {
    setState(() => _isStartingChat = true);

    try {
      // Create a new session for this chat
      final session =
          await _sessionService.createSession('Chat with ${friend.nickname}');

      // Update session with recipient info
      await _sessionService.updateSessionRecipient(
        session.sessionId,
        friend.oderId,
        friend.nickname,
      );

      // Join the session on WebSocket (2 positional args)
      widget.wsService.createSession(session.sessionId, session.passcode);

      // Send ping to friend
      if (_rateLimiter.canPerformAction(
        'ping_${friend.oderId}',
        cooldownSeconds: _pingCooldownSeconds,
        maxActionsPerWindow: _pingMaxPerWindow,
        windowSeconds: _pingWindowSeconds,
      )) {
        widget.wsService.sendPing(
          session.sessionId,
          friend.oderId,
          passcode: session.passcode,
        );
        _rateLimiter.recordAction('ping_${friend.oderId}');
      }

      if (!mounted) return;

      // Callback or navigate
      if (widget.onStartChat != null) {
        widget.onStartChat!(session.sessionId);
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (ctx) => ChatScreen(
              sessionId: session.sessionId,
              sessionName: 'Chat with ${friend.nickname}',
              wsService: widget.wsService,
              passcode: session.passcode,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Friends] Error starting chat: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to start chat'),
            backgroundColor: EchoChatTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isStartingChat = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EchoChatTheme.background,
      appBar: AppBar(
        backgroundColor: EchoChatTheme.surface,
        title: const Text('Friends',
            style: TextStyle(color: EchoChatTheme.textPrimary)),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_outlined),
            color: EchoChatTheme.primary,
            tooltip: 'Add friend by code',
            onPressed: _addByFriendCode,
          ),
        ],
      ),
      body: Column(
        children: [
          // My QR Card
          Container(
            margin: const EdgeInsets.all(16),
            child: Card(
              child: InkWell(
                onTap: _showMyQrCode,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: EchoChatTheme.primary.withAlpha(30),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.qr_code,
                            color: EchoChatTheme.primary, size: 28),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('My QR Code',
                                style: TextStyle(
                                    color: EchoChatTheme.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text(widget.identity.oderId,
                                style: const TextStyle(
                                    color: EchoChatTheme.textMuted,
                                    fontSize: 12,
                                    fontFamily: 'monospace')),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          color: EchoChatTheme.textMuted),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Text('Your Friends',
                  style: TextStyle(
                      color: EchoChatTheme.textSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: EchoChatTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(10)),
                  child: Text('${_friends.length}',
                      style: const TextStyle(
                          color: EchoChatTheme.textMuted, fontSize: 12))),
            ]),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _friends.isEmpty
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.people_outline,
                        size: 64,
                        color: EchoChatTheme.textMuted.withAlpha(100)),
                    const SizedBox(height: 16),
                    const Text('No friends yet',
                        style: TextStyle(
                            color: EchoChatTheme.textSecondary, fontSize: 16)),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                        onPressed: _addByFriendCode,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add by Friend Code')),
                  ]))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _friends.length,
                    itemBuilder: (context, index) =>
                        _buildFriendCard(_friends[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendCard(Friend friend) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                  color: EchoChatTheme.primary.withAlpha(38),
                  borderRadius: BorderRadius.circular(12)),
              child: Center(
                  child: Text(friend.nickname.substring(0, 1).toUpperCase(),
                      style: const TextStyle(
                          color: EchoChatTheme.primary,
                          fontSize: 20,
                          fontWeight: FontWeight.bold))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(friend.nickname,
                          style: const TextStyle(
                              color: EchoChatTheme.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w500)),
                      // Show verified badge
                      if (friend.isVerified) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.verified,
                            size: 16, color: EchoChatTheme.online)
                      ] else if (friend.hasPublicKey) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.lock,
                            size: 14, color: EchoChatTheme.primary)
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(friend.oderId,
                        style: const TextStyle(
                            color: EchoChatTheme.textMuted,
                            fontSize: 12,
                            fontFamily: 'monospace')),
                  ]),
            ),
            // Security button
            IconButton(
              icon: Icon(
                friend.isVerified ? Icons.verified_user : Icons.fingerprint,
                size: 20,
              ),
              color: friend.isVerified
                  ? EchoChatTheme.online
                  : EchoChatTheme.textMuted,
              tooltip: 'Security info',
              onPressed: () => _showFriendFingerprint(friend),
            ),
            _isStartingChat
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: EchoChatTheme.primary),
                  )
                : IconButton(
                    icon: const Icon(Icons.chat_bubble_outline),
                    color: EchoChatTheme.primary,
                    onPressed: () => _startChatWithFriend(friend)),
            IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: EchoChatTheme.textMuted,
                onPressed: () => _removeFriend(friend)),
          ],
        ),
      ),
    );
  }
}

class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
        text: newValue.text.toUpperCase(), selection: newValue.selection);
  }
}

class _QrActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;

  const _QrActionButton(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.isPrimary = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isPrimary ? EchoChatTheme.primary : EchoChatTheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
              border: isPrimary
                  ? null
                  : Border.all(color: EchoChatTheme.surfaceHighlight),
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Icon(icon,
                color: isPrimary ? Colors.black : EchoChatTheme.primary,
                size: 28),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                    color: isPrimary ? Colors.black : EchoChatTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class _QrScannerScreen extends StatefulWidget {
  final void Function(String qrData) onScanned;
  final String myOderId;

  const _QrScannerScreen({required this.onScanned, required this.myOderId});

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  MobileScannerController? _controller;
  bool _hasScanned = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal, facing: CameraFacing.back);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title:
            const Text('Scan QR Code', style: TextStyle(color: Colors.white)),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_hasScanned) return;
              final barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                final value = barcode.rawValue;
                if (value != null && value.isNotEmpty) {
                  _hasScanned = true;
                  HapticFeedback.mediumImpact();
                  widget.onScanned(value);
                  break;
                }
              }
            },
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: EchoChatTheme.primary, width: 3),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Point camera at a QR code',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
