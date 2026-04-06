import 'package:flutter/material.dart';

const Color appBackground = Color(0xFF0B1220);
const Color appSurface = Color(0xFF111827);
const Color appSurfaceAlt = Color(0xFF172033);
const Color appPrimary = Color(0xFF3B82F6);
const Color appAccent = Color(0xFFF97316);
const Color appSuccess = Color(0xFF22C55E);
const Color appWarning = Color(0xFFF59E0B);
const Color appDanger = Color(0xFFEF4444);
const Color appTextMuted = Color(0xFF94A3B8);

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: appBackground,
    colorScheme: const ColorScheme.dark(
      primary: appPrimary,
      secondary: appAccent,
      surface: appSurface,
      error: appDanger,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: Color(0xFFE5E7EB),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: appBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: appSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: appSurfaceAlt,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(18)),
        borderSide: BorderSide(color: appPrimary, width: 1.4),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: appPrimary),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: appSurface,
      indicatorColor: appPrimary.withValues(alpha: 0.18),
      surfaceTintColor: Colors.transparent,
      height: 74,
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: appSurfaceAlt,
      side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
      ),
      labelStyle: const TextStyle(color: Colors.white),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: appPrimary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    ),
  );
}
