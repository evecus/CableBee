import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

class ToolsScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const ToolsScreen({super.key, this.onActionsChanged});
  @override
  State<ToolsScreen> createState() => ToolsScreenState();
}

class ToolsScreenState extends State<ToolsScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => widget.onActionsChanged?.call([]);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onActionsChanged?.call([]);
    });
  }

  bool _takingScreenshot = false;
  String? _resultMsg;
  bool _resultOk = true;

  // ── 结果提示 ────────────────────────────────────────────────────────────────

  void _showResult(String msg, {bool ok = true}) {
    setState(() { _resultMsg = msg; _resultOk = ok; });
  }

  // ── 截图 ────────────────────────────────────────────────────────────────────

  Future<void> _takeScreenshot() async {
    setState(() { _takingScreenshot = true; _resultMsg = null; });
    final prefs = await SharedPreferences.getInstance();
    final saveDir = prefs.getString('local_save_path') ?? '/sdcard/Download/CableBee';
    await Directory(saveDir).create(recursive: true);
    final path = '$saveDir/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';
    final res = await context.read<AdbService>().screenshot(path);
    setState(() {
      _takingScreenshot = false;
      if (res.isSuccess && File(path).existsSync()) {
        _showResult('✓ 截图已保存至 $path');
      } else {
        _showResult('✗ 截图失败：${res.stderr}', ok: false);
      }
    });
  }

  // ── 重启 ────────────────────────────────────────────────────────────────────

  Future<void> _reboot([String? mode]) async {
    final labels = {
      null: ('重启', '正常重启系统？'),
      'update': ('重启到更新模式', '设备将进入 OTA 更新模式'),
      'recovery': ('重启到 Recovery', '设备将进入 Recovery 模式'),
      'fastboot': ('重启到 Fastboot', '设备将进入 Fastboot 模式'),
      'bootloader': ('重启到 Bootloader', '设备将进入 Bootloader 模式，可能触发数据清除'),
    };
    final info = labels[mode] ?? ('重启', '确认重启？');
    final ok = await showConfirmDialog(context,
      title: info.$1,
      message: info.$2,
      confirmText: '确认',
      destructive: mode == 'bootloader',
    );
    if (ok != true) return;
    await context.read<AdbService>().reboot(mode);
    _showResult('${info.$1}命令已发送...');
  }

  // ── 修改动画速率 ─────────────────────────────────────────────────────────────

  Future<void> _setAnimations() async {
    await showDialog(
      context: context,
      builder: (ctx) => _AnimationDialog(
        onSet: (scale) async {
          Navigator.pop(ctx);
          final res = await context.read<AdbService>().setAnimationScale(scale);
          _showResult(scale == 0
              ? '✓ 动画已关闭（最快速度）'
              : '✓ 动画速率已设为 ${scale}x',
            ok: res.isSuccess);
        },
      ),
    );
  }

  // ── 修改分辨率 ───────────────────────────────────────────────────────────────

  Future<void> _setResolution() async {
    await showDialog(
      context: context,
      builder: (ctx) => _ResolutionDialog(
        onSet: (w, h) async {
          Navigator.pop(ctx);
          final res = await context.read<AdbService>().setWmSize(w, h);
          _showResult(res.isSuccess ? '✓ 分辨率已设为 ${w}x$h' : '✗ 失败：${res.stderr}',
              ok: res.isSuccess);
        },
        onReset: () async {
          Navigator.pop(ctx);
          final res = await context.read<AdbService>().resetWmSize();
          _showResult(res.isSuccess ? '✓ 分辨率已恢复默认' : '✗ 失败：${res.stderr}',
              ok: res.isSuccess);
        },
      ),
    );
  }

  // ── 修改 DPI ────────────────────────────────────────────────────────────────

  Future<void> _setDpi() async {
    await showDialog(
      context: context,
      builder: (ctx) => _DpiDialog(
        onSet: (dpi) async {
          Navigator.pop(ctx);
          final res = await context.read<AdbService>().setWmDensity(dpi);
          _showResult(res.isSuccess ? '✓ DPI 已设为 $dpi' : '✗ 失败：${res.stderr}',
              ok: res.isSuccess);
        },
        onReset: () async {
          Navigator.pop(ctx);
          final res = await context.read<AdbService>().resetWmDensity();
          _showResult(res.isSuccess ? '✓ DPI 已恢复默认' : '✗ 失败：${res.stderr}',
              ok: res.isSuccess);
        },
      ),
    );
  }

  // ── 息屏 / 亮屏 ─────────────────────────────────────────────────────────────

  Future<void> _screenOff() async {
    final res = await context.read<AdbService>().shell(
        'input keyevent KEYCODE_SLEEP');
    _showResult(res.isSuccess ? '✓ 屏幕已息屏' : '✗ 失败：${res.stderr}',
        ok: res.isSuccess);
  }

  Future<void> _screenOn() async {
    final res = await context.read<AdbService>().shell(
        'input keyevent KEYCODE_WAKEUP');
    _showResult(res.isSuccess ? '✓ 屏幕已点亮' : '✗ 失败：${res.stderr}',
        ok: res.isSuccess);
  }

  // ── 墓碑模式 ────────────────────────────────────────────────────────────────

  Future<void> _enableTombstone() async {
    final ok = await showConfirmDialog(context,
      title: '启用墓碑模式',
      message: '启用后系统将记录详细崩溃日志，可能影响性能。确认启用？',
      confirmText: '启用',
    );
    if (ok != true) return;
    final res = await context.read<AdbService>().shell(
        'setprop tombstoned.max_tombstone_count 50');
    _showResult(res.isSuccess ? '✓ 墓碑模式已启用' : '✗ 失败：${res.stderr}',
        ok: res.isSuccess);
  }

  // ── NTP 服务器 ───────────────────────────────────────────────────────────────

  Future<void> _setNtp() async {
    await showDialog(
      context: context,
      builder: (ctx) => _NtpDialog(
        onSet: (server) async {
          Navigator.pop(ctx);
          final res = await context.read<AdbService>().shell(
              'settings put global ntp_server $server');
          _showResult(res.isSuccess ? '✓ NTP 服务器已设为 $server' : '✗ 失败：${res.stderr}',
              ok: res.isSuccess);
        },
      ),
    );
  }

  // ── 激活第三方工具 ────────────────────────────────────────────────────────────

  Future<void> _activateTool(String label, String cmd) async {
    final ok = await showConfirmDialog(context,
      title: '激活 $label',
      message: '将执行：\n$cmd\n\n请确保该应用已安装。',
      confirmText: '激活',
    );
    if (ok != true) return;
    final res = await context.read<AdbService>().shell(cmd);
    _showResult(res.isSuccess ? '✓ $label 激活命令已发送' : '✗ 失败：${res.stderr}',
        ok: res.isSuccess);
  }

  // ── 启用 TCP/IP ──────────────────────────────────────────────────────────────

  Future<void> _enableTcpip() async {
    final port = await showInputDialog(context,
      title: '启用 TCP/IP',
      hint: '5555',
      initialValue: '5555',
      keyboardType: TextInputType.number,
    );
    if (port == null) return;
    final res = await context.read<AdbService>().enableTcpip(
        port: int.tryParse(port) ?? 5555);
    _showResult(res.isSuccess ? '✓ TCP/IP 已启用，端口 $port' : '✗ 失败：${res.stderr}',
        ok: res.isSuccess);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [

          // ── 结果提示条 ────────────────────────────────────────────
          if (_resultMsg != null) ...[
            const SizedBox(height: 8),
            _ResultBar(
              message: _resultMsg!,
              ok: _resultOk,
              onDismiss: () => setState(() => _resultMsg = null),
            ),
          ],

          // ══════════════════════════════════════════════════════════
          // 截图
          // ══════════════════════════════════════════════════════════
          const SizedBox(height: 16),
          _ToolGroup(
            title: '截图',
            icon: Icons.screenshot_monitor_rounded,
            iconColor: AppTheme.primary,
            children: [
              _ToolTile(
                icon: Icons.screenshot_rounded,
                iconColor: AppTheme.primary,
                title: '截取屏幕',
                subtitle: 'screencap → 拉取保存到本机',
                loading: _takingScreenshot,
                onTap: _takingScreenshot ? null : _takeScreenshot,
              ),
            ],
          ),


          // ══════════════════════════════════════════════════════════
          // 电源
          // ══════════════════════════════════════════════════════════
          const SizedBox(height: 16),
          _ToolGroup(
            title: '电源',
            icon: Icons.power_settings_new_rounded,
            iconColor: AppTheme.danger,
            children: [
              _ToolTile(
                icon: Icons.restart_alt_rounded,
                iconColor: AppTheme.success,
                title: '重启',
                subtitle: '正常重启系统',
                onTap: () => _reboot(),
              ),
              _ToolTile(
                icon: Icons.system_update_alt_rounded,
                iconColor: AppTheme.primary,
                title: '重启到更新模式',
                subtitle: 'adb reboot update',
                onTap: () => _reboot('update'),
              ),
              _ToolTile(
                icon: Icons.build_circle_outlined,
                iconColor: AppTheme.warning,
                title: '重启到 Recovery',
                subtitle: 'adb reboot recovery',
                onTap: () => _reboot('recovery'),
              ),
              _ToolTile(
                icon: Icons.flash_on_rounded,
                iconColor: AppTheme.warning,
                title: '重启到 Fastboot',
                subtitle: 'adb reboot fastboot',
                onTap: () => _reboot('fastboot'),
              ),
              _ToolTile(
                icon: Icons.developer_mode_rounded,
                iconColor: AppTheme.danger,
                title: '重启到 Bootloader',
                subtitle: 'adb reboot bootloader',
                onTap: () => _reboot('bootloader'),
              ),
            ],
          ),

          // ══════════════════════════════════════════════════════════
          // 屏幕
          // ══════════════════════════════════════════════════════════
          const SizedBox(height: 16),
          _ToolGroup(
            title: '屏幕',
            icon: Icons.monitor_rounded,
            iconColor: AppTheme.secondary,
            children: [
              _ToolTile(
                icon: Icons.brightness_2_rounded,
                iconColor: const Color(0xFF6C63FF),
                title: '息屏待机',
                subtitle: 'input keyevent KEYCODE_SLEEP',
                onTap: _screenOff,
              ),
              _ToolTile(
                icon: Icons.wb_sunny_rounded,
                iconColor: AppTheme.warning,
                title: '点亮屏幕',
                subtitle: 'input keyevent KEYCODE_WAKEUP',
                onTap: _screenOn,
              ),
              _ToolTile(
                icon: Icons.animation_rounded,
                iconColor: AppTheme.secondary,
                title: '修改动画速率',
                subtitle: '窗口 / 过渡 / 动画倍率',
                onTap: _setAnimations,
              ),
              _ToolTile(
                icon: Icons.fit_screen_rounded,
                iconColor: AppTheme.secondary,
                title: '修改屏幕分辨率',
                subtitle: 'wm size — 覆盖显示分辨率',
                onTap: _setResolution,
              ),
              _ToolTile(
                icon: Icons.density_medium_rounded,
                iconColor: AppTheme.secondary,
                title: '修改 DPI',
                subtitle: 'wm density — 覆盖屏幕密度',
                onTap: _setDpi,
              ),
            ],
          ),

          // ══════════════════════════════════════════════════════════
          // 网络
          // ══════════════════════════════════════════════════════════
          const SizedBox(height: 16),
          _ToolGroup(
            title: '网络',
            icon: Icons.wifi_rounded,
            iconColor: AppTheme.primary,
            children: [
              _ToolTile(
                icon: Icons.wifi_tethering_rounded,
                iconColor: AppTheme.primary,
                title: '启用 TCP/IP',
                subtitle: '切换设备到无线 ADB 模式',
                onTap: _enableTcpip,
              ),
              _ToolTile(
                icon: Icons.access_time_rounded,
                iconColor: AppTheme.primary,
                title: '修改 NTP 服务器',
                subtitle: 'settings put global ntp_server',
                onTap: _setNtp,
              ),
            ],
          ),

          // ══════════════════════════════════════════════════════════
          // 系统
          // ══════════════════════════════════════════════════════════
          const SizedBox(height: 16),
          _ToolGroup(
            title: '系统',
            icon: Icons.settings_rounded,
            iconColor: AppTheme.textSecondary,
            children: [
              _ToolTile(
                icon: Icons.bug_report_rounded,
                iconColor: const Color(0xFF8B5CF6),
                title: '启用墓碑模式',
                subtitle: '记录详细崩溃日志',
                onTap: _enableTombstone,
              ),
            ],
          ),

          // ══════════════════════════════════════════════════════════
          // 激活工具
          // ══════════════════════════════════════════════════════════
          const SizedBox(height: 16),
          _ToolGroup(
            title: '激活工具',
            icon: Icons.rocket_launch_rounded,
            iconColor: const Color(0xFFE67E22),
            children: [
              _ToolTile(
                icon: Icons.tune_rounded,
                iconColor: const Color(0xFFE67E22),
                title: '激活 Scene',
                subtitle: 'sh /sdcard/.../com.omarea.vtools/up.sh',
                onTap: () => _activateTool(
                  'Scene',
                  'sh /storage/emulated/0/Android/data/com.omarea.vtools/up.sh',
                ),
              ),
              _ToolTile(
                icon: Icons.block_rounded,
                iconColor: const Color(0xFF2ECC71),
                title: '激活黑域',
                subtitle: 'sh /data/data/me.piebridge.brevent/brevent.sh',
                onTap: () => _activateTool(
                  '黑域',
                  'sh /data/data/me.piebridge.brevent/brevent.sh',
                ),
              ),
              _ToolTile(
                icon: Icons.verified_user_rounded,
                iconColor: const Color(0xFF3498DB),
                title: '激活 Shizuku',
                subtitle: 'sh /sdcard/.../moe.shizuku.privileged.api/start.sh',
                onTap: () => _activateTool(
                  'Shizuku',
                  'sh /storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh',
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
        ],
      );
  }
}

// ── 结果提示条 ─────────────────────────────────────────────────────────────────

class _ResultBar extends StatelessWidget {
  final String message;
  final bool ok;
  final VoidCallback onDismiss;
  const _ResultBar({required this.message, required this.ok, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final color = ok ? AppTheme.success : AppTheme.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(children: [
        Icon(
          ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
          size: 15, color: color,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 11,
          color: color,
        ))),
        GestureDetector(
          onTap: onDismiss,
          child: Icon(Icons.close_rounded, size: 14, color: color.withOpacity(0.6)),
        ),
      ]),
    );
  }
}

// ── 工具分组 ───────────────────────────────────────────────────────────────────

class _ToolGroup extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final List<_ToolTile> children;

  const _ToolGroup({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 分组标题
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Row(children: [
          Container(
            width: 20, height: 20,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(icon, size: 12, color: iconColor),
          ),
          const SizedBox(width: 7),
          Text(title, style: TextStyle(
            fontFamily: 'SpaceMono', fontSize: 11,
            fontWeight: FontWeight.w600,
            color: iconColor,
            letterSpacing: 0.3,
          )),
        ]),
      ),
      // 卡片
      Container(
        decoration: BoxDecoration(
          color: AppTheme.bg1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.bg3),
        ),
        child: Column(
          children: List.generate(children.length, (i) {
            return Column(children: [
              children[i],
              if (i < children.length - 1)
                const Divider(height: 1, indent: 56, endIndent: 0, color: AppTheme.bg3),
            ]);
          }),
        ),
      ),
    ]);
  }
}

// ── 工具条目 ───────────────────────────────────────────────────────────────────

class _ToolTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool loading;

  const _ToolTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(9),
            ),
            child: loading
                ? Padding(
                    padding: const EdgeInsets.all(9),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(iconColor),
                    ),
                  )
                : Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 13,
                fontWeight: FontWeight.w600,
                color: onTap == null ? AppTheme.textMuted : AppTheme.textPrimary,
              )),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 11,
                color: AppTheme.textMuted,
              )),
            ],
          )),
          Icon(
            Icons.chevron_right_rounded,
            size: 16,
            color: onTap == null ? AppTheme.bg3 : AppTheme.textMuted,
          ),
        ]),
      ),
    );
  }
}

// ── 动画速率弹窗 ───────────────────────────────────────────────────────────────

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
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: const Text('修改动画速率', style: TextStyle(
        fontFamily: 'SpaceMono', fontSize: 15,
        fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
      )),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            _scale == 0 ? '关闭（最快）' : '${_scale}x',
            style: TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 28,
              fontWeight: FontWeight.w700,
              color: _scale == 0 ? AppTheme.success : AppTheme.primary,
            ),
          ),
        ),
        Slider(
          value: _scale,
          min: 0, max: 3,
          divisions: 6,
          activeColor: AppTheme.primary,
          inactiveColor: AppTheme.bg3,
          onChanged: (v) => setState(() => _scale = v),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('0 = 关闭', style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, color: AppTheme.textMuted)),
          const Text('1x = 默认', style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, color: AppTheme.textMuted)),
          const Text('3x = 最慢', style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, color: AppTheme.textMuted)),
        ]),
        const SizedBox(height: 8),
        // 快捷按钮
        Wrap(spacing: 6, children: [
          for (final v in [0.0, 0.5, 1.0, 1.5, 2.0])
            ActionChip(
              label: Text(v == 0 ? '关闭' : '${v}x', style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 11,
                color: _scale == v ? AppTheme.bg0 : AppTheme.textSecondary,
              )),
              backgroundColor: _scale == v ? AppTheme.primary : AppTheme.bg3,
              onPressed: () => setState(() => _scale = v),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
        ]),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(fontFamily: 'SpaceMono', color: AppTheme.textSecondary)),
        ),
        FilledButton(
          onPressed: () => widget.onSet(_scale),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
          child: const Text('应用', style: TextStyle(fontFamily: 'SpaceMono')),
        ),
      ],
    );
  }
}

// ── 分辨率弹窗 ─────────────────────────────────────────────────────────────────

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
    ('720×1280', 720, 1280),
    ('1080×1920', 1080, 1920),
    ('1080×2400', 1080, 2400),
    ('1440×2560', 1440, 2560),
    ('1440×3200', 1440, 3200),
  ];

  @override
  void dispose() {
    _wCtrl.dispose(); _hCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: const Text('修改屏幕分辨率', style: TextStyle(
        fontFamily: 'SpaceMono', fontSize: 15,
        fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
      )),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('快捷预设', style: TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.textMuted,
        )),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6,
          children: _presets.map((p) => ActionChip(
            label: Text(p.$1, style: const TextStyle(
              fontFamily: 'SpaceMono', fontSize: 11, color: AppTheme.textSecondary,
            )),
            onPressed: () => setState(() {
              _wCtrl.text = '${p.$2}';
              _hCtrl.text = '${p.$3}';
            }),
          )).toList(),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: TextField(
            controller: _wCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14),
            decoration: const InputDecoration(labelText: '宽度 (px)'),
          )),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text('×', style: TextStyle(color: AppTheme.textMuted, fontSize: 22)),
          ),
          Expanded(child: TextField(
            controller: _hCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14),
            decoration: const InputDecoration(labelText: '高度 (px)'),
          )),
        ]),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(fontFamily: 'SpaceMono', color: AppTheme.textSecondary)),
        ),
        OutlinedButton(
          onPressed: widget.onReset,
          child: const Text('恢复默认', style: TextStyle(fontFamily: 'SpaceMono')),
        ),
        FilledButton(
          onPressed: () {
            final w = int.tryParse(_wCtrl.text);
            final h = int.tryParse(_hCtrl.text);
            if (w != null && h != null) widget.onSet(w, h);
          },
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
          child: const Text('应用', style: TextStyle(fontFamily: 'SpaceMono')),
        ),
      ],
    );
  }
}

// ── DPI 弹窗 ───────────────────────────────────────────────────────────────────

class _DpiDialog extends StatefulWidget {
  final void Function(int) onSet;
  final VoidCallback onReset;
  const _DpiDialog({required this.onSet, required this.onReset});
  @override
  State<_DpiDialog> createState() => _DpiDialogState();
}

class _DpiDialogState extends State<_DpiDialog> {
  final _ctrl = TextEditingController();

  final _presets = const [
    ('mdpi\n160', 160),
    ('hdpi\n240', 240),
    ('xhdpi\n320', 320),
    ('xxhdpi\n480', 480),
    ('xxxhdpi\n640', 640),
  ];

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: const Text('修改 DPI', style: TextStyle(
        fontFamily: 'SpaceMono', fontSize: 15,
        fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
      )),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('快捷预设', style: TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.textMuted,
        )),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6,
          children: _presets.map((p) => ActionChip(
            label: Text(p.$1, textAlign: TextAlign.center, style: const TextStyle(
              fontFamily: 'SpaceMono', fontSize: 10, color: AppTheme.textSecondary,
              height: 1.4,
            )),
            onPressed: () => setState(() => _ctrl.text = '${p.$2}'),
          )).toList(),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _ctrl,
          keyboardType: TextInputType.number,
          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 16),
          decoration: const InputDecoration(
            labelText: '自定义 DPI',
            suffixText: 'dpi',
          ),
        ),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(fontFamily: 'SpaceMono', color: AppTheme.textSecondary)),
        ),
        OutlinedButton(
          onPressed: widget.onReset,
          child: const Text('恢复默认', style: TextStyle(fontFamily: 'SpaceMono')),
        ),
        FilledButton(
          onPressed: () {
            final dpi = int.tryParse(_ctrl.text);
            if (dpi != null && dpi > 0) widget.onSet(dpi);
          },
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
          child: const Text('应用', style: TextStyle(fontFamily: 'SpaceMono')),
        ),
      ],
    );
  }
}

// ── NTP 服务器弹窗 ─────────────────────────────────────────────────────────────

class _NtpDialog extends StatefulWidget {
  final void Function(String) onSet;
  const _NtpDialog({required this.onSet});
  @override
  State<_NtpDialog> createState() => _NtpDialogState();
}

class _NtpDialogState extends State<_NtpDialog> {
  final _ctrl = TextEditingController(text: 'ntp.aliyun.com');

  final _presets = const [
    ('阿里云', 'ntp.aliyun.com'),
    ('腾讯云', 'ntp.tencent.com'),
    ('Google', 'time.google.com'),
    ('Cloudflare', 'time.cloudflare.com'),
    ('国家授时中心', 'ntp.ntsc.ac.cn'),
  ];

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: const Text('修改 NTP 服务器', style: TextStyle(
        fontFamily: 'SpaceMono', fontSize: 15,
        fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
      )),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Wrap(spacing: 6, runSpacing: 6,
          children: _presets.map((p) => ActionChip(
            label: Text(p.$1, style: const TextStyle(
              fontFamily: 'SpaceMono', fontSize: 11, color: AppTheme.textSecondary,
            )),
            onPressed: () => setState(() => _ctrl.text = p.$2),
          )).toList(),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _ctrl,
          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
          decoration: const InputDecoration(
            labelText: 'NTP 服务器地址',
            hintText: 'ntp.aliyun.com',
          ),
        ),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消', style: TextStyle(fontFamily: 'SpaceMono', color: AppTheme.textSecondary)),
        ),
        FilledButton(
          onPressed: () {
            final s = _ctrl.text.trim();
            if (s.isNotEmpty) widget.onSet(s);
          },
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
          child: const Text('应用', style: TextStyle(fontFamily: 'SpaceMono')),
        ),
      ],
    );
  }
}
