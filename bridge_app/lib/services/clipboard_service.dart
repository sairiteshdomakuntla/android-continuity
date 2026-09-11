import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'event_dedupe.dart';
import 'background_service.dart';

/// Foreground-only clipboard sync.
///
/// Registers as a [WidgetsBindingObserver] and reads the clipboard whenever
/// the app transitions to [AppLifecycleState.resumed]. Android 10+ only
/// allows clipboard reads while the UID owns the focused window.
///
/// Communicates with the background service isolate to send clipboard data to Windows.
class ClipboardService with WidgetsBindingObserver {
  ClipboardService._();
  static final ClipboardService instance = ClipboardService._();

  final _dedupe = EventDedupe();
  String _lastSyncedText = '';

  void init() {
    WidgetsBinding.instance.addObserver(this);

    // Listen for incoming clipboard messages forwarded from background service isolate
    final service = FlutterBackgroundService();
    service.on('clipboard_received').listen((event) {
      if (event == null) return;
      final eventId = event['eventId'] as String?;
      final text = event['text'] as String?;
      if (eventId != null) _dedupe.add(eventId);
      if (text != null) _lastSyncedText = text;
    });

    debugPrint('[ClipboardService] Initialized — will sync clipboard on each resume via BackgroundService');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncOnResume();
    }
  }

  /// Called once when the app first launches, or when user taps "Sync Clipboard Now".
  Future<void> syncNow({bool force = false}) async {
    await _syncOnResume(force: force);
  }

  Future<void> _syncOnResume({bool force = false}) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';

    if (text.isEmpty) return;
    if (!force && text == _lastSyncedText) return;

    _lastSyncedText = text;
    debugPrint('[ClipboardService] [SEND] Routing clipboard to BackgroundService — "${text.length > 60 ? '${text.substring(0, 60)}…' : text}"');
    BackgroundService.sendClipboard(text);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}
