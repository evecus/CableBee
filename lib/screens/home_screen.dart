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
  List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AdbService>().refreshDevices();
    });
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    super.dispose();
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

  /// 统一连接逻辑：连接成功后只刷新已连接区域，不自动跳转
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

    setState(() { _connecting = true; _connectMsg = null; });
    final result = await context.read<AdbService>().connect(host, port: port);
    final ok = result.isSuccess;
    setState(() {
      _connecting = false;
      _connectMsg = ok ? null : result.stderr;
    });

    if (ok) {
      await _saveHistory('$host:$port');
      // 连接成功：仅刷新列表，设备出现在"已连接"区域，不自动跳转
      if (mounted) {
        context.read<AdbService>().refreshDevices();
      }
    }
  }
    final result = await context.read<AdbService>().connect(host, port: port);
    final ok = result.isSuccess;
    setState(() {
      _connecting = false;
      _connectMsg = ok ? null : result.stderr;
    });

    if (ok) {
      await _saveHistory('$host:$port');
      // 连接成功：仅刷新列表，设备出现在"已连接"区域，不自动跳转
      if (mounted) {
        context.read<AdbService>().refreshDevices();
      }
    }
  }

  /// 断开指定设备
  Future<void> _disconnect(AdbDevice device) async {
    await context.read<AdbService>().disconnect(serial: device.serial);
  }

  /// 进入 ADB 功能页
  void _openDevice(AdbDevice device) {
    context.read<AdbService>().selectDevice(device);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DeviceScreen(device: device)),
    );
  }

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

  void _showScanDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _ScanDialog(
        onSelected: (ip) {
          Navigator.pop(ctx);
          // 扫描弹窗选中设备：只填入输入框，等用户手动点连接按钮
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

          // ── Logo ──────────────────────────────────────────────────
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

          // ── IP 输入框 ─────────────────────────────────────────────
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

          // ── 扫描 + 连接按钮 ───────────────────────────────────────
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
                label: Text(_connecting ? '等待授权...' : '连接'),
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

          // ── 已连接设备 ────────────────────────────────────────────
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

          // ── 历史设备 ──────────────────────────────────────────────
          if (_history.isNotEmpty) ...[
            _SectionLabel(label: '历史设备', count: _history.length),
            const SizedBox(height: 8),
            ..._history.map((ip) => _DeviceCard(
              icon: Icons.history_rounded,
              iconColor: AppTheme.textMuted,
              title: ip,
              subtitle: '点击填入输入框',
              onTap: () {
                setState(() {
                  _ipCtrl.text = ip;
                  _connectMsg = null;
                });
              },
              onDelete: () => _removeHistory(ip),
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

// ── Connected Device Card（已连接，带断开按钮）────────────────────────────────

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
            // 图标
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
            // 文字
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
            // 在线徽标
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
            // 断开按钮
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

// ── History / Generic Device Card ─────────────────────────────────────────────

class _DeviceCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final String? badge;
  final Color? badgeColor;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const _DeviceCard({
    required this.icon, required this.iconColor,
    required this.title, required this.subtitle,
    this.badge, this.badgeColor,
    this.onTap, this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.bg3),
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
                color: iconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, size: 18, color: iconColor),
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
                Text(subtitle, style: const TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 11,
                  color: AppTheme.textMuted,
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
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 16, color: AppTheme.textMuted),
                onPressed: onDelete,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            if (badge == null && onDelete == null)
              const Icon(Icons.chevron_right_rounded, size: 18, color: AppTheme.textMuted),
          ]),
        ),
      ),
    );
  }
}

// ── Pair Dialog ───────────────────────────────────────────────────────────────

class _PairDialog extends StatefulWidget {
  final VoidCallback onPaired;
  const _PairDialog({required this.onPaired});
  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _pairing = false;
  String? _result;
  bool _success = false;

  @override
  void dispose() {
    _hostCtrl.dispose(); _portCtrl.dispose(); _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 0;
    final code = _codeCtrl.text.trim();
    if (host.isEmpty || port == 0 || code.isEmpty) return;

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
          '在设备「开发者选项 → 无线调试 → 使用配对码配对」中获取 IP、端口和配对码',
          style: TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.textMuted,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _hostCtrl,
          decoration: const InputDecoration(labelText: 'IP 地址'),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _portCtrl,
          decoration: const InputDecoration(labelText: '配对端口'),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _codeCtrl,
          decoration: const InputDecoration(labelText: '配对码'),
          keyboardType: TextInputType.number,
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
                  // 点击后关闭弹窗并发起连接，成功后显示在已连接区域
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
