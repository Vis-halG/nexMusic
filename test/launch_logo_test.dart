import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/launch_logo.dart';

void main() {
  testWidgets(
    'launch content accepts taps immediately and the logo is gone in 200 ms',
    (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => LaunchLogo(child: child!),
          home: Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => tapped = true,
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Open'));
      expect(tapped, isTrue);
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump();
      expect(find.byKey(const ValueKey('launch-logo')), findsNothing);
    },
  );
  for (final reduced in [false, true]) {
    testWidgets(
      'launch logo finishes once and respects reduced motion: $reduced',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: LaunchLogo(child: child!),
            ),
            home: const Scaffold(body: Text('Ready')),
          ),
        );
        expect(
          find.byKey(const ValueKey('launch-logo')),
          reduced ? findsNothing : findsOneWidget,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('launch-logo')), findsNothing);
        expect(find.text('Ready'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        expect(find.byKey(const ValueKey('launch-logo')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
