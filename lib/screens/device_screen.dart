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

class DeviceScreen extends StatefulWidget {
  final AdbDevice device;
  const DeviceScreen({super.key, required this.device});
  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  int _tab = 0;

  static const _tabs = [
    _TabItem(icon: Icons.info_outline_rounded,   label: '信息'),
    _TabItem(icon: Icons.terminal_rounded,        label: 'Shell'),
    _TabItem(icon: Icons.apps_rounded,            label: '应用'),
    _TabItem(icon: Icons.folder_outlined,         label: '文件'),
    _TabItem(icon: Icons.build_outlined,          label: '工具'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AdbService>().selectDevice(widget.device);
    });
  }

  @override
  Widget build(BuildContext context) {
    final adb = context.watch<AdbService>();
    final connected = adb.hasDevice;

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(
        backgroundColor: AppTheme.bg0,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: AppTheme.textSecondary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.device.displayName,
              style: const TextStyle(
                fontFamily: 'SpaceMono', fontSize: 14,
                fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
              ),
            ),
            Row(children: [
              Container(
                width: 6, height: 6,
                decoration: BoxDecoration(
                  color: connected ? AppTheme.success : AppTheme.danger,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                connected ? widget.device.serial : '已断开',
                style: TextStyle(
                  fontFamily: 'JetBrainsMono', fontSize: 10,
                  color: connected ? AppTheme.success : AppTheme.danger,
                ),
              ),
            ]),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '断开连接',
            icon: const Icon(Icons.link_off_rounded, size: 20, color: AppTheme.textMuted),
            onPressed: () async {
              await context.read<AdbService>().disconnect(serial: widget.device.serial);
              if (context.mounted) Navigator.pop(context);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          const DeviceInfoScreen(),
          const ShellScreen(),
          const AppsScreen(),
          const FilesScreen(),
          const ToolsScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppTheme.bg1,
          border: Border(top: BorderSide(color: AppTheme.bg3, width: 1)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 60,
            child: Row(
              children: List.generate(_tabs.length, (i) {
                final item = _tabs[i];
                final selected = _tab == i;
                return Expanded(
                  child: InkWell(
                    onTap: () => setState(() => _tab = i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeInOut,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: selected ? 36 : 0,
                            height: 3,
                            margin: const EdgeInsets.only(bottom: 4),
                            decoration: BoxDecoration(
                              color: AppTheme.primary,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          Icon(
                            item.icon,
                            size: 20,
                            color: selected ? AppTheme.primary : AppTheme.textMuted,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            item.label,
                            style: TextStyle(
                              fontFamily: 'SpaceMono',
                              fontSize: 10,
                              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                              color: selected ? AppTheme.primary : AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
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

class _TabItem {
  final IconData icon;
  final String label;
  const _TabItem({required this.icon, required this.label});
}
