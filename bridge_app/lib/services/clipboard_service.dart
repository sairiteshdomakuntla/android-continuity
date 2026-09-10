import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import '../models/bridge_message.dart';
import 'event_dedupe.dart';
import 'socket_service.dart';

/// Foreground-only clipboard sync.
///
/// Registers as a [WidgetsBindingObserver] and reads the clipboard whenever
/// the app transitions to [AppLifecycleState.resumed]. Android 10+ only
/// allows clipboard reads while the UID owns the focused window — this
/// lifecycle hook guarantees that condition is met.
///
/// If the socket is not yet connected when a new clipboard value is detected,
/// the text is kept in [_pendingText]. As soon as the socket reports connected,
/// [_flushPending] re-reads the clipboard and sends whatever is there.
///
/// See DECISIONS.md ADR-001 for the full technical reasoning.
class ClipboardService with WidgetsBindingObserver {
  ClipboardService._();
  static final ClipboardService instance = ClipboardService._();

  final _dedupe = EventDedupe();
  final _uuid = const Uuid();
  String _lastSyncedText = '';

  /// Non-empty when we detected a new clipboard value but couldn't send it
  /// because the socket wasn't connected yet. Flushed on next connect.
  String _pendingText = '';

  void init() {
    WidgetsBinding.instance.addObserver(this);

    // Listen for incoming clipboard messages from Windows
    SocketService.instance.onMessage(MessageType.clipboard, _handleIncoming);

    // When the socket connects (or reconnects), flush any pending clipboard text.
    SocketService.instance.connected.addListener(_onConnectionChanged);

    debugPrint('[ClipboardService] Initialized — will sync clipboard on each resume');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SocketService.instance.ensureConnected();
      _syncOnResume();
    }
  }

  /// Called once when the app first launches, or when user taps "Sync Clipboard Now".
  Future<void> syncNow({bool force = false}) async {
    await SocketService.instance.ensureConnected();
    await _syncOnResume(force: force);
  }

  // ── Connection-aware flush ─────────────────────────────────────────────

  void _onConnectionChanged() {
    if (SocketService.instance.connected.value) {
      // Socket just connected/reconnected — flush pending clipboard text.
      _flushPending();
    }
  }

  Future<void> _flushPending() async {
    final textToSend = _pendingText;
    _pendingText = '';
    if (textToSend.isEmpty) return;

    // Re-read actual clipboard: prefer fresher clipboard value if non-empty
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final currentText = data?.text ?? '';
    final toSend = (currentText.isNotEmpty && currentText != _lastSyncedText)
        ? currentText
        : textToSend;

    debugPrint('[ClipboardService] Socket connected — flushing pending clipboard text');
    _sendClipboard(toSend);
  }

  // ── Core send logic ────────────────────────────────────────────────────

  Future<void> _syncOnResume({bool force = false}) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';

    if (text.isEmpty) return;
    if (!force && text == _lastSyncedText) return;

    if (!SocketService.instance.isConnected) {
      // Save for when the socket comes up; connection listener will flush.
      debugPrint('[ClipboardService] Not connected yet — queuing clipboard text for next connect');
      _pendingText = text;
      SocketService.instance.ensureConnected();
      return;
    }

    _pendingText = '';
    _sendClipboard(text);
  }

  void _sendClipboard(String text) {
    final eventId = _uuid.v4();
    _lastSyncedText = text;
    _dedupe.add(eventId);

    final msg = BridgeMessage(
      eventId: eventId,
      type: MessageType.clipboard,
      origin: Origin.android,
      timestamp: DateTime.now().toUtc().toIso8601String(),
      payload: {'text': text},
    );

    debugPrint('[ClipboardService] [SEND] [clipboard] $eventId — "${text.length > 60 ? '${text.substring(0, 60)}…' : text}"');
    SocketService.instance.emit(msg);
  }

  // ── Incoming from Windows ──────────────────────────────────────────────

  void _handleIncoming(BridgeMessage msg) {
    if (_dedupe.has(msg.eventId)) {
      debugPrint('[ClipboardService] Dedupe suppressed echo for ${msg.eventId}');
      return;
    }

    final text = msg.payload['text'] as String? ?? '';
    if (text.isEmpty) return;

    // Write to Android clipboard and mark as synced so resume doesn't echo back
    Clipboard.setData(ClipboardData(text: text));
    _lastSyncedText = text;
    _pendingText = ''; // incoming supersedes any pending outgoing text
    _dedupe.add(msg.eventId);

    debugPrint('[ClipboardService] Written to Android clipboard: "${text.length > 60 ? '${text.substring(0, 60)}…' : text}"');
  }

  void dispose() {
    SocketService.instance.connected.removeListener(_onConnectionChanged);
    WidgetsBinding.instance.removeObserver(this);
  }
}
