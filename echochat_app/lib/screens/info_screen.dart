import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/echochat_theme.dart';

class InfoScreen extends StatelessWidget {
  const InfoScreen({super.key});

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
                'Secure. Private. Simple.',
                style: TextStyle(
                  color: EchoChatTheme.textMuted,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 32),

            // How it works
            _buildSection(
              icon: Icons.security,
              title: 'End-to-End Encryption',
              description:
                  'All messages are encrypted on your device before being sent. Not even our servers can read your messages. Only you and your chat partner have the keys.',
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
              title: 'Easy Connection',
              description:
                  'Connect with friends by scanning QR codes or sharing your unique Friend Code. No phone number or email required.',
            ),
            const SizedBox(height: 20),

            _buildSection(
              icon: Icons.notifications_active,
              title: 'Ping Notifications',
              description:
                  'Send a ping to notify your friend when you want to chat. They\'ll receive a push notification to join your session.',
            ),
            const SizedBox(height: 32),

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
                  _buildStep('2', 'Create a new chat session'),
                  const SizedBox(height: 12),
                  _buildStep('3', 'Share the Session ID or ping your friend'),
                  const SizedBox(height: 12),
                  _buildStep('4', 'Start chatting securely!'),
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
              child: Column(
                children: [
                  Text(
                    'Version 1.0.0',
                    style: TextStyle(
                      color: EchoChatTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Made with ❤️ by TTA',
                    style: TextStyle(
                      color: EchoChatTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
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
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: EchoChatTheme.primary.withAlpha(30),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: EchoChatTheme.primary, size: 24),
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
