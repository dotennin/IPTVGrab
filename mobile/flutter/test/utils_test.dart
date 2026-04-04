import 'package:flutter_test/flutter_test.dart';
import 'package:media_nest/src/utils.dart';

void main() {
  group('formatBytes', () {
    test('formats 0 bytes', () {
      expect(formatBytes(0), '0 B');
    });

    test('formats bytes below 1 KB', () {
      expect(formatBytes(512), '512 B');
    });

    test('formats exact 1 KB', () {
      expect(formatBytes(1024), '1.0 KB');
    });

    test('formats kilobytes', () {
      expect(formatBytes(1536), '1.5 KB');
    });

    test('formats megabytes', () {
      expect(formatBytes(1048576), '1.0 MB');
    });

    test('formats gigabytes', () {
      expect(formatBytes(1073741824), '1.0 GB');
    });

    test('formats large gigabyte values', () {
      expect(formatBytes(5368709120), '5.0 GB');
    });

    test('formats terabytes', () {
      expect(formatBytes(1099511627776), '1.0 TB');
    });

    test('handles fractional values', () {
      // 2.5 MB = 2621440 bytes
      expect(formatBytes(2621440), '2.5 MB');
    });
  });

  group('formatSeconds', () {
    test('formats zero', () {
      expect(formatSeconds(0), '0s');
    });

    test('formats negative as 0s', () {
      expect(formatSeconds(-5), '0s');
    });

    test('formats seconds only', () {
      expect(formatSeconds(45), '45s');
    });

    test('formats minutes and seconds', () {
      expect(formatSeconds(125), '2m 5s');
    });

    test('formats hours', () {
      expect(formatSeconds(3661), '1h 1m 1s');
    });

    test('rounds fractional seconds', () {
      expect(formatSeconds(90.7), '1m 31s');
    });
  });

  group('formatClock', () {
    test('formats zero seconds', () {
      expect(formatClock(0), '0s');
    });

    test('formats seconds only', () {
      expect(formatClock(30), '30s');
    });

    test('formats minutes and seconds', () {
      expect(formatClock(90), '1m 30s');
    });

    test('formats hours, minutes, seconds', () {
      expect(formatClock(3723), '1h 2m 3s');
    });

    test('formats exact hour', () {
      expect(formatClock(3600), '1h 0m 0s');
    });
  });

  group('formatDurationLabel', () {
    test('formats null as 0:00', () {
      expect(formatDurationLabel(null), '0:00');
    });

    test('formats zero duration', () {
      expect(formatDurationLabel(Duration.zero), '0:00');
    });

    test('formats negative duration as 0:00', () {
      expect(formatDurationLabel(const Duration(seconds: -5)), '0:00');
    });

    test('formats seconds only', () {
      expect(formatDurationLabel(const Duration(seconds: 45)), '0:45');
    });

    test('formats minutes and seconds', () {
      expect(formatDurationLabel(const Duration(minutes: 3, seconds: 7)), '3:07');
    });

    test('pads seconds with zero', () {
      expect(formatDurationLabel(const Duration(minutes: 1, seconds: 5)), '1:05');
    });

    test('formats hours, minutes, seconds', () {
      expect(
        formatDurationLabel(
          const Duration(hours: 1, minutes: 23, seconds: 45),
        ),
        '1:23:45',
      );
    });

    test('pads minutes and seconds with hours', () {
      expect(
        formatDurationLabel(
          const Duration(hours: 2, minutes: 5, seconds: 3),
        ),
        '2:05:03',
      );
    });
  });

  group('shortId', () {
    test('returns short strings unchanged', () {
      expect(shortId('abc'), 'abc');
    });

    test('returns 8 char strings unchanged', () {
      expect(shortId('12345678'), '12345678');
    });

    test('truncates strings longer than 8 chars', () {
      expect(shortId('abcdefghij'), 'abcdefgh');
    });

    test('handles empty string', () {
      expect(shortId(''), '');
    });
  });

  group('titleCase', () {
    test('capitalizes first letter', () {
      expect(titleCase('downloading'), 'Downloading');
    });

    test('handles already capitalized', () {
      expect(titleCase('Recording'), 'Recording');
    });

    test('handles single character', () {
      expect(titleCase('a'), 'A');
    });

    test('handles empty string', () {
      expect(titleCase(''), '');
    });

    test('preserves rest of string', () {
      expect(titleCase('hELLO wORLD'), 'HELLO wORLD');
    });
  });

  group('dedupeMessages', () {
    test('removes duplicates preserving order', () {
      expect(
        dedupeMessages(['a', 'b', 'a', 'c', 'b']),
        ['a', 'b', 'c'],
      );
    });

    test('trims whitespace and deduplicates', () {
      expect(
        dedupeMessages([' hello ', 'hello', '  hello  ']),
        ['hello'],
      );
    });

    test('removes empty strings', () {
      expect(
        dedupeMessages(['a', '', '  ', 'b']),
        ['a', 'b'],
      );
    });

    test('handles empty input', () {
      expect(dedupeMessages([]), isEmpty);
    });

    test('handles single element', () {
      expect(dedupeMessages(['only']), ['only']);
    });
  });

  group('parseHeadersText', () {
    test('parses colon-separated headers', () {
      expect(
        parseHeadersText('Content-Type: application/json\nAuthorization: Bearer token'),
        {'Content-Type': 'application/json', 'Authorization': 'Bearer token'},
      );
    });

    test('parses equals-separated headers', () {
      expect(
        parseHeadersText('key=value'),
        {'key': 'value'},
      );
    });

    test('skips HTTP method lines', () {
      expect(
        parseHeadersText('GET /path HTTP/1.1\nHost: example.com'),
        {'Host': 'example.com'},
      );
    });

    test('skips POST and HEAD lines', () {
      expect(
        parseHeadersText('POST /api/data\nContent-Type: text/plain'),
        {'Content-Type': 'text/plain'},
      );
    });

    test('skips empty lines', () {
      expect(
        parseHeadersText('\n\nHost: example.com\n\n'),
        {'Host': 'example.com'},
      );
    });

    test('skips lines without separator', () {
      expect(
        parseHeadersText('noseparator\nHost: example.com'),
        {'Host': 'example.com'},
      );
    });

    test('skips headers with empty name or value', () {
      expect(
        parseHeadersText(': value\nname:\nGood: header'),
        {'Good': 'header'},
      );
    });

    test('returns empty map for empty input', () {
      expect(parseHeadersText(''), isEmpty);
    });

    test('handles colon in value', () {
      expect(
        parseHeadersText('Authorization: Bearer: token:123'),
        {'Authorization': 'Bearer: token:123'},
      );
    });
  });

  group('randomEditorId', () {
    test('starts with prefix', () {
      final id = randomEditorId('grp');
      expect(id, startsWith('grp_'));
    });

    test('generates unique ids', () {
      final ids = List.generate(10, (_) => randomEditorId('test'));
      expect(ids.toSet().length, ids.length);
    });
  });
}
