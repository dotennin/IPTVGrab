import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvgrab/src/theme.dart';

void main() {
  group('color constants', () {
    test('appBackground is defined', () {
      expect(appBackground, const Color(0xFF0B1220));
    });

    test('appSurface is defined', () {
      expect(appSurface, const Color(0xFF111827));
    });

    test('appPrimary is defined', () {
      expect(appPrimary, const Color(0xFF3B82F6));
    });

    test('appSuccess is defined', () {
      expect(appSuccess, const Color(0xFF22C55E));
    });

    test('appDanger is defined', () {
      expect(appDanger, const Color(0xFFEF4444));
    });

    test('appWarning is defined', () {
      expect(appWarning, const Color(0xFFF59E0B));
    });

    test('appAccent is defined', () {
      expect(appAccent, const Color(0xFFF97316));
    });

    test('appTextMuted is defined', () {
      expect(appTextMuted, const Color(0xFF94A3B8));
    });
  });

  group('buildAppTheme', () {
    late ThemeData theme;

    setUp(() {
      theme = buildAppTheme();
    });

    test('uses Material 3', () {
      expect(theme.useMaterial3, isTrue);
    });

    test('is dark mode', () {
      expect(theme.brightness, Brightness.dark);
    });

    test('sets scaffold background to appBackground', () {
      expect(theme.scaffoldBackgroundColor, appBackground);
    });

    test('sets primary color in color scheme', () {
      expect(theme.colorScheme.primary, appPrimary);
    });

    test('sets secondary color in color scheme', () {
      expect(theme.colorScheme.secondary, appAccent);
    });

    test('sets surface color in color scheme', () {
      expect(theme.colorScheme.surface, appSurface);
    });

    test('sets error color in color scheme', () {
      expect(theme.colorScheme.error, appDanger);
    });

    test('configures navigation bar theme', () {
      expect(theme.navigationBarTheme.backgroundColor, appSurface);
    });

    test('configures app bar theme', () {
      expect(theme.appBarTheme.backgroundColor, appBackground);
    });

    test('configures card theme', () {
      expect(theme.cardTheme.color, appSurface);
    });
  });
}
