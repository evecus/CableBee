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
  bool _retriedSafeProfile = false;

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
    // paused 时不停止 session（点击 NavBar 按键可能短暂触发 paused）
    // 只在应用真正退到后台（inactive/hidden）超过一段时间才停止
    if (state == AppLifecycleState.detached) _stopSession();
    // resumed 时若 session 已断开则重连
    if (state == AppLifecycleState.resumed && _connected && _textureId == null) _connect();
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
      // 0. 根据设备分辨率自动调参（不是降级重试，而是连接前预设最佳档位）
      setState(() => _statusMsg = '检测设备分辨率...');
      final tuned = await _autoTuneByResolution(adb);
      final tunedMaxSize = tuned.$1;
      final tunedBitRateMbps = tuned.$2;
      final tunedFps = tuned.$3;

      // 1. 推送 scrcpy server
      // 优先推到 /sdcard/（部分电视 /data/local/tmp/ 无写权限）
      // 回退到 /data/local/tmp/
      setState(() => _statusMsg = '正在推送 server...');
      const serverAsset = 'assets/scrcpy-server';
      const remotePath1 = '/sdcard/scrcpy_server.apk';
      const remotePath2 = '/data/local/tmp/scrcpy_server.apk';

      String remotePath = remotePath1;
      var pushRes = await adb.pushAsset(serverAsset, remotePath1);
      if (pushRes.exitCode != 0) {
        remotePath = remotePath2;
        pushRes = await adb.pushAsset(serverAsset, remotePath2);
      }
      if (pushRes.exitCode != 0) throw Exception('推送失败: ${pushRes.stderr}');

      // 2. 启动 server（scrcpy-server v3.x，key=value 参数格式）
      // 注意：部分电视（如 TCL）需要用 app_process ./ 而非 app_process /
      //      否则会被系统 SELinux 策略 SIGKILL
      setState(() => _statusMsg = '启动 server...');
      final serverCmd =
          'CLASSPATH=$remotePath '
          'app_process ./ com.genymobile.scrcpy.Server '
          '3.3.4 '
          'tunnel_forward=true '
          'video=true '
          'audio=false '
          'control=true '
          'max_size=$tunedMaxSize '
          'video_bit_rate=${tunedBitRateMbps * 1000000} '
          'max_fps=$tunedFps '
          'send_device_meta=true '
          'send_frame_meta=true '
          'send_dummy_byte=true '
          'send_codec_meta=true '
          'cleanup=true '
          'power_on=true '
          '>/dev/null 2>&1 &';
      await adb.shell(serverCmd, timeoutMs: 3000).catchError((_) {});

      // 3. adb forward（先建隧道）
      // tunnel_forward 模式下 server 启动后立即阻塞在 accept()，
      // 需要先建好 forward，再去检测 server 是否就绪。
      setState(() => _statusMsg = '建立隧道...');
      await _kAdb.invokeMethod('forward', {
        'serial': serial,
        'local':  'tcp:5005',
        'remote': 'localabstract:scrcpy',
      });

      // 等待 server socket 出现（最多6秒）
      // /proc/net/unix 有 "scrcpy" 条目说明 LocalServerSocket 已在监听
      setState(() => _statusMsg = '等待 server 就绪...');
      bool socketReady = false;
      for (int i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        final check = await adb.shell(
          'grep -c scrcpy /proc/net/unix 2>/dev/null || echo 0',
          timeoutMs: 2000,
        );
        final count = int.tryParse(check.stdout.trim()) ?? 0;
        if (count > 0) {
          socketReady = true;
          break;
        }
      }
      // 若 grep 始终为 0，也允许继续尝试连接（部分内核不暴露 unix socket 列表）
      if (!socketReady) {
        // 额外等待 1 秒给 server 启动时间
        await Future.delayed(const Duration(seconds: 1));
      }

      // 4. 通知 Kotlin 侧开始连接 socket
      final textureId = await _kMethod.invokeMethod<int>('start', {
        'serial':  serial,
        'maxSize': tunedMaxSize,
        'bitRate': tunedBitRateMbps * 1000000,
        'maxFps':  tunedFps,
      });

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
        _statusMsg  = '✗ 连接失败：$e';
      });
    }
  }

  /// 读取设备物理分辨率并自动选择更稳的投屏参数。
  Future<(int, int, int)> _autoTuneByResolution(AdbService adb) async {
    final res = await adb.shell('wm size 2>/dev/null || wm size');
    final out = res.stdout;
    final m = RegExp(r'Physical size:\s*(\d+)x(\d+)', caseSensitive: false).firstMatch(out)
        ?? RegExp(r'(\d+)x(\d+)').firstMatch(out);
    if (m == null) return (_maxSize, _bitRate, _maxFps);

    final w = int.tryParse(m.group(1) ?? '') ?? 0;
    final h = int.tryParse(m.group(2) ?? '') ?? 0;
    if (w <= 0 || h <= 0) return (_maxSize, _bitRate, _maxFps);

    final longEdge = w > h ? w : h;
    final shortEdge = w > h ? h : w;
    final pixelCount = w * h;
    final aspect = longEdge / shortEdge;

    // 1) maxSize：优先按短边，避免高纵横比机型（如 1080x2400）被错误放大到不稳定档位。
    //    向下取到 16 的倍数，兼容更多编码器。
    int maxSize = shortEdge.clamp(720, 1440);
    maxSize = (maxSize ~/ 16) * 16;
    if (maxSize < 720) maxSize = 720;

    // 2) bitrate：按总像素规模线性估算（相对 1080p），再做区间约束。
    //    1080p(2.07MP)≈8Mbps，2.5MP≈10Mbps，720p≈4~5Mbps。
    final megaPixels = pixelCount / 1000000.0;
    int bitRate = (megaPixels * 3.8).round();
    bitRate = bitRate.clamp(4, 14);

    // 3) fps：高分辨率或超长屏适当降帧，优先保稳定。
    int fps = 30;
    if (megaPixels >= 4.0) fps = 24;       // 接近 2K/更高
    if (aspect >= 2.1) {
      // 超长屏（如 1080x2400）使用短边等比例编码尺寸，避免原始分辨率导致编码链路不稳定黑屏。
      maxSize = (shortEdge ~/ 16) * 16;
      if (maxSize < 720) maxSize = 720;
      fps = fps > 25 ? 25 : fps;
    }

    // 如果用户手动设置了更低档位，则尊重用户选择（不强制升档）。
    maxSize = maxSize > _maxSize && _maxSize > 0 ? _maxSize : maxSize;
    bitRate = bitRate > _bitRate ? _bitRate : bitRate;
    fps = fps > _maxFps ? _maxFps : fps;

    return (maxSize, bitRate, fps);
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
        final msg = map['message'] as String? ?? '';
        if (msg == 'NO_VIDEO_FRAME' && !_retriedSafeProfile) {
          _retriedSafeProfile = true;
          _connectWithProfile(maxSize: 720, bitRateMbps: 4, fps: 20);
          return;
        }
        setState(() {
          _statusMsg  = msg == 'NO_VIDEO_FRAME'
              ? '✗ 设备未输出视频帧（已保存 server 日志）'
              : '✗ $msg';
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


  Future<void> _connectWithProfile({
    required int maxSize,
    required int bitRateMbps,
    required int fps,
  }) async {
    setState(() {
      _maxSize = maxSize;
      _bitRate = bitRateMbps;
      _maxFps = fps;
      _statusMsg = '检测到无视频帧，自动切换兼容档位重试...';
    });
    await _stopSession();
    await Future.delayed(const Duration(milliseconds: 300));
    await _connect();
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

  // 设备是否横屏
  bool get _devIsLandscape => _devW > _devH;

  // 将渲染坐标换算为设备坐标
  // 横屏设备使用 RotatedBox(quarterTurns: 1) 顺时针旋转90°显示
  //
  // 顺时针旋转90°后四角对应关系（纹理→屏幕）：
  //   纹理左上角(0,0)     → 屏幕右上角(renderW, 0)
  //   纹理右上角(devW,0)  → 屏幕右下角(renderW, renderH)
  //   纹理左下角(0,devH)  → 屏幕左上角(0, 0)
  //   纹理右下角(devW,devH)→ 屏幕左下角(0, renderH)
  //
  // 逆推：屏幕坐标(dx, dy) → 设备坐标：
  //   devX = (renderH - dy) * devW/renderH  （dy↑ → devX↓，需翻转）
  //   devY = (renderW - dx) * devH/renderW  （dx↑ → devY↓，也需翻转）
  Offset _toDev(Offset local, Size renderSize) {
    if (_devIsLandscape) {
      // quarterTurns:1 顺时针旋转，手机竖持操作横屏设备
      // 手机 dy → 设备 x，手机 dx → 设备 y（翻转）
      final scaleX = _devW / renderSize.height;
      final scaleY = _devH / renderSize.width;
      return Offset(
        local.dy * scaleX,
        (renderSize.width - local.dx) * scaleY,
      );
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

      if (_devIsLandscape) {
        // 横屏设备：旋转90°在竖屏手机上最大化显示
        // 旋转后显示比例 = devH/devW（竖向）
        final devAspect = _devH / _devW;
        final areaAspect = areaW / areaH;
        double renderW, renderH;
        if (devAspect > areaAspect) {
          renderW = areaW;
          renderH = areaW / devAspect;
        } else {
          renderH = areaH;
          renderW = areaH * devAspect;
        }
        final listenerSize = Size(renderW, renderH);
        return Center(
          child: SizedBox(
            width: renderW,
            height: renderH,
            child: Listener(
              onPointerDown: (e) => _onPointerDown(e, listenerSize),
              onPointerMove: (e) => _onPointerMove(e, listenerSize),
              onPointerUp:   (e) => _onPointerUp(e,   listenerSize),
              child: RotatedBox(
                quarterTurns: 1,
                child: SizedBox(
                  width: renderH,
                  height: renderW,
                  child: Texture(textureId: tid),
                ),
              ),
            ),
          ),
        );
      }

      // 竖屏设备：正常显示
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
