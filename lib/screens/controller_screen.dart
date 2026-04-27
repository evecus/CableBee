// lib/screens/controller_screen.dart
// 遥控器页面：按键模式
// 通过 adb shell input keyevent 发送按键

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/adb_service.dart';
import '../utils/theme.dart';

// ─────────────────────────────────────────────────────────────
//  ControllerScreen
// ─────────────────────────────────────────────────────────────
class ControllerScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const ControllerScreen({super.key, this.onActionsChanged});

  @override
  State<ControllerScreen> createState() => ControllerScreenState();
}

class ControllerScreenState extends State<ControllerScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => _pushActions();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pushActions());
  }

  void _pushActions() {
    widget.onActionsChanged?.call([]);
  }

  Future<void> _sendKey(int keyCode) async {
    final adb = context.read<AdbService>();
    await adb.shell('input keyevent $keyCode');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: AppTheme.bg0,
      body: _KeypadView(onKey: _sendKey),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  按键模式 - 遥控器布局
// ─────────────────────────────────────────────────────────────

// Android keyevent 常量
const _kPower      = 26;
const _kBack       = 4;
const _kHome       = 3;
const _kMenu       = 82;
const _kDpadUp     = 19;
const _kDpadDown   = 20;
const _kDpadLeft   = 21;
const _kDpadRight  = 22;
const _kDpadCenter = 23;
const _kVolUp      = 24;
const _kVolDown    = 25;
const _kMute       = 164;
const _k0          = 7;

class _KeypadView extends StatelessWidget {
  final Future<void> Function(int keyCode) onKey;
  const _KeypadView({required this.onKey});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _KeyBtn(icon: Icons.volume_down_rounded, label: '音量-',
              color: AppTheme.textMuted, onTap: () => onKey(_kVolDown)),
          _KeyBtn(icon: Icons.power_settings_new_rounded, label: '电源',
              color: AppTheme.danger, size: 56, onTap: () => onKey(_kPower)),
          _KeyBtn(icon: Icons.volume_up_rounded, label: '音量+',
              color: AppTheme.textMuted, onTap: () => onKey(_kVolUp)),
        ]),
        const SizedBox(height: 20),
        _DpadCluster(onKey: onKey),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _KeyBtn(icon: Icons.menu_rounded,       label: '菜单',
              color: AppTheme.secondary, onTap: () => onKey(_kMenu)),
          _KeyBtn(icon: Icons.home_rounded,       label: '主页',
              color: AppTheme.primary,   onTap: () => onKey(_kHome)),
          _KeyBtn(icon: Icons.arrow_back_rounded, label: '返回',
              color: AppTheme.warning,   onTap: () => onKey(_kBack)),
        ]),
        const SizedBox(height: 24),
        _NumPad(onKey: onKey),
      ]),
    );
  }
}

class _DpadCluster extends StatelessWidget {
  final Future<void> Function(int) onKey;
  const _DpadCluster({required this.onKey});

  @override
  Widget build(BuildContext context) {
    const btnSize = 56.0;
    const centerSize = 68.0;
    return SizedBox(
      width: btnSize * 3 + 8,
      height: btnSize * 3 + 8,
      child: Stack(alignment: Alignment.center, children: [
        Container(
          width: btnSize * 3 + 8,
          height: btnSize * 3 + 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.bg1,
            border: Border.all(color: AppTheme.bg3, width: 1.5),
          ),
        ),
        Positioned(top: 0,
            child: _DpadArrow(icon: Icons.keyboard_arrow_up_rounded,
                onTap: () => onKey(_kDpadUp))),
        Positioned(bottom: 0,
            child: _DpadArrow(icon: Icons.keyboard_arrow_down_rounded,
                onTap: () => onKey(_kDpadDown))),
        Positioned(left: 0,
            child: _DpadArrow(icon: Icons.keyboard_arrow_left_rounded,
                onTap: () => onKey(_kDpadLeft))),
        Positioned(right: 0,
            child: _DpadArrow(icon: Icons.keyboard_arrow_right_rounded,
                onTap: () => onKey(_kDpadRight))),
        GestureDetector(
          onTap: () => onKey(_kDpadCenter),
          child: Container(
            width: centerSize, height: centerSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.primary,
              boxShadow: [
                BoxShadow(color: AppTheme.primary.withOpacity(0.35),
                    blurRadius: 12, spreadRadius: 2),
              ],
            ),
            child: const Center(
              child: Text('OK', style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 16,
                fontWeight: FontWeight.w800, color: Colors.white,
              )),
            ),
          ),
        ),
      ]),
    );
  }
}

class _DpadArrow extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _DpadArrow({required this.icon, required this.onTap});
  @override
  State<_DpadArrow> createState() => _DpadArrowState();
}

class _DpadArrowState extends State<_DpadArrow> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) { setState(() => _pressed = true); widget.onTap(); },
      onTapUp:   (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: 56, height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _pressed ? AppTheme.primary.withOpacity(0.2) : Colors.transparent,
        ),
        child: Icon(widget.icon, size: 30,
            color: _pressed ? AppTheme.primary : AppTheme.textSecondary),
      ),
    );
  }
}

class _NumPad extends StatelessWidget {
  final Future<void> Function(int) onKey;
  const _NumPad({required this.onKey});

  @override
  Widget build(BuildContext context) {
    final nums = [
      ['1','2','3'],
      ['4','5','6'],
      ['7','8','9'],
      [' ','0',' '],
    ];
    return Column(
      children: nums.map((row) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: row.map((n) {
            if (n == ' ') return const SizedBox(width: 64, height: 56);
            return _NumBtn(n: n, onTap: () => onKey(_k0 + int.parse(n)));
          }).toList(),
        ),
      )).toList(),
    );
  }
}

class _NumBtn extends StatefulWidget {
  final String n;
  final VoidCallback onTap;
  const _NumBtn({required this.n, required this.onTap});
  @override
  State<_NumBtn> createState() => _NumBtnState();
}

class _NumBtnState extends State<_NumBtn> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) { setState(() => _pressed = true); widget.onTap(); },
      onTapUp:   (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: 64, height: 56,
        decoration: BoxDecoration(
          color: _pressed ? AppTheme.primary : AppTheme.bg1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _pressed ? AppTheme.primary : AppTheme.bg3,
            width: 1.5,
          ),
          boxShadow: _pressed ? [] : [
            BoxShadow(color: Colors.black.withOpacity(0.08),
                blurRadius: 4, offset: const Offset(0, 2)),
          ],
        ),
        child: Center(
          child: Text(widget.n, style: TextStyle(
            fontFamily: 'SpaceMono', fontSize: 20,
            fontWeight: FontWeight.w700,
            color: _pressed ? Colors.white : AppTheme.textPrimary,
          )),
        ),
      ),
    );
  }
}

class _KeyBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double size;
  final VoidCallback onTap;
  const _KeyBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.size = 52,
  });
  @override
  State<_KeyBtn> createState() => _KeyBtnState();
}

class _KeyBtnState extends State<_KeyBtn> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) { setState(() => _pressed = true); widget.onTap(); },
      onTapUp:   (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: Column(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          width: widget.size, height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _pressed
                ? widget.color.withOpacity(0.25)
                : widget.color.withOpacity(0.1),
            border: Border.all(
              color: _pressed ? widget.color : widget.color.withOpacity(0.3),
              width: 1.5,
            ),
          ),
          child: Icon(widget.icon, size: widget.size * 0.42, color: widget.color),
        ),
        const SizedBox(height: 4),
        Text(widget.label, style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 10,
          color: widget.color.withOpacity(0.8),
        )),
      ]),
    );
  }
}
