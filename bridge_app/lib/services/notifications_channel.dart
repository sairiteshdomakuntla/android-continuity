import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NotificationsChannel {
  NotificationsChannel._();
  static const _channel = MethodChannel('bridge/notifications');

  /// Checks whether Bridge has been granted Notification Access in Android Settings.
  static Future<bool> isNotificationAccessGranted() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isNotificationAccessGranted');
      return res ?? false;
    } catch (e) {
      debugPrint('[NotificationsChannel] isNotificationAccessGranted error: $e');
      return false;
    }
  }

  /// Opens the Android system Notification Access settings page.
  static Future<bool> requestNotificationAccess() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('requestNotificationAccess');
      return res ?? false;
    } catch (e) {
      debugPrint('[NotificationsChannel] requestNotificationAccess error: $e');
      return false;
    }
  }

  /// Triggers a Direct Reply (RemoteInput) on the active notification.
  /// Returns false if the PendingIntent was canceled or failed.
  static Future<bool> sendReply(String notificationId, String replyText) async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('sendReply', {
        'notificationId': notificationId,
        'replyText': replyText,
      });
      return res ?? false;
    } catch (e) {
      debugPrint('[NotificationsChannel] sendReply error: $e');
      return false;
    }
  }

  /// Cancels / dismisses the notification from the Android status bar.
  static Future<bool> dismissNotification(String notificationId) async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod<bool>('dismissNotification', {
        'notificationId': notificationId,
      });
      return res ?? false;
    } catch (e) {
      debugPrint('[NotificationsChannel] dismissNotification error: $e');
      return false;
    }
  }

  /// Registers a callback invoked whenever native Android posts or removes a notification.
  static void setEventListener(void Function(Map<String, dynamic> event) onEvent) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationEvent') {
        try {
          final map = Map<String, dynamic>.from(call.arguments as Map);
          onEvent(map);
        } catch (e) {
          debugPrint('[NotificationsChannel] Error parsing onNotificationEvent: $e');
        }
      }
    });
  }
}
