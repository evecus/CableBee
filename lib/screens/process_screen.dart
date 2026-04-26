// lib/screens/process_screen.dart
// 进程管理页面：显示设备内存概览 + 运行进程列表（按内存降序），支持 force-stop

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

// ── 数据模型 ─────────────────────────────────────────────────────────────────

class _ProcInfo {
  final String pkg;
  final int kbRss; // 单位 KB
  _ProcInfo({required this.pkg, required this.kbRss});
}

// ── Screen ───────────────────────────────────────────────────────────────────

class ProcessScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const ProcessScreen({super.key, this.onActionsChanged});
  @override
  State<ProcessScreen> createState() => ProcessScreenState();
}

class ProcessScreenState extends State<ProcessScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => _pushActions();

  bool _loading = false;
  int _totalKb = 0;
  int _usedKb  = 0;
  List<_ProcInfo> _procs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _pushActions();
    });
  }

  void _pushActions() {
    widget.onActionsChanged?.call([
      IconButton(
        icon: const Icon(Icons.refresh_rounded, size: 20, color: AppTheme.textMuted),
        onPressed: _load,
        tooltip: '刷新',
      ),
    ]);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final adb = context.read<AdbService>();

    // ① 总内存 & 可用内存
    final memRes = await adb.shell(
        'cat /proc/meminfo | grep -E "^MemTotal:|^MemAvailable:"');
    int totalKb = 0, availKb = 0;
    for (final line in memRes.stdout.split('\n')) {
      final m = RegExp(r'(\w+):\s+(\d+)').firstMatch(line);
      if (m == null) continue;
      final kb = int.tryParse(m.group(2)!) ?? 0;
      if (m.group(1) == 'MemTotal') totalKb = kb;
      if (m.group(1) == 'MemAvailable') availKb = kb;
    }

    // ② 进程内存：解析 dumpsys meminfo "Total PSS by process" 段
    // 行格式:  "   166,712K: system_server (pid 659)"
    // 用 sed 提取：包名($2) 和内存KB($1去掉K:和逗号)
    final procRes = await adb.shell(
        r"dumpsys meminfo 2>/dev/null | grep -E '^\s+[0-9,]+K:' | "
        r"sed 's/,//g; s/K://' | awk '{kb=$1; pkg=$2; if(pkg~/\(/)pkg=$2; print pkg, kb}' | "
        "sort -rn -k2 | head -40");

    final procs = <_ProcInfo>[];
    for (final line in procRes.stdout.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final pkg = parts[0].replaceAll(RegExp(r'[()]'), '').trim();
      final kb  = int.tryParse(parts[1]) ?? 0;
      if (kb <= 0 || pkg.isEmpty || pkg == '(pid') continue;
      procs.add(_ProcInfo(pkg: pkg, kbRss: kb));
    }

    // fallback：用 ps + cat /proc/PID/status
    if (procs.isEmpty) {
      final psRes = await adb.shell(
          'ps -A -o NAME,RSS 2>/dev/null | tail -n +2');
      for (final line in psRes.stdout.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        final kb = int.tryParse(parts.last) ?? 0;
        final name = parts.first;
        if (kb <= 0 || name.isEmpty) continue;
        procs.add(_ProcInfo(pkg: name, kbRss: kb));
      }
      procs.sort((a, b) => b.kbRss.compareTo(a.kbRss));
    }

    if (mounted) {
      setState(() {
        _totalKb = totalKb;
        _usedKb  = totalKb - availKb;
        _procs   = procs.take(40).toList();
        _loading = false;
      });
    }
  }

  Future<void> _forceStop(String pkg) async {
    final adb = context.read<AdbService>();
    await adb.forceStop(pkg);
    _load();
  }

  String _fmt(int kb) {
    if (kb >= 1024 * 1024) {
      return '${(kb / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (kb >= 1024) {
      return '${(kb / 1024).toStringAsFixed(1)} MB';
    }
    return '$kb KB';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final usedRatio = _totalKb > 0 ? _usedKb / _totalKb : 0.0;

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      body: _loading
          ? const CbeeLoader(message: '读取进程...')
          : RefreshIndicator(
              color: AppTheme.primary,
              onRefresh: _load,
              child: CustomScrollView(
                slivers: [
                  // ── 内存概览 ──
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('设备内存', style: TextStyle(
                                fontFamily: 'SpaceMono', fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              )),
                              Text(_fmt(_totalKb), style: const TextStyle(
                                fontFamily: 'JetBrainsMono', fontSize: 13,
                                color: AppTheme.textSecondary,
                              )),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // 进度条
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: usedRatio.clamp(0.0, 1.0),
                              minHeight: 10,
                              backgroundColor: AppTheme.bg3,
                              valueColor: AlwaysStoppedAnimation(
                                usedRatio > 0.85
                                    ? AppTheme.danger
                                    : usedRatio > 0.65
                                        ? AppTheme.warning
                                        : AppTheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(children: [
                            _MemTag(color: AppTheme.primary, label: '已用内存', value: _fmt(_usedKb)),
                            const SizedBox(width: 24),
                            _MemTag(color: AppTheme.bg3,    label: '可用内存', value: _fmt(_totalKb - _usedKb)),
                          ]),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
                  ),

                  const SliverToBoxAdapter(child: Divider(height: 1)),

                  // ── 进程列表 ──
                  if (_procs.isEmpty)
                    const SliverFillRemaining(
                      child: Center(child: Text('暂无进程数据',
                        style: TextStyle(color: AppTheme.textMuted, fontSize: 13))),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (ctx, i) {
                          final p = _procs[i];
                          // 图标颜色按包名前缀区分
                          final isSystem = p.pkg.startsWith('com.android') ||
                              p.pkg.startsWith('android') ||
                              p.pkg.startsWith('system');
                          final iconColor = isSystem ? AppTheme.textMuted : AppTheme.primary;
                          final icon = isSystem
                              ? Icons.settings_suggest_rounded
                              : Icons.apps_rounded;

                          return Column(children: [
                            ListTile(
                              contentPadding:
                                  const EdgeInsets.fromLTRB(16, 6, 8, 6),
                              leading: Container(
                                width: 40, height: 40,
                                decoration: BoxDecoration(
                                  color: iconColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(icon, size: 20, color: iconColor),
                              ),
                              title: Text(
                                // 如果包名含点则取最后一段作为短名，否则直接用包名
                                p.pkg.contains('.') ? p.pkg.split('.').last : p.pkg,
                                style: const TextStyle(
                                  fontFamily: 'SpaceMono', fontSize: 13,
                                  color: AppTheme.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                p.pkg,
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono', fontSize: 10,
                                  color: AppTheme.textMuted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                Text(
                                  _fmt(p.kbRss),
                                  style: const TextStyle(
                                    fontFamily: 'JetBrainsMono', fontSize: 12,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded,
                                      size: 18, color: AppTheme.primary),
                                  onPressed: () => _confirmStop(p.pkg),
                                  tooltip: '强制停止',
                                ),
                              ]),
                            ),
                            const Divider(height: 1, indent: 72),
                          ]);
                        },
                        childCount: _procs.length,
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  void _confirmStop(String pkg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bg1,
        title: const Text('强制停止', style: TextStyle(
          color: AppTheme.textPrimary, fontFamily: 'SpaceMono', fontSize: 15)),
        content: Text('强制停止 $pkg？', style: const TextStyle(
          color: AppTheme.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(color: AppTheme.textMuted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () { Navigator.pop(context); _forceStop(pkg); },
            child: const Text('停止'),
          ),
        ],
      ),
    );
  }
}

class _MemTag extends StatelessWidget {
  final Color color;
  final String label;
  final String value;
  const _MemTag({required this.color, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(width: 12, height: 12,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(
        fontFamily: 'SpaceMono', fontSize: 11, color: AppTheme.textSecondary)),
      const SizedBox(width: 8),
      Text(value, style: const TextStyle(
        fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.textPrimary,
        fontWeight: FontWeight.w600)),
    ]);
  }
}
