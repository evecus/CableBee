// lib/services/adb_service.dart
//
// 全原生实现：ADB 协议在 Kotlin 层直接与设备通信，不启动任何 adb 进程。
// push/pull 通过原生 SYNC 协议实现。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/device.dart';
import 'binary_manager.dart';

const _ch          = MethodChannel('com.cablebee/adb');
const _shellStream = EventChannel('com.cablebee/shell_stream');

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

  Stream<String> shellStream(String command, {int timeoutMs = 120000}) {
    if (!hasDevice) return const Stream.empty();
    // 用 StreamController 把广播流转为单订阅流，避免 await for 订阅晚导致丢数据
    final controller = StreamController<String>();
    final sub = _shellStream
        .receiveBroadcastStream({
          'serial':    _selectedDevice!.serial,
          'command':   command,
          'timeoutMs': timeoutMs,
        })
        .listen(
          (e) => controller.add(e as String),
          onError: controller.addError,
          onDone:  controller.close,
          cancelOnError: false,
        );
    controller.onCancel = () => sub.cancel();
    return controller.stream;
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

  /// 将 Flutter asset 写到本机临时文件后推送到设备。
  /// [assetPath]  如 'assets/pkgserver.dex'
  /// [remotePath] 设备上的目标路径
  Future<AdbCommandResult> pushAsset(String assetPath, String remotePath) async {
    if (!hasDevice) return _noDevice();
    try {
      // 写到 app cache 目录
      final data = await rootBundle.load(assetPath);
      final tmpFile = File(
        '${(await getTemporaryDirectory()).path}/${assetPath.split('/').last}',
      );
      await tmpFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return push(tmpFile.path, remotePath);
    } catch (e) {
      return AdbCommandResult(exitCode: 1, stdout: '', stderr: e.toString());
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
    final result = await shell('ls -laL "$path" 2>&1');
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
          final raw = l.substring(8); // 去掉 "package:"
          // 格式: /data/app/~~hash/com.pkg-hash==/base.apk=com.pkg
          // 用最后一个 '=' 分割，左边是 apkPath，右边是 packageName
          final lastEq = raw.lastIndexOf('=');
          if (lastEq < 0) return null;
          final apkPath = raw.substring(0, lastEq);
          final packageName = raw.substring(lastEq + 1).trim();
          if (packageName.isEmpty) return null;
          return AppInfo(apkPath: apkPath, packageName: packageName);
        })
        .whereType<AppInfo>()
        .toList();
  }

  /// 从 APK 提取 launcher icon，返回 PNG 字节；失败返回 null。
  /// 策略：用设备上的 unzip 列出文件 → 找最高分辨率 mipmap/ic_launcher*.png → base64 输出
  Future<Uint8List?> loadAppIcon(String apkPath) async {
    if (!hasDevice) return null;
    try {
      // 列出 APK 内所有 png 文件
      final listRes = await shell('unzip -l "$apkPath" "*.png" 2>/dev/null');
      if (!listRes.isSuccess && listRes.stdout.isEmpty) return null;

      // 筛选 mipmap 或 drawable 下的 ic_launcher
      final lines = listRes.stdout.split('\n');
      final candidates = lines
          .map((l) => l.trim().split(RegExp(r'\s+')).last)
          .where((f) =>
              f.endsWith('.png') &&
              (f.contains('mipmap') || f.contains('drawable')) &&
              (f.contains('ic_launcher') || f.contains('icon')))
          .toList();

      // 按分辨率优先级排序
      int rank(String f) {
        if (f.contains('xxxhdpi')) return 0;
        if (f.contains('xxhdpi'))  return 1;
        if (f.contains('xhdpi'))   return 2;
        if (f.contains('hdpi'))    return 3;
        if (f.contains('mdpi'))    return 4;
        return 5;
      }
      candidates.sort((a, b) => rank(a).compareTo(rank(b)));

      // 没有精确匹配则取任意 mipmap/drawable png
      String? target;
      if (candidates.isNotEmpty) {
        target = candidates.first;
      } else {
        target = lines
            .map((l) => l.trim().split(RegExp(r'\s+')).last)
            .where((f) =>
                f.endsWith('.png') &&
                (f.contains('mipmap') || f.contains('drawable')))
            .firstOrNull;
      }
      if (target == null) return null;

      // 解压单个文件并 base64 输出
      final b64Res = await shell(
          'unzip -p "$apkPath" "$target" 2>/dev/null | base64 2>/dev/null');
      if (!b64Res.isSuccess || b64Res.stdout.trim().isEmpty) return null;

      return base64Decode(b64Res.stdout.trim().replaceAll('\n', ''));
    } catch (_) {
      return null;
    }
  }

  Future<AdbCommandResult> installApk(String localPath) =>
      shell('pm install -r "$localPath"');
  Future<AdbCommandResult> uninstall(String pkg)  => shell('pm uninstall $pkg');
  Future<AdbCommandResult> forceStop(String pkg)  => shell('am force-stop $pkg');
  Future<AdbCommandResult> clearData(String pkg)  => shell('pm clear $pkg');

  // ── 设备信息 ──────────────────────────────────────────────────────────────

  Future<Map<String, String>> getDeviceInfo() async {
    const sep = '<<<SEP>>>';
    final result = await shell(
      'getprop ro.product.model; echo "$sep";'
      'getprop ro.product.brand; echo "$sep";'
      'getprop ro.product.manufacturer; echo "$sep";'
      'getprop ro.board.platform; echo "$sep";'
      'getprop ro.product.cpu.abi; echo "$sep";'
      'cat /proc/cpuinfo | grep "^processor" | wc -l; echo "$sep";'
      'wm size; echo "$sep";'
      'wm density; echo "$sep";'
      'cat /proc/meminfo | grep MemTotal; echo "$sep";'
      'df /data | tail -1; echo "$sep";'
      'dumpsys battery | grep level; echo "$sep";'
      'dumpsys battery | grep voltage; echo "$sep";'
      'dumpsys battery | grep temperature; echo "$sep";'
      'dumpsys battery | grep present; echo "$sep";'
      'getprop ro.build.version.release; echo "$sep";'
      'getprop ro.build.version.sdk; echo "$sep";'
      'getprop ro.build.version.security_patch; echo "$sep";'
      'uname -r; echo "$sep";'
      'getprop ro.serialno; echo "$sep";'
      'ip addr show wlan0 | grep "inet "; echo "$sep";'
      'cat /sys/class/net/wlan0/address; echo "$sep";'
      'settings get secure android_id',
    );
    final parts = result.stdout.split(sep);
    String at(int i) => i < parts.length ? parts[i].trim() : '';

    // 分辨率解析: "Physical size 1080x2400"
    String resolution = '无';
    final sizeRaw = at(6);
    final sizeMatch = RegExp(r'(\d+x\d+)').firstMatch(sizeRaw);
    if (sizeMatch != null) resolution = sizeMatch.group(1)!;

    // DPI解析: "Physical density 420"
    String dpi = '无';
    final dpiRaw = at(7);
    final dpiMatch = RegExp(r'(\d+)').firstMatch(dpiRaw);
    if (dpiMatch != null) dpi = '${dpiMatch.group(1)!} dpi';

    // 内存解析: "MemTotal: 3821568 kB"
    String memory = '无';
    final memMatch = RegExp(r'(\d+)\s*kB').firstMatch(at(8));
    if (memMatch != null) {
      final kb = int.tryParse(memMatch.group(1)!) ?? 0;
      memory = '${(kb / 1024 / 1024).toStringAsFixed(1)} GB';
    }

    // 存储解析: df 输出
    String storageTotal = '无', storageFree = '无';
    final dfParts = at(9).trim().split(RegExp(r'\s+'));
    if (dfParts.length >= 4) {
      int? parseK(String s) => int.tryParse(s.replaceAll(RegExp(r'[^\d]'), ''));
      final total = parseK(dfParts[1]);
      final avail = parseK(dfParts.length >= 4 ? dfParts[3] : '');
      if (total != null) storageTotal = '${(total / 1024 / 1024).toStringAsFixed(1)} GB';
      if (avail != null) storageFree = '${(avail / 1024 / 1024).toStringAsFixed(1)} GB';
    }

    // 电池
    String batteryLevel = '无', batteryVolt = '无', batteryTemp = '无';
    final battPresent = at(13);
    final hasBattery = !battPresent.contains('false');
    if (hasBattery) {
      final lvlMatch = RegExp(r'level:\s*(\d+)').firstMatch(at(10));
      if (lvlMatch != null) batteryLevel = '${lvlMatch.group(1)!}%';
      final voltMatch = RegExp(r'voltage:\s*(\d+)').firstMatch(at(11));
      if (voltMatch != null) {
        final mv = int.tryParse(voltMatch.group(1)!) ?? 0;
        batteryVolt = mv > 1000 ? '${(mv / 1000).toStringAsFixed(2)} V' : '$mv mV';
      }
      final tempMatch = RegExp(r'temperature:\s*(\d+)').firstMatch(at(12));
      if (tempMatch != null) {
        final t = int.tryParse(tempMatch.group(1)!) ?? 0;
        batteryTemp = '${(t / 10).toStringAsFixed(1)} °C';
      }
    }

    // IP 地址解析: "    inet 192.168.1.x/24 brd ..."
    String ipAddr = '无';
    final ipMatch = RegExp(r'inet\s+([\d.]+)').firstMatch(at(19));
    if (ipMatch != null) ipAddr = ipMatch.group(1)!;

    // MAC
    String mac = at(20).trim();
    if (mac.isEmpty || mac.contains('Permission') || mac == '02:00:00:00:00:00') mac = '无';

    // 核心数
    String cores = at(5).trim();
    if (cores.isEmpty || cores == '0') {
      // fallback: nproc
      final np = await shell('nproc');
      cores = np.stdout.trim();
    }
    if (cores.isNotEmpty && cores != '0') cores = '$cores 核';

    return {
      'model':           at(0).isEmpty ? '无' : at(0),
      'brand':           at(1).isEmpty ? '无' : at(1),
      'manufacturer':    at(2).isEmpty ? '无' : at(2),
      'platform':        at(3).isEmpty ? '无' : at(3),
      'cpu_abi':         at(4).isEmpty ? '无' : at(4),
      'cpu_cores':       cores.isEmpty ? '无' : cores,
      'resolution':      resolution,
      'dpi':             dpi,
      'memory':          memory,
      'storage_total':   storageTotal,
      'storage_free':    storageFree,
      'battery_level':   batteryLevel,
      'battery_voltage': batteryVolt,
      'battery_temp':    batteryTemp,
      'android':         at(14).isEmpty ? '无' : at(14),
      'sdk':             at(15).isEmpty ? '无' : at(15),
      'security_patch':  at(16).isEmpty ? '无' : at(16),
      'kernel':          at(17).isEmpty ? '无' : at(17),
      'serial':          at(18).isEmpty ? '无' : at(18),
      'ip':              ipAddr,
      'mac':             mac,
      'android_id':      at(21).isEmpty ? '无' : at(21),
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
    // symlink 格式: lrwxrwxrwx ... name -> target
    // 只取 '->' 前的部分作为 name，symlink 视为目录（可导航）
    final rawName = parts.sublist(7).join(' ');
    final arrowIdx = rawName.indexOf(' -> ');
    final name = arrowIdx >= 0 ? rawName.substring(0, arrowIdx) : rawName;
    if (name == '.' || name == '..') return null;
    final isDir = perms.startsWith('d') || perms.startsWith('l');
    return FileEntry(
      permissions: perms, isDirectory: isDir,
      size: parts[4], date: '${parts[5]} ${parts[6]}', name: name,
    );
  }
}
