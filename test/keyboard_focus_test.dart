import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_music/keyboard_focus.dart';

void main() {
  testWidgets(
    'hiding the keyboard clears search focus and permits focusing again',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => KeyboardDismissFocus(child: child!),
          home: Scaffold(body: TextField(focusNode: focus)),
        ),
      );
      await tester.tap(find.byType(TextField));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
