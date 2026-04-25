import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../utils/theme.dart';
import '../models/device.dart';

// ── Status Badge ─────────────────────────────────────────────────────────────

class DeviceStateBadge extends StatelessWidget {
  final DeviceState state;
  const DeviceStateBadge({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      DeviceState.online       => (AppTheme.success, 'online'),
      DeviceState.offline      => (AppTheme.textMuted, 'offline'),
      DeviceState.unauthorized => (AppTheme.warning, 'auth?'),
      DeviceState.connecting   => (AppTheme.secondary, 'connecting'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.35), width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 5, height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(
          fontFamily: 'SpaceMono', fontSize: 10,
          fontWeight: FontWeight.w600, color: color,
          letterSpacing: 0.3,
        )),
      ]),
    );
  }
}

// ── Section Header ────────────────────────────────────────────────────────────

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const SectionHeader({super.key, required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(
            fontFamily: 'SpaceMono', fontSize: 11,
            fontWeight: FontWeight.w600, color: AppTheme.textMuted,
            letterSpacing: 1.2,
          )),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 12,
              color: AppTheme.textSecondary,
            )),
          ],
        ])),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

// ── Tinted Card ───────────────────────────────────────────────────────────────

class TintedCard extends StatelessWidget {
  final Widget child;
  final Color? borderColor;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  const TintedCard({
    super.key,
    required this.child,
    this.borderColor,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.bg1,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor: AppTheme.primary.withOpacity(0.06),
        highlightColor: AppTheme.primary.withOpacity(0.04),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor ?? AppTheme.bg3,
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ── Terminal Output ───────────────────────────────────────────────────────────

class TerminalBox extends StatelessWidget {
  final String text;
  final bool showCopyButton;
  final int maxLines;

  const TerminalBox({
    super.key,
    required this.text,
    this.showCopyButton = true,
    this.maxLines = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.bg3),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Row(children: [
            _dot(const Color(0xFFFF5F56)),
            const SizedBox(width: 6),
            _dot(const Color(0xFFFFBD2E)),
            const SizedBox(width: 6),
            _dot(const Color(0xFF27C93F)),
          ]),
          const Spacer(),
          if (showCopyButton && text.isNotEmpty)
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: text));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制到剪贴板'),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              child: const Icon(Icons.copy_rounded, size: 14, color: AppTheme.textMuted),
            ),
        ]),
        const SizedBox(height: 10),
        SelectableText(
          text.isEmpty ? '// output will appear here' : text,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 12,
            height: 1.6,
            color: text.isEmpty ? AppTheme.textMuted : AppTheme.primary.withOpacity(0.9),
          ),
          maxLines: maxLines,
        ),
      ]),
    );
  }

  Widget _dot(Color color) => Container(
    width: 10, height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

// ── Action Tile ───────────────────────────────────────────────────────────────

class ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? iconColor;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool enabled;

  const ActionTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconColor,
    this.onTap,
    this.trailing,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = iconColor ?? AppTheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.4,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withOpacity(0.2)),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(
                    fontFamily: 'SpaceMono', fontSize: 13,
                    fontWeight: FontWeight.w600, color: AppTheme.textPrimary,
                  )),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: const TextStyle(
                      fontFamily: 'JetBrainsMono', fontSize: 11,
                      color: AppTheme.textSecondary,
                    )),
                  ],
                ],
              )),
              if (trailing != null)
                trailing!
              else
                const Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppTheme.textMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

// ── Stat Grid Cell ────────────────────────────────────────────────────────────

class StatCell extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final IconData? icon;

  const StatCell({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bg1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.bg3),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: AppTheme.textMuted),
            const SizedBox(width: 4),
          ],
          Text(label, style: const TextStyle(
            fontFamily: 'SpaceMono', fontSize: 10,
            color: AppTheme.textMuted, letterSpacing: 0.8,
          )),
        ]),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 14,
          fontWeight: FontWeight.w700,
          color: valueColor ?? AppTheme.textPrimary,
        )),
      ]),
    );
  }
}

// ── Empty State ───────────────────────────────────────────────────────────────

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: AppTheme.textMuted),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(
            fontFamily: 'SpaceMono', fontSize: 15,
            fontWeight: FontWeight.w600, color: AppTheme.textSecondary,
          ), textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message!, style: const TextStyle(
              fontFamily: 'JetBrainsMono', fontSize: 12,
              color: AppTheme.textMuted,
            ), textAlign: TextAlign.center),
          ],
          if (action != null) ...[
            const SizedBox(height: 24),
            action!,
          ],
        ]),
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.1);
  }
}

// ── Loading Indicator ─────────────────────────────────────────────────────────

class CbeeLoader extends StatelessWidget {
  final String? message;
  const CbeeLoader({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 32, height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 16),
          Text(message!, style: const TextStyle(
            fontFamily: 'JetBrainsMono', fontSize: 12,
            color: AppTheme.textSecondary,
          )),
        ],
      ]),
    );
  }
}

// ── Confirm Dialog ────────────────────────────────────────────────────────────

Future<bool?> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = 'Confirm',
  Color? confirmColor,
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: Text(title, style: const TextStyle(
        fontFamily: 'SpaceMono', fontSize: 16,
        fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
      )),
      content: Text(message, style: const TextStyle(
        fontFamily: 'JetBrainsMono', fontSize: 13,
        color: AppTheme.textSecondary, height: 1.5,
      )),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel', style: TextStyle(
            fontFamily: 'SpaceMono', color: AppTheme.textSecondary,
          )),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: destructive ? AppTheme.danger
                : (confirmColor ?? AppTheme.primary),
            foregroundColor: AppTheme.bg0,
          ),
          child: Text(confirmText),
        ),
      ],
    ),
  );
}

// ── Input Dialog ──────────────────────────────────────────────────────────────

Future<String?> showInputDialog(
  BuildContext context, {
  required String title,
  String? hint,
  String? initialValue,
  String confirmText = 'OK',
  TextInputType keyboardType = TextInputType.text,
}) {
  final controller = TextEditingController(text: initialValue);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.bg1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.bg3),
      ),
      title: Text(title, style: const TextStyle(
        fontFamily: 'SpaceMono', fontSize: 15,
        fontWeight: FontWeight.w700, color: AppTheme.textPrimary,
      )),
      content: TextField(
        controller: controller,
        keyboardType: keyboardType,
        autofocus: true,
        style: const TextStyle(
          fontFamily: 'JetBrainsMono', fontSize: 14,
          color: AppTheme.textPrimary,
        ),
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel', style: TextStyle(
            fontFamily: 'SpaceMono', color: AppTheme.textSecondary,
          )),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(confirmText),
        ),
      ],
    ),
  );
}
