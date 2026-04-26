// lib/screens/controller_screen.dart
// 遥控器页面：按键模式 + 鼠标模式
// 按键模式：模拟遥控器布局，通过 adb shell input keyevent 发送按键
// 鼠标模式：触摸板区域，滑动 → 移动光标（input mouse move），点击 → 左键点击

import 'dart:async';

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

  // 0 = 按键模式，1 = 鼠标模式
  int _mode = 0;

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
      body: Column(
        children: [
          // ── 顶部模式切换栏 ──
          _ModeBar(
            selected: _mode,
            onSelect: (i) => setState(() => _mode = i),
          ),
          const Divider(height: 1),
          // ── 内容区 ──
          Expanded(
            child: _mode == 0
                ? _KeypadView(onKey: _sendKey)
                : _MousepadView(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  顶部模式切换栏
// ─────────────────────────────────────────────────────────────
class _ModeBar extends StatelessWidget {
  final int selected;
  final void Function(int) onSelect;
  const _ModeBar({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: AppTheme.bg1,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          _ModeBtn(label: '⌨  按键', selected: selected == 0, onTap: () => onSelect(0)),
          const SizedBox(width: 10),
          _ModeBtn(label: '🖱  鼠标', selected: selected == 1, onTap: () => onSelect(1)),
        ],
      ),
    );
  }
}

class _ModeBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ModeBtn({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : AppTheme.bg3,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'SpaceMono',
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: selected ? Colors.white : AppTheme.textMuted,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  按键模式 - 遥控器布局
// ─────────────────────────────────────────────────────────────

// Android keyevent 常量
const _kPower   = 26;
const _kBack    = 4;
const _kHome    = 3;
const _kMenu    = 82;
const _kDpadUp    = 19;
const _kDpadDown  = 20;
const _kDpadLeft  = 21;
const _kDpadRight = 22;
const _kDpadCenter = 23; // 确认/OK
const _kVolUp   = 24;
const _kVolDown = 25;
const _kMute    = 164;
const _k0 = 7;  // keycode 0-9: 7~16

class _KeypadView extends StatelessWidget {
  final Future<void> Function(int keyCode) onKey;
  const _KeypadView({required this.onKey});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(children: [
        // ── 第一行：音量 + 电源 + 静音 ──
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _KeyBtn(icon: Icons.volume_down_rounded, label: '音量-',
              color: AppTheme.textMuted, onTap: () => onKey(_kVolDown)),
          _KeyBtn(icon: Icons.power_settings_new_rounded, label: '电源',
              color: AppTheme.danger, size: 56, onTap: () => onKey(_kPower)),
          _KeyBtn(icon: Icons.volume_up_rounded, label: '音量+',
              color: AppTheme.textMuted, onTap: () => onKey(_kVolUp)),
        ]),

        const SizedBox(height: 20),

        // ── 方向键 + 确认键（D-pad） ──
        _DpadCluster(onKey: onKey),

        const SizedBox(height: 20),

        // ── 功能键：菜单 / 主页 / 返回 ──
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _KeyBtn(icon: Icons.menu_rounded,           label: '菜单',
              color: AppTheme.secondary, onTap: () => onKey(_kMenu)),
          _KeyBtn(icon: Icons.home_rounded,           label: '主页',
              color: AppTheme.primary,   onTap: () => onKey(_kHome)),
          _KeyBtn(icon: Icons.arrow_back_rounded,     label: '返回',
              color: AppTheme.warning,   onTap: () => onKey(_kBack)),
        ]),

        const SizedBox(height: 24),

        // ── 数字键盘 ──
        _NumPad(onKey: onKey),
      ]),
    );
  }
}

// D-pad 方向键 + 中间确认
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
        // 背景圆形
        Container(
          width: btnSize * 3 + 8,
          height: btnSize * 3 + 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.bg1,
            border: Border.all(color: AppTheme.bg3, width: 1.5),
          ),
        ),
        // 上
        Positioned(
          top: 0,
          child: _DpadArrow(icon: Icons.keyboard_arrow_up_rounded,
              onTap: () => onKey(_kDpadUp)),
        ),
        // 下
        Positioned(
          bottom: 0,
          child: _DpadArrow(icon: Icons.keyboard_arrow_down_rounded,
              onTap: () => onKey(_kDpadDown)),
        ),
        // 左
        Positioned(
          left: 0,
          child: _DpadArrow(icon: Icons.keyboard_arrow_left_rounded,
              onTap: () => onKey(_kDpadLeft)),
        ),
        // 右
        Positioned(
          right: 0,
          child: _DpadArrow(icon: Icons.keyboard_arrow_right_rounded,
              onTap: () => onKey(_kDpadRight)),
        ),
        // 中心确认
        GestureDetector(
          onTap: () => onKey(_kDpadCenter),
          child: Container(
            width: centerSize,
            height: centerSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.primary,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withOpacity(0.35),
                  blurRadius: 12, spreadRadius: 2,
                ),
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
      onTapDown: (_) { setState(() => _pressed = true);  widget.onTap(); },
      onTapUp:   (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: 56, height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _pressed
              ? AppTheme.primary.withOpacity(0.2)
              : Colors.transparent,
        ),
        child: Icon(widget.icon, size: 30,
          color: _pressed ? AppTheme.primary : AppTheme.textSecondary),
      ),
    );
  }
}

// 数字键盘 0-9
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
      onTapDown: (_) { setState(() => _pressed = true);  widget.onTap(); },
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

// 通用功能键按钮
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
      onTapDown: (_) { setState(() => _pressed = true);  widget.onTap(); },
      onTapUp:   (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: Column(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          width: widget.size,
          height: widget.size,
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
          child: Icon(widget.icon,
              size: widget.size * 0.42, color: widget.color),
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

// ─────────────────────────────────────────────────────────────
//  鼠标模式 - 触摸板
// ─────────────────────────────────────────────────────────────
class _MousepadView extends StatefulWidget {
  @override
  State<_MousepadView> createState() => _MousepadViewState();
}

class _MousepadViewState extends State<_MousepadView> {
  // 鼠标在设备上的当前坐标（从设备中心开始）
  double _mx = 540, _my = 960; // 默认 1080p 中心
  // 光标在触摸板上的显示位置（规范化 0~1）
  double _cursorX = 0.5, _cursorY = 0.5;

  bool _cursorVisible = false;

  // 灵敏度倍率
  double _sensitivity = 2.0;

  // 防抖：避免发送太多命令
  Timer? _moveDebounce;
  Offset? _lastLocal;

  // 设备分辨率（从 wm size 读取）
  int _devW = 1080, _devH = 1920;
  bool _devInfoLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevInfo());
  }

  Future<void> _loadDevInfo() async {
    final adb = context.read<AdbService>();
    final res = await adb.shell('wm size');
    final m = RegExp(r'(\d+)x(\d+)').firstMatch(res.stdout);
    if (m != null) {
      setState(() {
        _devW = int.parse(m.group(1)!);
        _devH = int.parse(m.group(2)!);
        _mx = _devW / 2;
        _my = _devH / 2;
        _devInfoLoaded = true;
      });
    } else {
      setState(() => _devInfoLoaded = true);
    }
  }

  // 先在设备上启动鼠标（需要开启无障碍/输入法或直接 tap）
  // 实际通过 input mouse 命令移动
  Future<void> _moveMouse(double dx, double dy) async {
    _mx = (_mx + dx * _sensitivity).clamp(0, _devW.toDouble());
    _my = (_my + dy * _sensitivity).clamp(0, _devH.toDouble());

    // 用 input tap 暂时模拟光标移动（input mouse 在部分设备需要 root）
    // 真正的光标移动使用 input mouse move dx dy
    final adb = context.read<AdbService>();
    await adb.shell('input mouse move ${dx.round()} ${dy.round()} 2>/dev/null || true');
  }

  Future<void> _click() async {
    final adb = context.read<AdbService>();
    // 先尝试 input mouse click，fallback 到 input tap
    await adb.shell(
        'input mouse click 0 2>/dev/null || input tap ${_mx.round()} ${_my.round()}');
  }

  // 计算光标在触摸板内的相对位置
  void _updateCursorPos(Size padSize, Offset local) {
    setState(() {
      _cursorX = (local.dx / padSize.width).clamp(0.0, 1.0);
      _cursorY = (local.dy / padSize.height).clamp(0.0, 1.0);
      _cursorVisible = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // ── 灵敏度控制 ──
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          const Icon(Icons.mouse_rounded, size: 16, color: AppTheme.textMuted),
          const SizedBox(width: 8),
          const Text('灵敏度', style: TextStyle(
            fontFamily: 'SpaceMono', fontSize: 12, color: AppTheme.textSecondary)),
          Expanded(
            child: Slider(
              value: _sensitivity,
              min: 0.5, max: 5.0, divisions: 9,
              activeColor: AppTheme.primary,
              inactiveColor: AppTheme.bg3,
              label: '${_sensitivity.toStringAsFixed(1)}x',
              onChanged: (v) => setState(() => _sensitivity = v),
            ),
          ),
          Text('${_sensitivity.toStringAsFixed(1)}x',
            style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 11,
              color: AppTheme.textSecondary)),
        ]),
      ),

      // ── 触摸板区域 ──
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: LayoutBuilder(builder: (ctx, constraints) {
            final padSize = Size(constraints.maxWidth, constraints.maxHeight);
            return GestureDetector(
              // 滑动：移动光标
              onPanStart: (d) {
                _lastLocal = d.localPosition;
                _updateCursorPos(padSize, d.localPosition);
                setState(() => _cursorVisible = true);
              },
              onPanUpdate: (d) {
                if (_lastLocal != null) {
                  final delta = d.localPosition - _lastLocal!;
                  _lastLocal = d.localPosition;
                  _updateCursorPos(padSize, d.localPosition);

                  // 防抖：16ms（约60fps）发一次
                  _moveDebounce?.cancel();
                  _moveDebounce = Timer(const Duration(milliseconds: 16), () {
                    _moveMouse(delta.dx, delta.dy);
                  });
                }
              },
              onPanEnd: (_) {
                _lastLocal = null;
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted) setState(() => _cursorVisible = false);
                });
              },
              // 单击：模拟左键
              onTapUp: (d) {
                _updateCursorPos(padSize, d.localPosition);
                _click();
                // 闪一下反馈
                setState(() => _cursorVisible = true);
              },
              child: Stack(children: [
                // 背景
                Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: AppTheme.bg1,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.bg3, width: 1.5),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.touch_app_rounded,
                          size: 36,
                          color: AppTheme.textMuted.withOpacity(0.3)),
                      const SizedBox(height: 8),
                      Text(
                        _devInfoLoaded
                            ? '触摸板  •  ${_devW}x$_devH'
                            : '加载中...',
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono', fontSize: 11,
                          color: AppTheme.textMuted.withOpacity(0.5)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '滑动移动光标  单击确认',
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono', fontSize: 10,
                          color: AppTheme.textMuted.withOpacity(0.4)),
                      ),
                    ],
                  ),
                ),
                // 光标
                if (_cursorVisible)
                  Positioned(
                    left: _cursorX * padSize.width - 16,
                    top:  _cursorY * padSize.height - 8,
                    child: _MouseCursor(),
                  ),
              ]),
            );
          }),
        ),
      ),

      // ── 鼠标按键行 ──
      _MouseButtonRow(
        onLeft:   _click,
        onScroll: (up) async {
          final adb = context.read<AdbService>();
          // input scroll 兼容写法
          final dir = up ? -3 : 3;
          await adb.shell(
              'input mouse scroll 0 $dir 2>/dev/null || '
              'input swipe ${_mx.round()} ${_my.round()} '
              '${_mx.round()} ${(_my + (up ? 300 : -300)).clamp(0, _devH).round()} 200');
        },
      ),

      const SizedBox(height: 8),
    ]);
  }

  @override
  void dispose() {
    _moveDebounce?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────
//  自绘鼠标图样
// ─────────────────────────────────────────────────────────────
class _MouseCursor extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(24, 32),
      painter: _CursorPainter(),
    );
  }
}

class _CursorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // 箭头路径（标准鼠标指针形状）
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, size.height * 0.78)
      ..lineTo(size.width * 0.28, size.height * 0.56)
      ..lineTo(size.width * 0.48, size.height)
      ..lineTo(size.width * 0.62, size.height * 0.92)
      ..lineTo(size.width * 0.42, size.height * 0.5)
      ..lineTo(size.width * 0.7, size.height * 0.5)
      ..close();

    // 阴影
    canvas.drawShadow(path, Colors.black45, 2, false);
    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(_) => false;
}

// ─────────────────────────────────────────────────────────────
//  鼠标按键行（左键 / 滚轮上 / 滚轮下）
// ─────────────────────────────────────────────────────────────
class _MouseButtonRow extends StatelessWidget {
  final VoidCallback onLeft;
  final Future<void> Function(bool up) onScroll;
  const _MouseButtonRow({required this.onLeft, required this.onScroll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        Expanded(
          flex: 2,
          child: _MouseBtn(
            label: '左键  点击',
            icon: Icons.ads_click_rounded,
            color: AppTheme.primary,
            onTap: onLeft,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MouseBtn(
            label: '上滑',
            icon: Icons.keyboard_arrow_up_rounded,
            color: AppTheme.textMuted,
            onTap: () => onScroll(true),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _MouseBtn(
            label: '下滑',
            icon: Icons.keyboard_arrow_down_rounded,
            color: AppTheme.textMuted,
            onTap: () => onScroll(false),
          ),
        ),
      ]),
    );
  }
}

class _MouseBtn extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _MouseBtn({
    required this.label, required this.icon,
    required this.color, required this.onTap,
  });
  @override
  State<_MouseBtn> createState() => _MouseBtnState();
}

class _MouseBtnState extends State<_MouseBtn> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) { setState(() => _pressed = true);  widget.onTap(); },
      onTapUp:   (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: 48,
        decoration: BoxDecoration(
          color: _pressed
              ? widget.color.withOpacity(0.2)
              : AppTheme.bg1,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _pressed ? widget.color : AppTheme.bg3,
            width: 1.5,
          ),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(widget.icon, size: 18,
              color: _pressed ? widget.color : AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(widget.label, style: TextStyle(
            fontFamily: 'SpaceMono', fontSize: 10,
            color: _pressed ? widget.color : AppTheme.textSecondary,
          )),
        ]),
      ),
    );
  }
}
