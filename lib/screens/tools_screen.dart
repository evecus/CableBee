import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});
  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  Map<String, String>? _deviceInfo;
  bool _loadingInfo = false;
  String? _screenshotPath;
  bool _takingScreenshot = false;
  String? _lastResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDeviceInfo());
  }

  Future<void> _loadDeviceInfo() async {
    final adb = context.read<AdbService>();
    setState(() => _loadingInfo = true);
    final info = await adb.getDeviceInfo();
    setState(() { _deviceInfo = info; _loadingInfo = false; });
  }

  Future<void> _takeScreenshot() async {
    setState(() { _takingScreenshot = true; _screenshotPath = null; });
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final path = '${dir.path}/cablebee_screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
    final res = await context.read<AdbService>().screenshot(path);
    setState(() {
      _takingScreenshot = false;
      if (res.isSuccess && File(path).existsSync()) {
        _screenshotPath = path;
      } else {
        _lastResult = 'Screenshot failed: ${res.stderr}';
      }
    });
  }

  Future<void> _enableTcpip() async {
    final port = await showInputDialog(context,
      title: '启用 TCP/IP',
      hint: '5555',
      initialValue: '5555',
      keyboardType: TextInputType.number,
    );
    if (port == null) return;
    final res = await context.read<AdbService>().enableTcpip(port: int.tryParse(port) ?? 5555);
    setState(() => _lastResult = res.output);
  }

  Future<void> _setAnimations() async {
    await showDialog(
      context: context,
      builder: (ctx) => _AnimationDialog(
        onSet: (scale) async {
          Navigator.pop(ctx);
          final res = await context.read<AdbService>().setAnimationScale(scale);
          setState(() => _lastResult = scale == 0
              ? '✓ Animations disabled'
              : '✓ Animation scale: ${scale}x  ${res.isSuccess ? '' : res.stderr}');
        },
      ),
    );
  }

  Future<void> _setResolution() async {
    await showDialog(
      context: context,
      builder: (ctx) => _ResolutionDialog(
        onSet: (w, h) async {
          Navigator.pop(ctx);
          final res = await context.read<AdbService>().setWmSize(w, h);
          setState(() => _lastResult = res.output);
        },
        onReset: () async {
          Navigator.pop(ctx);
          final res = await context.read<AdbService>().resetWmSize();
          setState(() => _lastResult = res.output);
        },
      ),
    );
  }

  Future<void> _reboot([String? mode]) async {
    final title = mode == null ? 'Reboot' : 'Reboot to ${mode.toUpperCase()}';
    final ok = await showConfirmDialog(context,
      title: title,
      message: 'Reboot the connected device${mode != null ? ' to $mode mode' : ''}?',
      confirmText: '重启',
      destructive: mode == 'bootloader' || mode == 'recovery',
    );
    if (ok != true) return;
    await context.read<AdbService>().reboot(mode);
    setState(() => _lastResult = 'Rebooting${mode != null ? ' → $mode' : ''}...');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final adb = context.watch<AdbService>();

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(title: const Text('工具')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // ── Device Info ───────────────────────────────────────────
          SectionHeader(
            title: '设备信息',
            trailing: IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 16, color: AppTheme.textMuted),
              onPressed: _loadDeviceInfo,
            ),
          ),
          if (_loadingInfo)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CbeeLoader(message: '读取设备信息...'),
            )
          else if (_deviceInfo != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(children: [
                Row(children: [
                  Expanded(child: StatCell(
                    label: '型号',
                    value: _deviceInfo!['model'] ?? '—',
                    icon: Icons.smartphone_rounded,
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: StatCell(
                    label: 'Android 版本',
                    value: _deviceInfo!['android'] ?? '—',
                    valueColor: AppTheme.success,
                    icon: Icons.android_rounded,
                  )),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: StatCell(
                    label: 'SDK',
                    value: 'API ${_deviceInfo!['sdk'] ?? '—'}',
                    icon: Icons.code_rounded,
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: StatCell(
                    label: '制造商',
                    value: _deviceInfo!['manufacturer'] ?? '—',
                    icon: Icons.business_rounded,
                  )),
                ]),
                const SizedBox(height: 8),
                StatCell(
                  label: '内存',
                  value: _deviceInfo!['memory'] ?? '—',
                  icon: Icons.memory_rounded,
                ),
              ]),
            ),

          // ── Result bar ────────────────────────────────────────────
          if (_lastResult != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: TerminalBox(text: _lastResult!, maxLines: 5),
            ),

          // ── Screenshot ────────────────────────────────────────────
          const SectionHeader(title: '截图'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                ActionTile(
                  icon: Icons.screenshot_rounded,
                  title: '截取屏幕',
                  subtitle: 'screencap → 拉取到本机',
                  onTap: _takingScreenshot ? null : _takeScreenshot,
                  trailing: _takingScreenshot
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(AppTheme.primary),
                          ),
                        )
                      : null,
                ),
                if (_screenshotPath != null) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(_screenshotPath!),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Text('预览不可用'),
                      ),
                    ),
                  ),
                ],
              ]),
            ),
          ),

          // ── Display tweaks ────────────────────────────────────────
          const SectionHeader(title: '显示'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                ActionTile(
                  icon: Icons.animation_rounded,
                  title: '动画速率',
                  subtitle: '窗口 / 过渡 / 动画',
                  iconColor: AppTheme.secondary,
                  onTap: _setAnimations,
                ),
                const Divider(height: 1, indent: 60),
                ActionTile(
                  icon: Icons.fit_screen_rounded,
                  title: '屏幕分辨率',
                  subtitle: 'wm size — override display size',
                  iconColor: AppTheme.secondary,
                  onTap: _setResolution,
                ),
              ]),
            ),
          ),

          // ── Network ───────────────────────────────────────────────
          const SectionHeader(title: '网络'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: EdgeInsets.zero,
              child: ActionTile(
                icon: Icons.wifi_tethering_rounded,
                title: '启用 TCP/IP',
                subtitle: '切换设备到无线 ADB 模式',
                iconColor: AppTheme.primary,
                onTap: _enableTcpip,
              ),
            ),
          ),

          // ── Reboot ────────────────────────────────────────────────
          const SectionHeader(title: '电源'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                ActionTile(
                  icon: Icons.restart_alt_rounded,
                  title: '重启',
                  subtitle: '正常重启系统',
                  onTap: () => _reboot(),
                ),
                const Divider(height: 1, indent: 60),
                ActionTile(
                  icon: Icons.build_circle_outlined,
                  title: '重启到 Recovery',
                  subtitle: '进入 Recovery 模式',
                  iconColor: AppTheme.warning,
                  onTap: () => _reboot('recovery'),
                ),
                const Divider(height: 1, indent: 60),
                ActionTile(
                  icon: Icons.lock_open_rounded,
                  title: '重启到 Bootloader',
                  subtitle: '进入 Fastboot / Bootloader 模式',
                  iconColor: AppTheme.danger,
                  onTap: () => _reboot('bootloader'),
                ),
                const Divider(height: 1, indent: 60),
                ActionTile(
                  icon: Icons.system_update_rounded,
                  title: '重启到 Sideload',
                  subtitle: '进入 ADB Sideload 模式',
                  iconColor: AppTheme.warning,
                  onTap: () => _reboot('sideload'),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Animation Dialog ──────────────────────────────────────────────────────────

class _AnimationDialog extends StatefulWidget {
  final void Function(double) onSet;
  const _AnimationDialog({required this.onSet});
  @override
  State<_AnimationDialog> createState() => _AnimationDialogState();
}

class _AnimationDialogState extends State<_AnimationDialog> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: const Text('Animation Scale', style: TextStyle(
        fontFamily: 'SpaceMono', fontSize: 15,
        fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
      )),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
          _scale == 0 ? 'OFF (fastest)' : '${_scale}x',
          style: const TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 24,
            fontWeight: FontWeight.w700, color: AppTheme.primary,
          ),
        ),
        Slider(
          value: _scale,
          min: 0, max: 5,
          divisions: 10,
          activeColor: AppTheme.primary,
          inactiveColor: AppTheme.bg3,
          onChanged: (v) => setState(() => _scale = v),
        ),
        const Text('0 = disable animations (fastest)', style: TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 11,
          color: AppTheme.textMuted,
        )),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(
            fontFamily: 'SpaceMono', color: AppTheme.textSecondary,
          )),
        ),
        FilledButton(
          onPressed: () => widget.onSet(_scale),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

// ── Resolution Dialog ─────────────────────────────────────────────────────────

class _ResolutionDialog extends StatefulWidget {
  final void Function(int, int) onSet;
  final VoidCallback onReset;
  const _ResolutionDialog({required this.onSet, required this.onReset});
  @override
  State<_ResolutionDialog> createState() => _ResolutionDialogState();
}

class _ResolutionDialogState extends State<_ResolutionDialog> {
  final _wCtrl = TextEditingController();
  final _hCtrl = TextEditingController();

  final _presets = const [
    ('1080×1920', 1080, 1920),
    ('1080×2400', 1080, 2400),
    ('720×1280', 720, 1280),
    ('1440×3200', 1440, 3200),
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: const Text('Screen Resolution', style: TextStyle(
        fontFamily: 'SpaceMono', fontSize: 15,
        fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
      )),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Wrap(
          spacing: 6, runSpacing: 6,
          children: _presets.map((p) => ActionChip(
            label: Text(p.$1, style: const TextStyle(
              fontFamily: 'SpaceMono', fontSize: 11, color: AppTheme.textSecondary,
            )),
            onPressed: () {
              _wCtrl.text = '${p.$2}';
              _hCtrl.text = '${p.$3}';
              setState(() {});
            },
          )).toList(),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(
            controller: _wCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '宽度'),
          )),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('×', style: TextStyle(color: AppTheme.textMuted, fontSize: 20)),
          ),
          Expanded(child: TextField(
            controller: _hCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '高度'),
          )),
        ]),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(
            fontFamily: 'SpaceMono', color: AppTheme.textSecondary,
          )),
        ),
        OutlinedButton(
          onPressed: widget.onReset,
          child: const Text('Reset', style: TextStyle(fontFamily: 'SpaceMono')),
        ),
        FilledButton(
          onPressed: () {
            final w = int.tryParse(_wCtrl.text);
            final h = int.tryParse(_hCtrl.text);
            if (w != null && h != null) widget.onSet(w, h);
          },
          child: const Text('应用'),
        ),
      ],
    );
  }
}
