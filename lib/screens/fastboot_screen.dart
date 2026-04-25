import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/fastboot_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';
import '../widgets/local_file_picker.dart';

class FastbootScreen extends StatefulWidget {
  const FastbootScreen({super.key});
  @override
  State<FastbootScreen> createState() => _FastbootScreenState();
}

class _FastbootScreenState extends State<FastbootScreen> {
  final _cmdCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _busy = false;
  final _outputLines = <String>[];

  @override
  void dispose() {
    _cmdCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final results = await showLocalFilePicker(
      context,
      allowMultiple: false,
      allowFolders: false,
    );
    if (results == null || results.isEmpty) return;
    final path = results.first;
    setState(() {
      final current = _cmdCtrl.text.trimRight();
      _cmdCtrl.text = current.isEmpty ? path : '$current $path';
      _cmdCtrl.selection = TextSelection.collapsed(offset: _cmdCtrl.text.length);
    });
  }

  Future<void> _execute() async {
    final cmd = _cmdCtrl.text.trim();
    if (cmd.isEmpty) return;
    FocusScope.of(context).unfocus();

    setState(() {
      _busy = true;
      _outputLines.add('\$ $cmd');
    });
    _scrollToBottom();

    String fullCmd = cmd;
    if (!cmd.startsWith('fastboot ') && cmd != 'fastboot') {
      fullCmd = 'fastboot $cmd';
    }

    final parts = fullCmd.split(RegExp(r'\s+'));
    final args = parts.sublist(1);

    final fb = context.read<FastbootService>();
    FastbootResult result;

    if (args.isEmpty) {
      result = await fb.devices();
    } else {
      final sub = args[0];
      if (sub == 'flash' && args.length >= 3) {
        result = await fb.flash(args[1], args.sublist(2).join(' '));
      } else if (sub == 'erase' && args.length >= 2) {
        result = await fb.erase(args[1]);
      } else if (sub == 'reboot') {
        result = await fb.reboot(args.length >= 2 ? args[1] : null);
      } else if (sub == 'flashing' && args.length >= 2 && args[1] == 'unlock') {
        result = await fb.oemUnlock();
      } else if (sub == 'flashing' && args.length >= 2 && args[1] == 'lock') {
        result = await fb.oemLock();
      } else if (sub == 'getvar' && args.length >= 2) {
        result = await fb.getVar(args[1]);
      } else {
        result = await fb.runRaw(args);
      }
    }

    final out = result.output.trim();
    setState(() {
      _busy = false;
      if (out.isNotEmpty) _outputLines.addAll(out.split('\n'));
      _outputLines.add('');
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clearOutput() => setState(() => _outputLines.clear());

  void _fillCmd(String cmd) {
    setState(() {
      _cmdCtrl.text = cmd;
      _cmdCtrl.selection = TextSelection.collapsed(offset: cmd.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        backgroundColor: AppTheme.bg0,
        elevation: 0,
        title: const Text('Fastboot', style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 16, fontWeight: FontWeight.w700,
          color: AppTheme.textPrimary,
        )),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_rounded, size: 20, color: AppTheme.textMuted),
            tooltip: '清空输出',
            onPressed: _clearOutput,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [

          // ── 设备状态卡片 ──
          _DeviceStatusCard(),

          const SizedBox(height: 12),

          // ── 命令输入 + 终端输出 卡片 ──
          Container(
            decoration: BoxDecoration(
              color: AppTheme.bg1,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.bg3),
            ),
            child: Column(children: [

              // 命令输入行
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _cmdCtrl,
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono', fontSize: 13,
                        color: AppTheme.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: 'fastboot flash recovery ...',
                        hintStyle: const TextStyle(
                          fontFamily: 'JetBrainsMono', fontSize: 12,
                          color: AppTheme.textMuted,
                        ),
                        prefixIcon: const Padding(
                          padding: EdgeInsets.only(left: 10, right: 6),
                          child: Text('\$', style: TextStyle(
                            fontFamily: 'JetBrainsMono', fontSize: 14,
                            color: AppTheme.primary, fontWeight: FontWeight.w700,
                          )),
                        ),
                        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                        suffixIcon: _cmdCtrl.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close_rounded, size: 15, color: AppTheme.textMuted),
                                onPressed: () => setState(() => _cmdCtrl.clear()),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              )
                            : null,
                        filled: true,
                        fillColor: AppTheme.bg0,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppTheme.bg3),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppTheme.bg3),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppTheme.primary, width: 1.5),
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _execute(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _IconBtn(
                    icon: Icons.folder_open_rounded,
                    tooltip: '选择本机文件',
                    color: AppTheme.warning,
                    onTap: _pickFile,
                  ),
                  const SizedBox(width: 6),
                  _ExecBtn(busy: _busy, onTap: _execute),
                ]),
              ),

              const SizedBox(height: 10),

              // 终端输出框
              Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                height: 220,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF1A1A1A), width: 1.5),
                ),
                child: _outputLines.isEmpty
                    ? const Center(child: Text('等待执行...', style: TextStyle(
                        fontFamily: 'JetBrainsMono', fontSize: 12,
                        color: Color(0xFFAAAAAA),
                      )))
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(10),
                        itemCount: _outputLines.length,
                        itemBuilder: (_, i) {
                          final line = _outputLines[i];
                          final isCmd = line.startsWith('\$');
                          Color lineColor;
                          if (isCmd) {
                            lineColor = AppTheme.primary;
                          } else if (line.toLowerCase().contains('error') ||
                              line.toLowerCase().contains('fail') ||
                              line.toLowerCase().contains('failed')) {
                            lineColor = AppTheme.danger;
                          } else if (line.toLowerCase().contains('okay') ||
                              line.toLowerCase().contains('success') ||
                              line.toLowerCase().contains('finished')) {
                            lineColor = AppTheme.success;
                          } else {
                            lineColor = const Color(0xFF1A1A1A);
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(line, style: TextStyle(
                              fontFamily: 'JetBrainsMono', fontSize: 12,
                              color: lineColor, height: 1.5,
                            )),
                          );
                        },
                      ),
              ),
            ]),
          ),

          const SizedBox(height: 24),

          // ── 快捷命令 ──
          const SectionHeader(title: '快捷命令'),
          const SizedBox(height: 8),

          Container(
            decoration: BoxDecoration(
              color: AppTheme.bg1,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.bg3),
            ),
            child: Column(
              children: _quickCmds.asMap().entries.map((entry) {
                final i = entry.key;
                final cmd = entry.value;
                final isLast = i == _quickCmds.length - 1;
                return Column(children: [
                  _QuickCmdTile(
                    title: cmd.title,
                    command: cmd.command,
                    copyCommand: cmd.copyCommand,
                    iconColor: cmd.color,
                    icon: cmd.icon,
                    onFill: () => _fillCmd(cmd.command),
                  ),
                  if (!isLast)
                    const Divider(height: 1, indent: 56, color: AppTheme.bg3),
                ]);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(Color color) => Container(
    width: 10, height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

// ── 快捷命令数据 ───────────────────────────────────────────────────────────────

class _CmdData {
  final String title;
  final String command;
  final String copyCommand;
  final IconData icon;
  final Color color;
  const _CmdData({
    required this.title, required this.command, required this.copyCommand,
    required this.icon, required this.color,
  });
}

const _quickCmds = [
  _CmdData(title: '重启系统', command: 'fastboot reboot',
    copyCommand: 'fastboot reboot', icon: Icons.restart_alt_rounded, color: AppTheme.success),
  _CmdData(title: '重启到恢复模式', command: 'fastboot reboot recovery',
    copyCommand: 'fastboot reboot recovery', icon: Icons.build_circle_outlined, color: AppTheme.warning),
  _CmdData(title: '重启到 Bootloader 模式', command: 'fastboot reboot bootloader',
    copyCommand: 'fastboot reboot bootloader', icon: Icons.developer_mode_rounded, color: AppTheme.textMuted),
  _CmdData(title: '重启到 Fastboot 模式', command: 'fastboot reboot fastboot',
    copyCommand: 'fastboot reboot fastboot', icon: Icons.flash_on_rounded, color: AppTheme.primary),
  _CmdData(title: '解锁 Bootloader', command: 'fastboot flashing unlock',
    copyCommand: 'fastboot flashing unlock', icon: Icons.lock_open_rounded, color: AppTheme.danger),
  _CmdData(title: '回锁 Bootloader', command: 'fastboot flashing lock',
    copyCommand: 'fastboot flashing lock', icon: Icons.lock_rounded, color: AppTheme.warning),
  _CmdData(title: '刷写分区', command: 'fastboot flash ',
    copyCommand: 'fastboot flash', icon: Icons.system_update_rounded, color: AppTheme.primary),
  _CmdData(title: '擦除分区', command: 'fastboot erase ',
    copyCommand: 'fastboot erase', icon: Icons.delete_forever_rounded, color: AppTheme.danger),
  _CmdData(title: '查看设备所有变量', command: 'fastboot getvar all',
    copyCommand: 'fastboot getvar all', icon: Icons.info_outline_rounded, color: AppTheme.textSecondary),
  _CmdData(title: '列出已连接设备', command: 'fastboot devices',
    copyCommand: 'fastboot devices', icon: Icons.usb_rounded, color: AppTheme.success),
  _CmdData(title: '刷入 boot.img', command: 'fastboot flash boot ',
    copyCommand: 'fastboot flash boot', icon: Icons.memory_rounded, color: AppTheme.primary),
  _CmdData(title: '刷入 recovery.img', command: 'fastboot flash recovery ',
    copyCommand: 'fastboot flash recovery', icon: Icons.health_and_safety_outlined, color: AppTheme.primary),
  _CmdData(title: '刷入 vbmeta（禁用校验）',
    command: 'fastboot flash vbmeta --disable-verity --disable-verification ',
    copyCommand: 'fastboot flash vbmeta --disable-verity --disable-verification',
    icon: Icons.verified_user_outlined, color: AppTheme.warning),
  _CmdData(title: '擦除 userdata', command: 'fastboot erase userdata',
    copyCommand: 'fastboot erase userdata', icon: Icons.delete_outline_rounded, color: AppTheme.danger),
  _CmdData(title: '擦除 cache', command: 'fastboot erase cache',
    copyCommand: 'fastboot erase cache', icon: Icons.cleaning_services_rounded, color: AppTheme.warning),
  _CmdData(title: '格式化 userdata', command: 'fastboot format userdata',
    copyCommand: 'fastboot format userdata', icon: Icons.format_color_reset_rounded, color: AppTheme.danger),
  _CmdData(title: '设置活跃槽位为 a', command: 'fastboot set_active a',
    copyCommand: 'fastboot set_active a', icon: Icons.swap_horiz_rounded, color: AppTheme.textSecondary),
  _CmdData(title: '设置活跃槽位为 b', command: 'fastboot set_active b',
    copyCommand: 'fastboot set_active b', icon: Icons.swap_horiz_rounded, color: AppTheme.textSecondary),
  _CmdData(title: '查看电池电量', command: 'fastboot getvar battery-voltage',
    copyCommand: 'fastboot getvar battery-voltage', icon: Icons.battery_full_rounded, color: AppTheme.success),
  _CmdData(title: '查看 bootloader 锁定状态', command: 'fastboot getvar unlocked',
    copyCommand: 'fastboot getvar unlocked', icon: Icons.security_rounded, color: AppTheme.textSecondary),
];

// ── 快捷命令条目 ───────────────────────────────────────────────────────────────

class _QuickCmdTile extends StatelessWidget {
  final String title;
  final String command;
  final String copyCommand;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onFill;

  const _QuickCmdTile({
    required this.title, required this.command, required this.copyCommand,
    required this.icon, required this.iconColor, required this.onFill,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onFill,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(
                fontFamily: 'SpaceMono', fontSize: 12,
                fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
              )),
              const SizedBox(height: 2),
              Text(copyCommand, style: const TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 10, color: AppTheme.textMuted,
              ), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          )),
          _CopyBtn(text: copyCommand),
        ]),
      ),
    );
  }
}

// ── 复制按钮 ───────────────────────────────────────────────────────────────────

class _CopyBtn extends StatefulWidget {
  final String text;
  const _CopyBtn({required this.text});
  @override
  State<_CopyBtn> createState() => _CopyBtnState();
}

class _CopyBtnState extends State<_CopyBtn> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _copy,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: _copied ? AppTheme.success.withOpacity(0.12) : AppTheme.bg3.withOpacity(0.5),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(
          _copied ? Icons.check_rounded : Icons.copy_rounded,
          size: 14,
          color: _copied ? AppTheme.success : AppTheme.textMuted,
        ),
      ),
    );
  }
}

// ── 图标按钮 ───────────────────────────────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  const _IconBtn({required this.icon, required this.tooltip, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}

// ── 执行按钮 ───────────────────────────────────────────────────────────────────

class _ExecBtn extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;

  const _ExecBtn({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: busy ? AppTheme.primary.withOpacity(0.5) : AppTheme.primary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (busy)
            const SizedBox(width: 13, height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            )
          else
            const Icon(Icons.play_arrow_rounded, size: 18, color: Colors.white),
          const SizedBox(width: 5),
          Text(busy ? '执行中' : '执行', style: const TextStyle(
            fontFamily: 'SpaceMono', fontSize: 12,
            fontWeight: FontWeight.w700, color: Colors.white,
          )),
        ]),
      ),
    );
  }
}

// ── 设备状态卡片 ───────────────────────────────────────────────────────────────

class _DeviceStatusCard extends StatelessWidget {
  const _DeviceStatusCard();

  @override
  Widget build(BuildContext context) {
    final fb = context.watch<FastbootService>();
    final connected = fb.deviceConnected;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: connected
              ? AppTheme.success.withOpacity(0.4)
              : AppTheme.warning.withOpacity(0.4),
        ),
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: connected
                ? AppTheme.success.withOpacity(0.12)
                : AppTheme.warning.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            connected ? Icons.usb_rounded : Icons.usb_off_rounded,
            size: 20,
            color: connected ? AppTheme.success : AppTheme.warning,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              connected ? 'Fastboot 设备已连接' : '未检测到 Fastboot 设备',
              style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 13,
                fontWeight: FontWeight.w700,
                color: connected ? AppTheme.success : AppTheme.warning,
              ),
            ),
            if (fb.deviceSerial != null) ...[ 
              const SizedBox(height: 3),
              Text(fb.deviceSerial!, style: const TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 11,
                color: AppTheme.textMuted,
              )),
            ] else ...[ 
              const SizedBox(height: 3),
              const Text('通过 USB OTG 连接设备并进入 Fastboot 模式', style: TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 11,
                color: AppTheme.textMuted,
              )),
            ],
          ],
        )),
        // 刷新按钮
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 18, color: AppTheme.textMuted),
          tooltip: '刷新设备状态',
          onPressed: () => context.read<FastbootService>().devices(),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ]),
    );
  }
}
