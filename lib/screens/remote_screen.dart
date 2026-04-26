// lib/screens/remote_screen.dart
// 远程控制页面
// 原理：每隔 N ms 截图（screencap -> pull）-> 展示在 Image widget 上
//      用户点触 / 滑动 -> 换算为设备坐标 -> adb shell input tap/swipe
// 注意：截图轮询有延迟，不是真正 mirroring，但无需额外原生支持。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

// ─────────────────────────────────────────────────────────────
class RemoteScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const RemoteScreen({super.key, this.onActionsChanged});
  @override
  State<RemoteScreen> createState() => RemoteScreenState();
}

class RemoteScreenState extends State<RemoteScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => _pushActions();

  // ── 状态 ──
  bool _connected   = false;
  bool _connecting  = false;
  bool _capturing   = false;

  // 分辨率（从 wm size 获取）
  int _devW = 0, _devH = 0;

  // 当前帧
  File?  _frameFile;
  Uint8List? _frameBytes;

  Timer? _captureTimer;
  int    _intervalMs = 500;   // 刷新间隔，可调
  bool   _frameLoading = false;

  // 触摸状态（用于 swipe）
  Offset? _touchStart;
  int?    _touchStartMs;

  String? _statusMsg;

  // 设置项
  String _resolutionMode = '原始分辨率';  // 原始分辨率 / 720p / 480p
  int    _bitrateMode    = 8;            // Mbps（仅展示用）
  bool   _fullScreen     = false;
  bool   _landscape      = false;        // 强制横屏显示

  // 临时截图文件路径
  String? _localFramePath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pushActions());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCapture();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _stopCapture();
    if (state == AppLifecycleState.resumed && _connected) _startCapture();
  }

  void _pushActions() {
    widget.onActionsChanged?.call([
      if (_connected)
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded, size: 20, color: AppTheme.textMuted),
          color: AppTheme.bg1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          onSelected: (v) {
            if (v == 'disconnect') _disconnect();
            if (v == 'quality')   _showQualityDialog();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'quality',    child: _MenuRow(icon: Icons.tune_rounded,         label: '质量设置')),
            PopupMenuItem(value: 'disconnect', child: _MenuRow(icon: Icons.link_off_rounded,      label: '断开投屏',  color: AppTheme.danger)),
          ],
        ),
    ]);
  }

  // ── 连接 ──────────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    setState(() { _connecting = true; _statusMsg = null; });
    final adb = context.read<AdbService>();

    // 获取设备分辨率
    final sizeRes = await adb.shell('wm size');
    final m = RegExp(r'(\d+)x(\d+)').firstMatch(sizeRes.stdout);
    if (m != null) {
      _devW = int.parse(m.group(1)!);
      _devH = int.parse(m.group(2)!);
    } else {
      _devW = 1080; _devH = 1920; // fallback
    }

    // 准备本机缓存路径
    final dir  = await getTemporaryDirectory();
    _localFramePath = '${dir.path}/cbee_frame.png';

    setState(() { _connected = true; _connecting = false; });
    _pushActions();
    _startCapture();
  }

  void _disconnect() {
    _stopCapture();
    setState(() {
      _connected   = false;
      _frameBytes  = null;
      _frameFile   = null;
      _statusMsg   = null;
    });
    _pushActions();
  }

  // ── 截图轮询 ──────────────────────────────────────────────────────────────

  void _startCapture() {
    _captureTimer?.cancel();
    _captureTimer = Timer.periodic(Duration(milliseconds: _intervalMs), (_) {
      if (!_frameLoading) _captureFrame();
    });
  }

  void _stopCapture() {
    _captureTimer?.cancel();
    _captureTimer = null;
    _capturing = false;
  }

  Future<void> _captureFrame() async {
    if (!mounted || !_connected) return;
    _frameLoading = true;
    try {
      final adb  = context.read<AdbService>();
      final path = _localFramePath!;

      // 决定截图缩放命令
      String scaleCmd = '';
      if (_resolutionMode == '720p')  scaleCmd = 'screencap -p /sdcard/cbee_sc.png && convert /sdcard/cbee_sc.png -resize 720x /sdcard/cbee_sc.png';
      if (_resolutionMode == '480p')  scaleCmd = 'screencap -p /sdcard/cbee_sc.png && convert /sdcard/cbee_sc.png -resize 480x /sdcard/cbee_sc.png';

      if (scaleCmd.isNotEmpty) {
        await adb.shell(scaleCmd);
      } else {
        await adb.shell('screencap -p /sdcard/cbee_sc.png');
      }

      final res = await adb.pull('/sdcard/cbee_sc.png', path);
      if (res.isSuccess) {
        final bytes = await File(path).readAsBytes();
        if (mounted && bytes.isNotEmpty) {
          setState(() {
            _frameBytes = bytes;
            _capturing  = true;
          });
        }
      }
    } catch (_) {}
    _frameLoading = false;
  }

  // ── 输入 ──────────────────────────────────────────────────────────────────

  // 将屏幕点击坐标换算成设备坐标
  Offset _toDevCoord(Offset local, Size renderSize) {
    final scaleX = _devW / renderSize.width;
    final scaleY = _devH / renderSize.height;

    // 如果设备横屏且 app 竖屏投屏，需要旋转坐标
    if (_devW > _devH && renderSize.width < renderSize.height) {
      // 设备横屏，app 竖屏显示 → 旋转 90°
      final rx = local.dy * scaleY;
      final ry = (renderSize.width - local.dx) * scaleX;
      return Offset(rx, ry);
    }
    return Offset(local.dx * scaleX, local.dy * scaleY);
  }

  Future<void> _sendTap(Offset devCoord) async {
    final adb = context.read<AdbService>();
    await adb.shell(
        'input tap ${devCoord.dx.round()} ${devCoord.dy.round()}');
  }

  Future<void> _sendSwipe(Offset start, Offset end, int durationMs) async {
    final adb = context.read<AdbService>();
    await adb.shell(
        'input swipe '
        '${start.dx.round()} ${start.dy.round()} '
        '${end.dx.round()} ${end.dy.round()} '
        '$durationMs');
  }

  Future<void> _sendKeyEvent(int keyCode) async {
    final adb = context.read<AdbService>();
    await adb.shell('input keyevent $keyCode');
  }

  // ── 设置弹窗 ──────────────────────────────────────────────────────────────

  void _showConnectDialog() {
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        backgroundColor: AppTheme.bg1,
        title: const Text('投屏设置', style: TextStyle(
          color: AppTheme.textPrimary, fontFamily: 'SpaceMono', fontSize: 15)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          // 分辨率
          _SettingRow(
            label: '分辨率',
            child: DropdownButton<String>(
              value: _resolutionMode,
              dropdownColor: AppTheme.bg1,
              style: const TextStyle(color: AppTheme.textPrimary,
                fontFamily: 'JetBrainsMono', fontSize: 12),
              underline: const SizedBox(),
              items: ['原始分辨率', '720p', '480p'].map((v) =>
                DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: (v) => setS(() => _resolutionMode = v!),
            ),
          ),
          // 刷新间隔
          _SettingRow(
            label: '刷新间隔',
            child: DropdownButton<int>(
              value: _intervalMs,
              dropdownColor: AppTheme.bg1,
              style: const TextStyle(color: AppTheme.textPrimary,
                fontFamily: 'JetBrainsMono', fontSize: 12),
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 300,  child: Text('300ms (快)')),
                DropdownMenuItem(value: 500,  child: Text('500ms')),
                DropdownMenuItem(value: 1000, child: Text('1000ms (省电)')),
              ],
              onChanged: (v) => setS(() => _intervalMs = v!),
            ),
          ),
          // 全屏
          _SettingRow(
            label: '全屏显示',
            child: Switch(
              value: _fullScreen,
              activeColor: AppTheme.primary,
              onChanged: (v) => setS(() => _fullScreen = v),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(color: AppTheme.textMuted))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () { Navigator.pop(context); _connect(); },
            child: const Text('连接'),
          ),
        ],
      )),
    );
  }

  void _showQualityDialog() {
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        backgroundColor: AppTheme.bg1,
        title: const Text('质量设置', style: TextStyle(
          color: AppTheme.textPrimary, fontFamily: 'SpaceMono', fontSize: 15)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _SettingRow(
            label: '分辨率',
            child: DropdownButton<String>(
              value: _resolutionMode,
              dropdownColor: AppTheme.bg1,
              style: const TextStyle(color: AppTheme.textPrimary,
                fontFamily: 'JetBrainsMono', fontSize: 12),
              underline: const SizedBox(),
              items: ['原始分辨率', '720p', '480p'].map((v) =>
                DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: (v) {
                setS(() => _resolutionMode = v!);
                setState(() => _resolutionMode = v!);
              },
            ),
          ),
          _SettingRow(
            label: '刷新间隔',
            child: DropdownButton<int>(
              value: _intervalMs,
              dropdownColor: AppTheme.bg1,
              style: const TextStyle(color: AppTheme.textPrimary,
                fontFamily: 'JetBrainsMono', fontSize: 12),
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 300,  child: Text('300ms (快)')),
                DropdownMenuItem(value: 500,  child: Text('500ms')),
                DropdownMenuItem(value: 1000, child: Text('1000ms (省电)')),
              ],
              onChanged: (v) {
                setS(() => _intervalMs = v!);
                setState(() => _intervalMs = v!);
                // 重启定时器
                _stopCapture();
                _startCapture();
              },
            ),
          ),
        ]),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.pop(context),
            child: const Text('确定'),
          ),
        ],
      )),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // 未连接：展示配置页
    if (!_connected) {
      return _buildConfigPage();
    }

    // 已连接：投屏视图
    return _buildMirrorPage();
  }

  // ── 配置页（未连接时）──────────────────────────────────────────────────────
  Widget _buildConfigPage() {
    return Scaffold(
      backgroundColor: AppTheme.bg0,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 12),

          // 标题卡片
          TintedCard(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
                ),
                child: const Icon(Icons.cast_rounded, size: 28, color: AppTheme.primary),
              ),
              const SizedBox(height: 12),
              const Text('远程投屏控制', style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 16,
                fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
              const SizedBox(height: 6),
              const Text(
                '将被连接设备的屏幕实时投屏到此处\n支持点击和滑动操作',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 11,
                  color: AppTheme.textMuted, height: 1.6)),
            ]),
          ),

          const SizedBox(height: 16),

          // 配置卡片
          TintedCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              _ConfigTile(
                label: '分辨率',
                value: _resolutionMode,
                icon: Icons.high_quality_rounded,
                onTap: () => _showPickerDialog<String>(
                  title: '分辨率',
                  options: ['原始分辨率', '720p', '480p'],
                  current: _resolutionMode,
                  onSelect: (v) => setState(() => _resolutionMode = v),
                ),
              ),
              const Divider(height: 1),
              _ConfigTile(
                label: '码率',
                value: '$_bitrateMode Mbps',
                icon: Icons.speed_rounded,
                onTap: () => _showPickerDialog<int>(
                  title: '码率',
                  options: [2, 4, 8, 16],
                  labels: ['2 Mbps', '4 Mbps', '8 Mbps', '16 Mbps'],
                  current: _bitrateMode,
                  onSelect: (v) => setState(() => _bitrateMode = v),
                ),
              ),
              const Divider(height: 1),
              _ConfigTile(
                label: '刷新间隔',
                value: '${_intervalMs}ms',
                icon: Icons.timer_outlined,
                onTap: () => _showPickerDialog<int>(
                  title: '刷新间隔',
                  options: [300, 500, 1000],
                  labels: ['300ms (快)', '500ms', '1000ms (省电)'],
                  current: _intervalMs,
                  onSelect: (v) => setState(() => _intervalMs = v),
                ),
              ),
              const Divider(height: 1),
              _ConfigTile(
                label: '画面比例',
                value: '保持原始比例',
                icon: Icons.aspect_ratio_rounded,
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [
                  const Icon(Icons.fullscreen_rounded, size: 18, color: AppTheme.textMuted),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('全屏显示', style: TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 13, color: AppTheme.textPrimary))),
                  Switch(
                    value: _fullScreen,
                    activeColor: AppTheme.primary,
                    onChanged: (v) => setState(() => _fullScreen = v),
                  ),
                ]),
              ),
            ]),
          ),

          const SizedBox(height: 24),

          // 连接按钮
          SizedBox(
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _connecting ? null : _connect,
              child: _connecting
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                  : const Text('连接', style: TextStyle(
                      fontFamily: 'SpaceMono', fontSize: 15,
                      fontWeight: FontWeight.w700)),
            ),
          ),

          if (_statusMsg != null) ...[
            const SizedBox(height: 12),
            Text(_statusMsg!, textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 12,
                color: _statusMsg!.startsWith('✗') ? AppTheme.danger : AppTheme.textMuted)),
          ],
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  // ── 投屏页（已连接时）──────────────────────────────────────────────────────
  Widget _buildMirrorPage() {
    final devIsLandscape = _devW > _devH;

    Widget frameView = LayoutBuilder(builder: (ctx, constraints) {
      if (_frameBytes == null) {
        return const Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppTheme.primary),
            SizedBox(height: 12),
            Text('截图中...', style: TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 12,
              color: AppTheme.textMuted)),
          ],
        ));
      }

      return GestureDetector(
        onTapUp: (d) {
          final box = ctx.findRenderObject() as RenderBox;
          final size = box.size;
          final local = d.localPosition;
          final devCoord = _toDevCoord(local, size);
          _sendTap(devCoord);
        },
        onPanStart: (d) {
          final box = ctx.findRenderObject() as RenderBox;
          _touchStart   = _toDevCoord(d.localPosition, box.size);
          _touchStartMs = DateTime.now().millisecondsSinceEpoch;
        },
        onPanEnd: (d) {
          if (_touchStart == null) return;
          // tap vs swipe 由 onTapUp 处理，这里只做 swipe（移动距离 > 20px）
        },
        onPanUpdate: (d) {
          // 用于更精准的 swipe：panEnd 触发时发送
        },
        onLongPressStart: (d) {
          final box = ctx.findRenderObject() as RenderBox;
          _touchStart   = _toDevCoord(d.localPosition, box.size);
          _touchStartMs = DateTime.now().millisecondsSinceEpoch;
        },
        onLongPressEnd: (d) {
          if (_touchStart == null) return;
          final box = ctx.findRenderObject() as RenderBox;
          final end = _toDevCoord(d.localPosition, box.size);
          final dur = DateTime.now().millisecondsSinceEpoch - (_touchStartMs ?? 0);
          final dist = (end - _touchStart!).distance;
          if (dist > 30) {
            _sendSwipe(_touchStart!, end, dur.clamp(100, 2000));
          }
          _touchStart = null;
        },
        child: Image.memory(
          _frameBytes!,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      );
    });

    // 如果设备横屏，把整个视图旋转 90°，让用户横持手机看
    if (devIsLandscape) {
      frameView = RotatedBox(
        quarterTurns: 1,
        child: frameView,
      );
    }

    final body = Column(children: [
      // 导航虚拟按键栏
      _NavBar(
        onBack:   () => _sendKeyEvent(4),   // KEYCODE_BACK
        onHome:   () => _sendKeyEvent(3),   // KEYCODE_HOME
        onRecent: () => _sendKeyEvent(187), // KEYCODE_APP_SWITCH
      ),
      Expanded(
        child: Container(
          color: Colors.black,
          child: frameView,
        ),
      ),
    ]);

    if (_fullScreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(child: body),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      body: body,
    );
  }

  void _showPickerDialog<T>({
    required String title,
    required List<T> options,
    List<String>? labels,
    required T current,
    required void Function(T) onSelect,
  }) {
    showDialog(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: AppTheme.bg1,
        title: Text(title, style: const TextStyle(
          color: AppTheme.textPrimary, fontFamily: 'SpaceMono', fontSize: 14)),
        children: List.generate(options.length, (i) {
          final opt = options[i];
          final label = labels != null ? labels[i] : opt.toString();
          return SimpleDialogOption(
            onPressed: () { Navigator.pop(context); onSelect(opt); },
            child: Row(children: [
              Icon(
                opt == current
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 16,
                color: opt == current ? AppTheme.primary : AppTheme.textMuted,
              ),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 13,
                color: opt == current ? AppTheme.primary : AppTheme.textPrimary,
              )),
            ]),
          );
        }),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  虚拟导航栏
// ─────────────────────────────────────────────────────────────
class _NavBar extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onHome;
  final VoidCallback onRecent;
  const _NavBar({required this.onBack, required this.onHome, required this.onRecent});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: const Color(0xFF1A1A1A),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _NavBtn(icon: Icons.arrow_back_rounded,   onTap: onBack,   tooltip: '返回'),
          _NavBtn(icon: Icons.circle_outlined,      onTap: onHome,   tooltip: '主页'),
          _NavBtn(icon: Icons.crop_square_rounded,  onTap: onRecent, tooltip: '最近任务'),
        ],
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  const _NavBtn({required this.icon, required this.onTap, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 22, color: Colors.white70),
      onPressed: onTap,
      tooltip: tooltip,
      splashRadius: 20,
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  配置行
// ─────────────────────────────────────────────────────────────
class _ConfigTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;
  const _ConfigTile({
    required this.label, required this.value, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, size: 18, color: AppTheme.textMuted),
      title: Text(label, style: const TextStyle(
        fontFamily: 'SpaceMono', fontSize: 13, color: AppTheme.textPrimary)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(value, style: const TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 12, color: AppTheme.textSecondary)),
        if (onTap != null) ...[
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded, size: 16, color: AppTheme.textMuted),
        ],
      ]),
      onTap: onTap,
    );
  }
}

class _SettingRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _SettingRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(
          fontFamily: 'SpaceMono', fontSize: 12, color: AppTheme.textSecondary))),
        const Spacer(),
        child,
      ]),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _MenuRow({required this.icon, required this.label,
    this.color = AppTheme.textPrimary});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 10),
      Text(label, style: TextStyle(
        fontFamily: 'JetBrainsMono', fontSize: 13, color: color)),
    ]);
  }
}

