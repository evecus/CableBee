// lib/screens/remote_screen.dart
// scrcpy 投屏 — 通过 MediaCodec 硬解 H.264，渲染到 Flutter Texture
// 控制通过 scrcpy 控制协议发送，不再用 adb shell input

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

// ── scrcpy MethodChannel / EventChannel ────────────────────────────────────

const _kMethod = MethodChannel('com.cablebee.assistant/scrcpy');
const _kEvents = EventChannel('com.cablebee.assistant/scrcpy_events');
const _kAdb    = MethodChannel('com.cablebee/adb');

// ── Android keycode 常量 ────────────────────────────────────────────────────
const _kKeyBack   = 4;
const _kKeyHome   = 3;
const _kKeySwitch = 187;
const _kKeyMenu   = 82;

// ── 触摸 action 常量（MotionEvent） ─────────────────────────────────────────
const _kActionDown  = 0;
const _kActionUp    = 1;
const _kActionMove  = 2;

// ─────────────────────────────────────────────────────────────────────────────

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

  // ── 状态 ──────────────────────────────────────────────────────────────────
  bool _connected   = false;
  bool _connecting  = false;

  int? _textureId;          // Flutter Texture id（由 Kotlin 返回）
  int  _devW = 1080;
  int  _devH = 1920;

  String? _statusMsg;
  StreamSubscription? _eventSub;

  // 配置
  int  _maxSize  = 1080;   // 最大边长
  int  _bitRate  = 8;      // Mbps
  int  _maxFps   = 30;
  bool _fullScreen = false;

  // 触摸跟踪（用于多点）
  final Map<int, Offset> _pointers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pushActions());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopSession();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused)  _stopSession();
    if (state == AppLifecycleState.resumed && _connected) _connect();
  }

  void _pushActions() {
    widget.onActionsChanged?.call([
      if (_connected)
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded,
              size: 20, color: AppTheme.textMuted),
          color: AppTheme.bg1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          onSelected: (v) {
            if (v == 'disconnect') _stopSession();
            if (v == 'quality')   _showQualityDialog();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'quality',
                child: _MenuRow(icon: Icons.tune_rounded, label: '质量设置')),
            PopupMenuItem(value: 'disconnect',
                child: _MenuRow(icon: Icons.link_off_rounded,
                    label: '断开投屏', color: AppTheme.danger)),
          ],
        ),
    ]);
  }

  // ── 连接 ──────────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    setState(() { _connecting = true; _statusMsg = '正在初始化...'; });

    final adb = context.read<AdbService>();
    final serial = adb.selectedDevice?.serial ?? '';

    // 订阅事件流
    _eventSub?.cancel();
    _eventSub = _kEvents.receiveBroadcastStream().listen(_onEvent);

    try {
      // [诊断] 检查 serial
      if (serial.isEmpty) throw Exception('[诊断] 未选中设备，serial 为空');
      setState(() => _statusMsg = '[1/4] serial=$serial');
      await Future.delayed(const Duration(milliseconds: 400));

      // 1. 推送 scrcpy server
      setState(() => _statusMsg = '[2/4] 正在推送 server...');
      const serverAsset = 'assets/scrcpy-server';
      const remotePath  = '/data/local/tmp/scrcpy_server.apk';
      final pushRes = await adb.pushAsset(serverAsset, remotePath);
      if (pushRes.exitCode != 0) throw Exception('[诊断] 推送失败(${pushRes.exitCode}): ${pushRes.stderr}');
      setState(() => _statusMsg = '[2/4] server 推送完成 ✓');
      await Future.delayed(const Duration(milliseconds: 300));

      // 2. 启动 server
      setState(() => _statusMsg = '[3/4] 启动 server...');
      const serverCmd =
          'CLASSPATH=/data/local/tmp/scrcpy_server.apk '
          'app_process ./ com.genymobile.scrcpy.Server '
          '1.18 verbose 0 8000000 30 -1 true - true true 0 false false - - false';
      // 后台启动，不等待返回
      adb.shell(serverCmd, timeoutMs: 100).catchError((_) {});
      await Future.delayed(const Duration(milliseconds: 2500));
      setState(() => _statusMsg = '[3/4] server 已启动，等待就绪...');

      // 3. adb forward
      setState(() => _statusMsg = '[4/4] 建立隧道...');
      final fwdResult = await _kAdb.invokeMethod('forward', {
        'serial': serial,
        'local':  'tcp:5005',
        'remote': 'localabstract:scrcpy',
      });
      setState(() => _statusMsg = '[4/4] 隧道建立完成 fwd=$fwdResult ✓');
      await Future.delayed(const Duration(milliseconds: 300));

      // 4. 通知 Kotlin 侧开始连接 socket，等待 connected 事件后返回 textureId
      setState(() => _statusMsg = '正在连接设备（等待握手，最多15秒）...');
      final textureId = await _kMethod.invokeMethod<int>('start', {
        'serial':  serial,
        'maxSize': _maxSize,
        'bitRate': _bitRate * 1000000,
        'maxFps':  _maxFps,
      }).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw Exception('[诊断] start 超时：socket 连不上，请检查 scrcpy server 是否正常启动'),
      );

      setState(() {
        _textureId  = textureId;
        _connecting = false;
        _connected  = true;
        _statusMsg  = null;
      });
      _pushActions();
    } on PlatformException catch (e) {
      setState(() {
        _connecting = false;
        _statusMsg  = '✗ 连接失败：${e.message}';
      });
    } catch (e) {
      setState(() {
        _connecting = false;
        _statusMsg  = '✗ $e';
      });
    }
  }

  void _onEvent(dynamic raw) {
    if (!mounted) return;
    final map  = Map<String, dynamic>.from(raw as Map);
    final type = map['type'] as String? ?? '';

    switch (type) {
      case 'status':
        setState(() => _statusMsg = map['msg'] as String?);
        break;
      case 'connected':
        setState(() {
          _devW      = (map['deviceWidth']  as int?) ?? _devW;
          _devH      = (map['deviceHeight'] as int?) ?? _devH;
          _statusMsg = null;
        });
        break;
      case 'error':
        setState(() {
          _statusMsg  = '✗ ${map['message']}';
          _connected  = false;
          _connecting = false;
          _textureId  = null;
        });
        _pushActions();
        break;
      case 'stopped':
        if (mounted) {
          setState(() {
            _connected  = false;
            _connecting = false;
            _textureId  = null;
            _statusMsg  = null;
          });
          _pushActions();
        }
        break;
    }
  }

  Future<void> _stopSession() async {
    _eventSub?.cancel();
    _eventSub = null;
    try { await _kMethod.invokeMethod('stop'); } catch (_) {}
    if (mounted) {
      setState(() {
        _connected  = false;
        _connecting = false;
        _textureId  = null;
        _statusMsg  = null;
      });
      _pushActions();
    }
  }

  // ── 控制事件 ──────────────────────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent e, Size renderSize) {
    _pointers[e.pointer] = e.localPosition;
    final dev = _toDev(e.localPosition, renderSize);
    _kMethod.invokeMethod('touch', {
      'action':    _kActionDown,
      'pointerId': e.pointer,
      'x': dev.dx.round(), 'y': dev.dy.round(),
      'w': _devW, 'h': _devH,
      'pressure': e.pressure,
    });
  }

  void _onPointerMove(PointerMoveEvent e, Size renderSize) {
    _pointers[e.pointer] = e.localPosition;
    final dev = _toDev(e.localPosition, renderSize);
    _kMethod.invokeMethod('touch', {
      'action':    _kActionMove,
      'pointerId': e.pointer,
      'x': dev.dx.round(), 'y': dev.dy.round(),
      'w': _devW, 'h': _devH,
      'pressure': e.pressure,
    });
  }

  void _onPointerUp(PointerUpEvent e, Size renderSize) {
    _pointers.remove(e.pointer);
    final dev = _toDev(e.localPosition, renderSize);
    _kMethod.invokeMethod('touch', {
      'action':    _kActionUp,
      'pointerId': e.pointer,
      'x': dev.dx.round(), 'y': dev.dy.round(),
      'w': _devW, 'h': _devH,
      'pressure': 0.0,
    });
  }

  void _sendKeycode(int keycode) {
    _kMethod.invokeMethod('keycode', {'action': 0, 'keycode': keycode});
    Future.delayed(const Duration(milliseconds: 50), () {
      _kMethod.invokeMethod('keycode', {'action': 1, 'keycode': keycode});
    });
  }

  // 将渲染坐标换算为设备坐标
  Offset _toDev(Offset local, Size renderSize) {
    // 设备横屏但渲染区域竖屏时旋转
    if (_devW > _devH && renderSize.width < renderSize.height) {
      final scaleX = _devH / renderSize.width;
      final scaleY = _devW / renderSize.height;
      return Offset(local.dy * scaleY, (_devH - local.dx * scaleX));
    }
    final scaleX = _devW / renderSize.width;
    final scaleY = _devH / renderSize.height;
    return Offset(local.dx * scaleX, local.dy * scaleY);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return _connected ? _buildMirrorPage() : _buildConfigPage();
  }

  // ── 配置页 ────────────────────────────────────────────────────────────────

  Widget _buildConfigPage() {
    return Scaffold(
      backgroundColor: AppTheme.bg0,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 12),

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
                child: const Icon(Icons.cast_rounded,
                    size: 28, color: AppTheme.primary),
              ),
              const SizedBox(height: 12),
              const Text('实时投屏控制', style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 16,
                fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
              const SizedBox(height: 6),
              const Text(
                '基于 scrcpy 协议的硬件加速投屏\n支持触摸、多点、滚动操作',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 11,
                  color: AppTheme.textMuted, height: 1.6)),
            ]),
          ),

          const SizedBox(height: 16),

          TintedCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              _ConfigTile(
                label: '最大分辨率',
                value: _maxSize == 0 ? '原始' : '${_maxSize}p',
                icon: Icons.high_quality_rounded,
                onTap: () => _showPickerDialog<int>(
                  title: '最大分辨率',
                  options: [0, 720, 1080, 1440],
                  labels: ['原始', '720p', '1080p', '1440p'],
                  current: _maxSize,
                  onSelect: (v) => setState(() => _maxSize = v),
                ),
              ),
              const Divider(height: 1),
              _ConfigTile(
                label: '码率',
                value: '$_bitRate Mbps',
                icon: Icons.speed_rounded,
                onTap: () => _showPickerDialog<int>(
                  title: '码率',
                  options: [2, 4, 8, 16],
                  labels: ['2 Mbps', '4 Mbps', '8 Mbps', '16 Mbps'],
                  current: _bitRate,
                  onSelect: (v) => setState(() => _bitRate = v),
                ),
              ),
              const Divider(height: 1),
              _ConfigTile(
                label: '最大帧率',
                value: '$_maxFps fps',
                icon: Icons.timer_outlined,
                onTap: () => _showPickerDialog<int>(
                  title: '最大帧率',
                  options: [15, 30, 60],
                  labels: ['15 fps', '30 fps', '60 fps'],
                  current: _maxFps,
                  onSelect: (v) => setState(() => _maxFps = v),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [
                  const Icon(Icons.fullscreen_rounded,
                      size: 18, color: AppTheme.textMuted),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('全屏显示', style: TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 13,
                    color: AppTheme.textPrimary))),
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

          SizedBox(
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
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
                color: _statusMsg!.startsWith('✗')
                    ? AppTheme.danger : AppTheme.textMuted)),
          ],
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  // ── 投屏页 ────────────────────────────────────────────────────────────────

  Widget _buildMirrorPage() {
    final tid = _textureId;
    final devIsLandscape = _devW > _devH;

    Widget mirrorView = LayoutBuilder(builder: (ctx, constraints) {
      if (tid == null) {
        return const Center(child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppTheme.primary),
            SizedBox(height: 12),
            Text('等待视频流...', style: TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 12,
              color: AppTheme.textMuted)),
          ],
        ));
      }

      // 计算渲染尺寸（保持设备宽高比）
      final areaW = constraints.maxWidth;
      final areaH = constraints.maxHeight;
      final devAspect = _devW / _devH;
      final areaAspect = areaW / areaH;

      double renderW, renderH;
      if (devAspect > areaAspect) {
        renderW = areaW;
        renderH = areaW / devAspect;
      } else {
        renderH = areaH;
        renderW = areaH * devAspect;
      }

      return Center(
        child: SizedBox(
          width: renderW,
          height: renderH,
          child: Listener(
            onPointerDown: (e) => _onPointerDown(e, Size(renderW, renderH)),
            onPointerMove: (e) => _onPointerMove(e, Size(renderW, renderH)),
            onPointerUp:   (e) => _onPointerUp(e,   Size(renderW, renderH)),
            child: Texture(textureId: tid),
          ),
        ),
      );
    });

    if (devIsLandscape) {
      mirrorView = RotatedBox(quarterTurns: 1, child: mirrorView);
    }

    final body = Column(children: [
      Expanded(
        child: Container(color: Colors.black, child: mirrorView),
      ),
      _NavBar(
        onBack:   () => _sendKeycode(_kKeyBack),
        onHome:   () => _sendKeycode(_kKeyHome),
        onRecent: () => _sendKeycode(_kKeySwitch),
        onMenu:   () => _sendKeycode(_kKeyMenu),
      ),
    ]);

    return Scaffold(
      backgroundColor: _fullScreen ? Colors.black : AppTheme.bg0,
      body: _fullScreen ? SafeArea(child: body) : body,
    );
  }

  // ── 弹窗 ──────────────────────────────────────────────────────────────────

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
            child: DropdownButton<int>(
              value: _maxSize,
              dropdownColor: AppTheme.bg1,
              style: const TextStyle(color: AppTheme.textPrimary,
                fontFamily: 'JetBrainsMono', fontSize: 12),
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 0,    child: Text('原始')),
                DropdownMenuItem(value: 720,  child: Text('720p')),
                DropdownMenuItem(value: 1080, child: Text('1080p')),
                DropdownMenuItem(value: 1440, child: Text('1440p')),
              ],
              onChanged: (v) {
                setS(() => _maxSize = v!);
                setState(() => _maxSize = v!);
              },
            ),
          ),
          _SettingRow(
            label: '码率',
            child: DropdownButton<int>(
              value: _bitRate,
              dropdownColor: AppTheme.bg1,
              style: const TextStyle(color: AppTheme.textPrimary,
                fontFamily: 'JetBrainsMono', fontSize: 12),
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 2,  child: Text('2 Mbps')),
                DropdownMenuItem(value: 4,  child: Text('4 Mbps')),
                DropdownMenuItem(value: 8,  child: Text('8 Mbps')),
                DropdownMenuItem(value: 16, child: Text('16 Mbps')),
              ],
              onChanged: (v) {
                setS(() => _bitRate = v!);
                setState(() => _bitRate = v!);
              },
            ),
          ),
          _SettingRow(
            label: '帧率',
            child: DropdownButton<int>(
              value: _maxFps,
              dropdownColor: AppTheme.bg1,
              style: const TextStyle(color: AppTheme.textPrimary,
                fontFamily: 'JetBrainsMono', fontSize: 12),
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 15, child: Text('15 fps')),
                DropdownMenuItem(value: 30, child: Text('30 fps')),
                DropdownMenuItem(value: 60, child: Text('60 fps')),
              ],
              onChanged: (v) {
                setS(() => _maxFps = v!);
                setState(() => _maxFps = v!);
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
          final opt   = options[i];
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

// ── 虚拟导航栏 ──────────────────────────────────────────────────────────────

class _NavBar extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onHome;
  final VoidCallback onRecent;
  final VoidCallback onMenu;
  const _NavBar({
    required this.onBack, required this.onHome,
    required this.onRecent, required this.onMenu});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: const Color(0xFF1A1A1A),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _NavBtn(icon: Icons.menu_rounded,        onTap: onMenu,   tooltip: '菜单'),
          _NavBtn(icon: Icons.arrow_back_rounded,  onTap: onBack,   tooltip: '返回'),
          _NavBtn(icon: Icons.circle_outlined,     onTap: onHome,   tooltip: '主页'),
          _NavBtn(icon: Icons.crop_square_rounded, onTap: onRecent, tooltip: '最近任务'),
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

// ── 配置行 ──────────────────────────────────────────────────────────────────

class _ConfigTile extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final VoidCallback? onTap;
  const _ConfigTile({
    required this.label, required this.value,
    required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Icon(icon, size: 18, color: AppTheme.textMuted),
      title: Text(label, style: const TextStyle(
        fontFamily: 'SpaceMono', fontSize: 13, color: AppTheme.textPrimary)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(value, style: const TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 12,
          color: AppTheme.textSecondary)),
        if (onTap != null) ...[
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded,
              size: 16, color: AppTheme.textMuted),
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
          fontFamily: 'SpaceMono', fontSize: 12,
          color: AppTheme.textSecondary))),
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
