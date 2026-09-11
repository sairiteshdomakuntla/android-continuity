import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'event_dedupe.dart';
import 'background_service.dart';
import 'clipboard_history_service.dart';

enum SyncDirectionResult {
  sentToWindows,
  upToDate,
  pulledFromWindows,
}

/// Foreground-only clipboard sync and UI coordinator.
///
/// Registers as a [WidgetsBindingObserver] and reads the clipboard whenever
/// the app transitions to [AppLifecycleState.resumed]. Android 10+ only
/// allows clipboard reads while the UID owns the focused window.
///
/// Communicates with the background service isolate to send and receive clipboard data.
class ClipboardService with WidgetsBindingObserver {
  ClipboardService._();
  static final ClipboardService instance = ClipboardService._();

  final _dedupe = EventDedupe();
  String _lastSyncedText = '';

  void init() {
    WidgetsBinding.instance.addObserver(this);

    // Initialize clipboard history storage
    ClipboardHistoryService.instance.init();

    final service = FlutterBackgroundService();

    // Listen for incoming clipboard messages forwarded from background service isolate
    service.on('clipboard_received').listen((event) async {
      if (event == null) return;
      final eventId = event['eventId'] as String?;
      final text = event['text'] as String?;
      final origin = event['origin'] as String? ?? 'windows';
      final timestampStr = event['timestamp'] as String?;
      final timestamp = timestampStr != null ? DateTime.tryParse(timestampStr) : null;

      if (eventId != null) _dedupe.add(eventId);
      if (text != null && text.isNotEmpty) {
        _lastSyncedText = text;

        // Apply to Android clipboard in UI isolate (active window)
        try {
          await Clipboard.setData(ClipboardData(text: text));
          debugPrint('[ClipboardService] UI isolate Clipboard.setData applied: "${text.length > 40 ? '${text.substring(0, 40)}…' : text}"');
        } catch (e) {
          debugPrint('[ClipboardService] UI isolate Clipboard.setData error: $e');
        }

        // Add to history
        await ClipboardHistoryService.instance.addEntry(
          text,
          origin,
          id: eventId,
          timestamp: timestamp,
        );
      }
    });

    debugPrint('[ClipboardService] Initialized — will sync Android clipboard on each resume via BackgroundService');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncOnResume();
    }
  }

  /// Marks text as already synced so resume sync does not echo it back.
  void markAsSynced(String text) {
    _lastSyncedText = text;
  }

  /// Called when user taps "Sync Clipboard Now" or when resuming.
  /// Reads Android clipboard; if new or forced, pushes to Windows.
  Future<SyncDirectionResult> syncNow({bool force = false}) async {
    String localText = '';
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      localText = data?.text ?? '';
    } catch (e) {
      debugPrint('[ClipboardService] Error reading local clipboard: $e');
    }

    if (localText.isEmpty) {
      debugPrint('[ClipboardService] Local clipboard is empty');
      return SyncDirectionResult.upToDate;
    }

    if (!force && localText == _lastSyncedText) {
      debugPrint('[ClipboardService] Clipboard already in sync with Windows ("${localText.length > 40 ? '${localText.substring(0, 40)}…' : localText}")');
      return SyncDirectionResult.upToDate;
    }

    _lastSyncedText = localText;
    debugPrint('[ClipboardService] [SEND] Routing Android clipboard to Windows: "${localText.length > 60 ? '${localText.substring(0, 60)}…' : localText}"');
    BackgroundService.sendClipboard(localText);
    await ClipboardHistoryService.instance.addEntry(localText, 'android');
    return SyncDirectionResult.sentToWindows;
  }

  Future<void> _syncOnResume({bool force = false}) async {
    debugPrint('[ClipboardService] App resumed — checking if new content was copied on Android');
    await syncNow(force: force);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}
