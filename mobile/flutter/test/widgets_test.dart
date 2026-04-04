import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_nest/src/widgets.dart';

void main() {
  group('InfoChip', () {
    testWidgets('displays label and value', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InfoChip(label: 'Status', value: 'Active'),
          ),
        ),
      );

      expect(find.text('Status: Active'), findsOneWidget);
      expect(find.byType(Chip), findsOneWidget);
    });

    testWidgets('handles empty values', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InfoChip(label: '', value: ''),
          ),
        ),
      );

      expect(find.text(': '), findsOneWidget);
    });
  });

  group('ChannelLogo', () {
    testWidgets('shows TV icon when url is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChannelLogo(url: null),
          ),
        ),
      );

      expect(find.byIcon(Icons.tv), findsOneWidget);
      expect(find.byType(CircleAvatar), findsOneWidget);
    });

    testWidgets('shows TV icon when url is empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChannelLogo(url: ''),
          ),
        ),
      );

      expect(find.byIcon(Icons.tv), findsOneWidget);
    });

    testWidgets('renders Image.network when url is provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChannelLogo(url: 'https://example.com/logo.png'),
          ),
        ),
      );

      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(ClipRRect), findsOneWidget);
    });

    testWidgets('uses custom size', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChannelLogo(url: null, size: 60),
          ),
        ),
      );

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.radius, 30); // size / 2
    });

    testWidgets('uses default size of 40', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChannelLogo(url: null),
          ),
        ),
      );

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.radius, 20); // default 40 / 2
    });
  });
}
