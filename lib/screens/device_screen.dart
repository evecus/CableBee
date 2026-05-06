// lib/screens/device_screen.dart
// 底部导航栏支持左右滑动，共 8 个 Tab

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/device.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import 'device_info_screen.dart';
import 'shell_screen.dart';
import 'apps_screen.dart';
import 'files_screen.dart';
import 'tools_screen.dart';
import 'process_screen.dart';
import 'remote_screen.dart';
import 'controller_screen.dart';

class DeviceScreen extends StatefulWidget {
  final AdbDevice device;
  const DeviceScreen({super.key, required this.device});
  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  int _tab = 0;
  List<Widget> _tabActions = [];

  final _infoKey       = GlobalKey<DeviceInfoScreenState>();
  final _shellKey      = GlobalKey<ShellScreenState>();
  final _appsKey       = GlobalKey<AppsScreenState>();
  final _filesKey      = GlobalKey<FilesScreenState>();
  final _toolsKey      = GlobalKey<ToolsScreenState>();
  final _procKey       = GlobalKey<ProcessScreenState>();
  final _remoteKey     = GlobalKey<RemoteScreenState>();
  final _controllerKey = GlobalKey<ControllerScreenState>();

  static const _tabs = [
    _TabItem(icon: Icons.info_outline_rounded,        label: '信息'),
    _TabItem(icon: Icons.build_outlined,               label: '工具'),
    _TabItem(icon: Icons.apps_rounded,                 label: '应用'),
    _TabItem(icon: Icons.folder_outlined,              label: '文件'),
    _TabItem(icon: Icons.memory_rounded,               label: '进程'),
    _TabItem(icon: Icons.gamepad_rounded,              label: '遥控'),
    _TabItem(icon: Icons.cast_rounded,                 label: '投屏'),
    _TabItem(icon: Icons.terminal_rounded,             label: 'Shell'),
  ];

  static const _tabTitles = [
    '信息', '工具', '应用', '文件', '进程管理', '遥控器', '远程控制', 'Shell',
  ];

  void _onActionsChanged(List<Widget> actions) {
    if (mounted) setState(() => _tabActions = actions);
  }

  void _switchTab(int i) {
    // 离开投屏 tab 时自动断开投屏
    if (_tab == 6 && i != 6) {
      _remoteKey.currentState?.stopSession();
    }
    setState(() {
      _tab = i;
      _tabActions = [];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      switch (i) {
        case 0: _infoKey.currentState?.refreshActions();       break;
        case 1: _toolsKey.currentState?.refreshActions();      break;
        case 2: _appsKey.currentState?.refreshActions();       break;
        case 3: _filesKey.currentState?.refreshActions();      break;
        case 4: _procKey.currentState?.refreshActions();       break;
        case 5: _controllerKey.currentState?.refreshActions(); break;
        case 6: _remoteKey.currentState?.refreshActions();     break;
        case 7: _shellKey.currentState?.refreshActions();      break;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AdbService>().selectDevice(widget.device);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        backgroundColor: AppTheme.bg0,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppTheme.textSecondary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _tabTitles[_tab],
          style: const TextStyle(
            fontFamily: 'SpaceMono', fontSize: 16,
            fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
          ),
        ),
        actions: [
          ..._tabActions,
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          DeviceInfoScreen (key: _infoKey,       onActionsChanged: _onActionsChanged),
          ToolsScreen      (key: _toolsKey,      onActionsChanged: _onActionsChanged),
          AppsScreen       (key: _appsKey,       onActionsChanged: _onActionsChanged),
          FilesScreen      (key: _filesKey,      onActionsChanged: _onActionsChanged),
          ProcessScreen    (key: _procKey,       onActionsChanged: _onActionsChanged),
          ControllerScreen (key: _controllerKey, onActionsChanged: _onActionsChanged),
          RemoteScreen     (key: _remoteKey,     onActionsChanged: _onActionsChanged),
          ShellScreen      (key: _shellKey,      onActionsChanged: _onActionsChanged),
        ],
      ),
      bottomNavigationBar: _ScrollableBottomNav(
        tabs: _tabs,
        selectedIndex: _tab,
        onTap: _switchTab,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  可横向滑动的底部导航栏
// ─────────────────────────────────────────────────────────────
class _ScrollableBottomNav extends StatefulWidget {
  final List<_TabItem> tabs;
  final int selectedIndex;
  final void Function(int) onTap;

  const _ScrollableBottomNav({
    required this.tabs,
    required this.selectedIndex,
    required this.onTap,
  });

  @override
  State<_ScrollableBottomNav> createState() => _ScrollableBottomNavState();
}

class _ScrollableBottomNavState extends State<_ScrollableBottomNav> {
  final _scrollCtrl = ScrollController();

  @override
  void didUpdateWidget(_ScrollableBottomNav old) {
    super.didUpdateWidget(old);
    if (old.selectedIndex != widget.selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
    }
  }

  void _scrollToSelected() {
    if (!_scrollCtrl.hasClients) return;
    const itemW = 72.0;
    final target = widget.selectedIndex * itemW;
    final viewport = _scrollCtrl.position.viewportDimension;
    final offset = (target - viewport / 2 + itemW / 2).clamp(
      _scrollCtrl.position.minScrollExtent,
      _scrollCtrl.position.maxScrollExtent,
    );
    _scrollCtrl.animateTo(offset,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.bg1,
        border: Border(top: BorderSide(color: AppTheme.bg3, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: SingleChildScrollView(
            controller: _scrollCtrl,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              children: List.generate(widget.tabs.length, (i) {
                final item     = widget.tabs[i];
                final selected = widget.selectedIndex == i;
                return InkWell(
                  onTap: () => widget.onTap(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeInOut,
                    width: 72,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: selected ? 32 : 0,
                          height: 3,
                          margin: const EdgeInsets.only(bottom: 4),
                          decoration: BoxDecoration(
                            color: AppTheme.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Icon(item.icon, size: 20,
                          color: selected ? AppTheme.primary : AppTheme.textMuted),
                        const SizedBox(height: 3),
                        Text(
                          item.label,
                          style: TextStyle(
                            fontFamily: 'SpaceMono',
                            fontSize: 9,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: selected ? AppTheme.primary : AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
class _TabItem {
  final IconData icon;
  final String label;
  const _TabItem({required this.icon, required this.label});
}
