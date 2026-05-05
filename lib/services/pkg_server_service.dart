// lib/services/pkg_server_service.dart
//
// Deploys pkgserver.dex to the connected device and runs it via app_process.
// The server writes one JSON line per package to stdout:
//
//   {"package":"com.foo","label":"Foo","icon":"<base64-png>","apkPath":"...","enabled":true,...}
//
// Usage:
//   final svc = PkgServerService(adb);
//   await for (final info in svc.streamPackages()) {
//     // update UI
//   }

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'adb_service.dart';

class PkgInfo {
  final String packageName;
  final String label;
  final Uint8List? icon;   // PNG bytes, null if not available
  final String apkPath;
  final int apkSize;
  final bool enabled;
  final int flags;
  final int versionCode;
  final String versionName;
  final int firstInstallTime;
  final int lastUpdateTime;
  final String dataDir;
  final int targetSdkVersion;
  final int minSdkVersion;
  final String? error;

  bool get isSystem => (flags & 0x01) != 0; // ApplicationInfo.FLAG_SYSTEM = 1

  const PkgInfo({
    required this.packageName,
    required this.label,
    this.icon,
    this.apkPath = '',
    this.apkSize = 0,
    this.enabled = true,
    this.flags = 0,
    this.versionCode = 0,
    this.versionName = '',
    this.firstInstallTime = 0,
    this.lastUpdateTime = 0,
    this.dataDir = '',
    this.targetSdkVersion = 0,
    this.minSdkVersion = 0,
    this.error,
  });

  factory PkgInfo.fromJson(Map<String, dynamic> json) {
    Uint8List? icon;
    final iconB64 = json['icon'] as String?;
    if (iconB64 != null && iconB64.isNotEmpty) {
      try { icon = base64Decode(iconB64); } catch (_) {}
    }
    return PkgInfo(
      packageName:      json['package']          as String? ?? '',
      label:            json['label']             as String? ?? json['package'] as String? ?? '',
      icon:             icon,
      apkPath:          json['apkPath']           as String? ?? '',
      apkSize:          (json['apkSize']          as num?)?.toInt() ?? 0,
      enabled:          json['enabled']           as bool?   ?? true,
      flags:            (json['flags']            as num?)?.toInt() ?? 0,
      versionCode:      (json['versionCode']      as num?)?.toInt() ?? 0,
      versionName:      json['versionName']       as String? ?? '',
      firstInstallTime: (json['firstInstallTime'] as num?)?.toInt() ?? 0,
      lastUpdateTime:   (json['lastUpdateTime']   as num?)?.toInt() ?? 0,
      dataDir:          json['dataDir']           as String? ?? '',
      targetSdkVersion: (json['targetSdkVersion'] as num?)?.toInt() ?? 0,
      minSdkVersion:    (json['minSdkVersion']    as num?)?.toInt() ?? 0,
      error:            json['error']             as String?,
    );
  }
}

class PkgServerService {
  static const _assetPath    = 'assets/pkgserver.apk';
  static const _preferredDex = '/data/local/tmp/pkgserver.apk';
  static const _fallbackDex  = '/sdcard/pkgserver.apk';

  final AdbService _adb;
  bool _deployed = false;
  String? _activeDex; // 实际使用的路径，由 _ensureDeployed 决定

  PkgServerService(this._adb);

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Stream all packages from the connected device, one [PkgInfo] at a time.
  /// Yields each package as soon as it's parsed — no waiting for the full list.
  Stream<PkgInfo> streamPackages({String sortBy = 'package'}) => _run(sortBy: sortBy);

  /// Fetch info for a single package.
  Future<PkgInfo?> getPackage(String packageName) async {
    await _ensureDeployed();
    final dex = _activeDex!;
    final androidData = dex.startsWith('/sdcard') ? 'ANDROID_DATA=/sdcard ' : '';
    final res = await _adb.shell(
        'CLASSPATH=$dex ${androidData}'
        'app_process ./ '
        'com.cablebee.pkgserver.Main '
        '"$packageName" 2>/dev/null');
    for (final line in res.stdout.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try { return PkgInfo.fromJson(jsonDecode(t) as Map<String, dynamic>); }
      catch (_) {}
    }
    return null;
  }

  /// Force re-deploy on next call (e.g. after reconnect).
  void invalidate() {
    _deployed = false;
    _activeDex = null;
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Stream<PkgInfo> _run({String sortBy = 'package'}) async* {
    await _ensureDeployed();
    final dex = _activeDex!;
    final androidData = dex.startsWith('/sdcard') ? 'ANDROID_DATA=/sdcard ' : '';
    final cmd = 'CLASSPATH=$dex ${androidData}'
        'app_process ./ '
        'com.cablebee.pkgserver.Main '
        '--sort=$sortBy '
        '2>/dev/null';

    // 真正流式：每读到一行 JSON 就立刻 yield，不等全部完成
    await for (final line in _adb.shellStream(cmd, timeoutMs: 120000)) {
      final t = line.trim();
      if (t.isEmpty || !t.startsWith('{')) continue;
      try {
        final json = jsonDecode(t) as Map<String, dynamic>;
        yield PkgInfo.fromJson(json);
      } catch (_) {
        // malformed line — skip
      }
    }
  }

  /// 优先推送到 /data/local/tmp，失败则 fallback 到 /sdcard。
  Future<void> _ensureDeployed() async {
    if (_deployed && _activeDex != null) return;

    final ByteData assetData = await rootBundle.load(_assetPath);
    final int localSize = assetData.lengthInBytes;

    for (final dexPath in [_preferredDex, _fallbackDex]) {
      // 检查远端文件大小是否一致，一致则直接复用
      final checkRes = await _adb.shell('wc -c < $dexPath 2>/dev/null');
      final remoteSize = int.tryParse(checkRes.stdout.trim()) ?? 0;
      if (remoteSize == localSize) {
        _activeDex = dexPath;
        _deployed = true;
        return;
      }

      // 尝试推送
      try {
        await _adb.pushAsset(_assetPath, dexPath);
        // 验证推送成功
        final verifyRes = await _adb.shell('wc -c < $dexPath 2>/dev/null');
        final pushedSize = int.tryParse(verifyRes.stdout.trim()) ?? 0;
        if (pushedSize == localSize) {
          // /data/local/tmp 支持 chmod；/sdcard 是 FUSE 不支持，忽略错误
          await _adb.shell('chmod 644 $dexPath 2>/dev/null');
          _activeDex = dexPath;
          _deployed = true;
          return;
        }
      } catch (_) {
        // 推送失败，尝试下一个路径
        continue;
      }
    }

    // 两个路径都失败
    throw Exception('无法将 pkgserver.dex 推送到被连接设备，'
        '请确认设备已授权 ADB 调试');
  }
}
