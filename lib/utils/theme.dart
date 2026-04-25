import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // ── Palette (Light) ───────────────────────────────────────
  static const Color bg0 = Color(0xFFFFFFFF);      // deepest bg  → 纯白
  static const Color bg1 = Color(0xFFF5F5F5);      // card bg     → 浅灰
  static const Color bg2 = Color(0xFFEEEEEE);      // elevated    → 更浅灰
  static const Color bg3 = Color(0xFFDDDDDD);      // border      → 边框灰

  static const Color primary   = Color(0xFF00957A); // teal-green (加深适配白底)
  static const Color secondary = Color(0xFF1565C0); // blue
  static const Color warning   = Color(0xFFE65100); // amber
  static const Color danger    = Color(0xFFB71C1C); // red
  static const Color success   = Color(0xFF2E7D32); // green

  static const Color textPrimary   = Color(0xFF111111); // 主文字 → 近黑
  static const Color textSecondary = Color(0xFF444444); // 次要文字 → 深灰
  static const Color textMuted     = Color(0xFF888888); // 弱化文字 → 中灰

  // ── Typography ───────────────────────────────────────────
  static TextTheme get textTheme => GoogleFonts.jetBrainsMonoTextTheme().copyWith(
    displayLarge: GoogleFonts.spaceMono(
      fontSize: 28, fontWeight: FontWeight.w700, color: textPrimary,
    ),
    titleLarge: GoogleFonts.spaceMono(
      fontSize: 18, fontWeight: FontWeight.w600, color: textPrimary,
    ),
    titleMedium: GoogleFonts.spaceMono(
      fontSize: 14, fontWeight: FontWeight.w600, color: textPrimary,
      letterSpacing: 0.5,
    ),
    bodyLarge: GoogleFonts.jetBrainsMono(
      fontSize: 14, fontWeight: FontWeight.w400, color: textPrimary,
    ),
    bodyMedium: GoogleFonts.jetBrainsMono(
      fontSize: 13, fontWeight: FontWeight.w400, color: textSecondary,
    ),
    bodySmall: GoogleFonts.jetBrainsMono(
      fontSize: 11, fontWeight: FontWeight.w400, color: textMuted,
    ),
    labelLarge: GoogleFonts.spaceMono(
      fontSize: 13, fontWeight: FontWeight.w600, color: primary,
      letterSpacing: 0.8,
    ),
  );

  // ── Theme ─────────────────────────────────────────────────
  static ThemeData get dark => ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: bg0,
    colorScheme: const ColorScheme.light(
      surface: bg1,
      primary: primary,
      secondary: secondary,
      error: danger,
      onSurface: textPrimary,
      onPrimary: Colors.white,
    ),
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: bg0,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.spaceMono(
        fontSize: 17, fontWeight: FontWeight.w700, color: textPrimary,
      ),
      iconTheme: const IconThemeData(color: textPrimary),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: bg1,
      indicatorColor: primary.withOpacity(0.15),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return GoogleFonts.spaceMono(
            fontSize: 10, fontWeight: FontWeight.w600, color: primary,
          );
        }
        return GoogleFonts.spaceMono(
          fontSize: 10, fontWeight: FontWeight.w400, color: textMuted,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: primary, size: 22);
        }
        return const IconThemeData(color: textMuted, size: 22);
      }),
    ),
    cardTheme: CardTheme(
      color: bg1,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: bg3, width: 1),
      ),
      margin: EdgeInsets.zero,
    ),
    dividerTheme: const DividerThemeData(
      color: bg3, thickness: 1, space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        textStyle: GoogleFonts.spaceMono(
          fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.5,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: textPrimary,
        side: const BorderSide(color: bg3),
        textStyle: GoogleFonts.spaceMono(
          fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.3,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bg1,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: bg3),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: bg3),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: primary, width: 1.5),
      ),
      labelStyle: GoogleFonts.spaceMono(fontSize: 12, color: textSecondary),
      hintStyle: GoogleFonts.jetBrainsMono(fontSize: 13, color: textMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: bg2,
      labelStyle: GoogleFonts.spaceMono(fontSize: 11, color: textSecondary),
      side: const BorderSide(color: bg3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    useMaterial3: true,
  );
}
