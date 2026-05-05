import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'services/binary_manager.dart';
import 'services/adb_service.dart';
import 'services/usb_service.dart';
import 'services/fastboot_service.dart';
import 'utils/theme.dart';
import 'screens/home_screen.dart';
import 'screens/fastboot_screen.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarBrightness: Brightness.light,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Color(0xFFFFFFFF),
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  runApp(const CableBeeApp());
}

class CableBeeApp extends StatelessWidget {
  const CableBeeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BinaryManager()),
        ChangeNotifierProxyProvider<BinaryManager, AdbService>(
          create: (ctx) => AdbService(ctx.read<BinaryManager>()),
          update: (_, bins, prev) => prev ?? AdbService(bins),
        ),
        ChangeNotifierProxyProvider<BinaryManager, FastbootService>(
          create: (ctx) => FastbootService(ctx.read<BinaryManager>()),
          update: (_, bins, prev) => prev ?? FastbootService(bins),
        ),
        ChangeNotifierProvider(create: (_) => UsbService()),
      ],
      child: MaterialApp(
        title: 'CableBee',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: const _InitGate(),
        routes: {
          '/fastboot': (_) => const FastbootScreen(),
          '/settings': (_) => const SettingsScreen(),
        },
      ),
    );
  }
}

// ── Init Gate ─────────────────────────────────────────────────────────────────

class _InitGate extends StatefulWidget {
  const _InitGate();
  @override
  State<_InitGate> createState() => _InitGateState();
}

class _InitGateState extends State<_InitGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Android 13+ 需要运行时申请通知权限（配对本机通知栏用）
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }

    context.read<BinaryManager>().initialize();
    await Future.wait([
      context.read<AdbService>().startServer(),
      context.read<UsbService>().initialize(),
    ]);
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return const MainApp();

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      body: SafeArea(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.12),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: AppTheme.primary.withOpacity(0.3), width: 1.5,
                ),
              ),
              child: const Icon(Icons.cable_rounded, size: 40, color: AppTheme.primary),
            ).animate()
              .fadeIn(duration: 500.ms)
              .scale(begin: const Offset(0.85, 0.85), curve: Curves.elasticOut),

            const SizedBox(height: 24),
            const Text('CableBee', style: TextStyle(
              fontFamily: 'SpaceMono', fontSize: 28,
              fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
              letterSpacing: -0.5,
            )).animate().fadeIn(delay: 150.ms, duration: 400.ms).slideY(begin: 0.2),

            const SizedBox(height: 4),
            const Text('ADB Assistant', style: TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 13,
              color: AppTheme.textMuted,
            )).animate().fadeIn(delay: 280.ms, duration: 400.ms),

            const SizedBox(height: 52),
            const SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(AppTheme.primary),
              ),
            ).animate().fadeIn(delay: 400.ms),
          ]),
        ),
      ),
    );
  }
}
