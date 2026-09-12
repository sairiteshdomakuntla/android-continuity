import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'event_dedupe.dart';
import 'background_service.dart';
import 'clipboard_history_service.dart';
import 'system_channel.dart';

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
  String _lastSyncedImageHash = '';

  void init() {
    WidgetsBinding.instance.addObserver(this);

    // Initialize clipboard history storage
    ClipboardHistoryService.instance.init();

    final service = FlutterBackgroundService();

    // Listen for incoming text clipboard messages forwarded from background service isolate
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
        _lastSyncedImageHash = '';

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

    // Listen for incoming image clipboard notifications forwarded from background service isolate
    service.on('clipboard_image_received').listen((event) async {
      if (event == null) return;
      final imagePath = event['imagePath'] as String?;
      final origin = event['origin'] as String? ?? 'windows';
      final transferId = event['transferId'] as String?;

      if (imagePath != null && imagePath.isNotEmpty) {
        markImageAsSynced(imagePath);
        await ClipboardHistoryService.instance.addImageEntry(
          imagePath: imagePath,
          origin: origin,
          id: transferId,
        );
      }
    });

    debugPrint('[ClipboardService] Initialized — rich clipboard sync active on resume');
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
    _lastSyncedImageHash = '';
  }

  /// Marks an image as already synced (by file path or hash) so resume sync does not echo it back.
  void markImageAsSynced(String imagePathOrHash) {
    try {
      final file = File(imagePathOrHash);
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        _lastSyncedImageHash = sha256.convert(bytes).toString();
      } else {
        _lastSyncedImageHash = imagePathOrHash;
      }
    } catch (_) {
      _lastSyncedImageHash = imagePathOrHash;
    }
    _lastSyncedText = '';
  }

  /// Called when user taps "Sync Clipboard Now" or when resuming.
  /// Reads Android clipboard (image or text); if new or forced, pushes to Windows.
  Future<SyncDirectionResult> syncNow({bool force = false}) async {
    Map<String, dynamic>? clipData;
    try {
      clipData = await SystemChannel.getClipboard();
    } catch (e) {
      debugPrint('[ClipboardService] Error reading SystemChannel clipboard: $e');
    }

    // 1. Handle image clipboard content
    if (clipData != null && clipData['type'] == 'image') {
      final bytes = clipData['bytes'] as Uint8List?;
      final mimeType = clipData['mimeType'] as String? ?? 'image/png';
      final path = clipData['path'] as String?;

      if (bytes != null && bytes.isNotEmpty) {
        final hash = sha256.convert(bytes).toString();
        if (!force && hash == _lastSyncedImageHash) {
          debugPrint('[ClipboardService] Clipboard image already in sync with Windows');
          return SyncDirectionResult.upToDate;
        }

        _lastSyncedImageHash = hash;
        _lastSyncedText = '';

        if (path != null && path.isNotEmpty) {
          await ClipboardHistoryService.instance.addImageEntry(
            imagePath: path,
            origin: 'android',
          );
        }

        debugPrint('[ClipboardService] [SEND] Routing Android clipboard image to Windows: ${bytes.length} bytes');
        BackgroundService.sendClipboardImage(bytes, mimeType: mimeType);
        return SyncDirectionResult.sentToWindows;
      }
    }

    // 2. Handle text clipboard content
    String localText = '';
    if (clipData != null && clipData['type'] == 'text') {
      localText = (clipData['text'] as String?) ?? '';
    }
    if (localText.isEmpty) {
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        localText = data?.text ?? '';
      } catch (e) {
        debugPrint('[ClipboardService] Error reading Flutter clipboard: $e');
      }
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
    _lastSyncedImageHash = '';
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
