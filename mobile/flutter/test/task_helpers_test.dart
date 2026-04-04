import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_nest/src/task_helpers.dart';
import 'package:media_nest/src/theme.dart';

void main() {
  group('statusColor', () {
    test('returns appPrimary for downloading', () {
      expect(statusColor('downloading'), appPrimary);
    });

    test('returns appDanger for recording', () {
      expect(statusColor('recording'), appDanger);
    });

    test('returns appWarning for stopping', () {
      expect(statusColor('stopping'), appWarning);
    });

    test('returns appWarning for merging', () {
      expect(statusColor('merging'), appWarning);
    });

    test('returns appSuccess for completed', () {
      expect(statusColor('completed'), appSuccess);
    });

    test('returns appDanger for failed', () {
      expect(statusColor('failed'), appDanger);
    });

    test('returns grey for cancelled', () {
      expect(statusColor('cancelled'), Colors.grey);
    });

    test('returns grey for interrupted', () {
      expect(statusColor('interrupted'), Colors.grey);
    });

    test('returns appWarning for paused', () {
      expect(statusColor('paused'), appWarning);
    });

    test('returns blueGrey for unknown status', () {
      expect(statusColor('unknown'), Colors.blueGrey);
    });

    test('returns blueGrey for empty status', () {
      expect(statusColor(''), Colors.blueGrey);
    });
  });

  group('healthStatusColor', () {
    test('returns appSuccess for ok', () {
      expect(healthStatusColor('ok'), appSuccess);
    });

    test('returns appSuccess for OK (case insensitive)', () {
      expect(healthStatusColor('OK'), appSuccess);
    });

    test('returns appDanger for dead', () {
      expect(healthStatusColor('dead'), appDanger);
    });

    test('returns appDanger for DEAD (case insensitive)', () {
      expect(healthStatusColor('DEAD'), appDanger);
    });

    test('returns slate for null', () {
      expect(healthStatusColor(null), const Color(0xFF64748B));
    });

    test('returns slate for unknown status', () {
      expect(healthStatusColor('pending'), const Color(0xFF64748B));
    });
  });
}
