import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'background_service.dart';

/// "Phone as Remote" — stage 1 (trackpad).
///
/// UI-isolate half of the remote-input feature:
///   • Sends remote-input events (mouse-move / mouse-click / scroll /
///     set-sensitivity / key-input / key-special / media-command) to
///     Windows through the background service's persistent socket.
///   • Receives [event: 'open-remote'] from Windows (via BackgroundService
///     cross-isolate signal) and exposes it as [onOpenRemoteRequested].
///
/// Pointer events are throttled to ~60 Hz by [RemoteScreen]; each payload
/// carries the summed delta since the previous flush.
class RemoteInputService {
  RemoteInputService._();
  static final RemoteInputService instance = RemoteInputService._();

  /// Invoked when Windows asks the phone to open the Remote screen.
  VoidCallback? onOpenRemoteRequested;

  /// Call once at app start to register the remote-input message handler
  /// forwarded from the background service isolate.
  void init() {
    final service = FlutterBackgroundService();
    service.on('remote_input_received').listen((event) {
      if (event == null) return;
      final rawPayload = event['payload'];
      if (rawPayload == null) return;
      final payload = Map<String, dynamic>.from(rawPayload as Map);

      final type = payload['event'] as String?;
      debugPrint('[RemoteInputService] Received remote-input event: $type');
      if (type == 'open-remote') {
        onOpenRemoteRequested?.call();
      }
    });
    debugPrint('[RemoteInputService] Initialized — listening for remote_input_received from BackgroundService');
  }

  // ── Senders ────────────────────────────────────────────────────────────────

  // Sub-pixel remainders: pointer deltas are fractional; the wire carries
  // integers. Keeping the remainder here prevents slow drift over long drags
  // (Windows applies its own float sensitivity scaling on top).
  double _moveRemX = 0;
  double _moveRemY = 0;

  /// Relative cursor movement (logical px deltas, already throttled+summed).
  void sendMouseMove(double dx, double dy) {
    final tx = dx + _moveRemX;
    final ty = dy + _moveRemY;
    final ix = tx.round();
    final iy = ty.round();
    _moveRemX = tx - ix;
    _moveRemY = ty - iy;
    if (ix == 0 && iy == 0) return;
    _send({'event': 'mouse-move', 'dx': ix, 'dy': iy});
  }

  /// Single click of [button] ('left' or 'right').
  void sendMouseClick(String button) {
    _send({'event': 'mouse-click', 'button': button});
  }

  /// Vertical scroll. Positive [dy] = fingers moved down. The host applies
  /// natural (laptop-style) scrolling: fingers down scrolls content up.
  /// Fractional deltas are sent as-is; the host converts them into
  /// high-resolution wheel units for smooth (sub-notch) scrolling.
  void sendScroll(double dy) {
    if (dy == 0) return;
    _send({'event': 'scroll', 'dy': dy});
  }

  /// Cursor-movement sensitivity multiplier. Affects mouse moves only —
  /// never scroll speed or clicks. Sent when the Remote screen opens,
  /// whenever the slider changes, and after a reconnect.
  void sendSensitivity(double value) {
    _send({'event': 'set-sensitivity', 'value': value});
  }

  /// Typed text from the keyboard tab — usually one character per
  /// keystroke, streamed as typed into whatever window has focus on PC.
  void sendKeyInput(String text) {
    if (text.isEmpty) return;
    _send({'event': 'key-input', 'text': text});
  }

  /// Non-character key tap: 'enter', 'backspace', or 'space'.
  void sendKeySpecial(String key) {
    _send({'event': 'key-special', 'key': key});
  }

  /// Media command: 'play-pause', 'next', 'previous', 'volume-up',
  /// 'volume-down', or 'mute'. Applies to the app with media focus on PC.
  void sendMediaCommand(String command) {
    _send({'event': 'media-command', 'command': command});
  }

  void _send(Map<String, dynamic> payload) {
    BackgroundService.sendRemoteInput(payload);
  }
}
