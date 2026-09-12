import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Max retained notifications — same cap as clipboard history.
const int kMaxNotificationHistory = 20;
const String _kStorageKey = 'notification_history';

/// A phone notification mirrored for the Notifications tab.
/// Shape follows the `posted` payload from PROTOCOL.md.
class NotificationHistoryItem {
  final String notificationId;
  final String packageName;
  final String appName;
  final String title;
  final String text;
  final DateTime timestamp;
  final bool hasReplyAction;
  final String? replyError;

  const NotificationHistoryItem({
    required this.notificationId,
    this.packageName = '',
    this.appName = 'Phone',
    this.title = '',
    this.text = '',
    required this.timestamp,
    this.hasReplyAction = false,
    this.replyError,
  });

  NotificationHistoryItem copyWith({String? replyError, bool clearError = false}) {
    return NotificationHistoryItem(
      notificationId: notificationId,
      packageName: packageName,
      appName: appName,
      title: title,
      text: text,
      timestamp: timestamp,
      hasReplyAction: hasReplyAction,
      replyError: clearError ? null : (replyError ?? this.replyError),
    );
  }

  Map<String, dynamic> toJson() => {
        'notificationId': notificationId,
        'packageName': packageName,
        'appName': appName,
        'title': title,
        'text': text,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'hasReplyAction': hasReplyAction,
        'replyError': replyError,
      };

  factory NotificationHistoryItem.fromJson(Map<String, dynamic> json) {
    final ts = json['timestamp'] as String?;
    return NotificationHistoryItem(
      notificationId: json['notificationId'] as String? ?? '',
      packageName: json['packageName'] as String? ?? '',
      appName: json['appName'] as String? ?? 'Phone',
      title: json['title'] as String? ?? '',
      text: json['text'] as String? ?? '',
      timestamp: ts != null
          ? DateTime.tryParse(ts)?.toLocal() ?? DateTime.now()
          : DateTime.now(),
      hasReplyAction: json['hasReplyAction'] as bool? ?? false,
      replyError: json['replyError'] as String?,
    );
  }

  /// Builds an item from a native listener `posted` event map.
  factory NotificationHistoryItem.fromEvent(Map<String, dynamic> event) {
    final ts = event['timestamp'] as String?;
    return NotificationHistoryItem(
      notificationId: event['notificationId'] as String? ?? '',
      packageName: event['packageName'] as String? ?? '',
      appName: event['appName'] as String? ?? 'Phone',
      title: event['title'] as String? ?? '',
      text: event['text'] as String? ?? '',
      timestamp: ts != null
          ? DateTime.tryParse(ts)?.toLocal() ?? DateTime.now()
          : DateTime.now(),
      hasReplyAction: event['hasReplyAction'] as bool? ?? false,
    );
  }
}

/// UI-isolate mirror of recent phone notifications, persisted to secure
/// storage with the same pattern as [ClipboardHistoryService]: 20-item cap,
/// persist on every mutation, oldest pruned on overflow.
///
/// Fed by `notification_posted` / `notification_dismissed` invokes from the
/// background isolate (which in turn receives native listener events).
/// Reply/dismiss actions still go through [NotificationsChannel] — this
/// service only stores what the tab displays.
class NotificationHistoryService {
  NotificationHistoryService._();
  static final NotificationHistoryService instance =
      NotificationHistoryService._();

  final _storage = const FlutterSecureStorage();
  final ValueNotifier<List<NotificationHistoryItem>> items =
      ValueNotifier([]);
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await load();

    final service = FlutterBackgroundService();
    service.on('notification_posted').listen((event) async {
      if (event == null) return;
      try {
        final item = NotificationHistoryItem.fromEvent(
            Map<String, dynamic>.from(event as Map));
        if (item.notificationId.isEmpty) return;
        await upsert(item);
      } catch (e) {
        debugPrint('[NotificationHistory] Bad posted event: $e');
      }
    });

    service.on('notification_dismissed').listen((event) async {
      if (event == null) return;
      final id = (event as Map)['notificationId'] as String?;
      if (id != null && id.isNotEmpty) {
        await remove(id);
      }
    });

    debugPrint('[NotificationHistory] Initialized');
  }

  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _kStorageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final parsed = decoded
            .map((e) => NotificationHistoryItem.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .where((i) => i.notificationId.isNotEmpty)
            .take(kMaxNotificationHistory)
            .toList();
        items.value = List.unmodifiable(parsed);
        debugPrint(
            '[NotificationHistory] Loaded ${parsed.length} items from storage');
      }
    } catch (e) {
      debugPrint('[NotificationHistory] Error loading history: $e');
    }
  }

  /// Inserts or refreshes an item: same-id re-posts (Android updates a
  /// notification in place) replace the old entry and move to the top.
  Future<void> upsert(NotificationHistoryItem item) async {
    final current =
        List<NotificationHistoryItem>.from(items.value);
    current.removeWhere((i) => i.notificationId == item.notificationId);
    current.insert(0, item);
    final capped = current.take(kMaxNotificationHistory).toList();
    items.value = List.unmodifiable(capped);
    await _save(capped);
    debugPrint(
        '[NotificationHistory] Upserted ${item.notificationId} (${capped.length}/$kMaxNotificationHistory)');
  }

  Future<void> remove(String notificationId) async {
    final current =
        List<NotificationHistoryItem>.from(items.value);
    final before = current.length;
    current.removeWhere((i) => i.notificationId == notificationId);
    if (current.length == before) return;
    items.value = List.unmodifiable(current);
    await _save(current);
  }

  Future<void> setReplyError(String notificationId, String message) async {
    final current =
        List<NotificationHistoryItem>.from(items.value);
    final idx =
        current.indexWhere((i) => i.notificationId == notificationId);
    if (idx < 0) return;
    current[idx] = current[idx].copyWith(replyError: message);
    items.value = List.unmodifiable(current);
    await _save(current);
  }

  Future<void> clear() async {
    items.value = const [];
    await _storage.delete(key: _kStorageKey);
  }

  Future<void> _save(List<NotificationHistoryItem> list) async {
    try {
      final jsonList = list.map((e) => e.toJson()).toList();
      await _storage.write(key: _kStorageKey, value: jsonEncode(jsonList));
    } catch (e) {
      debugPrint('[NotificationHistory] Error saving history: $e');
    }
  }
}
