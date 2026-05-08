import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _ch = MethodChannel('com.cablebee/fastboot');

class FastbootService extends ChangeNotifier {
  bool    _deviceConnected = false;
  String? _deviceSerial;

  bool    get deviceConnected => _deviceConnected;
  String? get deviceSerial    => _deviceSerial;

  // ── 内部：调用 Kotlin 层执行 fastboot ────────────────────────────────────

  Future<FastbootResult> _invoke(List<String> args) async {
    try {
      final Map result = await _ch.invokeMethod('run', {'args': args});
      return FastbootResult(
        exitCode: result['exitCode'] as int,
        output:   result['output']  as String,
      );
    } on PlatformException catch (e) {
      return FastbootResult(exitCode: -1, output: e.message ?? e.code);
    } catch (e) {
      return FastbootResult(exitCode: -1, output: e.toString());
    }
  }

  // ── 设备检测 ─────────────────────────────────────────────────────────────

  Future<FastbootResult> devices() async {
    try {
      final Map map = await _ch.invokeMethod('getDevices');
      _deviceConnected = map['connected'] as bool? ?? false;
      _deviceSerial    = map['serial']    as String?;
      notifyListeners();
      final output = _deviceConnected
          ? '$_deviceSerial\tfastboot'
          : (map['needsPermission'] == true ? '(需要 USB 权限，请重试)' : '');
      return FastbootResult(exitCode: 0, output: output);
    } on PlatformException catch (e) {
      _deviceConnected = false;
      _deviceSerial    = null;
      notifyListeners();
      return FastbootResult(exitCode: -1, output: e.message ?? e.code);
    }
  }

  // ── 命令封装 ─────────────────────────────────────────────────────────────

  Future<FastbootResult> run(List<String> args) => _invoke(args);

  Future<FastbootResult> getVar(String variable) =>
      _invoke(['getvar', variable]);

  Future<FastbootResult> flash(String part, String path) =>
      _invoke(['flash', part, path]);

  Future<FastbootResult> erase(String partition) =>
      _invoke(['erase', partition]);

  Future<FastbootResult> reboot([String? target]) =>
      target != null ? _invoke(['reboot', target]) : _invoke(['reboot']);

  Future<FastbootResult> oemUnlock() => _invoke(['flashing', 'unlock']);

  Future<FastbootResult> oemLock()   => _invoke(['flashing', 'lock']);

  Future<FastbootResult> wipeData()  => _invoke(['-w']);

  Future<FastbootResult> runRaw(List<String> args) => _invoke(args);

  Future<Map<String, String>> getAllVars() async {
    final r   = await _invoke(['getvar', 'all']);
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
