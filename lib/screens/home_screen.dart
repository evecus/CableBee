import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import 'device_screen.dart';
import 'fastboot_screen.dart';
import 'settings_screen.dart';

// ── MainApp ───────────────────────────────────────────────────────────────────

class MainApp extends StatelessWidget {
  const MainApp({super.key});
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: AppTheme.bg0,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: const HomeScreen(),
    );
  }
}

// ── HomeScreen ────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _ipCtrl = TextEditingController();
  bool _connecting = false;
  String? _connectMsg;
  String? _connectingIp;
  List<String> _history = [];

  // ── 配对本机用的 EventChannel ──────────────────────────────────────────────
  static const _selfPairChannel = EventChannel('com.cablebee/self_pair_events');
  StreamSubscription? _selfPairSub;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AdbService>().refreshDevices();
    });
    // 监听 Kotlin 推过来的配对本机事件（通知栏 RemoteInput 提交配对码后触发）
    _selfPairSub = _selfPairChannel.receiveBroadcastStream().listen(_onSelfPairEvent);
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _selfPairSub?.cancel();
    super.dispose();
  }

  /// 收到 Kotlin 的自配对结果事件
  /// event: {'type': 'success'|'error', 'message': String}
  void _onSelfPairEvent(dynamic event) {
    if (!mounted) return;
    final map = Map<String, dynamic>.from(event as Map);
    final type = map['type'] as String?;
    final msg  = map['message'] as String? ?? '';

    if (type == 'success') {
      // 配对成功后自动以 127.0.0.1:port 连接
      final port = map['connectPort'] as int?;
      if (port != null) {
        _connect(overrideIp: '127.0.0.1:$port');
      } else {
        context.read<AdbService>().refreshDevices();
      }
      _showSnack('配对成功！正在连接本机...', success: true);
    } else if (type == 'error') {
      _showSnack('配对失败：$msg', success: false);
    }
  }

  void _showSnack(String msg, {required bool success}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12)),
      backgroundColor: success ? AppTheme.success : AppTheme.danger,
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _history = prefs.getStringList('ip_history') ?? []);
  }

  Future<void> _saveHistory(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    _history.remove(ip);
    _history.insert(0, ip);
    if (_history.length > 10) _history = _history.sublist(0, 10);
    await prefs.setStringList('ip_history', _history);
    setState(() {});
  }

  Future<void> _removeHistory(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    _history.remove(ip);
    await prefs.setStringList('ip_history', _history);
    setState(() {});
  }

  Future<void> _connect({String? overrideIp}) async {
    final raw = (overrideIp ?? _ipCtrl.text).trim();
    if (raw.isEmpty) return;

    String host;
    int port = 5555;
    if (raw.contains(':')) {
      final parts = raw.split(':');
      host = parts[0];
      port = int.tryParse(parts[1]) ?? 5555;
    } else {
      host = raw;
    }

    setState(() { _connecting = true; _connectMsg = null; _connectingIp = '$host:$port'; });
    final result = await context.read<AdbService>().connect(host, port: port);
    final ok = result.isSuccess;
    setState(() {
      _connecting = false;
      _connectingIp = null;
      _connectMsg = ok ? null : result.stderr;
    });

    if (ok) {
      await _saveHistory('$host:$port');
      if (mounted) context.read<AdbService>().refreshDevices();
    }
  }

  Future<void> _disconnect(AdbDevice device) async {
    await context.read<AdbService>().disconnect(serial: device.serial);
  }

  void _openDevice(AdbDevice device) {
    context.read<AdbService>().selectDevice(device);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DeviceScreen(device: device)),
    );
  }

  // ── 普通无线配对弹窗（保留原功能）────────────────────────────────────────
  void _showPairDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _PairDialog(
        onPaired: () {
          Navigator.pop(ctx);
          context.read<AdbService>().refreshDevices();
        },
      ),
    );
  }

  // ── 配对本机弹窗 ──────────────────────────────────────────────────────────
  void _showSelfPairDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _SelfPairDialog(
        onStart: () {
          Navigator.pop(ctx);
          _startSelfPairing();
        },
      ),
    );
  }

  /// 通知 Kotlin 启动 mDNS 监听 + 跳转开发者选项
  static const _adbChannel = MethodChannel('com.cablebee/adb');

  Future<void> _startSelfPairing() async {
    try {
      await _adbChannel.invokeMethod('startSelfPair');
    } catch (e) {
      _showSnack('启动配对失败：$e', success: false);
    }
  }

  void _showScanDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _ScanDialog(
        onSelected: (ip) {
          Navigator.pop(ctx);
          setState(() {
            _ipCtrl.text = ip;
            _connectMsg = null;
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final adb = context.watch<AdbService>();
    final connected = adb.devices;

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        backgroundColor: AppTheme.bg0,
        elevation: 0,
        titleSpacing: 16,
        title: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Image.asset(
            'assets/logo_text.png',
            height: 22,
            errorBuilder: (_, __, ___) => const Text(
              'CableBee',
              style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 18,
                fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
              ),
            ),
          ),
        ),
        actions: [
          // ── 新增：配对本机入口（在无线配对左边）──────────────────────────
          IconButton(
            tooltip: '配对本机',
            icon: const Icon(Icons.phonelink_rounded, size: 22, color: AppTheme.textSecondary),
            onPressed: _showSelfPairDialog,
          ),
          IconButton(
            tooltip: '无线配对',
            icon: const Icon(Icons.link_rounded, size: 22, color: AppTheme.textSecondary),
            onPressed: _showPairDialog,
          ),
          IconButton(
            tooltip: 'Fastboot',
            icon: const Icon(Icons.flash_on_rounded, size: 22, color: AppTheme.textSecondary),
            onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const FastbootScreen())),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined, size: 22, color: AppTheme.textSecondary),
            onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          const SizedBox(height: 32),

          Center(
            child: Image.asset(
              'assets/bee_logo.png',
              height: 150,
              errorBuilder: (_, __, ___) => const Text(
                'CableBee',
                style: TextStyle(
                  fontFamily: 'SpaceMono', fontSize: 34,
                  fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
                  letterSpacing: -1,
                ),
              ),
            ),
          ),

          const SizedBox(height: 40),

          TextField(
            controller: _ipCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 15, color: AppTheme.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: '输入设备 IP（默认端口 5555）',
              hintStyle: const TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 13, color: AppTheme.textMuted,
              ),
              prefixIcon: const Icon(Icons.router_outlined, size: 18, color: AppTheme.textMuted),
              suffixIcon: _ipCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16, color: AppTheme.textMuted),
                      onPressed: () { _ipCtrl.clear(); setState(() {}); },
                    )
                  : null,
              filled: true,
              fillColor: AppTheme.bg1,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.bg3),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.bg3),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.primary, width: 1.5),
              ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _connect(),
          ),

          if (_connectMsg != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.danger.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.danger.withOpacity(0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.error_outline_rounded, size: 14, color: AppTheme.danger),
                const SizedBox(width: 8),
                Expanded(child: Text(_connectMsg!, style: const TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.danger,
                ))),
              ]),
            ),
          ],

          const SizedBox(height: 14),

          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _showScanDialog,
                icon: const Icon(Icons.wifi_find_rounded, size: 16),
                label: const Text('扫描'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.bg3),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 13, fontWeight: FontWeight.w600,
                  ),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: _connecting ? null : _connect,
                icon: _connecting
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(AppTheme.bg0),
                        ),
                      )
                    : const Icon(Icons.cable_rounded, size: 16),
                label: Text(_connecting ? '连接中...' : '连接'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: AppTheme.bg0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 13, fontWeight: FontWeight.w700,
                  ),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ]),

          const SizedBox(height: 32),

          if (connected.isNotEmpty) ...[
            _SectionLabel(
              label: '已连接设备',
              count: connected.length,
              color: AppTheme.success,
            ),
            const SizedBox(height: 8),
            ...connected.map((d) => _ConnectedDeviceCard(
              device: d,
              onTap: () => _openDevice(d),
              onDisconnect: () => _disconnect(d),
            )),
            const SizedBox(height: 24),
          ],

          if (_history.isNotEmpty) ...[
            _SectionLabel(label: '历史设备', count: _history.length),
            const SizedBox(height: 8),
            ..._history.map((ip) => _DeviceCard(
              icon: Icons.history_rounded,
              iconColor: AppTheme.textMuted,
              title: ip,
              subtitle: _connectingIp == ip ? '等待授权...' : '点击直接连接',
              connecting: _connectingIp == ip,
              onTap: _connecting ? null : () => _connect(overrideIp: ip),
              onDelete: _connecting ? null : () => _removeHistory(ip),
            )),
          ],

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// ── Section Label ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  final int? count;
  final Color color;
  const _SectionLabel({
    required this.label, this.count, this.color = AppTheme.textMuted,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(width: 3, height: 14, decoration: BoxDecoration(
        color: color, borderRadius: BorderRadius.circular(2),
      )),
      const SizedBox(width: 8),
      Text(label, style: TextStyle(
        fontFamily: 'SpaceMono', fontSize: 11, fontWeight: FontWeight.w600,
        color: color, letterSpacing: 0.5,
      )),
      if (count != null) ...[
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('$count', style: TextStyle(
            fontFamily: 'SpaceMono', fontSize: 10, color: color,
          )),
        ),
      ],
    ]);
  }
}

// ── Connected Device Card ─────────────────────────────────────────────────────

class _ConnectedDeviceCard extends StatelessWidget {
  final AdbDevice device;
  final VoidCallback onTap;
  final VoidCallback onDisconnect;

  const _ConnectedDeviceCard({
    required this.device,
    required this.onTap,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.success.withOpacity(0.3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                device.isWifi ? Icons.wifi_rounded : Icons.usb_rounded,
                size: 18, color: AppTheme.success,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.displayName, style: const TextStyle(
                  fontFamily: 'SpaceMono', fontSize: 13,
                  fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
                )),
                const SizedBox(height: 2),
                Text(device.serial, style: const TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 11,
                  color: AppTheme.textMuted,
                )),
              ],
            )),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('在线', style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 10,
                fontWeight: FontWeight.w600, color: AppTheme.success,
              )),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '断开连接',
              icon: const Icon(Icons.link_off_rounded, size: 18, color: AppTheme.textMuted),
              onPressed: onDisconnect,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Generic Device Card ───────────────────────────────────────────────────────

class _DeviceCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String? badge;
  final Color? badgeColor;
  final bool connecting;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const _DeviceCard({
    required this.icon, required this.iconColor,
    required this.title, required this.subtitle,
    this.badge, this.badgeColor,
    this.connecting = false,
    this.onTap, this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: connecting ? AppTheme.primary.withOpacity(0.4) : AppTheme.bg3),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: (connecting ? AppTheme.primary : iconColor).withOpacity(0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: connecting
                  ? const Center(child: SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(AppTheme.primary),
                      ),
                    ))
                  : Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(
                  fontFamily: 'SpaceMono', fontSize: 13,
                  fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
                )),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 11,
                  color: connecting ? AppTheme.primary : AppTheme.textMuted,
                )),
              ],
            )),
            if (badge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (badgeColor ?? AppTheme.textMuted).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(badge!, style: TextStyle(
                  fontFamily: 'SpaceMono', fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: badgeColor ?? AppTheme.textMuted,
                )),
              ),
            ],
            if (onDelete != null && !connecting)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 16, color: AppTheme.textMuted),
                onPressed: onDelete,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            if (badge == null && onDelete == null && !connecting)
              const Icon(Icons.chevron_right_rounded, size: 18, color: AppTheme.textMuted),
          ]),
        ),
      ),
    );
  }
}

// ── Self Pair Dialog（配对本机）───────────────────────────────────────────────

class _SelfPairDialog extends StatelessWidget {
  final VoidCallback onStart;
  const _SelfPairDialog({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: const Row(children: [
        Icon(Icons.phonelink_rounded, size: 18, color: AppTheme.primary),
        SizedBox(width: 8),
        Text('配对本机', style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 15,
          fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
        )),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        // 步骤说明
        _StepRow(
          step: '1',
          text: '点击「开始配对」，将自动跳转到系统无线调试设置页',
        ),
        const SizedBox(height: 10),
        _StepRow(
          step: '2',
          text: '在系统页面点击「使用配对码配对」，配对弹窗出现后不要关闭',
        ),
        const SizedBox(height: 10),
        _StepRow(
          step: '3',
          text: '下拉通知栏，在「CableBee 检测到配对服务」通知中输入配对码',
        ),
        const SizedBox(height: 10),
        _StepRow(
          step: '4',
          text: '配对成功后自动连接本机，无需任何额外操作',
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.primary.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.primary.withOpacity(0.2)),
          ),
          child: const Row(children: [
            Icon(Icons.info_outline_rounded, size: 13, color: AppTheme.primary),
            SizedBox(width: 8),
            Expanded(child: Text(
              '需要 Android 11 及以上，且已开启无线调试',
              style: TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.primary,
              ),
            )),
          ]),
        ),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(
            fontFamily: 'SpaceMono', color: AppTheme.textSecondary,
          )),
        ),
        FilledButton.icon(
          onPressed: onStart,
          icon: const Icon(Icons.play_arrow_rounded, size: 16),
          label: const Text('开始配对'),
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: AppTheme.bg0,
            textStyle: const TextStyle(
              fontFamily: 'SpaceMono', fontSize: 13, fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  final String step;
  final String text;
  const _StepRow({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 20, height: 20,
        decoration: BoxDecoration(
          color: AppTheme.primary.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(child: Text(step, style: const TextStyle(
          fontFamily: 'SpaceMono', fontSize: 11,
          fontWeight: FontWeight.w700, color: AppTheme.primary,
        ))),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: const TextStyle(
        fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.textSecondary,
        height: 1.5,
      ))),
    ]);
  }
}

// ── Pair Dialog（原有无线配对保留）───────────────────────────────────────────

class _PairDialog extends StatefulWidget {
  final VoidCallback onPaired;
  const _PairDialog({required this.onPaired});
  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  final _codeCtrl = TextEditingController();
  final _addrCtrl = TextEditingController();
  bool _pairing = false;
  String? _result;
  bool _success = false;

  @override
  void dispose() {
    _codeCtrl.dispose(); _addrCtrl.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final code = _codeCtrl.text.trim();
    final addr = _addrCtrl.text.trim();
    if (code.isEmpty || addr.isEmpty) return;

    final colonIdx = addr.lastIndexOf(':');
    if (colonIdx < 0) {
      setState(() { _result = '请输入正确格式：IP地址:端口'; _success = false; });
      return;
    }
    final host = addr.substring(0, colonIdx).trim();
    final port = int.tryParse(addr.substring(colonIdx + 1).trim()) ?? 0;
    if (host.isEmpty || port == 0) {
      setState(() { _result = '请输入正确格式：IP地址:端口'; _success = false; });
      return;
    }

    setState(() { _pairing = true; _result = null; });
    final res = await context.read<AdbService>().pair(host, port, code);
    final ok = res.isSuccess;
    setState(() {
      _pairing = false;
      _result = ok ? '配对成功！' : res.stderr;
      _success = ok;
    });
    if (ok) {
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) widget.onPaired();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: const Text('无线配对', style: TextStyle(
        fontFamily: 'SpaceMono', fontSize: 15,
        fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
      )),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text(
          '在设备「开发者选项 → 无线调试 → 使用配对码配对」中获取配对码和 IP:端口',
          style: TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.textMuted,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _codeCtrl,
          decoration: const InputDecoration(labelText: '配对码'),
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _addrCtrl,
          decoration: const InputDecoration(
            labelText: 'IP 地址和端口',
            hintText: '10.0.0.6:43251',
          ),
          keyboardType: TextInputType.url,
        ),
        if (_result != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: (_success ? AppTheme.success : AppTheme.danger).withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: (_success ? AppTheme.success : AppTheme.danger).withOpacity(0.3),
              ),
            ),
            child: Row(children: [
              Icon(
                _success ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                size: 14,
                color: _success ? AppTheme.success : AppTheme.danger,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_result!, style: TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 11,
                color: _success ? AppTheme.success : AppTheme.danger,
              ))),
            ]),
          ),
        ],
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(
            fontFamily: 'SpaceMono', color: AppTheme.textSecondary,
          )),
        ),
        FilledButton(
          onPressed: _pairing ? null : _pair,
          child: _pairing
              ? const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppTheme.bg0),
                  ),
                )
              : const Text('配对'),
        ),
      ],
    );
  }
}

// ── Scan Dialog ───────────────────────────────────────────────────────────────

class _ScanDialog extends StatefulWidget {
  final void Function(String ip) onSelected;
  const _ScanDialog({required this.onSelected});
  @override
  State<_ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends State<_ScanDialog> {
  List<String> _found = [];
  bool _scanning = false;
  String _status = '准备扫描...';

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() { _scanning = true; _found = []; _status = '正在扫描局域网...'; });

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      String? prefix;
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('127.') && !ip.startsWith('169.')) {
            final parts = ip.split('.');
            if (parts.length == 4) {
              prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
              break;
            }
          }
        }
        if (prefix != null) break;
      }

      if (prefix == null) {
        setState(() { _scanning = false; _status = '无法获取本机 IP，请手动输入'; });
        return;
      }

      setState(() => _status = '扫描 $prefix.1-254:5555...');

      final futures = <Future>[];
      final results = <String>[];

      for (int i = 1; i <= 254; i++) {
        final ip = '$prefix.$i';
        futures.add(
          Socket.connect(ip, 5555, timeout: const Duration(milliseconds: 300))
            .then((s) { s.destroy(); results.add('$ip:5555'); })
            .catchError((_) {}),
        );
      }

      await Future.wait(futures);
      results.sort();

      setState(() {
        _found = results;
        _scanning = false;
        _status = results.isEmpty ? '未发现设备，请手动输入 IP' : '发现 ${results.length} 个设备';
      });
    } catch (e) {
      setState(() { _scanning = false; _status = '扫描失败：$e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: Row(children: [
        const Text('扫描局域网', style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 15,
          fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
        )),
        const Spacer(),
        if (!_scanning)
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 18, color: AppTheme.textMuted),
            onPressed: _scan,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
      ]),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_scanning) ...[
            const LinearProgressIndicator(
              valueColor: AlwaysStoppedAnimation(AppTheme.primary),
              backgroundColor: AppTheme.bg3,
            ),
            const SizedBox(height: 8),
          ],
          Text(_status, style: const TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.textMuted,
          )),
          if (_found.isNotEmpty) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _found.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.bg3),
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  leading: const Icon(Icons.smartphone_rounded, size: 16, color: AppTheme.primary),
                  title: Text(_found[i], style: const TextStyle(
                    fontFamily: 'JetBrainsMono', fontSize: 13, color: AppTheme.textPrimary,
                  )),
                  onTap: () => widget.onSelected(_found[i]),
                ),
              ),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(
            fontFamily: 'SpaceMono', color: AppTheme.textSecondary,
          )),
        ),
      ],
    );
  }
}
