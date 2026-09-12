import 'package:flutter/services.dart';

/// UI-isolate (or background-isolate) trigger that asks the native side to
/// re-render the home-screen clipboard widget from the snapshot file.
///
/// The channel is served by the `bridge_core` plugin, which registers on
/// every Flutter engine — so this works from both the UI isolate and the
/// `flutter_background_service` isolate.
class WidgetChannel {
  WidgetChannel._();

  static const _channel = MethodChannel('bridge/widget');

  static Future<void> updateWidget() async {
    try {
      await _channel.invokeMethod('updateWidget');
    } catch (e) {
      // Widget updates are best-effort; never break sync flows.
    }
  }
}
