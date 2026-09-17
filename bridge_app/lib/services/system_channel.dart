import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SystemChannel {
  SystemChannel._();
  static const _channel = MethodChannel('bridge/system');

  /// Checks whether Bridge is already exempt from battery optimization.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return res ?? false;
    } catch (e) {
      debugPrint('[SystemChannel] isIgnoringBatteryOptimizations error: $e');
      return true;
    }
  }

  /// Requests the user to exempt Bridge from battery optimization.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return res ?? false;
    } catch (e) {
      debugPrint('[SystemChannel] requestIgnoreBatteryOptimizations error: $e');
      return false;
    }
  }

  /// Checks if POST_NOTIFICATIONS runtime permission is granted on Android 13+.
  static Future<bool> isNotificationPermissionGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('isNotificationPermissionGranted');
      return res ?? true;
    } catch (e) {
      debugPrint('[SystemChannel] isNotificationPermissionGranted error: $e');
      return true;
    }
  }

  /// Prompts the user for runtime POST_NOTIFICATIONS permission on Android 13+.
  static Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('requestNotificationPermission');
      return res ?? true;
    } catch (e) {
      debugPrint('[SystemChannel] requestNotificationPermission error: $e');
      return true;
    }
  }

  /// Reads the native Android primary clip.
  /// Returns a Map with {"type": "text", "text": "..."} or
  /// {"type": "image", "uri": "...", "mimeType": "...", "bytes": Uint8List}, or null.
  static Future<Map<String, dynamic>?> getClipboard() async {
    if (!Platform.isAndroid) return null;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getClipboard');
      return res;
    } catch (e) {
      debugPrint('[SystemChannel] getClipboard error: $e');
      return null;
    }
  }

  /// Returns the latest screenshot from MediaStore (screenshots are saved as
  /// files, never to the clipboard, so they are queried explicitly).
  /// Returns {"type": "screenshot", "id": ..., "dateTakenMs": ..., "mimeType": ...,
  /// "path": ...}, {"needsPermission": true} when media access is missing, or null.
  static Future<Map<String, dynamic>?> getLatestScreenshot() async {
    if (!Platform.isAndroid) return null;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getLatestScreenshot');
      return res;
    } catch (e) {
      debugPrint('[SystemChannel] getLatestScreenshot error: $e');
      return null;
    }
  }

  /// Sets native Android clipboard content directly via ClipboardManager.setPrimaryClip().
  /// Safe to invoke from headless background service isolates without an active Activity.
  static Future<bool> setClipboard(String text) async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('setClipboard', {'text': text});
      return res ?? false;
    } catch (e) {
      debugPrint('[SystemChannel] setClipboard error: $e');
      return false;
    }
  }

  /// Writes an image file from disk to the Android clipboard via FileProvider URI.
  static Future<bool> setClipboardImage(String filePath) async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('setClipboardImage', {'path': filePath});
      return res ?? false;
    } catch (e) {
      debugPrint('[SystemChannel] setClipboardImage error: $e');
      return false;
    }
  }

  /// Returns the absolute path of the clipboard_images cache directory on Android.
  static Future<String?> getClipboardCacheDir() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getClipboardCacheDir');
    } catch (e) {
      debugPrint('[SystemChannel] getClipboardCacheDir error: $e');
      return null;
    }
  }

  /// One-shot battery read: {"level": 0-100, "isCharging": bool} or null.
  /// Backed by the sticky ACTION_BATTERY_CHANGED intent — no polling needed.
  static Future<Map<String, dynamic>?> getBatteryState() async {
    if (!Platform.isAndroid) return null;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getBatteryState');
      return res;
    } catch (e) {
      debugPrint('[SystemChannel] getBatteryState error: $e');
      return null;
    }
  }

  /// Registers a callback for native battery-change events (forwarded from
  /// the ACTION_BATTERY_CHANGED receiver registered in the plugin).
  /// The background isolate uses this for throttled battery-update emits.
  static void setBatteryListener(void Function(Map<String, dynamic> state) onEvent) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onBatteryChanged') {
        try {
          final map = Map<String, dynamic>.from(call.arguments as Map);
          onEvent(map);
        } catch (e) {
          debugPrint('[SystemChannel] Error parsing onBatteryChanged: $e');
        }
      }
    });
  }

  /// Starts the find-my-phone ringtone at max alarm volume (works on silent).
  /// Returns true if the ring actually started.
  static Future<bool> startRing() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('startRing');
      return res ?? false;
    } catch (e) {
      debugPrint('[SystemChannel] startRing error: $e');
      return false;
    }
  }

  /// Stops the find-my-phone ringtone immediately.
  static Future<bool> stopRing() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('stopRing');
      return res ?? false;
    } catch (e) {
      debugPrint('[SystemChannel] stopRing error: $e');
      return false;
    }
  }
}
