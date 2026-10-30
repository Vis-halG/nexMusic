import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/launch_logo.dart';

void main() {
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
