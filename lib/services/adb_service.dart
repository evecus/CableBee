// lib/services/adb_service.dart
//
// 全原生实现：ADB 协议在 Kotlin 层直接与设备通信，不启动任何 adb 进程。
// push/pull 通过原生 SYNC 协议实现。

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/device.dart';
import 'binary_manager.dart';

const _ch = MethodChannel('com.cablebee/adb');

class AdbService extends ChangeNotifier {
  List<AdbDevice> _devices        = [];
  AdbDevice?      _selectedDevice;
  bool            _serverRunning  = false;
  Timer?          _pollTimer;

  List<AdbDevice> get devices        => List.unmodifiable(_devices);
  AdbDevice?      get selectedDevice => _selectedDevice;
  bool            get serverRunning  => _serverRunning;
  bool            get hasDevice      => _selectedDevice != null;

  // ignore: unused_field
  final BinaryManager _binaries;
  AdbService(this._binaries);

  // ── 生命周期 ──────────────────────────────────────────────────────────────

  Future<bool> startServer() async {
    await refreshDevices();
    _startPolling();
    return true;
  }

  Future<void> killServer() async {
    _stopPolling();
    for (final d in _devices) {
      await _invoke('disconnect', {'serial': d.serial});
    }
    _devices.clear();
    _selectedDevice = null;
    _serverRunning  = false;
    notifyListeners();
  }

  // ── 设备列表 ──────────────────────────────────────────────────────────────

  Future<List<AdbDevice>> refreshDevices() async {
    try {
      final raw     = await _invoke<List<dynamic>>('devices', {});
      final serials = raw?.cast<String>() ?? <String>[];

      _devices = serials.map((s) => AdbDevice(
        serial:         s,
        connectionType: s.contains(':') ? ConnectionType.wifi : ConnectionType.usb,
        state:          DeviceState.online,
      )).toList();

      _serverRunning = _devices.isNotEmpty;

      // Keep selection valid
      if (_selectedDevice != null) {
        final match = _devices.where((d) => d.serial == _selectedDevice!.serial);
        _selectedDevice = match.isNotEmpty ? match.first : null;
      }
      if (_selectedDevice == null && _devices.length == 1) {
        _selectedDevice = _devices.first;
      }

      notifyListeners();
    } catch (_) {}
    return _devices;
  }

  void selectDevice(AdbDevice device) {
    _selectedDevice = device;
    notifyListeners();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => refreshDevices());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ── 连接 ──────────────────────────────────────────────────────────────────

  Future<AdbCommandResult> connect(String host, {int port = 5555}) async {
    try {
      final serial = await _invoke<String>('connect', {'host': host, 'port': port});
      await refreshDevices();
      return AdbCommandResult(exitCode: 0, stdout: 'connected to $serial', stderr: '');
    } on PlatformException catch (e) {
      return AdbCommandResult(exitCode: 1, stdout: '', stderr: e.message ?? 'connect failed');
    }
  }

  Future<AdbCommandResult> disconnect({String? serial}) async {
    final targets = serial != null ? [serial] : _devices.map((d) => d.serial).toList();
    for (final s in targets) await _invoke('disconnect', {'serial': s});
    await refreshDevices();
    return AdbCommandResult(exitCode: 0, stdout: 'disconnected', stderr: '');
  }

  /// Android 11+ 无线配对（SPAKE2）通过 jniLibs 中的 libadb.so 执行。
  Future<AdbCommandResult> pair(String host, int port, String pairingCode) async {
    try {
      final output = await _invoke<String>('pair', {
        'host': host,
        'port': port,
        'code': pairingCode,
        // adbBinPath 不再需要：Kotlin 直接从 nativeLibraryDir 找 libadb.so
      });
      return AdbCommandResult(exitCode: 0, stdout: output ?? '', stderr: '');
    } on PlatformException catch (e) {
      return AdbCommandResult(exitCode: 1, stdout: '', stderr: e.message ?? 'pair failed');
    }
  }

  Future<AdbCommandResult> enableTcpip({int port = 5555}) =>
      shell('setprop service.adb.tcp.port $port && stop adbd && start adbd');

  // ── Shell ─────────────────────────────────────────────────────────────────

  Future<AdbCommandResult> shell(String command, {int timeoutMs = 15000}) async {
    if (!hasDevice) return _noDevice();
    try {
      final out = await _invoke<String>('shell', {
        'serial':    _selectedDevice!.serial,
        'command':   command,
        'timeoutMs': timeoutMs,
      });
      return AdbCommandResult(exitCode: 0, stdout: out ?? '', stderr: '');
    } on PlatformException catch (e) {
      return AdbCommandResult(exitCode: 1, stdout: '', stderr: e.message ?? 'shell failed');
    }
  }

  Stream<String> shellStream(String command) async* {
    if (!hasDevice) return;
    final result = await shell(command, timeoutMs: 8000);
    for (final line in result.stdout.split('\n')) yield line;
  }

  // ── push / pull ───────────────────────────────────────────────────────────

  /// 将本机文件推送到设备。
  /// [localPath]  本机绝对路径。
  /// [remotePath] 设备上的绝对路径（如 /sdcard/test.txt）。
  Future<AdbCommandResult> push(String localPath, String remotePath) async {
    if (!hasDevice) return _noDevice();
    try {
      await _invoke<void>('push', {
        'serial':     _selectedDevice!.serial,
        'localPath':  localPath,
        'remotePath': remotePath,
      });
      return AdbCommandResult(exitCode: 0, stdout: 'pushed: $remotePath', stderr: '');
    } on PlatformException catch (e) {
      return AdbCommandResult(exitCode: 1, stdout: '', stderr: e.message ?? 'push failed');
    }
  }

  /// 从设备拉取文件到本机。
  /// [remotePath] 设备上的绝对路径。
  /// [localPath]  本机保存路径。
  Future<AdbCommandResult> pull(String remotePath, String localPath) async {
    if (!hasDevice) return _noDevice();
    try {
      await _invoke<void>('pull', {
        'serial':     _selectedDevice!.serial,
        'remotePath': remotePath,
        'localPath':  localPath,
      });
      return AdbCommandResult(exitCode: 0, stdout: 'pulled: $localPath', stderr: '');
    } on PlatformException catch (e) {
      return AdbCommandResult(exitCode: 1, stdout: '', stderr: e.message ?? 'pull failed');
    }
  }

  // ── 文件列表 ──────────────────────────────────────────────────────────────

  Future<List<FileEntry>> listFiles(String path) async {
    final result = await shell('ls -la "$path" 2>&1');
    return result.stdout
        .split('\n')
        .map(FileEntry.parseLsLine)
        .whereType<FileEntry>()
        .toList();
  }

  // ── 应用管理 ──────────────────────────────────────────────────────────────

  Future<List<AppInfo>> listPackages({bool includeSystem = false}) async {
    final cmd = includeSystem ? 'pm list packages -f 2>&1' : 'pm list packages -f -3 2>&1';
    final result = await shell(cmd);
    return result.stdout.split('\n')
        .where((l) => l.startsWith('package:'))
        .map((l) {
          final parts = l.substring(8).split('=');
          if (parts.length < 2) return null;
          return AppInfo(apkPath: parts[0], packageName: parts.sublist(1).join('=').trim());
        })
        .whereType<AppInfo>()
        .toList();
  }

  Future<AdbCommandResult> installApk(String localPath) =>
      shell('pm install -r "$localPath"');
  Future<AdbCommandResult> uninstall(String pkg)  => shell('pm uninstall $pkg');
  Future<AdbCommandResult> forceStop(String pkg)  => shell('am force-stop $pkg');
  Future<AdbCommandResult> clearData(String pkg)  => shell('pm clear $pkg');

  // ── 设备信息 ──────────────────────────────────────────────────────────────

  Future<Map<String, String>> getDeviceInfo() async {
    final result = await shell(
      'getprop ro.product.model; echo "---";'
      'getprop ro.build.version.release; echo "---";'
      'getprop ro.build.version.sdk; echo "---";'
      'getprop ro.product.manufacturer; echo "---";'
      'cat /proc/meminfo | grep MemTotal; echo "---";'
      'getprop ro.serialno',
    );
    final p = result.stdout.split('---');
    String at(int i) => i < p.length ? p[i].trim() : '';
    return {
      'model': at(0), 'android': at(1), 'sdk': at(2),
      'manufacturer': at(3), 'memory': at(4), 'serial': at(5),
    };
  }

  Future<AdbCommandResult> screenshot(String savePath) async {
    await shell('screencap -p /sdcard/cablebee_sc.png');
    return pull('/sdcard/cablebee_sc.png', savePath);
  }

  // ── 调试设置 ──────────────────────────────────────────────────────────────

  Future<AdbCommandResult> setAnimationScale(double scale) {
    final s = scale.toStringAsFixed(1);
    return shell(
      'settings put global window_animation_scale $s; '
      'settings put global transition_animation_scale $s; '
      'settings put global animator_duration_scale $s',
    );
  }

  Future<AdbCommandResult> setWmSize(int w, int h)  => shell('wm size ${w}x$h');
  Future<AdbCommandResult> resetWmSize()             => shell('wm size reset');
  Future<AdbCommandResult> setWmDensity(int dpi)     => shell('wm density $dpi');
  Future<AdbCommandResult> resetWmDensity()          => shell('wm density reset');
  Future<AdbCommandResult> reboot([String? mode])    =>
      shell(mode != null ? 'reboot $mode' : 'reboot');

  // ── Logcat ────────────────────────────────────────────────────────────────

  Stream<String> logcat({String? filter, String level = 'V'}) async* {
    final cmd = StringBuffer('logcat -v time');
    if (filter != null) cmd.write(' -s $filter');
    cmd.write(' *:$level');
    yield* shellStream(cmd.toString());
  }

  // ── 工具方法 ──────────────────────────────────────────────────────────────

  Future<T?> _invoke<T>(String method, Map<String, dynamic> args) =>
      _ch.invokeMethod<T>(method, args);

  AdbCommandResult _noDevice() =>
      AdbCommandResult(exitCode: -1, stdout: '', stderr: 'No device selected');

  @override
  void dispose() { _stopPolling(); super.dispose(); }
}

// ── 结果类型 ──────────────────────────────────────────────────────────────────

class AdbCommandResult {
  final int    exitCode;
  final String stdout;
  final String stderr;
  AdbCommandResult({required this.exitCode, required this.stdout, required this.stderr});
  bool   get isSuccess => exitCode == 0;
  String get output    => stdout.isNotEmpty ? stdout : stderr;
}

class AppInfo {
  final String apkPath;
  final String packageName;
  AppInfo({required this.apkPath, required this.packageName});
}

class FileEntry {
  final String name;
  final bool   isDirectory;
  final String permissions;
  final String size;
  final String date;
  FileEntry({required this.name, required this.isDirectory,
             required this.permissions, required this.size, required this.date});

  static FileEntry? parseLsLine(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 8) return null;
    final perms = parts[0];
    if (!perms.startsWith('-') && !perms.startsWith('d') && !perms.startsWith('l')) return null;
    final name = parts.sublist(7).join(' ');
    if (name == '.' || name == '..') return null;
    return FileEntry(
      permissions: perms, isDirectory: perms.startsWith('d'),
      size: parts[4], date: '${parts[5]} ${parts[6]}', name: name,
    );
  }
}
