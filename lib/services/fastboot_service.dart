import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'binary_manager.dart';

const _ch = MethodChannel('com.cablebee/adb');

class FastbootService extends ChangeNotifier {
  final BinaryManager _binaries;

  bool    _deviceConnected = false;
  String? _deviceSerial;

  bool    get deviceConnected => _deviceConnected;
  String? get deviceSerial    => _deviceSerial;

  FastbootService(this._binaries);

  // ── run fastboot subprocess ───────────────────────────────────────────────

  Future<FastbootResult> run(List<String> args) async {
    final fb = _binaries.fastbootPath;
    if (fb == null) {
      return FastbootResult(exitCode: -1, output: 'fastboot binary not ready');
    }
    try {
      final result = await Process.run(
        fb, args,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      return FastbootResult(
        exitCode: result.exitCode,
        output: '${result.stdout}${result.stderr}'.trim(),
      );
    } catch (e) {
      return FastbootResult(exitCode: -1, output: e.toString());
    }
  }

  Future<FastbootResult> devices() async {
    final r = await run(['devices']);
    _deviceConnected = r.output.isNotEmpty &&
        !r.output.contains('no permissions') &&
        r.output.contains('\t');
    _deviceSerial = _deviceConnected
        ? r.output.split('\t').first.trim()
        : null;
    notifyListeners();
    return r;
  }

  Future<FastbootResult> getVar(String variable)          => run(['getvar', variable]);
  Future<FastbootResult> flash(String part, String path)  => run(['flash', part, path]);
  Future<FastbootResult> erase(String partition)          => run(['erase', partition]);
  Future<FastbootResult> reboot([String? target])         =>
      target != null ? run(['reboot', target]) : run(['reboot']);
  Future<FastbootResult> oemUnlock()                      => run(['flashing', 'unlock']);
  Future<FastbootResult> oemLock()                        => run(['flashing', 'lock']);
  Future<FastbootResult> wipeData()                       => run(['-w']);
  Future<FastbootResult> runRaw(List<String> args)        => run(args);

  Future<Map<String, String>> getAllVars() async {
    final r   = await run(['getvar', 'all']);
    final map = <String, String>{};
    for (final line in r.output.split('\n')) {
      final idx = line.indexOf(':');
      if (idx > 0) {
        map[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
      }
    }
    return map;
  }
}

class FastbootResult {
  final int    exitCode;
  final String output;
  bool get isSuccess => exitCode == 0;
  FastbootResult({required this.exitCode, required this.output});
}
