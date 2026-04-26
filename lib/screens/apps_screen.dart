import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

// ── 排序方式枚举 ──────────────────────────────────────────────────────────────

enum SortMode { packageName, appName }

// ── 扩展 AppInfo，包含应用名称和图标 ─────────────────────────────────────────

class AppInfoEx {
  final AppInfo base;
  String? appLabel;        // 应用名称（可能为 null，未加载时）
  Uint8List? iconBytes;    // 图标字节（可能为 null）
  bool isSystem;
  bool isDisabled;         // 停用状态
  bool isFrozen;           // 冻结状态（pm disable）

  AppInfoEx({
    required this.base,
    this.appLabel,
    this.iconBytes,
    this.isSystem = false,
    this.isDisabled = false,
    this.isFrozen = false,
  });

  String get packageName => base.packageName;
  String get apkPath => base.apkPath;
  String get displayName => (appLabel != null && appLabel!.isNotEmpty) ? appLabel! : _shortName;
  String get _shortName => packageName.split('.').last;
}

// ── AppsScreen ────────────────────────────────────────────────────────────────

class AppsScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const AppsScreen({super.key, this.onActionsChanged});

  @override
  State<AppsScreen> createState() => AppsScreenState();
}

class AppsScreenState extends State<AppsScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => _pushActions();

  List<AppInfoEx> _apps = [];
  List<AppInfoEx> _filtered = [];
  bool _loading = false;
  String? _actionResult;
  String? _busyPackage;

  // 过滤/排序选项
  bool _showSystem = true;
  bool _showThirdParty = true;
  SortMode _sortMode = SortMode.packageName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadApps();
      _pushActions();
    });
  }

  void _pushActions() {
    widget.onActionsChanged?.call([
      IconButton(
        icon: const Icon(Icons.search_rounded, size: 22),
        color: AppTheme.textMuted,
        tooltip: '搜索',
        onPressed: _showSearchDialog,
      ),
      IconButton(
        icon: const Icon(Icons.more_vert_rounded, size: 22),
        color: AppTheme.textMuted,
        tooltip: '更多选项',
        onPressed: _showOptionsMenu,
      ),
    ]);
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ── 加载应用列表 ────────────────────────────────────────────────────────────

  Future<void> _loadApps() async {
    final adb = context.read<AdbService>();
    setState(() {
      _loading = true;
      _actionResult = null;
    });

    // 加载所有包（系统+第三方），通过本地过滤
    final rawApps = await adb.listPackages(includeSystem: true);

    // 解析系统 vs 第三方
    final systemPkgs = await _getSystemPackages(adb);

    // 加载停用/冻结状态
    final disabledPkgs = await _getDisabledPackages(adb);

    // 转换
    final exApps = rawApps.map((a) {
      final isSys = systemPkgs.contains(a.packageName);
      final isDisabled = disabledPkgs.contains(a.packageName);
      return AppInfoEx(
        base: a,
        isSystem: isSys,
        isDisabled: isDisabled,
        isFrozen: isDisabled,
      );
    }).toList();

    // 加载应用名称（批量 dumpsys）
    await _loadAppLabels(adb, exApps);

    setState(() {
      _apps = exApps;
      _loading = false;
    });
    _applyFilter();
  }

  Future<Set<String>> _getSystemPackages(AdbService adb) async {
    final res = await adb.shell('pm list packages -s 2>&1');
    return res.stdout
        .split('\n')
        .where((l) => l.startsWith('package:'))
        .map((l) => l.substring(8).trim())
        .toSet();
  }

  Future<Set<String>> _getDisabledPackages(AdbService adb) async {
    final res = await adb.shell('pm list packages -d 2>&1');
    return res.stdout
        .split('\n')
        .where((l) => l.startsWith('package:'))
        .map((l) => l.substring(8).trim())
        .toSet();
  }

  Future<void> _loadAppLabels(AdbService adb, List<AppInfoEx> apps) async {
    // 方案一：cmd package list packages --show-labels（部分系统支持）
    try {
      final res = await adb.shell('cmd package list packages --show-labels 2>&1');
      if (res.isSuccess && res.stdout.contains('package:')) {
        // 格式: package:com.example.app  label:App Name
        final labelMap = <String, String>{};
        for (final line in res.stdout.split('\n')) {
          final pkgMatch = RegExp(r'package:(\S+)').firstMatch(line);
          final labelMatch = RegExp(r'label:(.+)$').firstMatch(line);
          if (pkgMatch != null && labelMatch != null) {
            labelMap[pkgMatch.group(1)!.trim()] = labelMatch.group(1)!.trim();
          }
        }
        if (labelMap.isNotEmpty) {
          for (final app in apps) {
            app.appLabel = labelMap[app.packageName];
          }
          // 如果大部分有标签就认为成功
          final labeled = apps.where((a) => a.appLabel != null).length;
          if (labeled > apps.length ~/ 2) return;
        }
      }
    } catch (_) {}

    // 方案二：通过 dumpsys package 逐个解析 applicationInfo 的 nonLocalizedLabel
    // 批量执行以减少往返次数（每批 10 个）
    const batchSize = 10;
    for (var i = 0; i < apps.length; i += batchSize) {
      final batch = apps.skip(i).take(batchSize).toList();
      final cmds = batch
          .map((a) => 'dumpsys package ${a.packageName} 2>/dev/null | grep -m1 "nonLocalizedLabel\\|labelRes\\|label="')
          .join('; echo "---"; ');
      try {
        final res = await adb.shell(cmds);
        final segments = res.stdout.split('---');
        for (var j = 0; j < batch.length && j < segments.length; j++) {
          final seg = segments[j];
          // Try nonLocalizedLabel first
          final nlMatch = RegExp(r'nonLocalizedLabel=(.+?)(?:\s|$)').firstMatch(seg);
          if (nlMatch != null && nlMatch.group(1) != 'null') {
            batch[j].appLabel = nlMatch.group(1)!.trim();
          }
        }
      } catch (_) {}
    }
    // 没有标签的 app 保持 null，displayName 会使用 _shortName（包名最后一段）
  }

  // ── 过滤与排序 ──────────────────────────────────────────────────────────────

  void _applyFilter({String query = ''}) {
    var list = _apps.where((a) {
      if (a.isSystem && !_showSystem) return false;
      if (!a.isSystem && !_showThirdParty) return false;
      return true;
    }).toList();

    if (query.isNotEmpty) {
      final q = query.toLowerCase();
      list = list
          .where((a) =>
              a.packageName.toLowerCase().contains(q) ||
              (a.appLabel?.toLowerCase().contains(q) ?? false))
          .toList();
    }

    list.sort((a, b) {
      if (_sortMode == SortMode.packageName) {
        return a.packageName.compareTo(b.packageName);
      } else {
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      }
    });

    setState(() => _filtered = list);
  }

  // ── 搜索弹窗 ────────────────────────────────────────────────────────────────

  void _showSearchDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppTheme.bg3),
        ),
        title: const Text(
          '搜索应用',
          style: TextStyle(
            fontFamily: 'SpaceMono',
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppTheme.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '输入包名或应用名称...',
                prefixIcon: Icon(Icons.search_rounded,
                    size: 18, color: AppTheme.textMuted),
              ),
              onSubmitted: (v) {
                Navigator.pop(ctx);
                _showSearchResults(v.trim());
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消',
                style: TextStyle(
                    fontFamily: 'SpaceMono',
                    fontSize: 12,
                    color: AppTheme.textMuted)),
          ),
          FilledButton(
            onPressed: () {
              final q = ctrl.text.trim();
              Navigator.pop(ctx);
              _showSearchResults(q);
            },
            child: const Text('搜索',
                style: TextStyle(fontFamily: 'SpaceMono', fontSize: 12)),
          ),
        ],
      ),
    );
  }

  void _showSearchResults(String query) {
    if (query.isEmpty) return;
    final q = query.toLowerCase();
    final results = _apps
        .where((a) =>
            a.packageName.toLowerCase().contains(q) ||
            (a.appLabel?.toLowerCase().contains(q) ?? false))
        .toList();

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.bg1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppTheme.bg3),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Row(children: [
                Expanded(
                  child: Text(
                    '搜索结果  "${query}"',
                    style: const TextStyle(
                      fontFamily: 'SpaceMono',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: AppTheme.primary.withOpacity(0.3)),
                  ),
                  child: Text(
                    '${results.length} 个',
                    style: const TextStyle(
                      fontFamily: 'SpaceMono',
                      fontSize: 11,
                      color: AppTheme.primary,
                    ),
                  ),
                ),
              ]),
            ),
            const Divider(height: 1),
            if (results.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    '未找到匹配的应用',
                    style: TextStyle(
                      fontFamily: 'SpaceMono',
                      fontSize: 13,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: results.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 64),
                  itemBuilder: (_, i) {
                    final app = results[i];
                    return ListTile(
                      contentPadding:
                          const EdgeInsets.fromLTRB(16, 6, 16, 6),
                      leading: _AppIcon(app: app),
                      title: Text(
                        app.displayName,
                        style: const TextStyle(
                          fontFamily: 'SpaceMono',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        app.packageName,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _showAppActions(app);
                      },
                    );
                  },
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭',
                      style: TextStyle(
                          fontFamily: 'SpaceMono',
                          fontSize: 12,
                          color: AppTheme.textMuted)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 选项菜单弹窗 ─────────────────────────────────────────────────────────────

  void _showOptionsMenu() {
    bool showSys = _showSystem;
    bool showThird = _showThirdParty;
    SortMode sort = _sortMode;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.bg1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppTheme.bg3),
          ),
          title: const Text(
            '选项',
            style: TextStyle(
              fontFamily: 'SpaceMono',
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 显示类型
              const _OptionSectionLabel('显示范围'),
              _CheckOption(
                label: '显示系统应用',
                value: showSys,
                onChanged: (v) => setDialogState(() => showSys = v),
              ),
              _CheckOption(
                label: '显示第三方应用',
                value: showThird,
                onChanged: (v) => setDialogState(() => showThird = v),
              ),
              const SizedBox(height: 12),
              // 排序方式
              const _OptionSectionLabel('排序方式'),
              _RadioOption(
                label: '包名',
                value: SortMode.packageName,
                groupValue: sort,
                onChanged: (v) => setDialogState(() => sort = v!),
              ),
              _RadioOption(
                label: '应用名称',
                value: SortMode.appName,
                groupValue: sort,
                onChanged: (v) => setDialogState(() => sort = v!),
              ),
              const SizedBox(height: 12),
              const Divider(),
              // 刷新列表
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.refresh_rounded,
                    size: 18, color: AppTheme.primary),
                title: const Text(
                  '刷新列表',
                  style: TextStyle(
                    fontFamily: 'SpaceMono',
                    fontSize: 13,
                    color: AppTheme.textPrimary,
                  ),
                ),
                onTap: () {
                  setState(() {
                    _showSystem = showSys;
                    _showThirdParty = showThird;
                    _sortMode = sort;
                  });
                  Navigator.pop(ctx);
                  _loadApps();
                },
              ),
              // 恢复应用
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restore_rounded,
                    size: 18, color: AppTheme.secondary),
                title: const Text(
                  '恢复应用',
                  style: TextStyle(
                    fontFamily: 'SpaceMono',
                    fontSize: 13,
                    color: AppTheme.textPrimary,
                  ),
                ),
                onTap: () {
                  setState(() {
                    _showSystem = showSys;
                    _showThirdParty = showThird;
                    _sortMode = sort;
                  });
                  Navigator.pop(ctx);
                  _showRestoreApps();
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消',
                  style: TextStyle(
                      fontFamily: 'SpaceMono',
                      fontSize: 12,
                      color: AppTheme.textMuted)),
            ),
            FilledButton(
              onPressed: () {
                setState(() {
                  _showSystem = showSys;
                  _showThirdParty = showThird;
                  _sortMode = sort;
                });
                _applyFilter();
                Navigator.pop(ctx);
              },
              child: const Text('应用',
                  style: TextStyle(fontFamily: 'SpaceMono', fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  // ── 恢复应用弹窗 ─────────────────────────────────────────────────────────────

  void _showRestoreApps() {
    final disabled = _apps.where((a) => a.isDisabled || a.isFrozen).toList();

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.bg1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppTheme.bg3),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(children: [
                const Icon(Icons.restore_rounded,
                    size: 18, color: AppTheme.secondary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '恢复应用',
                    style: TextStyle(
                      fontFamily: 'SpaceMono',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '${disabled.length} 个已停用',
                  style: const TextStyle(
                    fontFamily: 'SpaceMono',
                    fontSize: 11,
                    color: AppTheme.textMuted,
                  ),
                ),
              ]),
            ),
            const Divider(height: 1),
            if (disabled.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    '没有被冻结或停用的应用',
                    style: TextStyle(
                      fontFamily: 'SpaceMono',
                      fontSize: 13,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: disabled.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 64),
                  itemBuilder: (_, i) {
                    final app = disabled[i];
                    return ListTile(
                      contentPadding:
                          const EdgeInsets.fromLTRB(16, 6, 16, 6),
                      leading: _AppIcon(app: app),
                      title: Text(
                        app.displayName,
                        style: const TextStyle(
                          fontFamily: 'SpaceMono',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      subtitle: Text(
                        app.packageName,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.play_circle_outline_rounded,
                          size: 20, color: AppTheme.success),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _enableApp(app);
                      },
                    );
                  },
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭',
                      style: TextStyle(
                          fontFamily: 'SpaceMono',
                          fontSize: 12,
                          color: AppTheme.textMuted)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── App 操作弹窗 ─────────────────────────────────────────────────────────────

  void _showAppActions(AppInfoEx app) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bg1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppTheme.bg3),
        ),
        contentPadding: EdgeInsets.zero,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 头部
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Row(children: [
                _AppIcon(app: app, size: 48),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.displayName,
                        style: const TextStyle(
                          fontFamily: 'SpaceMono',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        app.packageName,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(children: [
                        if (app.isSystem)
                          _TagChip(label: '系统', color: AppTheme.secondary),
                        if (!app.isSystem)
                          _TagChip(label: '第三方', color: AppTheme.primary),
                        if (app.isDisabled)
                          _TagChip(label: '已停用', color: AppTheme.warning),
                      ]),
                    ],
                  ),
                ),
              ]),
            ),
            const Divider(height: 1),
            // 操作列表
            _ActionItem(
              icon: Icons.info_outline_rounded,
              label: '应用详情',
              color: AppTheme.secondary,
              onTap: () {
                Navigator.pop(ctx);
                _showAppDetails(app);
              },
            ),
            const Divider(height: 1, indent: 56),
            _ActionItem(
              icon: Icons.play_arrow_rounded,
              label: '启动',
              color: AppTheme.success,
              onTap: () {
                Navigator.pop(ctx);
                _launchApp(app);
              },
            ),
            const Divider(height: 1, indent: 56),
            _ActionItem(
              icon: Icons.ac_unit_rounded,
              label: '冻结',
              color: AppTheme.secondary,
              onTap: () {
                Navigator.pop(ctx);
                _freezeApp(app);
              },
            ),
            const Divider(height: 1, indent: 56),
            _ActionItem(
              icon: Icons.block_rounded,
              label: '停用',
              color: AppTheme.warning,
              onTap: () {
                Navigator.pop(ctx);
                _disableApp(app);
              },
            ),
            const Divider(height: 1, indent: 56),
            _ActionItem(
              icon: Icons.cleaning_services_rounded,
              label: '清除数据',
              color: AppTheme.warning,
              onTap: () {
                Navigator.pop(ctx);
                _clearData(app);
              },
            ),
            const Divider(height: 1, indent: 56),
            _ActionItem(
              icon: Icons.download_rounded,
              label: '下载安装包',
              color: AppTheme.primary,
              onTap: () {
                Navigator.pop(ctx);
                _downloadApk(app);
              },
            ),
            const Divider(height: 1, indent: 56),
            _ActionItem(
              icon: Icons.delete_outline_rounded,
              label: '卸载',
              color: AppTheme.danger,
              onTap: () {
                Navigator.pop(ctx);
                _uninstall(app);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── 应用详情弹窗 ─────────────────────────────────────────────────────────────

  void _showAppDetails(AppInfoEx app) async {
    final adb = context.read<AdbService>();

    // 获取详细信息
    final res = await adb.shell('dumpsys package ${app.packageName} 2>&1');
    final raw = res.stdout;

    // 解析关键字段
    String version = _extract(raw, RegExp(r'versionName=(\S+)')) ?? '未知';
    String versionCode = _extract(raw, RegExp(r'versionCode=(\d+)')) ?? '未知';
    String targetSdk = _extract(raw, RegExp(r'targetSdk=(\d+)')) ?? '未知';
    String minSdk = _extract(raw, RegExp(r'minSdk=(\d+)')) ?? '未知';
    String installer =
        _extract(raw, RegExp(r'installerPackageName=(\S+)')) ?? '未知';
    String firstInstall = _extract(
            raw, RegExp(r'firstInstallTime=(.+?)(?:\n|$)'))?.trim() ??
        '未知';
    String lastUpdate = _extract(
            raw, RegExp(r'lastUpdateTime=(.+?)(?:\n|$)'))?.trim() ??
        '未知';
    String dataDir = _extract(raw, RegExp(r'dataDir=(\S+)')) ?? '未知';

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.bg1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppTheme.bg3),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
              child: Row(children: [
                _AppIcon(app: app, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.displayName,
                          style: const TextStyle(
                            fontFamily: 'SpaceMono',
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          )),
                      Text(app.packageName,
                          style: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 10,
                            color: AppTheme.textMuted,
                          ),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ]),
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _DetailRow(label: 'APK 路径', value: app.apkPath),
                    _DetailRow(label: '版本名', value: version),
                    _DetailRow(label: '版本号', value: versionCode),
                    _DetailRow(label: '目标 SDK', value: targetSdk),
                    _DetailRow(label: '最低 SDK', value: minSdk),
                    _DetailRow(label: '数据目录', value: dataDir),
                    _DetailRow(label: '安装来源', value: installer),
                    _DetailRow(label: '首次安装', value: firstInstall),
                    _DetailRow(label: '最近更新', value: lastUpdate),
                    _DetailRow(
                        label: '类型',
                        value: app.isSystem ? '系统应用' : '第三方应用'),
                    _DetailRow(
                        label: '状态',
                        value: app.isDisabled ? '已停用/冻结' : '正常'),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭',
                      style: TextStyle(
                          fontFamily: 'SpaceMono',
                          fontSize: 12,
                          color: AppTheme.textMuted)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _extract(String text, RegExp pattern) =>
      pattern.firstMatch(text)?.group(1);

  // ── ADB 操作 ─────────────────────────────────────────────────────────────────

  Future<void> _launchApp(AppInfoEx app) async {
    final adb = context.read<AdbService>();
    setState(() => _busyPackage = app.packageName);
    final res = await adb.shell(
        'monkey -p ${app.packageName} -c android.intent.category.LAUNCHER 1');
    setState(() {
      _busyPackage = null;
      _actionResult = res.output.trim().isEmpty ? '已启动 ${app.displayName}' : res.output;
    });
  }

  Future<void> _freezeApp(AppInfoEx app) async {
    final adb = context.read<AdbService>();
    setState(() => _busyPackage = app.packageName);
    final res = await adb.shell('pm disable-user --user 0 ${app.packageName}');
    setState(() {
      _busyPackage = null;
      _actionResult = res.isSuccess ? '已冻结 ${app.displayName}' : res.output;
    });
    if (res.isSuccess) _loadApps();
  }

  Future<void> _disableApp(AppInfoEx app) async {
    final ok = await showConfirmDialog(context,
        title: '停用应用',
        message: '确认停用 ${app.packageName}？\n停用后该应用将无法使用。',
        confirmText: '停用',
        destructive: true);
    if (ok != true) return;
    final adb = context.read<AdbService>();
    setState(() => _busyPackage = app.packageName);
    final res = await adb.shell('pm disable ${app.packageName}');
    setState(() {
      _busyPackage = null;
      _actionResult = res.isSuccess ? '已停用 ${app.displayName}' : res.output;
    });
    if (res.isSuccess) _loadApps();
  }

  Future<void> _enableApp(AppInfoEx app) async {
    final adb = context.read<AdbService>();
    setState(() => _busyPackage = app.packageName);
    final res = await adb.shell('pm enable ${app.packageName}');
    setState(() {
      _busyPackage = null;
      _actionResult = res.isSuccess ? '已恢复 ${app.displayName}' : res.output;
    });
    if (res.isSuccess) _loadApps();
  }

  Future<void> _uninstall(AppInfoEx app) async {
    final ok = await showConfirmDialog(context,
        title: '卸载应用',
        message: '确认卸载 ${app.packageName}？',
        confirmText: '卸载',
        destructive: true);
    if (ok != true) return;
    final adb = context.read<AdbService>();
    setState(() => _busyPackage = app.packageName);
    final res = await adb.uninstall(app.packageName);
    setState(() {
      _busyPackage = null;
      _actionResult = res.output;
    });
    if (res.isSuccess) _loadApps();
  }

  Future<void> _clearData(AppInfoEx app) async {
    final ok = await showConfirmDialog(context,
        title: '清除数据',
        message: '确认清除 ${app.packageName} 的全部数据？\n\n此操作不可撤销。',
        confirmText: '清除',
        destructive: true);
    if (ok != true) return;
    final adb = context.read<AdbService>();
    setState(() => _busyPackage = app.packageName);
    final res = await adb.clearData(app.packageName);
    setState(() {
      _busyPackage = null;
      _actionResult = res.output;
    });
  }

  Future<void> _downloadApk(AppInfoEx app) async {
    // 选择保存路径
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: '保存安装包',
      fileName: '${app.packageName}.apk',
      allowedExtensions: ['apk'],
      type: FileType.custom,
    );
    if (savePath == null) return;

    final adb = context.read<AdbService>();
    setState(() {
      _busyPackage = app.packageName;
      _actionResult = '正在拉取 ${app.displayName} 的安装包...';
    });
    final res = await adb.pull(app.apkPath, savePath);
    setState(() {
      _busyPackage = null;
      _actionResult = res.isSuccess
          ? '✓ 已保存到 $savePath'
          : '✗ 下载失败: ${res.output}';
    });
  }

  Future<void> _installApk() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk'],
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;

    setState(() {
      _loading = true;
      _actionResult = '正在安装 ${result.files.single.name}...';
    });
    final adb = context.read<AdbService>();
    final res = await adb.installApk(path);
    setState(() {
      _loading = false;
      _actionResult = res.output;
    });
    if (res.isSuccess) _loadApps();
  }

  // ── 构建 ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      body: Column(children: [
        // 操作结果提示条
        if (_actionResult != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.bg1,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.bg3),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded,
                  size: 14, color: AppTheme.primary),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(_actionResult!,
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                      ))),
              GestureDetector(
                onTap: () => setState(() => _actionResult = null),
                child: const Icon(Icons.close_rounded,
                    size: 14, color: AppTheme.textMuted),
              ),
            ]),
          ),

        // 计数徽章
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(children: [
            Text(
              '${_filtered.length} packages',
              style: const TextStyle(
                fontFamily: 'SpaceMono',
                fontSize: 11,
                color: AppTheme.textMuted,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 8),
            if (_showSystem && _showThirdParty)
              _TagChip(label: '全部', color: AppTheme.textMuted)
            else if (_showSystem)
              _TagChip(label: '系统', color: AppTheme.secondary)
            else if (_showThirdParty)
              _TagChip(label: '第三方', color: AppTheme.primary),
            const Spacer(),
            Text(
              _sortMode == SortMode.packageName ? '↑ 包名' : '↑ 名称',
              style: const TextStyle(
                fontFamily: 'SpaceMono',
                fontSize: 10,
                color: AppTheme.textMuted,
              ),
            ),
          ]),
        ),

        // 应用列表
        Expanded(
          child: _loading
              ? const CbeeLoader(message: '加载应用列表...')
              : _filtered.isEmpty
                  ? EmptyState(
                      icon: Icons.apps_outage_rounded,
                      title: '暂无应用',
                      message: '当前过滤条件下没有匹配的应用',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _filtered.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (ctx, i) {
                        final app = _filtered[i];
                        final busy = _busyPackage == app.packageName;
                        return _AppListTile(
                          app: app,
                          busy: busy,
                          onTap: () => _showAppActions(app),
                        );
                      },
                    ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _installApk,
        backgroundColor: AppTheme.primary,
        foregroundColor: AppTheme.bg0,
        icon: const Icon(Icons.install_mobile_rounded, size: 18),
        label: const Text('Install APK',
            style: TextStyle(
              fontFamily: 'SpaceMono',
              fontSize: 12,
              fontWeight: FontWeight.w700,
            )),
      ),
    );
  }
}

// ── 应用图标 Widget ──────────────────────────────────────────────────────────

class _AppIcon extends StatelessWidget {
  final AppInfoEx app;
  final double size;
  const _AppIcon({required this.app, this.size = 42});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTheme.bg2,
        borderRadius: BorderRadius.circular(size * 0.22),
        border: Border.all(color: AppTheme.bg3),
      ),
      child: app.iconBytes != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(size * 0.22 - 1),
              child: Image.memory(app.iconBytes!, fit: BoxFit.cover),
            )
          : Center(
              child: Icon(
                Icons.android_rounded,
                size: size * 0.52,
                color: AppTheme.primary,
              ),
            ),
    );
  }
}

// ── 应用列表项 ───────────────────────────────────────────────────────────────

class _AppListTile extends StatelessWidget {
  final AppInfoEx app;
  final bool busy;
  final VoidCallback onTap;

  const _AppListTile({
    required this.app,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(children: [
          _AppIcon(app: app),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      app.displayName,
                      style: const TextStyle(
                        fontFamily: 'SpaceMono',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (app.isDisabled)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.warning.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                            color: AppTheme.warning.withOpacity(0.4)),
                      ),
                      child: const Text('已停用',
                          style: TextStyle(
                            fontFamily: 'SpaceMono',
                            fontSize: 9,
                            color: AppTheme.warning,
                          )),
                    ),
                ]),
                const SizedBox(height: 3),
                Text(
                  app.packageName,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    color: AppTheme.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(AppTheme.primary),
              ),
            )
          else
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: AppTheme.bg3),
        ]),
      ),
    );
  }
}

// ── 辅助 Widget ──────────────────────────────────────────────────────────────

class _OptionSectionLabel extends StatelessWidget {
  final String label;
  const _OptionSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'SpaceMono',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppTheme.textMuted,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _CheckOption extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _CheckOption(
      {required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: AppTheme.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 10),
          Text(label,
              style: const TextStyle(
                fontFamily: 'SpaceMono',
                fontSize: 13,
                color: AppTheme.textPrimary,
              )),
        ]),
      ),
    );
  }
}

class _RadioOption<T> extends StatelessWidget {
  final String label;
  final T value;
  final T groupValue;
  final ValueChanged<T?> onChanged;
  const _RadioOption({
    required this.label,
    required this.value,
    required this.groupValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Radio<T>(
              value: value,
              groupValue: groupValue,
              onChanged: onChanged,
              activeColor: AppTheme.primary,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 10),
          Text(label,
              style: const TextStyle(
                fontFamily: 'SpaceMono',
                fontSize: 13,
                color: AppTheme.textPrimary,
              )),
        ]),
      ),
    );
  }
}

class _ActionItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionItem(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 13, 20, 13),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 18),
          Text(label,
              style: TextStyle(
                fontFamily: 'SpaceMono',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color,
              )),
        ]),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  final Color color;
  const _TagChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(label,
          style: TextStyle(
            fontFamily: 'SpaceMono',
            fontSize: 9,
            color: color,
          )),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(
                  fontFamily: 'SpaceMono',
                  fontSize: 11,
                  color: AppTheme.textMuted,
                )),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  color: AppTheme.textPrimary,
                )),
          ),
        ],
      ),
    );
  }
}
