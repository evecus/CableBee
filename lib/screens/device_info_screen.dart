import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

class DeviceInfoScreen extends StatefulWidget {
  final void Function(List<Widget> actions)? onActionsChanged;
  const DeviceInfoScreen({super.key, this.onActionsChanged});
  @override
  State<DeviceInfoScreen> createState() => DeviceInfoScreenState();
}

class DeviceInfoScreenState extends State<DeviceInfoScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void refreshActions() => widget.onActionsChanged?.call([]);

  Map<String, String>? _info;
  bool _loading = false;
  bool _didLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didLoad && context.read<AdbService>().hasDevice) {
      _didLoad = true;
      _load();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onActionsChanged?.call([]);
    });
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
      return const Center(child: CbeeLoader(message: '读取设备信息...'));
    }

    if (_info == null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.info_outline_rounded, size: 40, color: AppTheme.textMuted),
          const SizedBox(height: 12),
          const Text('暂无信息', style: TextStyle(
            fontFamily: 'SpaceMono', fontSize: 13, color: AppTheme.textMuted,
          )),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('重新读取'),
          ),
        ]),
      );
    }

    final i = _info!;

    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primary,
      backgroundColor: AppTheme.bg1,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [

          // ── 设备摘要卡片 ───────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppTheme.bg1,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.bg3),
            ),
            child: Row(children: [
              Container(
                width: 60, height: 60,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.smartphone_rounded, size: 30, color: AppTheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(i['model'] ?? '未知设备', style: const TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 16,
                    fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
                  )),
                  const SizedBox(height: 3),
                  Text(i['brand'] ?? i['manufacturer'] ?? '', style: const TextStyle(
                    fontFamily: 'JetBrainsMono', fontSize: 12,
                    color: AppTheme.textSecondary,
                  )),
                  const SizedBox(height: 8),
                  Row(children: [
                    _Badge('Android ${i['android'] ?? '?'}', AppTheme.success),
                    const SizedBox(width: 6),
                    _Badge('API ${i['sdk'] ?? '?'}', AppTheme.primary),
                  ]),
                ],
              )),
            ]),
          ),

          const SizedBox(height: 20),

          // ── 硬件 ──────────────────────────────────────────────────
          _InfoGroup(
            title: '硬件',
            icon: Icons.memory_rounded,
            iconColor: AppTheme.primary,
            items: [
              _Item('设备型号',     i['model']      ?? '无'),
              _Item('品牌',        i['brand']      ?? '无'),
              _Item('制造商',      i['manufacturer'] ?? '无'),
              _Item('处理器平台',   i['platform']   ?? '无'),
              _Item('CPU 架构',    i['cpu_abi']    ?? '无'),
              _Item('CPU 核心数',  i['cpu_cores']  ?? '无'),
              _Item('分辨率',      i['resolution'] ?? '无'),
              _Item('DPI',         i['dpi']        ?? '无'),
            ],
          ),

          const SizedBox(height: 12),

          // ── 存储与内存 ────────────────────────────────────────────
          _InfoGroup(
            title: '存储与内存',
            icon: Icons.storage_rounded,
            iconColor: AppTheme.warning,
            items: [
              _Item('运行内存',    i['memory']        ?? '无'),
              _Item('存储总量',    i['storage_total'] ?? '无'),
              _Item('存储剩余',    i['storage_free']  ?? '无'),
            ],
          ),

          const SizedBox(height: 12),

          // ── 电池 ──────────────────────────────────────────────────
          _InfoGroup(
            title: '电池',
            icon: Icons.battery_charging_full_rounded,
            iconColor: AppTheme.success,
            items: [
              _Item('电池电量',  i['battery_level']   ?? '无'),
              _Item('电池电压',  i['battery_voltage'] ?? '无'),
              _Item('电池温度',  i['battery_temp']    ?? '无'),
            ],
          ),

          const SizedBox(height: 12),

          // ── 系统 ──────────────────────────────────────────────────
          _InfoGroup(
            title: '系统',
            icon: Icons.android_rounded,
            iconColor: AppTheme.success,
            items: [
              _Item('Android 版本',  i['android']        ?? '无'),
              _Item('SDK 级别',      i['sdk'] != null ? 'API ${i['sdk']}' : '无'),
              _Item('安全补丁日期',   i['security_patch'] ?? '无'),
              _Item('内核版本',       i['kernel']         ?? '无'),
            ],
          ),

          const SizedBox(height: 12),

          // ── 网络与标识 ────────────────────────────────────────────
          _InfoGroup(
            title: '网络与标识',
            icon: Icons.wifi_rounded,
            iconColor: AppTheme.secondary,
            items: [
              _Item('序列号',    i['serial']     ?? '无', canCopy: true),
              _Item('IP 地址',   i['ip']         ?? '无', canCopy: true),
              _Item('MAC 地址',  i['mac']        ?? '无', canCopy: true),
              _Item('Android ID', i['android_id'] ?? '无', canCopy: true),
            ],
          ),

          const SizedBox(height: 24),

          Center(child: Text('下拉刷新', style: const TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.textMuted,
          ))),
        ],
      ),
    );
  }
}

// ── 徽标 ──────────────────────────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(text, style: TextStyle(
        fontFamily: 'SpaceMono', fontSize: 10,
        fontWeight: FontWeight.w600, color: color,
      )),
    );
  }
}

// ── Info Group ────────────────────────────────────────────────────────────────

class _Item {
  final String label;
  final String value;
  final bool canCopy;
  const _Item(this.label, this.value, {this.canCopy = false});
}

class _InfoGroup extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final List<_Item> items;
  const _InfoGroup({
    required this.title, required this.icon,
    required this.iconColor, required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 分组标题
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Row(children: [
          Container(
            width: 20, height: 20,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(icon, size: 12, color: iconColor),
          ),
          const SizedBox(width: 7),
          Text(title, style: TextStyle(
            fontFamily: 'SpaceMono', fontSize: 11,
            fontWeight: FontWeight.w600,
            color: iconColor,
            letterSpacing: 0.3,
          )),
        ]),
      ),
      // 内容卡片
      Container(
        decoration: BoxDecoration(
          color: AppTheme.bg1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.bg3),
        ),
        child: Column(
          children: List.generate(items.length, (i) {
            final item = items[i];
            return Column(children: [
              _InfoRow(label: item.label, value: item.value, canCopy: item.canCopy),
              if (i < items.length - 1)
                const Divider(height: 1, indent: 16, endIndent: 16, color: AppTheme.bg3),
            ]);
          }),
        ),
      ),
    ]);
  }
}

// ── Info Row ──────────────────────────────────────────────────────────────────

class _InfoRow extends StatefulWidget {
  final String label;
  final String value;
  final bool canCopy;
  const _InfoRow({required this.label, required this.value, this.canCopy = false});

  @override
  State<_InfoRow> createState() => _InfoRowState();
}

class _InfoRowState extends State<_InfoRow> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final isMissing = widget.value == '无' || widget.value.isEmpty;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: widget.canCopy && !isMissing ? _copy : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(children: [
          SizedBox(
            width: 100,
            child: Text(widget.label, style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 12,
              color: AppTheme.textMuted,
            )),
          ),
          Expanded(child: Text(
            widget.value,
            style: TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 12,
              color: isMissing ? AppTheme.textMuted : AppTheme.textPrimary,
              fontWeight: isMissing ? FontWeight.w400 : FontWeight.w500,
              fontStyle: isMissing ? FontStyle.italic : FontStyle.normal,
            ),
          )),
          if (widget.canCopy && !isMissing)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                key: ValueKey(_copied),
                size: 13,
                color: _copied ? AppTheme.success : AppTheme.textMuted,
              ),
            ),
        ]),
      ),
    );
  }
}
