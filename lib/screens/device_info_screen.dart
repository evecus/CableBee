import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

class DeviceInfoScreen extends StatefulWidget {
  const DeviceInfoScreen({super.key});
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

    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primary,
      backgroundColor: AppTheme.bg1,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          // ── Device summary card ───────────────────────────────────
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.bg1,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.bg3),
            ),
            child: Row(children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.smartphone_rounded, size: 28, color: AppTheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _info!['model'] ?? '未知设备',
                    style: const TextStyle(
                      fontFamily: 'SpaceMono', fontSize: 15,
                      fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _info!['manufacturer'] ?? '',
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono', fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppTheme.success.withOpacity(0.3)),
                    ),
                    child: Text(
                      'Android ${_info!['android'] ?? '?'}',
                      style: const TextStyle(
                        fontFamily: 'SpaceMono', fontSize: 10,
                        fontWeight: FontWeight.w600, color: AppTheme.success,
                      ),
                    ),
                  ),
                ],
              )),
            ]),
          ),

          const SizedBox(height: 16),

          // ── Info grid ─────────────────────────────────────────────
          _InfoGroup(title: '系统', items: [
            _InfoRow(label: 'Android 版本', value: _info!['android'] ?? '—'),
            _InfoRow(label: 'SDK 版本',    value: 'API ${_info!['sdk'] ?? '—'}'),
            _InfoRow(label: '序列号',      value: _info!['serial'] ?? '—', canCopy: true),
          ]),

          const SizedBox(height: 12),

          _InfoGroup(title: '硬件', items: [
            _InfoRow(label: '型号',   value: _info!['model'] ?? '—'),
            _InfoRow(label: '制造商', value: _info!['manufacturer'] ?? '—'),
            _InfoRow(label: '内存',   value: _info!['memory'] ?? '—'),
          ]),

          const SizedBox(height: 20),

          // ── Refresh hint ──────────────────────────────────────────
          Center(child: Text(
            '下拉刷新',
            style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 11, color: AppTheme.textMuted,
            ),
          )),
        ],
      ),
    );
  }
}

// ── Info Group ────────────────────────────────────────────────────────────────

class _InfoGroup extends StatelessWidget {
  final String title;
  final List<_InfoRow> items;
  const _InfoGroup({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(title, style: const TextStyle(
          fontFamily: 'SpaceMono', fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppTheme.textMuted,
          letterSpacing: 0.5,
        )),
      ),
      Container(
        decoration: BoxDecoration(
          color: AppTheme.bg1,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.bg3),
        ),
        child: Column(
          children: List.generate(items.length, (i) {
            return Column(children: [
              items[i],
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

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool canCopy;
  const _InfoRow({required this.label, required this.value, this.canCopy = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: canCopy ? () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已复制 $label', style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 12,
            )),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } : null,
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
            fontFamily: 'JetBrainsMono', fontSize: 12,
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.w500,
          ))),
          if (canCopy)
            const Icon(Icons.copy_rounded, size: 13, color: AppTheme.textMuted),
        ]),
      ),
    );
  }
}
