import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/tab_stage.dart';

class _Tabs extends StatefulWidget {
  const _Tabs();
  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  int index = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        for (final (i, label) in ['First', 'Second'].indexed)
          TabStage(
            active: index == i,
            child: ListView(
              key: PageStorageKey(label),
              children: [
                for (var row = 0; row < 40; row++)
                  SizedBox(height: 60, child: Text('$label $row')),
              ],
            ),
          ),
      ],
    ),
    bottomNavigationBar: Row(
      children: [
        TextButton(
          onPressed: () => setState(() => index = 0),
          child: const Text('Show first'),
        ),
        TextButton(
          onPressed: () => setState(() => index = 1),
          child: const Text('Show second'),
        ),
      ],
    ),
  );
}

double _opacity(WidgetTester tester, String text) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.text(text, skipOffstage: false),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

Widget _app({bool reduced = false}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: const _Tabs(),
);

void main() {
  testWidgets('every tab switch fades in, including revisits', (tester) async {
    await tester.pumpWidget(_app());
    expect(_opacity(tester, 'First 0'), 1);
    expect(find.text('Second 0'), findsNothing);

    for (final (button, label) in [
      ('Show second', 'Second 0'),
      ('Show first', 'First 0'),
      ('Show second', 'Second 0'),
    ]) {
      await tester.tap(find.text(button));
      await tester.pump();
      expect(find.text(label), findsOneWidget);
      expect(_opacity(tester, label), lessThan(0.1));
      await tester.pump(TabStage.duration ~/ 2);
      final halfway = _opacity(tester, label);
      expect(halfway, greaterThan(0.1));
      expect(halfway, lessThan(1));
      await tester.pumpAndSettle();
      expect(_opacity(tester, label), 1);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden tabs keep their scroll position', (tester) async {
    await tester.pumpWidget(_app());
    await tester.drag(find.text('First 0'), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('First 0'), findsNothing);
    final scrolled = tester.getRect(find.text('First 12'));

    await tester.tap(find.text('Show second'));
    await tester.pumpAndSettle();
    expect(find.text('First 12'), findsNothing);
    await tester.tap(find.text('Show first'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('First 12')), scrolled);
  });

  testWidgets('reduced motion shows the tab at once', (tester) async {
    await tester.pumpWidget(_app(reduced: true));
    await tester.tap(find.text('Show second'));
    await tester.pump();
    expect(_opacity(tester, 'Second 0'), 1);
    expect(find.text('First 0'), findsNothing);
  });
}
