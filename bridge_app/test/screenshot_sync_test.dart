import 'package:flutter_test/flutter_test.dart';
import 'package:bridge_app/services/clipboard_service.dart';

void main() {
  group('shouldSendScreenshot', () {
    const now = 1700000000000;

    test('already-synced id is not resent', () {
      expect(
        shouldSendScreenshot(
          storedId: '42',
          shotId: '42',
          dateTakenMs: now - 1000,
          nowMs: now,
        ),
        isFalse,
      );
    });

    test('empty shot id never sends', () {
      expect(
        shouldSendScreenshot(
          storedId: null,
          shotId: '',
          dateTakenMs: now - 1000,
          nowMs: now,
        ),
        isFalse,
      );
    });

    test('first run sends a freshly taken screenshot', () {
      expect(
        shouldSendScreenshot(
          storedId: null,
          shotId: '7',
          dateTakenMs: now - 5 * 60 * 1000,
          nowMs: now,
        ),
        isTrue,
      );
    });

    test('first run baselines an old screenshot instead of sending', () {
      expect(
        shouldSendScreenshot(
          storedId: null,
          shotId: '7',
          dateTakenMs: now - 2 * 24 * 60 * 60 * 1000,
          nowMs: now,
        ),
        isFalse,
      );
    });

    test('first run with unknown capture date baselines', () {
      expect(
        shouldSendScreenshot(
          storedId: null,
          shotId: '7',
          dateTakenMs: 0,
          nowMs: now,
        ),
        isFalse,
      );
    });

    test('new id after baseline always sends', () {
      expect(
        shouldSendScreenshot(
          storedId: '7',
          shotId: '8',
          dateTakenMs: now - 2 * 24 * 60 * 60 * 1000,
          nowMs: now,
        ),
        isTrue,
      );
    });
  });
}
