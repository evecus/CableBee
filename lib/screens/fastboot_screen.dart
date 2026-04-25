import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/fastboot_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

class FastbootScreen extends StatefulWidget {
  const FastbootScreen({super.key});
  @override
  State<FastbootScreen> createState() => _FastbootScreenState();
}

class _FastbootScreenState extends State<FastbootScreen> {
  Map<String, String> _vars = {};
  bool _loading = false;
  bool _busy = false;
  String? _lastOutput;
  final _outputHistory = <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkDevice());
  }

  Future<void> _checkDevice() async {
    setState(() => _loading = true);
    final fb = context.read<FastbootService>();
    await fb.devices();
    if (fb.deviceConnected) {
      final vars = await fb.getAllVars();
      setState(() { _vars = vars; });
    }
    setState(() => _loading = false);
  }

  Future<void> _exec(Future<FastbootResult> Function() action) async {
    setState(() { _busy = true; _lastOutput = null; });
    final r = await action();
    setState(() {
      _busy = false;
      _lastOutput = r.output;
      _outputHistory.insert(0, r.output);
      if (_outputHistory.length > 20) _outputHistory.removeLast();
    });
  }

  Future<void> _flashPartition() async {
    final partition = await showInputDialog(context,
      title: '刷写分区',
      hint: '例如 boot、recovery、system、vendor',
    );
    if (partition == null || partition.isEmpty) return;

    final file = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Select .img file for $partition',
    );
    if (file == null || file.files.single.path == null) return;

    final ok = await showConfirmDialog(context,
      title: 'Flash $partition',
      message: 'Flash "${file.files.single.name}" to partition "$partition"?\n\n'
          'Flashing the wrong image can brick your device.',
      confirmText: '刷写',
      destructive: true,
    );
    if (ok != true) return;

    await _exec(() => context.read<FastbootService>()
        .flash(partition, file.files.single.path!));
    _checkDevice();
  }

  Future<void> _erasePartition() async {
    final partition = await showInputDialog(context,
      title: '擦除分区',
      hint: '例如 userdata、cache',
    );
    if (partition == null || partition.isEmpty) return;

    final ok = await showConfirmDialog(context,
      title: 'Erase $partition',
      message: 'Erase partition "$partition"?\n\nAll data on this partition will be lost.',
      confirmText: 'Erase',
      destructive: true,
    );
    if (ok != true) return;

    await _exec(() => context.read<FastbootService>().erase(partition));
  }

  @override
  Widget build(BuildContext context) {
    final fb = context.watch<FastbootService>();

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        title: const Text('Fastboot'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: _checkDevice,
            color: AppTheme.textMuted,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [

          // ── Device status ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: TintedCard(
              borderColor: fb.deviceConnected
                  ? AppTheme.success.withOpacity(0.4)
                  : AppTheme.warning.withOpacity(0.4),
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: fb.deviceConnected
                        ? AppTheme.success.withOpacity(0.12)
                        : AppTheme.warning.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    fb.deviceConnected
                        ? Icons.usb_rounded
                        : Icons.usb_off_rounded,
                    color: fb.deviceConnected ? AppTheme.success : AppTheme.warning,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fb.deviceConnected ? 'Device in Fastboot' : 'No Fastboot Device',
                      style: TextStyle(
                        fontFamily: 'SpaceMono', fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: fb.deviceConnected
                            ? AppTheme.success : AppTheme.warning,
                      ),
                    ),
                    if (fb.deviceSerial != null) ...[
                      const SizedBox(height: 3),
                      Text(fb.deviceSerial!, style: const TextStyle(
                        fontFamily: 'JetBrainsMono', fontSize: 11,
                        color: AppTheme.textMuted,
                      )),
                    ],
                  ],
                )),
                if (_loading)
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(AppTheme.primary),
                    ),
                  ),
              ]),
            ),
          ),

          if (!fb.deviceConnected) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TintedCard(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('How to enter Fastboot mode', style: TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 12,
                    fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
                  )),
                  const SizedBox(height: 8),
                  const Text(
                    '• Connect device via USB OTG\n'
                    '• Hold Power + Volume Down until fastboot screen\n'
                    '• Or use ADB → Tools → Reboot to Bootloader',
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono', fontSize: 12,
                      color: AppTheme.textSecondary, height: 1.7,
                    ),
                  ),
                ]),
              ),
            ),
          ],

          // ── Device vars ────────────────────────────────────────
          if (_vars.isNotEmpty) ...[
            const SectionHeader(title: '设备变量'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TintedCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: _vars.entries.take(12).map((e) => Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(children: [
                        Expanded(flex: 2, child: Text(e.key, style: const TextStyle(
                          fontFamily: 'SpaceMono', fontSize: 11,
                          color: AppTheme.textMuted,
                        ))),
                        Expanded(flex: 3, child: Text(e.value, style: const TextStyle(
                          fontFamily: 'JetBrainsMono', fontSize: 12,
                          color: AppTheme.textPrimary,
                        ))),
                      ]),
                    ),
                    if (e.key != _vars.keys.skip(11).first)
                      const Divider(height: 1, indent: 14),
                  ])).toList(),
                ),
              ),
            ),
          ],

          // ── Flash & Erase ──────────────────────────────────────
          const SectionHeader(title: '刷写 / 擦除'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                ActionTile(
                  icon: Icons.flash_on_rounded,
                  title: '刷写分区',
                  subtitle: '选择 .img 文件和目标分区',
                  iconColor: AppTheme.warning,
                  enabled: fb.deviceConnected && !_busy,
                  onTap: _flashPartition,
                ),
                const Divider(height: 1, indent: 60),
                ActionTile(
                  icon: Icons.delete_forever_rounded,
                  title: '擦除分区',
                  subtitle: '清空指定分区（如 userdata、cache）',
                  iconColor: AppTheme.danger,
                  enabled: fb.deviceConnected && !_busy,
                  onTap: _erasePartition,
                ),
              ]),
            ),
          ),

          // ── Bootloader lock / unlock ────────────────────────────
          const SectionHeader(title: 'Bootloader'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                ActionTile(
                  icon: Icons.lock_open_rounded,
                  title: '解锁 Bootloader',
                  subtitle: 'fastboot flashing unlock — 将清空设备数据',
                  iconColor: AppTheme.danger,
                  enabled: fb.deviceConnected && !_busy,
                  onTap: () async {
                    final ok = await showConfirmDialog(context,
                      title: '解锁 Bootloader',
                      message: '此操作将清空设备全部数据，'
                          'void warranty on some devices.\n\nAre you sure?',
                      confirmText: '解锁',
                      destructive: true,
                    );
                    if (ok == true) _exec(() => context.read<FastbootService>().oemUnlock());
                  },
                ),
                const Divider(height: 1, indent: 60),
                ActionTile(
                  icon: Icons.lock_rounded,
                  title: '锁定 Bootloader',
                  subtitle: 'fastboot flashing lock',
                  iconColor: AppTheme.warning,
                  enabled: fb.deviceConnected && !_busy,
                  onTap: () async {
                    final ok = await showConfirmDialog(context,
                      title: '锁定 Bootloader',
                      message: '确认锁定 Bootloader？设备可能会清除数据。',
                      confirmText: '锁定',
                    );
                    if (ok == true) _exec(() => context.read<FastbootService>().oemLock());
                  },
                ),
              ]),
            ),
          ),

          // ── Reboot ────────────────────────────────────────────
          const SectionHeader(title: '重启'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                ActionTile(
                  icon: Icons.restart_alt_rounded,
                  title: '重启到系统',
                  subtitle: '退出 Fastboot，正常开机',
                  enabled: fb.deviceConnected && !_busy,
                  onTap: () => _exec(() => context.read<FastbootService>().reboot()),
                ),
                const Divider(height: 1, indent: 60),
                ActionTile(
                  icon: Icons.build_circle_outlined,
                  title: '重启到 Recovery',
                  enabled: fb.deviceConnected && !_busy,
                  iconColor: AppTheme.warning,
                  onTap: () => _exec(() => context.read<FastbootService>().reboot('recovery')),
                ),
                const Divider(height: 1, indent: 60),
                ActionTile(
                  icon: Icons.developer_mode_rounded,
                  title: '重启到 Bootloader',
                  enabled: fb.deviceConnected && !_busy,
                  iconColor: AppTheme.textMuted,
                  onTap: () => _exec(() => context.read<FastbootService>().reboot('bootloader')),
                ),
              ]),
            ),
          ),

          // ── Output ────────────────────────────────────────────
          if (_lastOutput != null) ...[
            const SectionHeader(title: '输出'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TerminalBox(text: _lastOutput!),
            ),
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
