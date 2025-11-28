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

  int getRemainingCooldown(String actionType, {int cooldownSeconds = 5}) {
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

  static const int _pingCooldownSeconds = 60;
  static const int _pingMaxPerWindow = 1;
  static const int _pingWindowSeconds = 60;

  static const int _inviteCooldownSeconds = 10;
  static const int _inviteMaxPerWindow = 10;
  static const int _inviteWindowSeconds = 60;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  Future<void> _loadFriends() async {
    final friends = await _friendsService.loadFriends();
    if (mounted) setState(() => _friends = friends);
  }

  void _showMyQrCode() {
    final qrData = _friendsService.generateQrData(
      oderId: widget.identity.oderId,
      nickname: widget.identity.nickname,
    );

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
                    borderRadius: BorderRadius.circular(16)),
                child: QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white),
              ),
              const SizedBox(height: 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                    color: EchoChatTheme.surfaceLight,
                    borderRadius: BorderRadius.circular(8)),
                child: Column(
                  children: [
                    Text(widget.identity.nickname,
                        style: const TextStyle(
                            color: EchoChatTheme.textPrimary,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.identity.oderId,
                            style: const TextStyle(
                                color: EchoChatTheme.primary,
                                fontSize: 16,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(
                                ClipboardData(text: widget.identity.oderId));
                            HapticFeedback.lightImpact();
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Friend Code copied!'),
                                    backgroundColor: EchoChatTheme.online));
                          },
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                                color: EchoChatTheme.primary.withAlpha(38),
                                borderRadius: BorderRadius.circular(6)),
                            child: const Icon(Icons.copy,
                                size: 16, color: EchoChatTheme.primary),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openScanner() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _QrScannerScreen(
          onScanned: _handleScannedQr, myOderId: widget.identity.oderId),
    ));
  }

  void _addByFriendCode() {
    final controller = TextEditingController();
    final nicknameController = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: EchoChatTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
                child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: EchoChatTheme.surfaceHighlight,
                        borderRadius: BorderRadius.circular(2)))),
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
            const Text('Friend Code',
                style: TextStyle(
                    color: EchoChatTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              style: const TextStyle(
                  color: EchoChatTheme.textPrimary,
                  fontSize: 18,
                  fontFamily: 'monospace',
                  letterSpacing: 1.5),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'ECHO-XXXXXXXX',
                hintStyle: TextStyle(
                    color: EchoChatTheme.textMuted.withAlpha(100),
                    fontFamily: 'monospace'),
                prefixIcon: const Icon(Icons.tag, color: EchoChatTheme.primary),
              ),
              inputFormatters: [
                _UpperCaseTextFormatter(),
                FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9\-]')),
                LengthLimitingTextInputFormatter(13),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Nickname (optional)',
                style: TextStyle(
                    color: EchoChatTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TextField(
              controller: nicknameController,
              style: const TextStyle(color: EchoChatTheme.textPrimary),
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  hintText: 'Friend\'s name',
                  prefixIcon: Icon(Icons.person_outline,
                      color: EchoChatTheme.textMuted)),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final friendCode = controller.text.trim().toUpperCase();
                  if (friendCode.isEmpty) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Please enter a Friend Code'),
                        backgroundColor: EchoChatTheme.error));
                    return;
                  }
                  final regex = RegExp(r'^ECHO-[A-Z0-9]{8}$');
                  if (!regex.hasMatch(friendCode)) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Invalid format. Use: ECHO-XXXXXXXX'),
                        backgroundColor: EchoChatTheme.error));
                    return;
                  }
                  if (friendCode == widget.identity.oderId) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('That\'s your own code!'),
                        backgroundColor: EchoChatTheme.warning));
                    return;
                  }
                  final existing = await _friendsService.findFriend(friendCode);
                  if (existing != null) {
                    if (mounted) {
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                              '${existing.nickname} is already your friend'),
                          backgroundColor: EchoChatTheme.primary));
                    }
                    return;
                  }
                  final nickname = nicknameController.text.trim().isNotEmpty
                      ? nicknameController.text.trim()
                      : 'Friend ${friendCode.substring(5, 9)}';
                  final friend = Friend(
                      oderId: friendCode,
                      nickname: nickname,
                      publicKeyHash: null,
                      addedAt: DateTime.now());
                  await _friendsService.addFriend(friend);
                  await _loadFriends();
                  if (mounted) {
                    Navigator.of(ctx).pop();
                    HapticFeedback.mediumImpact();
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('$nickname added! 🎉'),
                        backgroundColor: EchoChatTheme.online));
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

  Future<void> _handleScannedQr(String qrData) async {
    final friend = _friendsService.parseQrData(qrData);
    if (friend == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Invalid QR code'),
          backgroundColor: EchoChatTheme.error));
      return;
    }
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
    await _friendsService.addFriend(friend);
    await _loadFriends();
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${friend.nickname} added! 🎉'),
        backgroundColor: EchoChatTheme.online));
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
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove',
                  style: TextStyle(color: EchoChatTheme.error))),
        ],
      ),
    );
    if (confirm == true) {
      await _friendsService.removeFriend(friend.oderId);
      await _loadFriends();
    }
  }

  Future<void> _startChatWithFriend(Friend friend) async {
    if (_isStartingChat) return;

    final inviteKey = 'invite_${friend.oderId}';
    if (!_rateLimiter.canPerformAction(
      inviteKey,
      cooldownSeconds: _inviteCooldownSeconds,
      maxActionsPerWindow: _inviteMaxPerWindow,
      windowSeconds: _inviteWindowSeconds,
    )) {
      final remaining = _rateLimiter.getRemainingCooldown(
        inviteKey,
        cooldownSeconds: _inviteCooldownSeconds,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Please wait $remaining seconds'),
        backgroundColor: EchoChatTheme.warning,
      ));
      return;
    }

    setState(() => _isStartingChat = true);

    try {
      final session =
          await _sessionService.createSession('Chat with ${friend.nickname}');
      await _sessionService.updateSessionRecipient(
          session.sessionId, friend.oderId, friend.nickname);

      _rateLimiter.recordAction(inviteKey);

      if (!mounted) return;

      widget.wsService.createSession(session.sessionId, session.passcode);
      widget.wsService
          .joinSession(session.sessionId, passcode: session.passcode);
      _sendPingWithRateLimit(session.sessionId, session.passcode, friend);

      if (widget.onStartChat != null) {
        widget.onStartChat!(session.sessionId);
      } else {
        _navigateToChatScreen(session);
      }

      HapticFeedback.mediumImpact();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Invitation sent to ${friend.nickname}'),
        backgroundColor: EchoChatTheme.online,
      ));
    } catch (e) {
      debugPrint('[FriendsScreen] Error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed: $e'),
        backgroundColor: EchoChatTheme.error,
      ));
    } finally {
      if (mounted) setState(() => _isStartingChat = false);
    }
  }

  void _sendPingWithRateLimit(
      String sessionId, String passcode, Friend friend) {
    final pingKey = 'ping_${friend.oderId}';
    if (!_rateLimiter.canPerformAction(
      pingKey,
      cooldownSeconds: _pingCooldownSeconds,
      maxActionsPerWindow: _pingMaxPerWindow,
      windowSeconds: _pingWindowSeconds,
    )) {
      return;
    }
    widget.wsService.sendPing(sessionId, friend.oderId, passcode: passcode);
    _rateLimiter.recordAction(pingKey);
  }

  void _navigateToChatScreen(Session session) {
    Navigator.of(context)
        .push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        sessionId: session.sessionId,
        sessionName: session.recipientNickname ?? session.name,
        wsService: widget.wsService,
        passcode: session.passcode,
      ),
    ))
        .then((_) {
      widget.wsService.leaveSession(session.sessionId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EchoChatTheme.background,
      appBar: AppBar(title: const Text('Friends'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _loadFriends)
      ]),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                    child: _QrActionButton(
                        icon: Icons.qr_code,
                        label: 'My Code',
                        onTap: _showMyQrCode)),
                const SizedBox(width: 12),
                Expanded(
                    child: _QrActionButton(
                        icon: Icons.qr_code_scanner,
                        label: 'Scan',
                        onTap: _openScanner,
                        isPrimary: true)),
                const SizedBox(width: 12),
                Expanded(
                    child: _QrActionButton(
                        icon: Icons.add,
                        label: 'Add Code',
                        onTap: _addByFriendCode)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: EchoChatTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: EchoChatTheme.surfaceHighlight)),
              child: Row(
                children: [
                  Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: EchoChatTheme.primary.withAlpha(38),
                          borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.tag,
                          color: EchoChatTheme.primary, size: 20)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('My Friend Code',
                              style: TextStyle(
                                  color: EchoChatTheme.textSecondary,
                                  fontSize: 12)),
                          const SizedBox(height: 2),
                          Text(widget.identity.oderId,
                              style: const TextStyle(
                                  color: EchoChatTheme.textPrimary,
                                  fontSize: 16,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold)),
                        ]),
                  ),
                  IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      color: EchoChatTheme.primary,
                      onPressed: () {
                        Clipboard.setData(
                            ClipboardData(text: widget.identity.oderId));
                        HapticFeedback.lightImpact();
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Friend Code copied!'),
                                backgroundColor: EchoChatTheme.online,
                                duration: Duration(seconds: 2)));
                      }),
                ],
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
                      if (friend.hasPublicKey) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.lock,
                            size: 14, color: EchoChatTheme.online)
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

  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        try {
          final json = jsonDecode(value);
          if (json is Map && json.containsKey('id') && json.containsKey('n')) {
            _hasScanned = true;
            HapticFeedback.heavyImpact();
            Navigator.of(context).pop();
            widget.onScanned(value);
            return;
          }
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('Scan QR Code'),
          leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop())),
      body: Stack(children: [
        if (_controller != null)
          MobileScanner(controller: _controller!, onDetect: _onDetect),
        Center(
            child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                    border: Border.all(color: EchoChatTheme.primary, width: 3),
                    borderRadius: BorderRadius.circular(20)))),
      ]),
    );
  }
}
