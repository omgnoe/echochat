import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/echochat_theme.dart';
import '../services/identity_service.dart';
import '../services/session_service.dart';
import '../services/ws_service.dart';
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
  late final EchoChatWebSocketService _wsService;
  bool _ownsWsService = false;

  List<Session> _sessions = [];
  bool _isConnected = false;
  bool _isRefreshing = false;
  String? _connectionError;
  Timer? _expiryTimer;

  String? _pendingJoinSessionId;
  String? _pendingJoinPasscode;

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
    _wsService.onPingRateLimited = _handlePingRateLimited;
  }

  Future<void> _initServices() async {
    if (_ownsWsService) {
      await _wsService.setIdentity(widget.identity);
      await _wsService.connect();
    }
    await _loadSessions();
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
    if (mounted) {
      setState(() {
        _isConnected = false;
      });
    }
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
    if (!mounted) return;

    // ZERO-KNOWLEDGE: Server doesn't send sender name
    // Look up session name from local storage
    String displayName = senderName;
    if (senderName.isEmpty) {
      // Find session name from local sessions
      final session =
          _sessions.where((s) => s.sessionId == sessionId).firstOrNull;
      displayName = session?.name ?? 'Session ${sessionId.substring(0, 6)}';
    }

    _showPingDialog(displayName, sessionId);
  }

  void _handlePingRateLimited(int? cooldownRemaining, String? reason) {
    if (!mounted) return;

    String message;
    if (reason == 'cooldown' && cooldownRemaining != null) {
      message =
          'Wait ${cooldownRemaining ~/ 1000} seconds before pinging again';
    } else {
      message = 'Too many pings. Please wait a few minutes.';
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.timer, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: EchoChatTheme.warning,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _handleSessionExpired(String sessionId) {
    _wsService.forgetSession(sessionId);
    _sessionService.handleSessionExpired(sessionId);
    _loadSessions();
  }

  void _handleSessionJoined(String sessionId) {
    if (_pendingJoinSessionId == sessionId.toUpperCase()) {
      _completePendingJoin();
    }
  }

  void _handleSessionNotFound(String sessionId) {
    _cancelPendingJoin();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(child: Text('Session "$sessionId" not found')),
            ],
          ),
          backgroundColor: EchoChatTheme.error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _handleSessionInvalidPasscode(String sessionId) {
    _cancelPendingJoin();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.lock_outline, color: Colors.white),
              SizedBox(width: 12),
              Expanded(child: Text('Invalid passcode. Please try again.')),
            ],
          ),
          backgroundColor: EchoChatTheme.error,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  void _handleSessionJoinFailed(String sessionId, String reason) {
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
  }

  Future<void> _completePendingJoin() async {
    if (_pendingJoinSessionId == null || _pendingJoinPasscode == null) return;

    final sessionId = _pendingJoinSessionId!;
    final passcode = _pendingJoinPasscode!;
    _cancelPendingJoin();

    // Use positional arguments for joinSession
    final session = await _sessionService.joinSession(sessionId, passcode);
    await _loadSessions();

    if (mounted) {
      _openChatWithSession(session);
    }
  }

  /// Show ping dialog - user needs to enter passcode to join
  void _showPingDialog(String senderName, String sessionId) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: EchoChatTheme.primaryGradient,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.notifications_active,
                  color: Colors.black, size: 24),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Text('Chat Invitation',
                  style: TextStyle(color: EchoChatTheme.textPrimary)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(
              text: TextSpan(
                style: const TextStyle(
                    color: EchoChatTheme.textSecondary, fontSize: 15),
                children: [
                  TextSpan(
                    text: senderName,
                    style: const TextStyle(
                      color: EchoChatTheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const TextSpan(text: ' wants to chat with you!'),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: EchoChatTheme.surfaceHighlight),
              ),
              child: Row(
                children: [
                  const Icon(Icons.tag, color: EchoChatTheme.primary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Session ID',
                            style: TextStyle(
                                color: EchoChatTheme.textMuted, fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(
                          sessionId,
                          style: const TextStyle(
                            color: EchoChatTheme.primary,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'You\'ll need to enter the passcode to join.',
              style: TextStyle(color: EchoChatTheme.textMuted, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Later'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(ctx).pop();
              _showPasscodeDialogForSession(sessionId);
            },
            icon: const Icon(Icons.login, size: 18),
            label: const Text('Enter Passcode'),
          ),
        ],
      ),
    );
  }

  /// Show passcode dialog for joining a specific session
  Future<void> _showPasscodeDialogForSession(String sessionId) async {
    final passcode = await _showPasscodeInputDialog();
    if (passcode == null || passcode.isEmpty) return;

    _pendingJoinSessionId = sessionId.toUpperCase();
    _pendingJoinPasscode = passcode.toUpperCase();

    _wsService.joinSession(sessionId, passcode: passcode);
  }

  /// Passcode input dialog
  Future<String?> _showPasscodeInputDialog() async {
    final controller = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: EchoChatTheme.primary.withAlpha(30),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.lock,
                  color: EchoChatTheme.primary, size: 22),
            ),
            const SizedBox(width: 12),
            const Text('Enter Passcode',
                style: TextStyle(color: EchoChatTheme.textPrimary)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter the 4-digit passcode to join this session.',
              style:
                  TextStyle(color: EchoChatTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: controller,
              autofocus: true,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: EchoChatTheme.textPrimary,
                fontSize: 32,
                fontFamily: 'monospace',
                letterSpacing: 12,
                fontWeight: FontWeight.bold,
              ),
              decoration: InputDecoration(
                hintText: '• • • •',
                hintStyle: TextStyle(
                  color: EchoChatTheme.textMuted.withAlpha(100),
                  fontSize: 32,
                  letterSpacing: 12,
                ),
                filled: true,
                fillColor: EchoChatTheme.surfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide:
                      const BorderSide(color: EchoChatTheme.primary, width: 2),
                ),
              ),
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                LengthLimitingTextInputFormatter(4),
              ],
              onChanged: (value) {
                if (value.length == 4) {
                  Navigator.of(ctx).pop(value.toUpperCase());
                }
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
              if (controller.text.length == 4) {
                Navigator.of(ctx).pop(controller.text.toUpperCase());
              }
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

  Future<void> _refreshSessions() async {
    if (_isRefreshing) return;

    setState(() => _isRefreshing = true);

    // Reconnect WebSocket if needed
    if (!_wsService.isConnected) {
      _wsService.reconnect();
    }

    await _loadSessions();

    // Small delay for visual feedback
    await Future.delayed(const Duration(milliseconds: 300));

    if (mounted) {
      setState(() => _isRefreshing = false);
    }
  }

  Future<void> _createSession() async {
    final name = await _showNameDialog('New Session', 'Session name');
    if (name == null || name.isEmpty) return;

    final session = await _sessionService.createSession(name);

    _wsService.createSession(session.sessionId, session.passcode ?? '');

    await _loadSessions();
    if (mounted) _openChatWithSession(session);
  }

  /// Join Session Dialog with separate Session ID and Passcode fields
  Future<void> _joinSession() async {
    final result = await _showJoinDialog();
    if (result == null) return;

    _pendingJoinSessionId = result.sessionId.toUpperCase();
    _pendingJoinPasscode = result.passcode.toUpperCase();

    _wsService.joinSession(result.sessionId, passcode: result.passcode);
  }

  /// Join Dialog with separate fields
  Future<JoinSessionResult?> _showJoinDialog() async {
    final sessionController = TextEditingController();
    final passcodeController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    return showDialog<JoinSessionResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: EchoChatTheme.primary.withAlpha(30),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.login,
                  color: EchoChatTheme.primary, size: 22),
            ),
            const SizedBox(width: 12),
            const Text('Join Session',
                style: TextStyle(color: EchoChatTheme.textPrimary)),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter the session details shared with you.',
                style:
                    TextStyle(color: EchoChatTheme.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 24),

              // Session ID Field
              const Text('Session ID',
                  style: TextStyle(
                      color: EchoChatTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextFormField(
                controller: sessionController,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: EchoChatTheme.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 22,
                  letterSpacing: 4,
                  fontWeight: FontWeight.bold,
                ),
                decoration: InputDecoration(
                  hintText: 'XXXXXX',
                  hintStyle: TextStyle(
                    color: EchoChatTheme.textMuted.withAlpha(100),
                    fontFamily: 'monospace',
                    fontSize: 22,
                    letterSpacing: 4,
                  ),
                  prefixIcon:
                      const Icon(Icons.tag, color: EchoChatTheme.primary),
                  filled: true,
                  fillColor: EchoChatTheme.surfaceLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                        color: EchoChatTheme.primary, width: 2),
                  ),
                ),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                  LengthLimitingTextInputFormatter(6),
                ],
                validator: (value) {
                  if (value == null || value.length != 6) {
                    return 'Session ID must be 6 characters';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 20),

              // Passcode Field
              const Text('Passcode',
                  style: TextStyle(
                      color: EchoChatTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextFormField(
                controller: passcodeController,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: EchoChatTheme.textPrimary,
                  fontFamily: 'monospace',
                  fontSize: 28,
                  letterSpacing: 10,
                  fontWeight: FontWeight.bold,
                ),
                decoration: InputDecoration(
                  hintText: 'XXXX',
                  hintStyle: TextStyle(
                    color: EchoChatTheme.textMuted.withAlpha(100),
                    fontFamily: 'monospace',
                    fontSize: 28,
                    letterSpacing: 10,
                  ),
                  prefixIcon: const Icon(Icons.lock_outline,
                      color: EchoChatTheme.primary),
                  filled: true,
                  fillColor: EchoChatTheme.surfaceLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                        color: EchoChatTheme.primary, width: 2),
                  ),
                ),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                  LengthLimitingTextInputFormatter(4),
                ],
                validator: (value) {
                  if (value == null || value.length != 4) {
                    return 'Passcode must be 4 characters';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 16),

              // Help text
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: EchoChatTheme.primary.withAlpha(15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: EchoChatTheme.primary.withAlpha(180), size: 18),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Ask your friend for both the Session ID and Passcode.',
                        style: TextStyle(
                            color: EchoChatTheme.textMuted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(ctx).pop(JoinSessionResult(
                  sessionId: sessionController.text.toUpperCase(),
                  passcode: passcodeController.text.toUpperCase(),
                ));
              }
            },
            icon: const Icon(Icons.login, size: 18),
            label: const Text('Join'),
          ),
        ],
      ),
    );
  }

  void _openChatWithSession(Session session) {
    final passcode = session.passcode ?? '';

    _wsService.joinSession(session.sessionId, passcode: passcode);

    Navigator.of(context)
        .push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        sessionId: session.sessionId,
        sessionName: session.name,
        wsService: _wsService,
        passcode: passcode,
      ),
    ))
        .then((_) {
      _wsService.leaveSession(session.sessionId);
      _loadSessions();
    });
  }

  void _openChat(Session session) async {
    String passcodeToUse = session.passcode ?? '';

    // If no passcode stored, ask for it
    if (passcodeToUse.isEmpty) {
      final enteredPasscode = await _showPasscodeInputDialog();
      if (enteredPasscode == null || enteredPasscode.isEmpty) return;

      passcodeToUse = enteredPasscode;

      // Re-save the session by joining again (this updates the passcode)
      await _sessionService.joinSession(session.sessionId, passcodeToUse);
      await _loadSessions();
    }

    _wsService.joinSession(session.sessionId, passcode: passcodeToUse);

    if (!mounted) return;

    Navigator.of(context)
        .push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        sessionId: session.sessionId,
        sessionName: session.name,
        wsService: _wsService,
        passcode: passcodeToUse,
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Session?',
            style: TextStyle(color: EchoChatTheme.textPrimary)),
        content: Text(
          'Session "${session.name}" will be removed from your device.',
          style: const TextStyle(color: EchoChatTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style:
                ElevatedButton.styleFrom(backgroundColor: EchoChatTheme.error),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      _wsService.forgetSession(session.sessionId);
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title,
            style: const TextStyle(color: EchoChatTheme.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: EchoChatTheme.textPrimary),
          decoration: InputDecoration(
            labelText: label,
            filled: true,
            fillColor: EchoChatTheme.surfaceLight,
          ),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  String _formatExpiry(DateTime? expiry) {
    if (expiry == null) return 'No expiry';

    final now = DateTime.now();
    final diff = expiry.difference(now);

    if (diff.isNegative) return 'Expired';
    if (diff.inDays > 0) return '${diff.inDays}d left';
    if (diff.inHours > 0) return '${diff.inHours}h left';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m left';
    return 'Expiring soon';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EchoChatTheme.background,
      appBar: AppBar(
        backgroundColor: EchoChatTheme.surface,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: EchoChatTheme.primaryGradient,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.lock, color: Colors.black, size: 20),
            ),
            const SizedBox(width: 12),
            const Text('EchoChat',
                style: TextStyle(
                    color: EchoChatTheme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          // Refresh Button
          IconButton(
            onPressed: _isRefreshing ? null : _refreshSessions,
            icon: _isRefreshing
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: EchoChatTheme.primary,
                    ),
                  )
                : const Icon(Icons.refresh, color: EchoChatTheme.primary),
            tooltip: 'Refresh sessions',
          ),
          // Online Status
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _isConnected
                  ? EchoChatTheme.online.withAlpha(30)
                  : EchoChatTheme.error.withAlpha(30),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _isConnected
                        ? EchoChatTheme.online
                        : EchoChatTheme.error,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (_isConnected
                                ? EchoChatTheme.online
                                : EchoChatTheme.error)
                            .withAlpha(150),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _isConnected ? 'Online' : 'Offline',
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
          ),
        ],
      ),
      body: Column(
        children: [
          // Connection Error Banner
          if (_connectionError != null)
            Material(
              color: EchoChatTheme.error.withAlpha(30),
              child: InkWell(
                onTap: () => _wsService.reconnect(),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi_off,
                          color: EchoChatTheme.error, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _connectionError!,
                          style: const TextStyle(
                              color: EchoChatTheme.error, fontSize: 13),
                        ),
                      ),
                      const Text('Tap to retry',
                          style: TextStyle(
                              color: EchoChatTheme.error,
                              fontSize: 12,
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ),

          // User Info Card
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  EchoChatTheme.primary.withAlpha(20),
                  EchoChatTheme.primaryLight.withAlpha(10),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: EchoChatTheme.primary.withAlpha(50), width: 1),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: EchoChatTheme.primaryGradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      widget.identity.nickname.substring(0, 1).toUpperCase(),
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.identity.nickname,
                        style: const TextStyle(
                          color: EchoChatTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.identity.oderId,
                        style: const TextStyle(
                          color: EchoChatTheme.textMuted,
                          fontSize: 11,
                          fontFamily: 'monospace',
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _showUserIdSheet(),
                  icon: const Icon(Icons.qr_code, color: EchoChatTheme.primary),
                ),
              ],
            ),
          ),

          // Action Buttons
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    icon: Icons.add_circle_outline,
                    label: 'Create',
                    onTap: _createSession,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ActionButton(
                    icon: Icons.login,
                    label: 'Join',
                    onTap: _joinSession,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Sessions Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text('Your Sessions',
                    style: TextStyle(
                        color: EchoChatTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${_sessions.length} active',
                    style: const TextStyle(
                        color: EchoChatTheme.textMuted, fontSize: 12)),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Sessions List with Pull-to-Refresh
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshSessions,
              color: EchoChatTheme.primary,
              child: _sessions.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.4,
                          child: _buildEmptyState(),
                        ),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _sessions.length,
                      itemBuilder: (context, index) {
                        final session = _sessions[index];
                        return _buildSessionCard(session);
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceLight,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.chat_bubble_outline,
                size: 48,
                color: EchoChatTheme.primary.withAlpha(150),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'No sessions yet',
              style: TextStyle(
                color: EchoChatTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create a session to start chatting\nor join an existing one.',
              style: TextStyle(color: EchoChatTheme.textMuted, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionCard(Session session) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: EchoChatTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: EchoChatTheme.surfaceHighlight),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openChat(session),
          onLongPress: () => _deleteSession(session),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: EchoChatTheme.surfaceLight,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.chat,
                      color: EchoChatTheme.primary, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.name,
                        style: const TextStyle(
                          color: EchoChatTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: EchoChatTheme.primary.withAlpha(20),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              session.sessionId,
                              style: const TextStyle(
                                color: EchoChatTheme.primary,
                                fontSize: 11,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.timer_outlined,
                              size: 12, color: EchoChatTheme.textMuted),
                          const SizedBox(width: 4),
                          Text(
                            _formatExpiry(session.expiresAt),
                            style: const TextStyle(
                              color: EchoChatTheme.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: EchoChatTheme.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showUserIdSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: EchoChatTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
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
            const SizedBox(height: 24),
            const Text('Your EchoChat ID',
                style: TextStyle(
                    color: EchoChatTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Share this ID with friends so they can ping you.',
              style: TextStyle(color: EchoChatTheme.textMuted, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.identity.oderId,
                      style: const TextStyle(
                        color: EchoChatTheme.primary,
                        fontSize: 16,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: widget.identity.oderId));
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('ID copied!'),
                          backgroundColor: EchoChatTheme.online,
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy, color: EchoChatTheme.primary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: EchoChatTheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            border: Border.all(color: EchoChatTheme.surfaceHighlight),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: EchoChatTheme.primary, size: 22),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  color: EchoChatTheme.textPrimary,
                  fontSize: 15,
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

class JoinSessionResult {
  final String sessionId;
  final String passcode;

  JoinSessionResult({required this.sessionId, required this.passcode});
}
