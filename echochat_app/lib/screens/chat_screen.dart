import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/echochat_theme.dart';
import '../services/ws_service.dart';
import '../services/session_service.dart';

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

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _sessionService = SessionService();
  final _focusNode = FocusNode();
  final _rateLimiter = RateLimiter();
  final Map<String, String> _participants = {};

  List<ChatMessage> _messages = [];
  bool _cryptoInitialized = false;
  bool _isSending = false;
  String? _recipientId;
  String? _recipientName;

  static const int _pingCooldownSeconds = 60;
  static const int _pingMaxPerWindow = 1;
  static const int _pingWindowSeconds = 60;
  static const int _messageCooldownSeconds = 1;
  static const int _messageMaxPerWindow = 30;
  static const int _messageWindowSeconds = 60;

  // ===========================================
  // STATUS GETTERS - WICHTIG FÜR UI
  // ===========================================

  /// Ob wir noch auf jemanden warten (kein Participant)
  bool get _isWaiting => _participants.isEmpty;

  /// E2E ist nur ready wenn Crypto UND Participant vorhanden
  bool get _isE2EReady => _cryptoInitialized && !_isWaiting;

  /// Kann der User Nachrichten senden?
  bool get _canSend => _isE2EReady;

  /// Connection Status Text
  String get _connectionStatus {
    if (_isWaiting) {
      return 'Waiting for participant...';
    } else if (!_cryptoInitialized) {
      return 'Setting up encryption...';
    } else {
      return 'E2E Encrypted ✓';
    }
  }

  /// Status Farbe - ORANGE wenn wartend/nicht ready, GRÜN nur wenn alles ready
  Color get _statusColor =>
      _isE2EReady ? EchoChatTheme.online : EchoChatTheme.warning;

  /// Status Icon - Sanduhr wenn wartend, Schloss wenn ready
  IconData get _statusIcon => _isE2EReady ? Icons.lock : Icons.hourglass_empty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupWebSocket();
    _loadStoredMessages();
    _loadExistingState();
    _sessionService.clearUnreadCount(widget.sessionId);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _setupWebSocket() {
    widget.wsService.onMessage = _handleMessage;
    widget.wsService.onParticipantJoined = _handleParticipantJoined;
    widget.wsService.onParticipantLeft = _handleParticipantLeft;
    widget.wsService.onCryptoReady = _handleCryptoReady;
  }

  /// Lädt den bestehenden Status (Participants, Crypto) beim Öffnen des Screens
  void _loadExistingState() {
    debugPrint('[ChatScreen] Loading existing state...');

    // Prüfe ob Crypto bereits ready ist
    if (widget.wsService.cryptoService.isReady) {
      debugPrint('[ChatScreen] Crypto already ready!');
      setState(() => _cryptoInitialized = true);
    }

    // Lade bestehende Participants
    final existingParticipants =
        widget.wsService.getSessionParticipants(widget.sessionId);
    debugPrint(
        '[ChatScreen] Existing participants: ${existingParticipants.length}');

    for (final entry in existingParticipants.entries) {
      final token = entry.key;
      final info = entry.value;

      // Überspringe eigenen Token
      if (token == widget.wsService.currentUserId) continue;

      debugPrint('[ChatScreen] Found existing participant: ${info.nickname}');
      setState(() {
        _participants[token] = info.nickname;
        _recipientId = token;
        _recipientName = info.nickname;
      });
    }

    // Wenn bereits Participants da sind und Crypto ready, zeige das an
    if (_participants.isNotEmpty && _cryptoInitialized) {
      debugPrint(
          '[ChatScreen] E2E already established with existing participants');
    }
  }

  Future<void> _loadStoredMessages() async {
    final stored = await _sessionService.loadMessages(widget.sessionId);
    if (stored.isNotEmpty && mounted) {
      setState(() {
        _messages = stored
            .map((m) => ChatMessage(
                  id: m.id,
                  text: m.text,
                  senderId: m.senderId,
                  senderName: m.senderName,
                  timestamp: m.timestamp,
                  isMe: m.isMe,
                ))
            .toList();
      });
      _scrollToBottom();
    }
  }

  void _handleParticipantJoined(String oderId, String nickname, bool isOnline) {
    if (!mounted) return;

    debugPrint('[ChatScreen] 🟢 Participant joined: $nickname ($oderId)');

    setState(() {
      _participants[oderId] = nickname;
      _recipientId = oderId;
      _recipientName = nickname;
    });
    _addSystemMessage('$nickname joined the chat');
    _sessionService.updateSessionRecipient(widget.sessionId, oderId, nickname);
  }

  void _handleParticipantLeft(String oderId) {
    if (!mounted) return;
    final name = _participants[oderId] ?? 'Someone';

    debugPrint('[ChatScreen] 🔴 Participant left: $name');

    setState(() {
      _participants.remove(oderId);
      if (_recipientId == oderId) {
        _cryptoInitialized = false;
      }
    });
    _addSystemMessage('$name left the chat');
  }

  void _handleCryptoReady() {
    if (!mounted) return;
    debugPrint('[ChatScreen] ✅ Crypto initialized');
    setState(() => _cryptoInitialized = true);
    _addSystemMessage('🔐 End-to-end encryption established');
  }

  Future<void> _handleMessage(Map<String, dynamic> data) async {
    if (!mounted) return;

    try {
      final payload = data['payload'] as Map<String, dynamic>?;
      if (payload == null) return;

      final senderId = data['senderId'] as String? ?? '';
      final senderName =
          data['senderName'] as String? ?? _participants[senderId] ?? 'Unknown';

      String text;
      try {
        text = await widget.wsService.cryptoService.decrypt(payload);
      } catch (e) {
        text = '[Could not decrypt message]';
      }

      final message = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        text: text,
        senderId: senderId,
        senderName: senderName,
        timestamp: DateTime.now(),
        isMe: senderId == widget.wsService.currentUserId,
      );

      setState(() => _messages.add(message));
      _scrollToBottom();

      await _sessionService.addMessage(
        widget.sessionId,
        StoredMessage(
          id: message.id,
          text: message.text,
          senderId: message.senderId,
          senderName: message.senderName,
          timestamp: message.timestamp,
          isMe: message.isMe,
        ),
      );

      _sessionService.refreshSessionExpiry(widget.sessionId);
    } catch (e) {
      debugPrint('[Chat] Error: $e');
    }
  }

  void _addSystemMessage(String text) {
    final message = ChatMessage(
      id: 'sys_${DateTime.now().millisecondsSinceEpoch}',
      text: text,
      senderId: 'system',
      senderName: 'System',
      timestamp: DateTime.now(),
      isMe: false,
      isSystem: true,
    );
    setState(() => _messages.add(message));
    _scrollToBottom();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    if (!_isE2EReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Waiting for encryption...'),
          backgroundColor: EchoChatTheme.warning,
        ),
      );
      return;
    }

    const messageKey = 'message';
    if (!_rateLimiter.canPerformAction(
      messageKey,
      cooldownSeconds: _messageCooldownSeconds,
      maxActionsPerWindow: _messageMaxPerWindow,
      windowSeconds: _messageWindowSeconds,
    )) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sending too fast. Please slow down.'),
          backgroundColor: EchoChatTheme.warning,
        ),
      );
      return;
    }

    setState(() => _isSending = true);
    _messageController.clear();

    try {
      await widget.wsService.sendMessage(widget.sessionId, text);
      _rateLimiter.recordAction(messageKey);

      final message = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        text: text,
        senderId: widget.wsService.currentUserId ?? '',
        senderName: 'Me',
        timestamp: DateTime.now(),
        isMe: true,
      );

      setState(() => _messages.add(message));
      _scrollToBottom();

      await _sessionService.addMessage(
        widget.sessionId,
        StoredMessage(
          id: message.id,
          text: message.text,
          senderId: message.senderId,
          senderName: message.senderName,
          timestamp: message.timestamp,
          isMe: message.isMe,
        ),
      );

      _sessionService.refreshSessionExpiry(widget.sessionId);
      HapticFeedback.lightImpact();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Failed to send: $e'),
            backgroundColor: EchoChatTheme.error),
      );
      _messageController.text = text;
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copySessionId() {
    final code = widget.passcode != null
        ? '${widget.sessionId}-${widget.passcode}'
        : widget.sessionId;
    Clipboard.setData(ClipboardData(text: code));
    HapticFeedback.lightImpact();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Join code copied!'),
          backgroundColor: EchoChatTheme.online),
    );
  }

  void _showInviteSheet() {
    final fullCode = widget.passcode != null
        ? '${widget.sessionId}-${widget.passcode}'
        : widget.sessionId;

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
            const SizedBox(height: 20),
            const Text('Invite to Chat',
                style: TextStyle(
                    color: EchoChatTheme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(fullCode,
                      style: const TextStyle(
                          color: EchoChatTheme.primary,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          letterSpacing: 2)),
                  const SizedBox(width: 16),
                  IconButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: fullCode));
                      HapticFeedback.lightImpact();
                      Navigator.pop(ctx);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Join code copied!'),
                            backgroundColor: EchoChatTheme.online),
                      );
                    },
                    icon: const Icon(Icons.copy, color: EchoChatTheme.primary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            if (_recipientId != null) ...[
              SizedBox(
                width: double.infinity,
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
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                    text: 'Join my EchoChat!\n\nCode: $fullCode',
                  ));
                  HapticFeedback.mediumImpact();
                  Navigator.pop(ctx);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Invite copied!'),
                        backgroundColor: EchoChatTheme.online),
                  );
                },
                icon: const Icon(Icons.share, size: 18),
                label: const Text('Copy Invite'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showChatOptions() {
    final fullCode = widget.passcode != null
        ? '${widget.sessionId}-${widget.passcode}'
        : widget.sessionId;

    showModalBottomSheet(
      context: context,
      backgroundColor: EchoChatTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceHighlight,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.copy, color: EchoChatTheme.textPrimary),
              title: const Text('Copy Join Code',
                  style: TextStyle(color: EchoChatTheme.textPrimary)),
              subtitle: Text(fullCode,
                  style: const TextStyle(
                      color: EchoChatTheme.textMuted, fontFamily: 'monospace')),
              onTap: () {
                Navigator.pop(ctx);
                _copySessionId();
              },
            ),
            if (_recipientId != null)
              ListTile(
                leading: const Icon(Icons.notifications_active,
                    color: EchoChatTheme.primary),
                title: const Text('Ping Participant',
                    style: TextStyle(color: EchoChatTheme.textPrimary)),
                subtitle: Text('Notify $_recipientName',
                    style: const TextStyle(color: EchoChatTheme.textMuted)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pingRecipient();
                },
              ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: EchoChatTheme.error),
              title: const Text('Clear Chat History',
                  style: TextStyle(color: EchoChatTheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _clearChatHistory();
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _pingRecipient() {
    if (_recipientId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No participant to ping'),
            backgroundColor: EchoChatTheme.warning),
      );
      return;
    }

    final pingKey = 'ping_${widget.sessionId}';
    if (!_rateLimiter.canPerformAction(
      pingKey,
      cooldownSeconds: _pingCooldownSeconds,
      maxActionsPerWindow: _pingMaxPerWindow,
      windowSeconds: _pingWindowSeconds,
    )) {
      final remaining = _rateLimiter.getRemainingCooldown(pingKey,
          cooldownSeconds: _pingCooldownSeconds);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Wait $remaining seconds before pinging again'),
          backgroundColor: EchoChatTheme.warning,
        ),
      );
      return;
    }

    widget.wsService
        .sendPing(widget.sessionId, _recipientId!, passcode: widget.passcode);
    _rateLimiter.recordAction(pingKey);

    HapticFeedback.mediumImpact();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('Ping sent to $_recipientName'),
          backgroundColor: EchoChatTheme.primary),
    );
  }

  Future<void> _clearChatHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EchoChatTheme.surface,
        title: const Text('Clear Chat History?',
            style: TextStyle(color: EchoChatTheme.textPrimary)),
        content: const Text('This cannot be undone.',
            style: TextStyle(color: EchoChatTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear',
                  style: TextStyle(color: EchoChatTheme.error))),
        ],
      ),
    );

    if (confirm == true) {
      await _sessionService.clearMessages(widget.sessionId);
      if (!mounted) return;
      setState(() => _messages.clear());
      _addSystemMessage('Chat history cleared');
    }
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EchoChatTheme.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: EchoChatTheme.surfaceLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _statusIcon,
                color: _statusColor,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_recipientName ?? widget.sessionName,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _statusColor,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _connectionStatus,
                          style: TextStyle(fontSize: 12, color: _statusColor),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (_recipientId != null)
            IconButton(
              icon: const Icon(Icons.notifications_active,
                  color: EchoChatTheme.primary),
              onPressed: _pingRecipient,
            ),
          IconButton(
            icon: const Icon(Icons.person_add, color: EchoChatTheme.primary),
            onPressed: _showInviteSheet,
          ),
          IconButton(
              icon: const Icon(Icons.more_vert), onPressed: _showChatOptions),
        ],
      ),
      body: Column(
        children: [
          // Orange Banner wenn wartend
          if (_isWaiting)
            Material(
              color: EchoChatTheme.warning.withAlpha(38),
              child: InkWell(
                onTap: _showInviteSheet,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.hourglass_empty,
                          color: EchoChatTheme.warning, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Waiting for participant... Invite a friend!',
                              style: TextStyle(
                                  color: EchoChatTheme.warning, fontSize: 14),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Tap to share: ${widget.sessionId}',
                              style: TextStyle(
                                color: EchoChatTheme.warning.withAlpha(180),
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          color: EchoChatTheme.warning),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isWaiting) ...[
                          Icon(Icons.person_add,
                              size: 64,
                              color: EchoChatTheme.textMuted.withAlpha(100)),
                          const SizedBox(height: 16),
                          const Text('Waiting for someone to join...',
                              style: TextStyle(
                                  color: EchoChatTheme.textMuted,
                                  fontSize: 16)),
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _showInviteSheet,
                            icon: const Icon(Icons.share),
                            label: const Text('Share Invite'),
                          ),
                        ] else ...[
                          Icon(Icons.chat_bubble_outline,
                              size: 64,
                              color: EchoChatTheme.textMuted.withAlpha(100)),
                          const SizedBox(height: 16),
                          const Text('No messages yet',
                              style: TextStyle(
                                  color: EchoChatTheme.textMuted,
                                  fontSize: 16)),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) =>
                        _buildMessage(_messages[index]),
                  ),
          ),
          Container(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: MediaQuery.of(context).viewPadding.bottom + 12,
            ),
            decoration: const BoxDecoration(
              color: EchoChatTheme.surface,
              border: Border(
                  top: BorderSide(
                      color: EchoChatTheme.surfaceHighlight, width: 1)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: EchoChatTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _messageController,
                      focusNode: _focusNode,
                      style: const TextStyle(color: EchoChatTheme.textPrimary),
                      decoration: InputDecoration(
                        hintText: _canSend
                            ? 'Type a message...'
                            : 'Waiting for participant...',
                        hintStyle:
                            const TextStyle(color: EchoChatTheme.textMuted),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                      textCapitalization: TextCapitalization.sentences,
                      maxLines: 4,
                      minLines: 1,
                      enabled: _canSend,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  decoration: BoxDecoration(
                    gradient: _canSend && !_isSending
                        ? EchoChatTheme.primaryGradient
                        : null,
                    color: !_canSend || _isSending
                        ? EchoChatTheme.surfaceLight
                        : null,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: IconButton(
                    onPressed: _canSend && !_isSending ? _sendMessage : null,
                    icon: _isSending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: EchoChatTheme.textMuted))
                        : Icon(Icons.send,
                            color: _canSend
                                ? Colors.black
                                : EchoChatTheme.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(ChatMessage message) {
    if (message.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: EchoChatTheme.surfaceLight,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(message.text,
                style: const TextStyle(
                    color: EchoChatTheme.textMuted,
                    fontSize: 12,
                    fontStyle: FontStyle.italic)),
          ),
        ),
      );
    }

    return Align(
      alignment: message.isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: message.isMe ? EchoChatTheme.primary : EchoChatTheme.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(message.isMe ? 16 : 4),
            bottomRight: Radius.circular(message.isMe ? 4 : 16),
          ),
          border: message.isMe
              ? null
              : Border.all(color: EchoChatTheme.surfaceHighlight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message.text,
                style: TextStyle(
                    color:
                        message.isMe ? Colors.black : EchoChatTheme.textPrimary,
                    fontSize: 15)),
            const SizedBox(height: 4),
            Text(_formatTime(message.timestamp),
                style: TextStyle(
                    color: message.isMe
                        ? Colors.black.withAlpha(150)
                        : EchoChatTheme.textMuted,
                    fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
