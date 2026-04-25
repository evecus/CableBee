import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/adb_service.dart';
import '../utils/theme.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final adb = context.watch<AdbService>();

    return Scaffold(
      backgroundColor: AppTheme.bg0,
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [

          // ── 连接管理 ──────────────────────────────────────────────
          const SectionHeader(title: '连接'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: EdgeInsets.zero,
              child: Column(children: [
                // Status row
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(children: [
                    Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: (adb.serverRunning
                            ? AppTheme.success : AppTheme.textMuted).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.cable_rounded, size: 18,
                          color: adb.serverRunning ? AppTheme.success : AppTheme.textMuted),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('设备连接', style: TextStyle(
                          fontFamily: 'SpaceMono', fontSize: 13,
                          fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
                        )),
                        Text(
                          adb.serverRunning
                              ? '${adb.devices.length} 台设备已连接'
                              : '未连接设备',
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono', fontSize: 11,
                            color: adb.serverRunning ? AppTheme.success : AppTheme.textMuted,
                          ),
                        ),
                      ],
                    )),
                    FilledButton(
                      onPressed: () async {
                        if (adb.serverRunning) {
                          await adb.killServer();
                        } else {
                          await adb.startServer();
                        }
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: adb.serverRunning
                            ? AppTheme.danger : AppTheme.primary,
                        foregroundColor: AppTheme.bg0,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        adb.serverRunning ? '断开全部' : '启动轮询',
                        style: const TextStyle(
                          fontFamily: 'SpaceMono', fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ]),
                ),
                const Divider(height: 1),
                ActionTile(
                  icon: Icons.refresh_rounded,
                  title: '刷新设备列表',
                  subtitle: '立即重新扫描已连接设备',
                  iconColor: AppTheme.warning,
                  onTap: () async {
                    await adb.refreshDevices();
                  },
                ),
              ]),
            ),
          ),

          // ── 平台工具 ──────────────────────────────────────────────
          const SectionHeader(title: '平台工具'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.success.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.check_circle_rounded,
                          size: 18, color: AppTheme.success),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ADB 协议', style: TextStyle(
                          fontFamily: 'SpaceMono', fontSize: 12,
                          fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
                        )),
                        Text('原生 Kotlin 实现，无需 adb 进程', style: TextStyle(
                          fontFamily: 'JetBrainsMono', fontSize: 11,
                          color: AppTheme.textSecondary,
                        )),
                      ],
                    )),
                  ]),
                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  const _InfoRow(label: 'ADB 实现',    value: '原生协议 (Kotlin)'),
                  const _InfoRow(label: 'SYNC 支持',   value: 'push / pull ✓'),
                  const _InfoRow(label: 'fastboot',   value: 'v34.0.4 (内置)'),
                  const _InfoRow(label: '最低 Android', value: '8.0 (API 26)'),
                ],
              ),
            ),
          ),

          // ── 行为 ──────────────────────────────────────────────────
          const SectionHeader(title: '行为'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(children: [
                  const Icon(Icons.sensors_rounded, size: 18, color: AppTheme.secondary),
                  const SizedBox(width: 12),
                  const Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('自动检测设备', style: TextStyle(
                        fontFamily: 'SpaceMono', fontSize: 13,
                        fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
                      )),
                      Text('每 3 秒轮询一次已连接设备', style: TextStyle(
                        fontFamily: 'JetBrainsMono', fontSize: 11,
                        color: AppTheme.textMuted,
                      )),
                    ],
                  )),
                  Switch(
                    value: true,
                    onChanged: null,
                    activeColor: AppTheme.primary,
                  ),
                ]),
              ),
            ),
          ),

          // ── 关于 ──────────────────────────────────────────────────
          const SectionHeader(title: '关于'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TintedCard(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                Row(children: [
                  Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
                    ),
                    child: const Icon(Icons.cable_rounded, size: 24, color: AppTheme.primary),
                  ),
                  const SizedBox(width: 14),
                  const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('CableBee', style: TextStyle(
                      fontFamily: 'SpaceMono', fontSize: 18,
                      fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
                    )),
                    Text('ADB Assistant', style: TextStyle(
                      fontFamily: 'JetBrainsMono', fontSize: 12,
                      color: AppTheme.textMuted,
                    )),
                  ]),
                ]),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                const _InfoRow(label: '版本',     value: '1.0.0'),
                const _InfoRow(label: 'ADB 协议', value: '原生实现 (无进程)'),
                const _InfoRow(label: 'fastboot', value: 'v34.0.4 内置'),
                const _InfoRow(label: '最低系统', value: 'Android 8.0+'),
              ]),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text(label, style: const TextStyle(
          fontFamily: 'SpaceMono', fontSize: 11,
          color: AppTheme.textMuted, letterSpacing: 0.3,
        )),
        const Spacer(),
        Text(value, style: const TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 11,
          color: AppTheme.textSecondary,
        )),
      ]),
    );
  }
}
