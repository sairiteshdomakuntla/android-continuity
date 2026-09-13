import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bridge_app/screens/remote_screen.dart';
import 'package:bridge_app/theme/bridge_theme.dart';

/// RemoteScreen UI smoke tests: all three tabs must render their controls
/// at phone portrait sizes (and the media tab must also survive small and
/// landscape viewports). The background-service platform is registered
/// with its (mocked-channel) Android implementation so the fire-and-forget
/// remote-input senders no-op cleanly in tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    FlutterBackgroundServiceAndroid.registerWith();
  });

  // The plugin's channel uses a JSON codec — the mock must match it or
  // decoding throws "Message corrupted".
  const bgServiceChannel = MethodChannel(
    'id.flutter/background_service/android/method',
    JSONMethodCodec(),
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      bgServiceChannel,
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(bgServiceChannel, null);
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: BridgeTheme.light(),
        home: const RemoteScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  final mediaLabels = [
    'Play / Pause',
    'Previous',
    'Next',
    'Volume Up',
    'Volume Down',
    'Mute',
  ];

  Future<void> expectMediaControlsVisible(
    WidgetTester tester,
    Size screen,
  ) async {
    for (final label in mediaLabels) {
      expect(find.text(label), findsOneWidget, reason: '$label missing');
      final rect = tester.getRect(find.text(label));
      expect(rect.width, greaterThan(0), reason: '$label has zero width');
      expect(rect.height, greaterThan(0), reason: '$label has zero height');
      expect(rect.top, greaterThanOrEqualTo(0),
          reason: '$label clipped at top');
      expect(rect.bottom, lessThanOrEqualTo(screen.height),
          reason: '$label clipped at bottom (${rect.bottom} > ${screen.height})');
      expect(rect.left, greaterThanOrEqualTo(0),
          reason: '$label clipped at left');
      expect(rect.right, lessThanOrEqualTo(screen.width),
          reason: '$label clipped at right');
    }
    expect(find.text('PLAYBACK'), findsOneWidget);
    expect(find.text('VOLUME'), findsOneWidget);
  }

  testWidgets('trackpad tab shows its controls', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Sensitivity'), findsOneWidget);
    expect(find.text('Left Click'), findsOneWidget);
    expect(find.text('Right Click'), findsOneWidget);
    expect(find.text('Drag to move the cursor'), findsNothing);
    // Hint text exists but starts with the tap line now.
    expect(find.textContaining('Tap to click'), findsOneWidget);
  });

  testWidgets('media tab shows all six controls (390x844)', (tester) async {
    await pumpScreen(tester, size: const Size(390, 844));
    await tester.tap(find.text('Media'));
    await tester.pumpAndSettle();
    await expectMediaControlsVisible(tester, const Size(390, 844));

    // Tapping every button must not throw.
    for (final label in mediaLabels) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('media tab shows all six controls (small 360x640)', (tester) async {
    await pumpScreen(tester, size: const Size(360, 640));
    await tester.tap(find.text('Media'));
    await tester.pumpAndSettle();
    await expectMediaControlsVisible(tester, const Size(360, 640));
  });

  testWidgets('keyboard tab shows field + status + special keys',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Keyboard'));
    await tester.pumpAndSettle();

    expect(find.text('Type to send to PC…'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);

    // Typing streams characters and keeps the field cleared.
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);

    // Special-key icon buttons exist and tap without throwing.
    final iconButtons = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_KbIconButton',
    );
    expect(iconButtons, findsNWidgets(2));
    await tester.tap(iconButtons.at(0));
    await tester.pumpAndSettle();
    await tester.tap(iconButtons.at(1));
    await tester.pumpAndSettle();
  });

  testWidgets('cycling between all three tabs repeatedly', (tester) async {
    await pumpScreen(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Keyboard'));
      await tester.pumpAndSettle();
      expect(find.text('Type to send to PC…'), findsOneWidget);

      await tester.tap(find.text('Media'));
      await tester.pumpAndSettle();
      expect(find.text('Play / Pause'), findsOneWidget);

      await tester.tap(find.text('Trackpad'));
      await tester.pumpAndSettle();
      expect(find.text('Left Click'), findsOneWidget);
    }
  });
}
