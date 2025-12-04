import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/echochat_theme.dart';
import '../services/ws_service.dart';

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

class ChatMessage {
  final String id;
  final String text;
  final String senderId;
  final String senderName;
  final DateTime timestamp;
  final bool isMe;
  final bool isSystem;

  ChatMessage({
    required this.id,
    required this.text,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
    required this.isMe,
    this.isSystem = false,
  });
}

class ChatScreen extends StatefulWidget {
  final String sessionId;
  final String sessionName;
  final EchoChatWebSocketService wsService;
  final String? passcode;

  const ChatScreen({
    super.key,
    required this.sessionId,
    required this.sessionName,
    required this.wsService,
    this.passcode,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _rateLimiter = RateLimiter();
  final Map<String, String> _participants = {};

  final List<ChatMessage> _messages = [];
  bool _cryptoInitialized = false;
  bool _isSending = false;
  String? _recipientId;
  String? _recipientName;
  bool _isAtBottom = true;
  bool _showScrollToBottom = false;

  // Typing indicator
  bool _isTyping = false;
  bool _peerIsTyping = false;
  Timer? _typingTimer;
  Timer? _peerTypingTimer;

  static const int _pingCooldownSeconds = 30;
  static const int _pingMaxPerWindow = 5;
  static const int _pingWindowSeconds = 300;
  static const int _messageCooldownSeconds = 1;
  static const int _messageMaxPerWindow = 30;
  static const int _messageWindowSeconds = 60;

  bool get _isWaiting => _participants.isEmpty;
  bool get _isE2EReady => _cryptoInitialized && !_isWaiting;
  bool get _canSend => _isE2EReady;

  String get _connectionStatus {
    if (_isWaiting) {
      return 'Waiting for participant...';
    } else if (!_cryptoInitialized) {
      return 'Setting up encryption...';
    } else {
      return 'E2E Encrypted';
    }
  }

  Color get _statusColor =>
      _isE2EReady ? EchoChatTheme.online : EchoChatTheme.warning;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupCallbacks();
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final hasText = _messageController.text.trim().isNotEmpty;
    if (hasText && !_isTyping && _canSend) {
      _sendTypingIndicator(true);
    }

    _typingTimer?.cancel();
    if (hasText) {
      _typingTimer = Timer(const Duration(seconds: 2), () {
        if (_isTyping) {
          _sendTypingIndicator(false);
        }
      });
    } else if (_isTyping) {
      _sendTypingIndicator(false);
    }

    setState(() {});
  }

  void _sendTypingIndicator(bool typing) {
    if (!_canSend) return;
    _isTyping = typing;
    widget.wsService.sendTypingIndicator(widget.sessionId, typing);
  }

  void _onScroll() {
    final isAtBottom = _scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 100;

    if (isAtBottom != _isAtBottom) {
      setState(() {
        _isAtBottom = isAtBottom;
        _showScrollToBottom = !isAtBottom && _messages.length > 10;
      });
    }
  }

  void _scrollToBottom({bool animated = true}) {
    if (!_scrollController.hasClients) return;

    if (animated) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }
  }

  void _setupCallbacks() {
    widget.wsService.onMessage = _handleMessage;
    widget.wsService.onParticipantJoined = _handleParticipantJoined;
    widget.wsService.onParticipantRejoined = _handleParticipantRejoined;
    widget.wsService.onParticipantLeft = _handleParticipantLeft;
    widget.wsService.onCryptoReady = _handleCryptoReady;
  }

  void _handleMessage(Map<String, dynamic> data) {
    if (!mounted) return;

    final text = data['text'] as String? ?? '';
    final fromToken = data['fromToken'] as String? ?? 'unknown';

    // Skip empty messages
    if (text.isEmpty) return;

    // Handle typing indicator
    if (text.startsWith('__TYPING__:')) {
      final isTyping = text == '__TYPING__:true';
      setState(() => _peerIsTyping = isTyping);

      _peerTypingTimer?.cancel();
      if (isTyping) {
        _peerTypingTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _peerIsTyping = false);
        });
      }
      return;
    }

    final senderName = _participants[fromToken] ?? 'Unknown';

    setState(() {
      _messages.add(ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        text: text,
        senderId: fromToken,
        senderName: senderName,
        timestamp: DateTime.now(),
        isMe: false,
      ));
    });

    // Clear peer typing when message received
    setState(() => _peerIsTyping = false);

    if (_isAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }

    HapticFeedback.lightImpact();
  }

  void _handleParticipantJoined(String token, String nickname, bool isOnline) {
    if (!mounted) return;

    _participants[token] = nickname;
    _recipientId = token;
    _recipientName = nickname;

    if (widget.wsService.cryptoService.isReady) {
      setState(() => _cryptoInitialized = true);
    }

    setState(() {
      _messages.add(ChatMessage(
        id: 'system_${DateTime.now().millisecondsSinceEpoch}',
        text: '$nickname joined',
        senderId: 'system',
        senderName: 'System',
        timestamp: DateTime.now(),
        isMe: false,
        isSystem: true,
      ));
    });
  }

  void _handleParticipantRejoined(String token, String nickname) {
    if (!mounted) return;

    _participants[token] = nickname;
    _recipientId = token;
    _recipientName = nickname;

    widget.wsService.cryptoService.resetSession();

    if (widget.wsService.cryptoService.isReady) {
      setState(() => _cryptoInitialized = true);
    }

    setState(() {
      _messages.add(ChatMessage(
        id: 'system_${DateTime.now().millisecondsSinceEpoch}',
        text: '$nickname reconnected',
        senderId: 'system',
        senderName: 'System',
        timestamp: DateTime.now(),
        isMe: false,
        isSystem: true,
      ));
    });
  }

  void _handleParticipantLeft(String token) {
    if (!mounted) return;

    final name = _participants[token] ?? 'Someone';
    _participants.remove(token);

    if (token == _recipientId) {
      _recipientId = null;
      _recipientName = null;
      _cryptoInitialized = false;
    }

    setState(() {
      _peerIsTyping = false;
      _messages.add(ChatMessage(
        id: 'system_${DateTime.now().millisecondsSinceEpoch}',
        text: '$name left',
        senderId: 'system',
        senderName: 'System',
        timestamp: DateTime.now(),
        isMe: false,
        isSystem: true,
      ));
    });
  }

  void _handleCryptoReady() {
    if (!mounted) return;
    setState(() => _cryptoInitialized = true);
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || !_canSend || _isSending) return;

    if (!_rateLimiter.canPerformAction(
      'message',
      cooldownSeconds: _messageCooldownSeconds,
      maxActionsPerWindow: _messageMaxPerWindow,
      windowSeconds: _messageWindowSeconds,
    )) {
      return;
    }

    setState(() => _isSending = true);
    _sendTypingIndicator(false);

    try {
      await widget.wsService.sendMessage(widget.sessionId, text);
      _rateLimiter.recordAction('message');

      final myToken = widget.wsService.getMyToken(widget.sessionId) ?? 'me';

      setState(() {
        _messages.add(ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          text: text,
          senderId: myToken,
          senderName: 'Me',
          timestamp: DateTime.now(),
          isMe: true,
        ));
        _messageController.clear();
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send: $e'),
            backgroundColor: EchoChatTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _showInviteSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: EchoChatTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceHighlight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),

            // Title
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: EchoChatTheme.primaryGradient,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.share, color: Colors.black, size: 24),
                ),
                const SizedBox(width: 16),
                const Text('Share Invite',
                    style: TextStyle(
                        color: EchoChatTheme.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 32),

            // Session ID Card
            _buildCodeCard(
              label: 'Session ID',
              code: widget.sessionId,
              icon: Icons.tag,
              onCopy: () {
                Clipboard.setData(ClipboardData(text: widget.sessionId));
                HapticFeedback.lightImpact();
                Navigator.pop(ctx);
                _showCopiedSnackbar('Session ID copied!');
              },
            ),

            const SizedBox(height: 16),

            // Passcode Card
            if (widget.passcode != null && widget.passcode!.isNotEmpty) ...[
              _buildCodeCard(
                label: 'Passcode',
                code: widget.passcode!,
                icon: Icons.lock_outline,
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: widget.passcode!));
                  HapticFeedback.lightImpact();
                  Navigator.pop(ctx);
                  _showCopiedSnackbar('Passcode copied!');
                },
              ),
              const SizedBox(height: 24),

              // Divider
              Row(
                children: [
                  Expanded(
                      child: Divider(color: EchoChatTheme.surfaceHighlight)),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('or share together',
                        style: TextStyle(
                            color: EchoChatTheme.textMuted, fontSize: 12)),
                  ),
                  Expanded(
                      child: Divider(color: EchoChatTheme.surfaceHighlight)),
                ],
              ),
              const SizedBox(height: 24),
            ],

            // Share Button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: () {
                  final message = widget.passcode != null
                      ? '''Join my EchoChat! 🔐

Session ID: ${widget.sessionId}
Passcode: ${widget.passcode}'''
                      : '''Join my EchoChat! 🔐

Session ID: ${widget.sessionId}''';

                  Clipboard.setData(ClipboardData(text: message));
                  HapticFeedback.mediumImpact();
                  Navigator.pop(ctx);
                  _showCopiedSnackbar('Invite message copied!');
                },
                icon: const Icon(Icons.copy_all, size: 20),
                label: const Text('Copy Full Invite',
                    style: TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: EchoChatTheme.primary,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),

            // Ping button if recipient exists
            if (_recipientId != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _pingRecipient();
                  },
                  icon: const Icon(Icons.notifications_active, size: 18),
                  label: Text('Ping $_recipientName'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: EchoChatTheme.primary,
                    side: const BorderSide(color: EchoChatTheme.primary),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],

            SizedBox(height: MediaQuery.of(ctx).padding.bottom + 8),
          ],
        ),
      ),
    );
  }

  Widget _buildCodeCard({
    required String label,
    required String code,
    required IconData icon,
    required VoidCallback onCopy,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: EchoChatTheme.surfaceLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: EchoChatTheme.surfaceHighlight),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: EchoChatTheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: EchoChatTheme.primary, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: EchoChatTheme.textMuted, fontSize: 12)),
                const SizedBox(height: 4),
                Text(code,
                    style: const TextStyle(
                      color: EchoChatTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      letterSpacing: 4,
                    )),
              ],
            ),
          ),
          IconButton(
            onPressed: onCopy,
            icon: const Icon(Icons.copy, color: EchoChatTheme.primary),
            style: IconButton.styleFrom(
              backgroundColor: EchoChatTheme.primary.withAlpha(20),
            ),
          ),
        ],
      ),
    );
  }

  void _showCopiedSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Text(message),
          ],
        ),
        backgroundColor: EchoChatTheme.online,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _pingRecipient() async {
    if (_recipientId == null) return;

    if (!_rateLimiter.canPerformAction(
      'ping',
      cooldownSeconds: _pingCooldownSeconds,
      maxActionsPerWindow: _pingMaxPerWindow,
      windowSeconds: _pingWindowSeconds,
    )) {
      final remaining = _rateLimiter.getRemainingCooldown(
        'ping',
        cooldownSeconds: _pingCooldownSeconds,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Wait ${remaining}s before pinging again'),
          backgroundColor: EchoChatTheme.warning,
        ),
      );
      return;
    }

    _rateLimiter.recordAction('ping');
    widget.wsService
        .sendPing(widget.sessionId, _recipientId!, passcode: widget.passcode);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check, color: Colors.white),
              SizedBox(width: 12),
              Text('Ping sent!'),
            ],
          ),
          backgroundColor: EchoChatTheme.online,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _confirmLeave() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Leave Chat?',
            style: TextStyle(color: EchoChatTheme.textPrimary)),
        content: const Text(
          'You can rejoin later using the same session code.',
          style: TextStyle(color: EchoChatTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: EchoChatTheme.error,
            ),
            child: const Text('Leave', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _messageController.removeListener(_onTextChanged);
    _messageController.dispose();
    _focusNode.dispose();
    _typingTimer?.cancel();
    _peerTypingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    return Scaffold(
      backgroundColor: EchoChatTheme.background,
      appBar: AppBar(
        backgroundColor: EchoChatTheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: _confirmLeave,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.sessionName,
                style: const TextStyle(
                    color: EchoChatTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _statusColor,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: _statusColor.withAlpha(100),
                        blurRadius: 4,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(_connectionStatus,
                    style: TextStyle(
                        color: _statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _showInviteSheet,
            icon: const Icon(Icons.share, color: EchoChatTheme.primary),
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState()
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        itemCount: _messages.length + (_peerIsTyping ? 1 : 0),
                        itemBuilder: (context, index) {
                          // Typing indicator at the end
                          if (_peerIsTyping && index == _messages.length) {
                            return _buildTypingIndicator();
                          }

                          final message = _messages[index];
                          final showDateHeader = index == 0 ||
                              !_isSameDay(_messages[index - 1].timestamp,
                                  message.timestamp);

                          return Column(
                            children: [
                              if (showDateHeader)
                                _buildDateHeader(message.timestamp),
                              _MessageBubble(
                                key: ValueKey(message.id),
                                message: message,
                                isFirstInGroup: _isFirstInGroup(index),
                                isLastInGroup: _isLastInGroup(index),
                              ),
                            ],
                          );
                        },
                      ),

                      // Scroll to bottom FAB
                      if (_showScrollToBottom)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: FloatingActionButton.small(
                            onPressed: () => _scrollToBottom(),
                            backgroundColor: EchoChatTheme.surface,
                            child: const Icon(Icons.keyboard_arrow_down,
                                color: EchoChatTheme.primary),
                          ),
                        ),
                    ],
                  ),
          ),

          // Input Bar - only show when participant joined
          if (_canSend)
            _buildInputBar(bottomPadding)
          else
            _buildWaitingBar(bottomPadding),
        ],
      ),
    );
  }

  Widget _buildWaitingBar(double bottomPadding) {
    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: bottomPadding + 16,
      ),
      decoration: BoxDecoration(
        color: EchoChatTheme.surface,
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: EchoChatTheme.primary.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.hourglass_empty,
                color: EchoChatTheme.primary,
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Waiting for participant...',
                    style: TextStyle(
                      color: EchoChatTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Share your invite to start chatting',
                    style: TextStyle(
                      color: EchoChatTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            ElevatedButton.icon(
              onPressed: _showInviteSheet,
              icon: const Icon(Icons.share, size: 16),
              label: const Text('Share'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ],
        ),
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
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceLight,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isWaiting ? Icons.people_outline : Icons.chat_bubble_outline,
                size: 56,
                color: EchoChatTheme.primary.withAlpha(180),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              _isWaiting ? 'No one here yet' : 'No messages yet',
              style: const TextStyle(
                color: EchoChatTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _isWaiting
                  ? 'Invite a friend to start your encrypted chat'
                  : 'Be the first to say hello!',
              style: const TextStyle(
                color: EchoChatTheme.textMuted,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: EchoChatTheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: EchoChatTheme.surfaceHighlight),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _TypingDots(),
                const SizedBox(width: 10),
                Text(
                  '${_recipientName ?? 'Someone'} is typing',
                  style: const TextStyle(
                    color: EchoChatTheme.textMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateHeader(DateTime date) {
    String text;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) {
      text = 'Today';
    } else if (messageDate == today.subtract(const Duration(days: 1))) {
      text = 'Yesterday';
    } else {
      text = '${date.day}/${date.month}/${date.year}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: EchoChatTheme.surfaceLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(text,
              style: const TextStyle(
                  color: EchoChatTheme.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }

  Widget _buildInputBar(double bottomPadding) {
    final hasText = _messageController.text.trim().isNotEmpty;

    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: bottomPadding + 12,
      ),
      color: EchoChatTheme.surface,
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _messageController,
                focusNode: _focusNode,
                style: const TextStyle(
                  color: EchoChatTheme.textPrimary,
                  fontSize: 16,
                ),
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: const TextStyle(color: EchoChatTheme.textMuted),
                  filled: true,
                  fillColor: EchoChatTheme.surfaceLight,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                ),
                textCapitalization: TextCapitalization.sentences,
                maxLines: 5,
                minLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: hasText && !_isSending ? _sendMessage : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: hasText && !_isSending
                      ? EchoChatTheme.primaryGradient
                      : null,
                  color: hasText && !_isSending
                      ? null
                      : EchoChatTheme.surfaceLight,
                  shape: BoxShape.circle,
                  boxShadow: hasText && !_isSending
                      ? [
                          BoxShadow(
                            color: EchoChatTheme.primary.withAlpha(80),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  _isSending ? Icons.hourglass_empty : Icons.send_rounded,
                  color: hasText && !_isSending
                      ? Colors.black
                      : EchoChatTheme.textMuted,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isFirstInGroup(int index) {
    if (index == 0) return true;
    final prev = _messages[index - 1];
    final curr = _messages[index];
    if (prev.isSystem || curr.isSystem) return true;
    if (prev.isMe != curr.isMe) return true;
    if (curr.timestamp.difference(prev.timestamp).inMinutes > 5) return true;
    return false;
  }

  bool _isLastInGroup(int index) {
    if (index == _messages.length - 1) return true;
    final curr = _messages[index];
    final next = _messages[index + 1];
    if (curr.isSystem || next.isSystem) return true;
    if (curr.isMe != next.isMe) return true;
    if (next.timestamp.difference(curr.timestamp).inMinutes > 5) return true;
    return false;
  }
}

// Animated Message Bubble
class _MessageBubble extends StatefulWidget {
  final ChatMessage message;
  final bool isFirstInGroup;
  final bool isLastInGroup;

  const _MessageBubble({
    super.key,
    required this.message,
    required this.isFirstInGroup,
    required this.isLastInGroup,
  });

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );

    _slideAnimation = Tween<double>(begin: 20, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    // Add listener to rebuild on animation changes
    _controller.addListener(() {
      if (mounted) setState(() {});
    });

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;

    if (message.isSystem) {
      return _buildSystemMessage();
    }

    return Transform.translate(
      offset: Offset(
        message.isMe ? _slideAnimation.value : -_slideAnimation.value,
        0,
      ),
      child: Transform.scale(
        scale: _scaleAnimation.value,
        alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: _buildBubble(),
      ),
    );
  }

  Widget _buildSystemMessage() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: EchoChatTheme.surfaceLight,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.message.text.contains('joined')
                    ? Icons.login
                    : widget.message.text.contains('left')
                        ? Icons.logout
                        : Icons.info_outline,
                size: 14,
                color: EchoChatTheme.textMuted,
              ),
              const SizedBox(width: 8),
              Text(
                widget.message.text,
                style: const TextStyle(
                  color: EchoChatTheme.textMuted,
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBubble() {
    final message = widget.message;
    final isFirst = widget.isFirstInGroup;
    final isLast = widget.isLastInGroup;

    final topPadding = isFirst ? 8.0 : 2.0;
    final bottomPadding = isLast ? 8.0 : 2.0;

    // Beautiful gradient for own messages
    final decoration = message.isMe
        ? BoxDecoration(
            gradient: LinearGradient(
              colors: [
                EchoChatTheme.primary,
                EchoChatTheme.primaryLight,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: Radius.circular(isFirst ? 20 : 6),
              bottomLeft: const Radius.circular(20),
              bottomRight: Radius.circular(isLast ? 20 : 6),
            ),
            boxShadow: [
              BoxShadow(
                color: EchoChatTheme.primary.withAlpha(40),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          )
        : BoxDecoration(
            color: EchoChatTheme.surface,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(isFirst ? 20 : 6),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(isLast ? 20 : 6),
              bottomRight: const Radius.circular(20),
            ),
            border: Border.all(
              color: EchoChatTheme.surfaceHighlight,
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(10),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          );

    return Padding(
      padding: EdgeInsets.only(
        top: topPadding,
        bottom: bottomPadding,
        left: message.isMe ? 48 : 0,
        right: message.isMe ? 0 : 48,
      ),
      child: Align(
        alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: decoration,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                message.text,
                style: TextStyle(
                  color:
                      message.isMe ? Colors.black : EchoChatTheme.textPrimary,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              if (isLast) ...[
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatTime(message.timestamp),
                      style: TextStyle(
                        color: message.isMe
                            ? Colors.black.withAlpha(130)
                            : EchoChatTheme.textMuted,
                        fontSize: 11,
                      ),
                    ),
                    if (message.isMe) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.done_all,
                        size: 14,
                        color: Colors.black.withAlpha(130),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

// Typing Dots Animation - Simple bouncing dots
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with TickerProviderStateMixin {
  late List<AnimationController> _controllers;
  late List<Animation<double>> _animations;

  @override
  void initState() {
    super.initState();

    _controllers = List.generate(3, (index) {
      return AnimationController(
        duration: const Duration(milliseconds: 400),
        vsync: this,
      );
    });

    _animations = _controllers.map((controller) {
      return Tween<double>(begin: 0, end: -8).animate(
        CurvedAnimation(parent: controller, curve: Curves.easeInOut),
      );
    }).toList();

    // Add listeners for rebuild
    for (var controller in _controllers) {
      controller.addListener(() {
        if (mounted) setState(() {});
      });
    }

    // Start animations with delays
    _startAnimations();
  }

  void _startAnimations() async {
    for (int i = 0; i < 3; i++) {
      await Future.delayed(Duration(milliseconds: i * 150));
      if (mounted) {
        _controllers[i].repeat(reverse: true);
      }
    }
  }

  @override
  void dispose() {
    for (var controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (index) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          child: Transform.translate(
            offset: Offset(0, _animations[index].value),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: EchoChatTheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      }),
    );
  }
}
