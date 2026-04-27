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
  static const _remoteDir  = '/data/local/tmp';
  static const _remoteDex  = '$_remoteDir/cablebee_pkgserver.dex';
  static const _assetPath  = 'assets/pkgserver.dex';

  final AdbService _adb;
  bool _deployed = false;

  PkgServerService(this._adb);

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Stream all packages from the connected device, one [PkgInfo] at a time.
  /// Yields each package as soon as it's parsed — no waiting for the full list.
  Stream<PkgInfo> streamPackages() => _run();

  /// Fetch info for a single package.
  Future<PkgInfo?> getPackage(String packageName) async {
    await _ensureDeployed();
    final res = await _adb.shell(
        'CLASSPATH=$_remoteDex app_process /system/bin '
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
  void invalidate() => _deployed = false;

  // ── Internal ───────────────────────────────────────────────────────────────

  Stream<PkgInfo> _run() async* {
    await _ensureDeployed();

    // app_process launches the JVM in the shell context — no install needed.
    // -Djava.class.path tells it where to find our dex.
    // stdout is line-buffered JSON; stderr has progress messages.
    final res = await _adb.shell(
        'CLASSPATH=$_remoteDex app_process /system/bin '
        'com.cablebee.pkgserver.Main '
        '2>/dev/null',
        timeoutMs: 120000); // 2 min for large package lists

    for (final line in res.stdout.split('\n')) {
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

  /// Push dex to device if not already done this session.
  Future<void> _ensureDeployed() async {
    if (_deployed) return;

    // Check if already present with correct size
    final checkRes = await _adb.shell('wc -c < $_remoteDex 2>/dev/null');
    final remoteSize = int.tryParse(checkRes.stdout.trim()) ?? 0;

    // Load dex from Flutter assets
    final ByteData assetData = await rootBundle.load(_assetPath);
    final int localSize = assetData.lengthInBytes;

    if (remoteSize == localSize) {
      // Already up to date
      _deployed = true;
      return;
    }

    // Push dex via adb push (through MethodChannel in adb_service)
    await _adb.pushAsset(_assetPath, _remoteDex);
    await _adb.shell('chmod 644 $_remoteDex');
    _deployed = true;
  }
}
