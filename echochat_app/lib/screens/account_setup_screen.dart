import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/echochat_theme.dart';
import '../services/identity_service.dart';

class AccountSetupScreen extends StatefulWidget {
  final void Function(Identity identity) onAccountCreated;

  const AccountSetupScreen({
    super.key,
    required this.onAccountCreated,
  });

  @override
  State<AccountSetupScreen> createState() => _AccountSetupScreenState();
}

class _AccountSetupScreenState extends State<AccountSetupScreen> {
  final _nicknameController = TextEditingController();
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _createAccount() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      setState(() => _error = 'Please enter a nickname.');
      return;
    }

    if (nickname.length < 2) {
      setState(() => _error = 'Nickname must be at least 2 characters.');
      return;
    }

    setState(() {
      _creating = true;
      _error = null;
    });

    try {
      final identity = await IdentityService().createIdentity(nickname);
      HapticFeedback.mediumImpact();
      widget.onAccountCreated(identity);
    } catch (e) {
      setState(() => _error = 'Error creating account: $e');
    } finally {
      setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EchoChatTheme.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 40),

            // Logo
            Center(
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: EchoChatTheme.primaryGradient,
                  boxShadow: [
                    BoxShadow(
                      color: EchoChatTheme.primary.withAlpha(77),
                      blurRadius: 20,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: const Icon(Icons.lock_outline,
                    size: 50, color: Colors.black),
              ),
            ),

            const SizedBox(height: 32),

            const Center(
              child: Text(
                'Welcome to EchoChat',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: EchoChatTheme.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Zero Knowledge Messenger',
                style:
                    TextStyle(fontSize: 14, color: EchoChatTheme.textSecondary),
              ),
            ),

            const SizedBox(height: 48),

            const Text(
              'Choose your nickname',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: EchoChatTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _nicknameController,
              style: const TextStyle(
                  color: EchoChatTheme.textPrimary, fontSize: 16),
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                hintText: 'Your nickname...',
                prefixIcon:
                    Icon(Icons.person_outline, color: EchoChatTheme.textMuted),
              ),
              onSubmitted: (_) => _createAccount(),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: EchoChatTheme.error.withAlpha(38),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        size: 16, color: EchoChatTheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!,
                          style: const TextStyle(
                              color: EchoChatTheme.error, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 48),

            _buildFeature(Icons.lock, 'End-to-end encryption'),
            _buildFeature(Icons.cloud_off, 'No server storage'),
            _buildFeature(Icons.visibility_off, 'Zero Knowledge'),

            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _creating ? null : _createAccount,
                child: _creating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : const Text('Let\'s go!'),
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildFeature(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: EchoChatTheme.primary.withAlpha(38),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: EchoChatTheme.primary),
          ),
          const SizedBox(width: 12),
          Text(text,
              style: const TextStyle(
                  color: EchoChatTheme.textSecondary, fontSize: 13)),
        ],
      ),
    );
  }
}
