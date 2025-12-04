import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/echochat_theme.dart';

class InfoScreen extends StatelessWidget {
  const InfoScreen({super.key});

  static const String appVersion = '1.2.0';
  static const String buildDate = '2024-12';

  Future<void> _openLink() async {
    final uri = Uri.parse('https://www.tta.lu/echochat.html');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EchoChatTheme.background,
      appBar: AppBar(
        title: const Text('About EchoChat'),
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Logo
            Center(
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  gradient: EchoChatTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Center(
                  child: Text(
                    '((e))',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Title
            const Center(
              child: Text(
                'EchoChat',
                style: TextStyle(
                  color: EchoChatTheme.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Zero-Knowledge • End-to-End Encrypted',
                style: TextStyle(
                  color: EchoChatTheme.textMuted,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(height: 32),

            // Security Features
            _buildSection(
              icon: Icons.shield,
              title: 'Zero-Knowledge Architecture',
              description:
                  'Our servers never see your messages, nicknames, or identities. Everything is encrypted on your device. The server only relays encrypted data it cannot understand.',
              highlight: true,
            ),
            const SizedBox(height: 20),

            _buildSection(
              icon: Icons.security,
              title: 'End-to-End Encryption',
              description:
                  'Messages are encrypted with X25519 key exchange and AES-256-GCM. Only you and your chat partner can read messages. Not even us.',
            ),
            const SizedBox(height: 20),

            _buildSection(
              icon: Icons.fingerprint,
              title: 'MITM Protection',
              description:
                  'Verify your contacts with security fingerprints. Compare codes in person or via another channel to ensure no one is intercepting your chats.',
            ),
            const SizedBox(height: 20),

            _buildSection(
              icon: Icons.timer,
              title: 'Ephemeral Sessions',
              description:
                  'Chat sessions automatically expire after 3 days. No permanent data is stored on our servers. Your conversations disappear when you\'re done.',
            ),
            const SizedBox(height: 20),

            _buildSection(
              icon: Icons.qr_code,
              title: 'Private Connection',
              description:
                  'Connect with friends by scanning QR codes. No phone number or email required. Your identity stays with you.',
            ),
            const SizedBox(height: 32),

            // Zero-Knowledge Details
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: EchoChatTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: EchoChatTheme.online.withAlpha(100)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.visibility_off,
                          color: EchoChatTheme.online, size: 24),
                      const SizedBox(width: 12),
                      const Text(
                        'What the Server Cannot See',
                        style: TextStyle(
                          color: EchoChatTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildPrivacyItem(
                      Icons.check_circle, 'Message contents', true),
                  _buildPrivacyItem(Icons.check_circle, 'Your nickname', true),
                  _buildPrivacyItem(
                      Icons.check_circle, 'Who you\'re talking to', true),
                  _buildPrivacyItem(
                      Icons.check_circle, 'Friend relationships', true),
                  const SizedBox(height: 12),
                  Text(
                    'Server only sees: encrypted blobs, anonymous tokens, and timing metadata.',
                    style: TextStyle(
                      color: EchoChatTheme.textMuted,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // How to use
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: EchoChatTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: EchoChatTheme.surfaceHighlight),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb_outline,
                          color: EchoChatTheme.primary, size: 24),
                      const SizedBox(width: 12),
                      const Text(
                        'How to Start',
                        style: TextStyle(
                          color: EchoChatTheme.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildStep('1', 'Add a friend via QR code or Friend Code'),
                  const SizedBox(height: 12),
                  _buildStep(
                      '2', 'Verify their fingerprint for extra security'),
                  const SizedBox(height: 12),
                  _buildStep('3', 'Create a chat and ping your friend'),
                  const SizedBox(height: 12),
                  _buildStep('4', 'Chat with full end-to-end encryption!'),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Support section
            Container(
              padding: const EdgeInsets.all(20),
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
              child: Column(
                children: [
                  const Icon(Icons.favorite,
                      color: EchoChatTheme.primary, size: 32),
                  const SizedBox(height: 12),
                  const Text(
                    'Support the Project',
                    style: TextStyle(
                      color: EchoChatTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'EchoChat is an open project focused on privacy. Learn more about the project and how you can contribute.',
                    style: TextStyle(
                      color: EchoChatTheme.textSecondary,
                      fontSize: 14,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _openLink,
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Learn More & Support'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Version info
            Center(
              child: GestureDetector(
                onLongPress: () {
                  Clipboard.setData(const ClipboardData(
                    text: 'EchoChat v$appVersion ($buildDate)\n'
                        'Zero-Knowledge Architecture\n'
                        'E2E: X25519 + AES-256-GCM',
                  ));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Version info copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: EchoChatTheme.surfaceLight,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified_user,
                            size: 14,
                            color: EchoChatTheme.online,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Version $appVersion',
                            style: TextStyle(
                              color: EchoChatTheme.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Made with ❤️ by TTA',
                      style: TextStyle(
                        color: EchoChatTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Zero-Knowledge • Open Source',
                      style: TextStyle(
                        color: EchoChatTheme.textMuted.withAlpha(150),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildSection({
    required IconData icon,
    required String title,
    required String description,
    bool highlight = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: highlight
                ? EchoChatTheme.online.withAlpha(30)
                : EchoChatTheme.primary.withAlpha(30),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            color: highlight ? EchoChatTheme.online : EchoChatTheme.primary,
            size: 24,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: EchoChatTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: TextStyle(
                  color: EchoChatTheme.textSecondary,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPrivacyItem(IconData icon, String text, bool protected) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: protected ? EchoChatTheme.online : EchoChatTheme.error,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: EchoChatTheme.textPrimary,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: EchoChatTheme.online.withAlpha(30),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Protected',
              style: TextStyle(
                color: EchoChatTheme.online,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(String number, String text) {
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: EchoChatTheme.primary,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: EchoChatTheme.textPrimary,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}
