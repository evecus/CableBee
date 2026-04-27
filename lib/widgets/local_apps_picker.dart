import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/theme.dart';

// ── 本机应用信息 ────────────────────────────────────────────────────────────

class _LocalApp {
  final String packageName;
  final String label;
  final String apkPath;

  const _LocalApp({
    required this.packageName,
    required this.label,
    required this.apkPath,
  });
}

// ── 入口函数：弹出底部面板，返回选中的 APK 路径 ────────────────────────────

Future<String?> showLocalAppsPicker(BuildContext context) async {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _LocalAppsPickerSheet(),
  );
}

// ── 保留 LocalAppsPicker 供旧调用兼容（内部转发到底部面板）────────────────

class LocalAppsPicker extends StatelessWidget {
  const LocalAppsPicker({super.key});

  @override
  Widget build(BuildContext context) {
    return const _LocalAppsPickerSheet();
  }
}

// ── 底部面板 ────────────────────────────────────────────────────────────────

class _LocalAppsPickerSheet extends StatefulWidget {
  const _LocalAppsPickerSheet();

  @override
  State<_LocalAppsPickerSheet> createState() => _LocalAppsPickerSheetState();
}

class _LocalAppsPickerSheetState extends State<_LocalAppsPickerSheet> {
  static const _channel = MethodChannel('com.cablebee.assistant/local_apps');

  bool _loading = true;
  String? _error;
  List<_LocalApp> _apps = [];
  List<_LocalApp> _filtered = [];
  String _query = '';
  bool _extracting = false;
  String? _extractMsg;

  @override
  void initState() {
    super.initState();
    _requestAndLoad();
  }

  Future<void> _requestAndLoad() async {
    final status = await Permission.storage.request();
    if (!status.isGranted && !status.isLimited) {
      // Android 13+ storage 可能被拒但实际有权限，继续尝试
    }
    await _loadApps();
  }

  Future<void> _loadApps() async {
    setState(() { _loading = true; _error = null; });
    try {
      final result = await _channel.invokeMethod<List>('getInstalledApps');
      if (result == null) throw Exception('无法获取应用列表');

      final apps = result.map((item) {
        final map = Map<String, dynamic>.from(item as Map);
        return _LocalApp(
          packageName: map['packageName'] as String,
          label: (map['label'] as String?) ?? map['packageName'] as String,
          apkPath: map['apkPath'] as String,
        );
      }).toList();

      apps.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

      setState(() {
        _apps = apps;
        _filtered = apps;
        _loading = false;
      });
    } on PlatformException catch (e) {
      setState(() {
        _error = '加载失败：${e.message}';
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '加载失败：$e';
        _loading = false;
      });
    }
  }

  void _search(String query) {
    setState(() {
      _query = query;
      _filtered = _apps.where((a) {
        final q = query.toLowerCase();
        return a.label.toLowerCase().contains(q) ||
               a.packageName.toLowerCase().contains(q);
      }).toList();
    });
  }

  Future<void> _pick(_LocalApp app) async {
    setState(() {
      _extracting = true;
      _extractMsg = '正在提取 ${app.label}...';
    });

    try {
      final tmpPath = await _channel.invokeMethod<String>(
        'copyApkToTemp',
        {'packageName': app.packageName},
      );
      setState(() { _extracting = false; _extractMsg = null; });
      if (tmpPath != null && mounted) {
        Navigator.pop(context, tmpPath);
      } else {
        setState(() {
          _extracting = false;
          _extractMsg = '✗ 无法提取 APK，路径不可访问';
        });
      }
    } on PlatformException catch (e) {
      setState(() {
        _extracting = false;
        _extractMsg = '✗ 提取失败：${e.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;

    return Container(
      height: screenH * 0.88,
      decoration: const BoxDecoration(
        color: AppTheme.bg0,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Stack(children: [
        Column(children: [
          // ── 顶部把手 ──
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: AppTheme.bg3,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // ── 标题栏 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded,
                    size: 20, color: AppTheme.textSecondary),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
              const SizedBox(width: 4),
              const Text('选择本机应用', style: TextStyle(
                fontFamily: 'SpaceMono', fontSize: 15,
                fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
              )),
            ]),
          ),

          // ── 搜索框 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: TextField(
              onChanged: _search,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 13,
                color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: '搜索应用名称或包名',
                hintStyle: const TextStyle(
                  color: AppTheme.textMuted, fontSize: 12,
                  fontFamily: 'JetBrainsMono'),
                prefixIcon: const Icon(Icons.search_rounded,
                    size: 18, color: AppTheme.textMuted),
                filled: true,
                fillColor: AppTheme.bg1,
                contentPadding: const EdgeInsets.symmetric(
                    vertical: 8, horizontal: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          const Divider(height: 1, color: AppTheme.bg3),

          // ── 列表 ──
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(
                    color: AppTheme.primary))
                : _error != null
                    ? Center(child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.error_outline_rounded,
                              size: 40, color: AppTheme.danger),
                          const SizedBox(height: 12),
                          Text(_error!, textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono', fontSize: 12,
                                color: AppTheme.textSecondary)),
                          const SizedBox(height: 16),
                          FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.primary),
                            onPressed: _loadApps,
                            child: const Text('重试'),
                          ),
                        ]),
                      ))
                    : _filtered.isEmpty
                        ? Center(child: Text(
                            _query.isEmpty ? '没有已安装应用' : '无匹配结果',
                            style: const TextStyle(
                              fontFamily: 'JetBrainsMono', fontSize: 13,
                              color: AppTheme.textMuted)))
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: _filtered.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, indent: 16, color: AppTheme.bg3),
                            itemBuilder: (_, i) {
                              final app = _filtered[i];
                              return ListTile(
                                contentPadding:
                                    const EdgeInsets.fromLTRB(16, 4, 12, 4),
                                leading: Container(
                                  width: 40, height: 40,
                                  decoration: BoxDecoration(
                                    color: AppTheme.bg2,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(Icons.android_rounded,
                                      size: 22, color: AppTheme.textMuted),
                                ),
                                title: Text(app.label, style: const TextStyle(
                                  fontFamily: 'SpaceMono', fontSize: 13,
                                  color: AppTheme.textPrimary)),
                                subtitle: Text(app.packageName,
                                  style: const TextStyle(
                                    fontFamily: 'JetBrainsMono', fontSize: 10,
                                    color: AppTheme.textMuted),
                                  overflow: TextOverflow.ellipsis),
                                onTap: _extracting ? null : () => _pick(app),
                              );
                            },
                          ),
          ),
        ]),

        // ── 提取进度遮罩 ──
        if (_extracting || _extractMsg != null)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              child: Container(
                color: Colors.black54,
                child: Center(child: Container(
                  margin: const EdgeInsets.all(32),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppTheme.bg1,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_extracting) ...[
                      const CircularProgressIndicator(color: AppTheme.primary),
                      const SizedBox(height: 14),
                    ] else
                      Icon(
                        (_extractMsg ?? '').startsWith('✗')
                            ? Icons.error_outline_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 32,
                        color: (_extractMsg ?? '').startsWith('✗')
                            ? AppTheme.danger : AppTheme.success,
                      ),
                    const SizedBox(height: 8),
                    Text(
                      _extractMsg ?? '正在提取...',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono', fontSize: 12,
                        color: AppTheme.textSecondary),
                    ),
                    if (!_extracting) ...[
                      const SizedBox(height: 14),
                      FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.primary),
                        onPressed: () =>
                            setState(() => _extractMsg = null),
                        child: const Text('关闭'),
                      ),
                    ],
                  ]),
                )),
              ),
            ),
          ),
      ]),
    );
  }
}
