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
}
