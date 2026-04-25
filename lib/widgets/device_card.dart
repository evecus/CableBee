import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/device.dart';
import '../utils/theme.dart';
import 'common.dart';

class DeviceCard extends StatelessWidget {
  final AdbDevice device;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDisconnect;

  const DeviceCard({
    super.key,
    required this.device,
    this.selected = false,
    this.onTap,
    this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    return TintedCard(
      borderColor: selected ? AppTheme.primary.withOpacity(0.5) : null,
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        // Device icon
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: (selected ? AppTheme.primary : AppTheme.textMuted).withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: (selected ? AppTheme.primary : AppTheme.bg3).withOpacity(0.4),
            ),
          ),
          child: Icon(
            device.isWifi
                ? Icons.wifi_rounded
                : Icons.usb_rounded,
            size: 22,
            color: selected ? AppTheme.primary : AppTheme.textSecondary,
          ),
        ),
        const SizedBox(width: 12),
        // Info
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(
                device.displayName,
                style: const TextStyle(
                  fontFamily: 'SpaceMono', fontSize: 13,
                  fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              )),
              const SizedBox(width: 8),
              DeviceStateBadge(state: device.state),
            ]),
            const SizedBox(height: 4),
            Text(
              device.serial,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono', fontSize: 11,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        )),
        // Actions
        if (onDisconnect != null) ...[
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.link_off_rounded, size: 18),
            color: AppTheme.textMuted,
            onPressed: onDisconnect,
            tooltip: 'Disconnect',
            style: IconButton.styleFrom(
              backgroundColor: AppTheme.bg2,
              minimumSize: const Size(36, 36),
            ),
          ),
        ],
      ]),
    ).animate().fadeIn(duration: 200.ms).slideX(begin: -0.05);
  }
}

// ── Compact device header bar (shown when a device is selected) ───────────────

class DeviceHeaderBar extends StatelessWidget {
  final AdbDevice device;
  final VoidCallback onChangeDevice;

  const DeviceHeaderBar({
    super.key,
    required this.device,
    required this.onChangeDevice,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChangeDevice,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.bg1,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
        ),
        child: Row(children: [
          // Pulsing dot
          _PulsingDot(active: device.state == DeviceState.online),
          const SizedBox(width: 10),
          Icon(
            device.isWifi ? Icons.wifi_rounded : Icons.usb_rounded,
            size: 15, color: AppTheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(
            device.displayName,
            style: const TextStyle(
              fontFamily: 'SpaceMono', fontSize: 12,
              fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          )),
          const SizedBox(width: 8),
          const Text('change', style: TextStyle(
            fontFamily: 'SpaceMono', fontSize: 10,
            color: AppTheme.primary, letterSpacing: 0.3,
          )),
          const SizedBox(width: 2),
          const Icon(Icons.chevron_right_rounded, size: 14, color: AppTheme.primary),
        ]),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  final bool active;
  const _PulsingDot({required this.active});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = Tween(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return Container(
        width: 8, height: 8,
        decoration: const BoxDecoration(
          color: AppTheme.textMuted, shape: BoxShape.circle,
        ),
      );
    }
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          color: AppTheme.success.withOpacity(_anim.value),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppTheme.success.withOpacity(_anim.value * 0.5),
              blurRadius: 4, spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

// ── No device placeholder ─────────────────────────────────────────────────────

class NoDevicePlaceholder extends StatelessWidget {
  final VoidCallback onConnect;
  const NoDevicePlaceholder({super.key, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
            color: AppTheme.bg1,
            shape: BoxShape.circle,
            border: Border.all(color: AppTheme.bg3, width: 2),
          ),
          child: const Icon(Icons.phonelink_off_rounded,
            size: 36, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 20),
        const Text('No device connected', style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 16,
          fontWeight: FontWeight.w700, color: AppTheme.textSecondary,
        )),
        const SizedBox(height: 8),
        const Text(
          'Connect a device via Wi-Fi or USB\nto start using CableBee',
          style: TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 12,
            color: AppTheme.textMuted, height: 1.6,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: onConnect,
          icon: const Icon(Icons.add_link_rounded, size: 16),
          label: const Text('Connect Device'),
        ),
      ]),
    ).animate().fadeIn(duration: 400.ms).scale(begin: const Offset(0.95, 0.95));
  }
}
