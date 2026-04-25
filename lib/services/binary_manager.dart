import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Manages the adb and fastboot binaries bundled as native libraries.
///
/// Instead of Flutter assets (which pack ALL ABIs into every APK),
/// the binaries are stored as fake .so files in jniLibs:
///
///   android/app/src/main/jniLibs/arm64-v8a/libadb.so
///   android/app/src/main/jniLibs/arm64-v8a/libfastboot.so
///   android/app/src/main/jniLibs/armeabi-v7a/libadb.so
///   android/app/src/main/jniLibs/armeabi-v7a/libfastboot.so
///
/// Android ABI splits automatically include only the matching ABI's jniLibs,
/// so each split APK contains only its own architecture's binaries.
///
/// At runtime we locate the files via [ApplicationInfo.nativeLibraryDir],
/// which points directly to the already-extracted .so files on disk.
/// No extraction step needed — Android already puts them there.
/// We just chmod +x once and they're ready to run.

const _ch = MethodChannel('com.cablebee/adb');

class BinaryManager extends ChangeNotifier {
  String? _adbPath;
  String? _fastbootPath;
  bool    _isReady = false;

  String? get adbPath      => _adbPath;
  String? get fastbootPath => _fastbootPath;
  bool    get isReady      => _isReady;
  bool    get isDownloading    => false;
  double  get downloadProgress => 1.0;
  String  get statusMessage    => _isReady ? '就绪 (内置)' : '初始化中…';

  Future<void> initialize() async {
    try {
      // adb 和 fastboot 二进制由 MainActivity 从 assets 解压到 filesDir
      // 路径和甲壳虫完全一致：/data/user/0/包名/files/adb
      final nativeDir = await _ch.invokeMethod<String>('getNativeLibraryDir');
      if (nativeDir == null) throw Exception('getNativeLibraryDir returned null');

      val adb      = File('$nativeDir/libcablebee_adb.so');
      final fastboot = File('$nativeDir/libcablebee_fastboot.so');

      if (!await adb.exists())      throw Exception('libcablebee_adb.so not found in $nativeDir');
      if (!await fastboot.exists()) throw Exception('libcablebee_fastboot.so not found in $nativeDir');

      _adbPath      = adb.path;
      _fastbootPath = fastboot.path;
      _isReady      = true;
    } catch (e) {
      _isReady = false;
      debugPrint('BinaryManager.initialize error: $e');
    }
    notifyListeners();
  }

  /// Re-run chmod in case permissions were lost (e.g. after OTA).
  Future<void> reExtract() async {
    _isReady = false;
    notifyListeners();
    await initialize();
  }

  Future<void> redownload() => reExtract();

  Future<void> _chmod(String path) async {
    try {
      await Process.run('chmod', ['755', path]);
    } catch (_) {}
  }
}
