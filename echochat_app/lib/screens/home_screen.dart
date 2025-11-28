import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/echochat_theme.dart';
import '../services/identity_service.dart';
import '../services/session_service.dart';
import '../services/ws_service.dart';
import '../services/notification_service.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  final Identity identity;
  final EchoChatWebSocketService? wsService;

  const HomeScreen({
    super.key,
    required this.identity,
    this.wsService,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _sessionService = SessionService();
  final _notificationService = NotificationService();
  late final EchoChatWebSocketService _wsService;
  bool _ownsWsService = false;

  List<Session> _sessions = [];
  bool _isConnected = false;
  String? _connectionError;
  Timer? _expiryTimer;

  String? _pendingJoinSessionId;
  String? _pendingJoinPasscode;
  bool _isPingJoin = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.wsService != null) {
      _wsService = widget.wsService!;
    } else {
      _wsService = EchoChatWebSocketService();
      _ownsWsService = true;
    }

    _setupWebSocketCallbacks();
    _initServices();
    _expiryTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _setupWebSocketCallbacks() {
    _wsService.onPingReceived = _handlePingReceived;
    _wsService.onSessionExpired = _handleSessionExpired;
    _wsService.onConnected = _handleConnected;
    _wsService.onDisconnected = _handleDisconnected;
    _wsService.onConnectionError = _handleConnectionError;

    _wsService.onSessionJoined = _handleSessionJoined;
    _wsService.onSessionNotFound = _handleSessionNotFound;
    _wsService.onSessionInvalidPasscode = _handleSessionInvalidPasscode;
    _wsService.onSessionJoinFailed = _handleSessionJoinFailed;
  }

  Future<void> _initServices() async {
    if (_ownsWsService) {
      // WICHTIG: setIdentity muss vor connect() aufgerufen werden
      await _wsService.setIdentity(widget.identity);
      await _wsService.connect();
    }
    await _loadSessions();

    if (mounted) {
      setState(() => _isConnected = _wsService.isConnected);
    }
  }

  void _handleConnected() {
    if (mounted) {
      setState(() {
        _isConnected = true;
        _connectionError = null;
      });
    }
  }

  void _handleDisconnected() {
    if (mounted) setState(() => _isConnected = false);
  }

  void _handleConnectionError(String error) {
    if (mounted) {
      setState(() {
        _isConnected = false;
        _connectionError = error;
      });
    }
  }

  void _handlePingReceived(
      String senderName, String sessionId, String? passcodeHash) {
    _notificationService.showPingNotification(senderName, sessionId);
    if (mounted) _showPingDialog(senderName, sessionId, passcodeHash);
  }

  void _handleSessionExpired(String sessionId) {
    _sessionService.handleSessionExpired(sessionId);
    _loadSessions();
  }

  void _handleSessionJoined(String sessionId) {
    debugPrint('[HomeScreen] Session joined successfully: $sessionId');

    if (_pendingJoinSessionId == sessionId.toUpperCase()) {
      _completePendingJoin();
    }
  }

  void _handleSessionNotFound(String sessionId) {
    debugPrint('[HomeScreen] Session not found: $sessionId');
    _cancelPendingJoin();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Session "$sessionId" does not exist'),
              ),
            ],
          ),
          backgroundColor: EchoChatTheme.error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _handleSessionInvalidPasscode(String sessionId) {
    debugPrint('[HomeScreen] Invalid passcode for session: $sessionId');
    _cancelPendingJoin();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.lock_outline, color: Colors.white),
              SizedBox(width: 12),
              Expanded(
                child: Text('Invalid passcode. Please check and try again.'),
              ),
            ],
          ),
          backgroundColor: EchoChatTheme.error,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  void _handleSessionJoinFailed(String sessionId, String reason) {
    debugPrint('[HomeScreen] Session join failed: $sessionId - $reason');
    _cancelPendingJoin();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not join session: $reason'),
          backgroundColor: EchoChatTheme.error,
        ),
      );
    }
  }

  void _cancelPendingJoin() {
    _pendingJoinSessionId = null;
    _pendingJoinPasscode = null;
    _isPingJoin = false;
  }

  Future<void> _completePendingJoin() async {
    if (_pendingJoinSessionId == null) return;

    final sessionId = _pendingJoinSessionId!;
    final passcode = _pendingJoinPasscode ?? '';
    final wasPingJoin = _isPingJoin;
    _cancelPendingJoin();

    // Bei Ping-Join haben wir keinen Klartext-Passcode
    final session = await _sessionService.joinSession(
      sessionId,
      wasPingJoin ? '' : passcode,
    );
    await _loadSessions();

    if (mounted) {
      // Bei Ping-Join sind wir bereits gejoint, also nicht nochmal joinen!
      _openChat(session, alreadyJoined: wasPingJoin);
    }
  }

  void _showPingDialog(
      String senderName, String sessionId, String? passcodeHash) {
    debugPrint('');
    debugPrint(
        '╔══════════════════════════════════════════════════════════════╗');
    debugPrint(
        '║  📩 PING DIALOG OPENED (NEW VERSION)                         ║');
    debugPrint('║  Sender: $senderName');
    debugPrint('║  Session: $sessionId');
    debugPrint('║  PasscodeHash: ${passcodeHash ?? "NULL"}');
    debugPrint(
        '╚══════════════════════════════════════════════════════════════╝');
    debugPrint('');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        title: const Text('Invitation',
            style: TextStyle(color: EchoChatTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$senderName wants to chat!',
              style: const TextStyle(color: EchoChatTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.meeting_room,
                      color: EchoChatTheme.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    sessionId,
                    style: const TextStyle(
                      color: EchoChatTheme.primary,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              debugPrint('');
              debugPrint(
                  '╔══════════════════════════════════════════════════════════════╗');
              debugPrint(
                  '║  🚀 JOIN BUTTON PRESSED - CALLING _joinSessionFromPing       ║');
              debugPrint(
                  '╚══════════════════════════════════════════════════════════════╝');
              debugPrint('');
              Navigator.of(ctx).pop();
              // WICHTIG: Verwende joinSessionFromPing für bereits gehashte Passcodes!
              _joinSessionFromPing(sessionId, passcodeHash);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_wsService.isConnected) _wsService.connect();
      _loadSessions();
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsWsService) {
      _wsService.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSessions() async {
    final sessions = await _sessionService.loadSessions();
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _createSession() async {
    final name = await _showNameDialog('New Session', 'Session name');
    if (name == null || name.isEmpty) return;

    final session = await _sessionService.createSession(name);

    _wsService.createSession(session.sessionId, session.passcode);

    await _loadSessions();
    if (mounted) _openChat(session);
  }

  Future<void> _joinSession() async {
    final joinCode = await _showJoinSessionDialog();
    if (joinCode == null || joinCode.isEmpty) return;

    final parsed = SessionService.parseJoinCode(joinCode);

    if (parsed.passcode == null) {
      final passcode = await _showPasscodeDialog(parsed.sessionId);
      if (passcode == null || passcode.isEmpty) return;

      await _joinSessionWithPasscode(parsed.sessionId, passcode);
    } else {
      await _joinSessionWithPasscode(parsed.sessionId, parsed.passcode!);
    }
  }

  /// Joined eine Session mit Klartext-Passcode (für manuelle Joins)
  Future<void> _joinSessionWithPasscode(
      String sessionId, String passcode) async {
    _pendingJoinSessionId = sessionId.toUpperCase();
    _pendingJoinPasscode = passcode.toUpperCase();
    _isPingJoin = false;

    _wsService.joinSession(sessionId, passcode: passcode);
  }

  /// Joined eine Session von einem Ping (passcodeHash bereits gehasht!)
  Future<void> _joinSessionFromPing(
      String sessionId, String? passcodeHash) async {
    _pendingJoinSessionId = sessionId.toUpperCase();
    _pendingJoinPasscode = ''; // Wir haben keinen Klartext-Passcode
    _isPingJoin = true;

    debugPrint('[HomeScreen] ========================================');
    debugPrint('[HomeScreen] 🔔 JOINING FROM PING (using pre-hashed passcode)');
    debugPrint('[HomeScreen] Session: $sessionId');
    debugPrint('[HomeScreen] PasscodeHash: ${passcodeHash ?? "NULL"}');
    debugPrint('[HomeScreen] ========================================');

    // Verwende joinSessionWithHash da der Hash bereits vom Sender gehasht wurde
    _wsService.joinSessionWithHash(sessionId, passcodeHash: passcodeHash);
  }

  void _openChat(Session session, {bool alreadyJoined = false}) {
    // Nur joinen wenn wir nicht schon gejoint sind (z.B. von Ping)
    if (!alreadyJoined) {
      _wsService.joinSession(session.sessionId, passcode: session.passcode);
    } else {
      debugPrint(
          '[HomeScreen] Skipping joinSession - already joined from ping');
    }

    Navigator.of(context)
        .push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        sessionId: session.sessionId,
        sessionName: session.name,
        wsService: _wsService,
        passcode: session.passcode,
      ),
    ))
        .then((_) {
      _wsService.leaveSession(session.sessionId);
      _loadSessions();
    });
  }

  Future<void> _deleteSession(Session session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        title: const Text('Delete session?',
            style: TextStyle(color: EchoChatTheme.textPrimary)),
        content: Text(
          'Session "${session.name}" will be deleted.',
          style: const TextStyle(color: EchoChatTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete',
                style: TextStyle(color: EchoChatTheme.error)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _sessionService.deleteSession(session.sessionId);
      await _loadSessions();
    }
  }

  Future<String?> _showNameDialog(String title, String label) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        title: Text(title,
            style: const TextStyle(color: EchoChatTheme.textPrimary)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: EchoChatTheme.textPrimary),
          decoration: InputDecoration(labelText: label),
          autofocus: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Create')),
        ],
      ),
    );
  }

  Future<String?> _showJoinSessionDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        title: const Text('Join Session',
            style: TextStyle(color: EchoChatTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the Session Code',
              style:
                  TextStyle(color: EchoChatTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: const TextStyle(
                color: EchoChatTheme.textPrimary,
                fontFamily: 'monospace',
                fontSize: 18,
                letterSpacing: 2,
              ),
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'XXXXXX-YYYY',
                hintStyle: TextStyle(
                  color: EchoChatTheme.textMuted.withAlpha(100),
                  fontFamily: 'monospace',
                ),
                prefixIcon: const Icon(Icons.meeting_room,
                    color: EchoChatTheme.primary),
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]')),
                LengthLimitingTextInputFormatter(11),
              ],
              autofocus: true,
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
            const SizedBox(height: 12),
            Text(
              'Format: Session-ID (6 chars) + Passcode (4 chars)\nExample: ABC123-WXYZ',
              style: TextStyle(
                color: EchoChatTheme.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Join')),
        ],
      ),
    );
  }

  Future<String?> _showPasscodeDialog(String sessionId) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        title: const Text('Enter Passcode',
            style: TextStyle(color: EchoChatTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Session: $sessionId',
              style: const TextStyle(
                color: EchoChatTheme.primary,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: const TextStyle(
                color: EchoChatTheme.textPrimary,
                fontFamily: 'monospace',
                fontSize: 24,
                letterSpacing: 8,
              ),
              textCapitalization: TextCapitalization.characters,
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: 'XXXX',
                hintStyle: TextStyle(
                  color: EchoChatTheme.textMuted.withAlpha(100),
                  fontFamily: 'monospace',
                ),
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                LengthLimitingTextInputFormatter(4),
              ],
              autofocus: true,
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Join')),
        ],
      ),
    );
  }

  String _formatRemainingTime(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    return '${duration.inMinutes}m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EchoChatTheme.background,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    _isConnected ? EchoChatTheme.online : EchoChatTheme.error,
              ),
            ),
            const SizedBox(width: 8),
            const Text('EchoChat'),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: EchoChatTheme.primary.withAlpha(50),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'ZK',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: EchoChatTheme.primary,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _wsService.reconnect();
              _loadSessions();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_connectionError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: EchoChatTheme.error.withAlpha(38),
              child: Row(
                children: [
                  const Icon(Icons.wifi_off,
                      color: EchoChatTheme.error, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _connectionError!,
                      style: const TextStyle(color: EchoChatTheme.error),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _wsService.reconnect(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    EchoChatTheme.primary.withAlpha(30),
                    EchoChatTheme.primaryLight.withAlpha(20),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: EchoChatTheme.primary.withAlpha(50),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.person,
                      color: EchoChatTheme.primary,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.identity.nickname,
                          style: const TextStyle(
                            color: EchoChatTheme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _isConnected
                                    ? EchoChatTheme.online
                                    : EchoChatTheme.error,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _isConnected ? 'Connected' : 'Not connected',
                              style: TextStyle(
                                color: _isConnected
                                    ? EchoChatTheme.online
                                    : EchoChatTheme.error,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () {
                            Clipboard.setData(
                                ClipboardData(text: widget.identity.oderId));
                            HapticFeedback.lightImpact();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Friend Code copied!'),
                                backgroundColor: EchoChatTheme.online,
                              ),
                            );
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.identity.oderId,
                                style: const TextStyle(
                                  color: EchoChatTheme.primary,
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.copy,
                                  size: 12, color: EchoChatTheme.primary),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                    child: _ActionButton(
                        icon: Icons.add_circle_outline,
                        label: 'New Session',
                        onTap: _createSession)),
                const SizedBox(width: 12),
                Expanded(
                    child: _ActionButton(
                        icon: Icons.login, label: 'Join', onTap: _joinSession)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  'Your Sessions',
                  style: TextStyle(
                    color: EchoChatTheme.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text('${_sessions.length}',
                    style: const TextStyle(
                        color: EchoChatTheme.textMuted, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _sessions.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chat_bubble_outline,
                            size: 64,
                            color: EchoChatTheme.textMuted.withAlpha(100)),
                        const SizedBox(height: 16),
                        const Text('No sessions',
                            style: TextStyle(color: EchoChatTheme.textMuted)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _sessions.length,
                    itemBuilder: (context, index) =>
                        _buildSessionCard(_sessions[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCard(Session session) {
    final isExpiring = session.isExpiringSoon;
    final remaining = session.remainingTime;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _openChat(session),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isExpiring
                      ? EchoChatTheme.warning.withAlpha(38)
                      : EchoChatTheme.primary.withAlpha(38),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    session.name.substring(0, 1).toUpperCase(),
                    style: TextStyle(
                      color: isExpiring
                          ? EchoChatTheme.warning
                          : EchoChatTheme.primary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.recipientNickname ?? session.name,
                      style: const TextStyle(
                        color: EchoChatTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          session.isCreator
                              ? '${session.sessionId}-${session.passcode}'
                              : session.sessionId,
                          style: const TextStyle(
                            color: EchoChatTheme.textMuted,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (session.isCreator) ...[
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(ClipboardData(
                                text: session.fullJoinCode,
                              ));
                              HapticFeedback.lightImpact();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Join code copied!'),
                                  backgroundColor: EchoChatTheme.online,
                                ),
                              );
                            },
                            child: const Icon(
                              Icons.copy,
                              size: 12,
                              color: EchoChatTheme.primary,
                            ),
                          ),
                        ],
                        if (isExpiring && remaining != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: EchoChatTheme.warning.withAlpha(38),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.timer,
                                    size: 10, color: EchoChatTheme.warning),
                                const SizedBox(width: 2),
                                Text(
                                  _formatRemainingTime(remaining),
                                  style: const TextStyle(
                                    color: EchoChatTheme.warning,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (session.unreadCount > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: EchoChatTheme.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${session.unreadCount}',
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: EchoChatTheme.textMuted,
                onPressed: () => _deleteSession(session),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: EchoChatTheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border.all(color: EchoChatTheme.surfaceHighlight),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Icon(icon, color: EchoChatTheme.primary, size: 28),
              const SizedBox(height: 8),
              Text(
                label,
                style: const TextStyle(
                  color: EchoChatTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
