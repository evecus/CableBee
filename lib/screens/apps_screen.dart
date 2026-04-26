import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

class AppsScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const AppsScreen({super.key, this.onActionsChanged});
  @override
  State<AppsScreen> createState() => AppsScreenState();
}

class AppsScreenState extends State<AppsScreen> with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => _pushActions();

  List<AppInfo> _apps = [];
  List<AppInfo> _filtered = [];
  bool _loading = false;
  bool _showSystem = false;
  String _search = '';
  final _searchCtrl = TextEditingController();
  String? _actionResult;
  String? _busyPackage;
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() {
      setState(() {});
      _pushActions();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadApps();
      _pushActions();
    });
  }

  void _pushActions() {
    widget.onActionsChanged?.call([
      IconButton(
        icon: Icon(
          _showSystem ? Icons.phonelink_rounded : Icons.phonelink_off_rounded,
          size: 20, color: AppTheme.textMuted,
        ),
        tooltip: _showSystem ? '隐藏系统应用' : '显示系统应用',
        onPressed: () {
          setState(() => _showSystem = !_showSystem);
          _loadApps();
          _pushActions();
        },
      ),
      IconButton(
        icon: const Icon(Icons.refresh_rounded, size: 20),
        onPressed: _loadApps,
        color: AppTheme.textMuted,
      ),
    ]);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    final adb = context.read<AdbService>();
    setState(() { _loading = true; _actionResult = null; });
    final apps = await adb.listPackages(includeSystem: _showSystem);
    apps.sort((a, b) => a.packageName.compareTo(b.packageName));
    setState(() {
      _apps = apps;
      _loading = false;
    });
    _applyFilter();
  }

  void _applyFilter() {
    setState(() {
      _filtered = _apps.where((a) =>
        a.packageName.toLowerCase().contains(_search.toLowerCase())
      ).toList();
    });
  }

  Future<void> _installApk() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk'],
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;

    setState(() { _loading = true; _actionResult = 'Installing ${result.files.single.name}...'; });
    final adb = context.read<AdbService>();
    final res = await adb.installApk(path);
    setState(() {
      _loading = false;
      _actionResult = res.output;
    });
    if (res.isSuccess) _loadApps();
  }

  Future<void> _uninstall(AppInfo app) async {
    final ok = await showConfirmDialog(context,
      title: '卸载应用',
      message: '确认卸载 \${app.packageName}？',
      confirmText: '卸载',
      destructive: true,
    );
    if (ok != true) return;
    setState(() { _busyPackage = app.packageName; });
    final res = await context.read<AdbService>().uninstall(app.packageName);
    setState(() {
      _busyPackage = null;
      _actionResult = res.output;
    });
    if (res.isSuccess) _loadApps();
  }

  Future<void> _forceStop(AppInfo app) async {
    setState(() { _busyPackage = app.packageName; });
    final res = await context.read<AdbService>().forceStop(app.packageName);
    setState(() {
      _busyPackage = null;
      _actionResult = res.output;
    });
  }

  Future<void> _clearData(AppInfo app) async {
    final ok = await showConfirmDialog(context,
      title: '清除数据',
      message: '确认清除 \${app.packageName} 的全部数据？\n\n此操作不可撤销。',
      confirmText: '清除',
      destructive: true,
    );
    if (ok != true) return;
    setState(() { _busyPackage = app.packageName; });
    final res = await context.read<AdbService>().clearData(app.packageName);
    setState(() {
      _busyPackage = null;
      _actionResult = res.output;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final adb = context.watch<AdbService>();

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      body: Column(children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) { _search = v; _applyFilter(); },
            decoration: InputDecoration(
              hintText: '搜索包名...',
              prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppTheme.textMuted),
              suffixIcon: _search.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16, color: AppTheme.textMuted),
                      onPressed: () { _searchCtrl.clear(); _search = ''; _applyFilter(); },
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
        if (_actionResult != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.bg1,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.bg3),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, size: 14, color: AppTheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(_actionResult!, style: const TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 11,
                color: AppTheme.textSecondary,
              ))),
              GestureDetector(
                onTap: () => setState(() => _actionResult = null),
                child: const Icon(Icons.close_rounded, size: 14, color: AppTheme.textMuted),
              ),
            ]),
          ),

        // Count badge
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(children: [
            Text(
              '${_filtered.length} packages',
              style: const TextStyle(
                fontFamily: 'SpaceMono', fontSize: 11,
                color: AppTheme.textMuted, letterSpacing: 0.5,
              ),
            ),
            if (_showSystem)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
                ),
                child: const Text('incl. system', style: TextStyle(
                  fontFamily: 'SpaceMono', fontSize: 9,
                  color: AppTheme.warning, letterSpacing: 0.3,
                )),
              ),
          ]),
        ),

        Expanded(
          child: _loading
              ? const CbeeLoader(message: '加载应用列表...')
              : _filtered.isEmpty
                  ? EmptyState(
                      icon: Icons.apps_outage_rounded,
                      title: _search.isNotEmpty ? '无匹配结果' : '暂无应用',
                      message: _search.isNotEmpty
                          ? 'No packages matching "$_search"'
                          : 'No user apps found',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 68),
                      itemBuilder: (ctx, i) {
                        final app = _filtered[i];
                        final busy = _busyPackage == app.packageName;
                        return _AppTile(
                          app: app,
                          busy: busy,
                          onUninstall: () => _uninstall(app),
                          onForceStop: () => _forceStop(app),
                          onClearData: () => _clearData(app),
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
        label: const Text('Install APK', style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 12, fontWeight: FontWeight.w700,
        )),
      ),
    );
  }
}

class _AppTile extends StatelessWidget {
  final AppInfo app;
  final bool busy;
  final VoidCallback onUninstall;
  final VoidCallback onForceStop;
  final VoidCallback onClearData;

  const _AppTile({
    required this.app,
    required this.busy,
    required this.onUninstall,
    required this.onForceStop,
    required this.onClearData,
  });

  String get _shortName {
    final parts = app.packageName.split('.');
    return parts.last;
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: AppTheme.bg2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.bg3),
        ),
        child: Center(child: Text(
          _shortName.substring(0, 1).toUpperCase(),
          style: const TextStyle(
            fontFamily: 'SpaceMono', fontSize: 16,
            fontWeight: FontWeight.w700, color: AppTheme.primary,
          ),
        )),
      ),
      title: Text(
        _shortName,
        style: const TextStyle(
          fontFamily: 'SpaceMono', fontSize: 13,
          fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
        ),
      ),
      subtitle: Text(
        app.packageName,
        style: const TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 10,
          color: AppTheme.textMuted,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: busy
          ? const SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(AppTheme.primary),
              ),
            )
          : PopupMenuButton<String>(
              color: AppTheme.bg1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: AppTheme.bg3),
              ),
              icon: const Icon(Icons.more_vert_rounded,
                size: 18, color: AppTheme.textMuted),
              onSelected: (v) {
                if (v == 'uninstall') onUninstall();
                if (v == 'stop') onForceStop();
                if (v == 'clear') onClearData();
              },
              itemBuilder: (_) => [
                _menuItem('stop', Icons.stop_circle_outlined, 'Force Stop', AppTheme.warning),
                _menuItem('clear', Icons.cleaning_services_rounded, 'Clear Data', AppTheme.warning),
                const PopupMenuDivider(),
                _menuItem('uninstall', Icons.delete_outline_rounded, 'Uninstall', AppTheme.danger),
              ],
            ),
    );
  }

  PopupMenuItem<String> _menuItem(
    String value, IconData icon, String label, Color color,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 12,
          color: color,
        )),
      ]),
    );
  }
}
