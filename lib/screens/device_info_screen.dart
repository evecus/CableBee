import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

class DeviceInfoScreen extends StatefulWidget {
  final void Function(List<Widget> actions) onActionsChanged;
  const DeviceInfoScreen({super.key, required this.onActionsChanged});
  @override
  State<DeviceInfoScreen> createState() => _DeviceInfoScreenState();
}

class _DeviceInfoScreenState extends State<DeviceInfoScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  Map<String, String>? _info;
  bool _loading = false;
  bool _didLoad = false;

  @override
  void initState() {
    super.initState();
    // 信息页无额外 actions
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onActionsChanged([]);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didLoad && context.read<AdbService>().hasDevice) {
      _didLoad = true;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final info = await context.read<AdbService>().getDeviceInfo();
    if (mounted) setState(() { _info = info; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(
        valueColor: AlwaysStoppedAnimation(AppTheme.primary),
      ));
    }
    if (_info == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.info_outline_rounded, size: 36, color: AppTheme.textMuted),
        const SizedBox(height: 12),
        const Text('暂无设备信息', style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 13, color: AppTheme.textMuted,
        )),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _load,
          child: const Text('重新加载'),
        ),
      ]));
    }

    final sections = [
      _InfoSection(
        icon: Icons.memory_rounded,
        color: AppTheme.primary,
        title: '硬件',
        rows: [
          ('设备型号',     _info!['model']      ?? '无'),
          ('品牌',         _info!['brand']      ?? '无'),
          ('制造商',       _info!['manufacturer'] ?? '无'),
          ('处理器平台',   _info!['platform']   ?? '无'),
          ('CPU 架构',     _info!['cpu_abi']    ?? '无'),
          ('CPU 核心数',   _info!['cpu_cores']  ?? '无'),
          ('分辨率',       _info!['resolution'] ?? '无'),
          ('DPI',          _info!['dpi']        ?? '无'),
        ],
      ),
      _InfoSection(
        icon: Icons.storage_rounded,
        color: const Color(0xFFE67E22),
        title: '存储与内存',
        rows: [
          ('运行内存',   _info!['memory']        ?? '无'),
          ('存储总量',   _info!['storage_total']  ?? '无'),
          ('可用存储',   _info!['storage_free']   ?? '无'),
        ],
      ),
      _InfoSection(
        icon: Icons.battery_charging_full_rounded,
        color: AppTheme.success,
        title: '电池',
        rows: [
          ('电量',     _info!['battery_level']   ?? '无'),
          ('电压',     _info!['battery_voltage']  ?? '无'),
          ('温度',     _info!['battery_temp']     ?? '无'),
        ],
      ),
      _InfoSection(
        icon: Icons.android_rounded,
        color: const Color(0xFF3DDC84),
        title: '系统',
        rows: [
          ('Android 版本', _info!['android']        ?? '无'),
          ('API 级别',     _info!['sdk']            ?? '无'),
          ('安全补丁',     _info!['security_patch'] ?? '无'),
          ('内核版本',     _info!['kernel']         ?? '无'),
          ('序列号',       _info!['serial']         ?? '无'),
        ],
      ),
      _InfoSection(
        icon: Icons.wifi_rounded,
        color: const Color(0xFF5B8DEF),
        title: '网络与标识',
        rows: [
          ('IP 地址',    _info!['ip']         ?? '无'),
          ('MAC 地址',   _info!['mac']        ?? '无'),
          ('Android ID', _info!['android_id'] ?? '无'),
        ],
      ),
    ];

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      itemCount: sections.length,
      itemBuilder: (_, i) => _InfoSectionWidget(section: sections[i]),
    );
  }
}

// ── Data classes ──────────────────────────────────────────────────────────────

class _InfoSection {
  final IconData icon;
  final Color color;
  final String title;
  final List<(String, String)> rows;
  const _InfoSection({
    required this.icon, required this.color,
    required this.title, required this.rows,
  });
}

// ── Section widget ────────────────────────────────────────────────────────────

class _InfoSectionWidget extends StatelessWidget {
  final _InfoSection section;
  const _InfoSectionWidget({required this.section});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 20),
      // Header
      Row(children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: section.color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(section.icon, size: 15, color: section.color),
        ),
        const SizedBox(width: 8),
        Text(section.title, style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 12,
          fontWeight: FontWeight.w700, color: section.color,
        )),
      ]),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: AppTheme.bg1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.bg3),
        ),
        child: Column(children: [
          for (int i = 0; i < section.rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16,
                color: AppTheme.bg3),
            _InfoRow(label: section.rows[i].$1, value: section.rows[i].$2),
          ],
        ]),
      ),
    ]);
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已复制：$value'),
              duration: const Duration(seconds: 1)),
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          SizedBox(
            width: 90,
            child: Text(label, style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 12,
              color: AppTheme.textMuted,
            )),
          ),
          Expanded(child: Text(value, style: const TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 13,
            color: AppTheme.textPrimary, fontWeight: FontWeight.w500,
          ))),
        ]),
      ),
    );
  }
}
