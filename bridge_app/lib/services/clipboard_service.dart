import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'event_dedupe.dart';
import 'background_service.dart';
import 'clipboard_history_service.dart';
import 'system_channel.dart';

enum SyncDirectionResult {
  sentToWindows,
  upToDate,
  pulledFromWindows,
}

/// Decides whether an unseen screenshot should be pushed to Windows.
///
/// Screenshots never land in the clipboard, so Bridge tracks the last synced
/// MediaStore row ID instead of content hashes. The very first check only
/// establishes a silent baseline — unless the screenshot is fresh (taken
/// within [freshWindow]) — so installing Bridge doesn't blast an old
/// screenshot to the PC on first sync.
bool shouldSendScreenshot({
  required String? storedId,
  required String shotId,
  required int dateTakenMs,
  required int nowMs,
  Duration freshWindow = const Duration(minutes: 10),
}) {
  if (shotId.isEmpty || shotId == storedId) return false;
  if (storedId == null) {
    return dateTakenMs > 0 && (nowMs - dateTakenMs) <= freshWindow.inMilliseconds;
  }
  return true;
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

  /// Synchronous in-memory guard: two overlapping syncNow calls (double
  /// resume events) must not stream the same screenshot twice. Set before
  /// the first await so the second call sees it on the same event loop.
  bool _screenshotCheckInFlight = false;

  /// Full-method mutex: prevents concurrent syncNow calls from racing past
  /// hash/ID guards. Multiple resume events can fire in rapid succession.
  bool _syncInFlight = false;

  static const _storage = FlutterSecureStorage();
  static const _keyLastScreenshotId = 'screenshot_last_id';

  /// Set when the user dismisses the screenshot-permission rationale so Sync
  /// Now doesn't nag every tap (session-only; asked again on next launch).
  static bool screenshotRationaleDismissed = false;

  /// True when Bridge may read screenshots (READ_MEDIA_IMAGES / storage).
  /// Silent status check — never prompts; call [requestScreenshotAccess] for that.
  static Future<bool> isScreenshotAccessGranted() async {
    if (!Platform.isAndroid) return false;
    try {
      if (await Permission.photos.status.isGranted) return true;
      return await Permission.storage.status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Requests media access for screenshot sync. Callers should show a
  /// rationale dialog first (see BridgeHome._ensureScreenshotAccess).
  static Future<bool> requestScreenshotAccess() async {
    if (!Platform.isAndroid) return false;
    try {
      var status = await Permission.photos.request();
      if (status.isGranted) return true;
      status = await Permission.storage.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

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

    // Trampoline "Sync Now": the background isolate pushed clipboard text
    // read under transient window focus. Mark synced (resume echo guard)
    // and reload the history entry it wrote (background isolate is the
    // single writer here, same as the foreground send path's addEntry).
    service.on('clipboard_sent').listen((event) async {
      if (event == null) return;
      final text = event['text'] as String?;
      if (text == null || text.isEmpty) return;
      markAsSynced(text);
      try {
        await ClipboardHistoryService.instance.load();
        debugPrint('[ClipboardService] Trampoline push applied: "${text.length > 40 ? '${text.substring(0, 40)}…' : text}"');
      } catch (e) {
        debugPrint('[ClipboardService] clipboard_sent load error: $e');
      }
    });

    // Listen for incoming image clipboard notifications forwarded from background service isolate.
    // The background isolate's FileTransferService already persisted the entry
    // to storage, so we only reload (to pick up the new item) and mark the
    // image as synced to prevent resume-sync from echoing it back.
    service.on('clipboard_image_received').listen((event) async {
      if (event == null) return;
      final imagePath = event['imagePath'] as String?;

      if (imagePath != null && imagePath.isNotEmpty) {
        markImageAsSynced(imagePath);
        await ClipboardHistoryService.instance.load();
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
  /// Screenshots are checked first: they never reach the clipboard, so the
  /// latest unseen MediaStore screenshot is pushed as a clipboard image.
  Future<SyncDirectionResult> syncNow({bool force = false}) async {
    if (_syncInFlight) {
      debugPrint('[ClipboardService] syncNow already in flight — skipping concurrent call');
      return SyncDirectionResult.upToDate;
    }
    _syncInFlight = true;
    try {
      return await _syncNowInner(force: force);
    } finally {
      _syncInFlight = false;
    }
  }

  Future<SyncDirectionResult> _syncNowInner({bool force = false}) async {
    // 0. New screenshot? (silent — only runs when media permission is granted)
    if (_screenshotCheckInFlight) {
      debugPrint('[ClipboardService] Screenshot check already in flight — skipping duplicate');
    } else if (await isScreenshotAccessGranted()) {
      _screenshotCheckInFlight = true;
      try {
        final shot = await SystemChannel.getLatestScreenshot();
        if (shot != null && shot['needsPermission'] != true) {
          final shotId = shot['id'] as String? ?? '';
          final dateTakenMs = (shot['dateTakenMs'] as int?) ?? 0;
          final shotPath = shot['path'] as String?;
          final mimeType = shot['mimeType'] as String? ?? 'image/png';
          final storedId = await _storage.read(key: _keyLastScreenshotId);
          final nowMs = DateTime.now().millisecondsSinceEpoch;

          if (shouldSendScreenshot(
            storedId: storedId,
            shotId: shotId,
            dateTakenMs: dateTakenMs,
            nowMs: nowMs,
          )) {
            if (shotPath != null && shotPath.isNotEmpty) {
              final file = File(shotPath);
              if (await file.exists()) {
                final bytes = await file.readAsBytes();
                if (bytes.isNotEmpty) {
                  final hash = sha256.convert(bytes).toString();
                  _lastSyncedImageHash = hash;
                  _lastSyncedText = '';
                  await _storage.write(key: _keyLastScreenshotId, value: shotId);
                  await ClipboardHistoryService.instance.addImageEntry(
                    imagePath: shotPath,
                    origin: 'android',
                  );
                  debugPrint('[ClipboardService] [SEND] Routing Android screenshot to Windows: ${bytes.length} bytes');
                  BackgroundService.sendClipboardImage(
                    Uint8List.fromList(bytes),
                    mimeType: mimeType,
                  );
                  return SyncDirectionResult.sentToWindows;
                }
              }
            }
            // Unreadable screenshot: record it so we don't retry every resume.
            if (shotId.isNotEmpty) {
              await _storage.write(key: _keyLastScreenshotId, value: shotId);
            }
          } else if (storedId == null && shotId.isNotEmpty) {
            // First run with an old screenshot around: silent baseline, don't send.
            await _storage.write(key: _keyLastScreenshotId, value: shotId);
          }
        }
      } catch (e) {
        debugPrint('[ClipboardService] Screenshot check error: $e');
      } finally {
        _screenshotCheckInFlight = false;
      }
    }

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
