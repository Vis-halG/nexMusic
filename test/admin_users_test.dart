import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nex_music/admin_users.dart';
import 'package:nex_music/music_controller.dart';
import 'package:nex_music/music_ui.dart';
import 'music_discovery_test.dart' show FakeMusicProvider;

class AdminController extends MusicController {
  AdminController(super.preferences, this.admin)
    : super(musicProviders: [FakeMusicProvider('jiosaavn', [])]);
  bool admin, blocked = false;
  final actions = <Map<String, dynamic>>[];
  @override
  bool get isAdmin => admin;
  @override
  Future<Map<String, dynamic>> adminRequest(
    String route, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
  }) async {
    if (body != null) {
      actions.add(body);
      blocked = body['blocked'] == true;
      return body;
    }
    return {
      'nextPageToken': '',
      'users': [
        {
          'uid': 'owner',
          'name': 'Administrator',
          'email': nexMusicAdminEmail,
          'protected': true,
        },
        {
          'uid': 'listener',
          'name': 'Listener',
          'email': 'listener@example.com',
          'online': !blocked,
          'signedIn': !blocked,
          'blocked': blocked,
          'signInDisabled': blocked,
          'lastLogin': 1800000000000,
        },
      ],
    };
  }
}

void main() {
  test('only the exact verified admin email grants the local role', () {
    expect(isNexMusicAdmin('Vishalgupta25980@gmail.com', verified: true), true);
    expect(isNexMusicAdmin(nexMusicAdminEmail, verified: false), false);
    expect(
      isNexMusicAdmin('vishalgupta25989@gmail.com', verified: true),
      false,
    );
    expect(
      isNexMusicAdmin(
        'vishalgupta25980@gmail.com.attacker.test',
        verified: true,
      ),
      false,
    );
  });
  testWidgets(
    'admin can inspect accounts, confirm block, unblock, and loses access after account change',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = AdminController(
        await SharedPreferences.getInstance(),
        true,
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<MusicController>.value(
          value: controller,
          child: const MaterialApp(home: AdminUsersScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final email = find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == 'listener@example.com',
      );
      expect(email, findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
      await tester.tap(find.text('Block'));
      await tester.pumpAndSettle();
      expect(controller.actions, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();
      expect(controller.actions.single, {'uid': 'listener', 'blocked': true});
      await tester.tap(find.text('Unblock'));
      await tester.pumpAndSettle();
      expect(controller.actions.last['blocked'], false);
      controller.admin = false;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Administrator access required.'), findsOneWidget);
      expect(email, findsNothing);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
