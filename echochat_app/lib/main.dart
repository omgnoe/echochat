import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/echochat_theme.dart';
import 'screens/account_setup_screen.dart';
import 'screens/home_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/info_screen.dart';
import 'services/identity_service.dart';
import 'services/notification_service.dart';
import 'services/ws_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await NotificationService().init();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: EchoChatTheme.background,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const EchoChatApp());
}

class EchoChatApp extends StatelessWidget {
  const EchoChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EchoChat',
      debugShowCheckedModeBanner: false,
      theme: EchoChatTheme.darkTheme,
      home: const AppEntryPoint(),
    );
  }
}

class AppEntryPoint extends StatefulWidget {
  const AppEntryPoint({super.key});

  @override
  State<AppEntryPoint> createState() => _AppEntryPointState();
}

class _AppEntryPointState extends State<AppEntryPoint> {
  final _identityService = IdentityService();
  bool _isLoading = true;
  Identity? _identity;

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final identity = await _identityService.loadIdentity();
    if (mounted) {
      setState(() {
        _identity = identity;
        _isLoading = false;
      });
    }
  }

  void _onAccountCreated(Identity identity) {
    setState(() => _identity = identity);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: EchoChatTheme.background,
        body: Center(
          child: CircularProgressIndicator(color: EchoChatTheme.primary),
        ),
      );
    }

    if (_identity == null) {
      return AccountSetupScreen(onAccountCreated: _onAccountCreated);
    }

    return MainNavigationScreen(identity: _identity!);
  }
}

class MainNavigationScreen extends StatefulWidget {
  final Identity identity;

  const MainNavigationScreen({super.key, required this.identity});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  late final EchoChatWebSocketService _wsService;
  late List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _wsService = EchoChatWebSocketService();
    _wsService.setIdentity(widget.identity);
    _wsService.connect();

    _screens = [
      HomeScreen(identity: widget.identity, wsService: _wsService),
      FriendsScreen(identity: widget.identity, wsService: _wsService),
      const InfoScreen(),
    ];
  }

  @override
  void dispose() {
    _wsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: EchoChatTheme.surface,
          border: Border(
            top: BorderSide(color: EchoChatTheme.surfaceHighlight, width: 1),
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(
                    0, Icons.chat_bubble_outline, Icons.chat_bubble, 'Chats'),
                _buildNavItem(1, Icons.people_outline, Icons.people, 'Friends'),
                _buildNavItem(2, Icons.info_outline, Icons.info, 'Info'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
      int index, IconData icon, IconData activeIcon, String label) {
    final isSelected = _currentIndex == index;
    return InkWell(
      onTap: () => setState(() => _currentIndex = index),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? EchoChatTheme.primary.withAlpha(30)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              color:
                  isSelected ? EchoChatTheme.primary : EchoChatTheme.textMuted,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? EchoChatTheme.primary
                    : EchoChatTheme.textMuted,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
