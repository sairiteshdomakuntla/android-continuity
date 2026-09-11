import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'system_channel.dart';
import 'clipboard_service.dart';

const int kMaxClipboardHistory = 20;
const String _kStorageKey = 'clipboard_history';

class ClipboardHistoryItem {
  final String id;
  final String text;
  final DateTime timestamp;
  final String origin; // 'android' | 'windows'

  const ClipboardHistoryItem({
    required this.id,
    required this.text,
    required this.timestamp,
    required this.origin,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'origin': origin,
      };

  factory ClipboardHistoryItem.fromJson(Map<String, dynamic> json) => ClipboardHistoryItem(
        id: json['id'] as String? ?? const Uuid().v4(),
        text: json['text'] as String? ?? '',
        timestamp: json['timestamp'] != null
            ? DateTime.tryParse(json['timestamp'] as String)?.toLocal() ?? DateTime.now()
            : DateTime.now(),
        origin: json['origin'] as String? ?? 'android',
      );
}

class ClipboardHistoryService {
  ClipboardHistoryService._();
  static final ClipboardHistoryService instance = ClipboardHistoryService._();

  final _storage = const FlutterSecureStorage();
  final ValueNotifier<List<ClipboardHistoryItem>> items = ValueNotifier([]);
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await load();
  }

  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _kStorageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final parsed = decoded
            .map((e) => ClipboardHistoryItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .take(kMaxClipboardHistory)
            .toList();
        items.value = List.unmodifiable(parsed);
        debugPrint('[ClipboardHistory] Loaded ${parsed.length} items from storage');
      }
    } catch (e) {
      debugPrint('[ClipboardHistory] Error loading history: $e');
    }
  }

  Future<void> addEntry(
    String text,
    String origin, {
    String? id,
    DateTime? timestamp,
  }) async {
    if (text.trim().isEmpty) return;

    final currentList = List<ClipboardHistoryItem>.from(items.value);

    // Suppress consecutive identical item at the top
    if (currentList.isNotEmpty &&
        currentList.first.text == text &&
        currentList.first.origin == origin) {
      return;
    }

    final newItem = ClipboardHistoryItem(
      id: id ?? const Uuid().v4(),
      text: text,
      timestamp: timestamp ?? DateTime.now(),
      origin: origin,
    );

    // Prepend to list without reordering or removing existing items
    currentList.insert(0, newItem);

    // Cap at 20 entries (oldest drops off)
    final capped = currentList.take(kMaxClipboardHistory).toList();
    items.value = List.unmodifiable(capped);

    await _save(capped);
    debugPrint('[ClipboardHistory] Added new entry ($origin): "${text.length > 40 ? '${text.substring(0, 40)}…' : text}" (${capped.length}/20)');
  }

  /// Copies an item back to Android's local clipboard without re-syncing to Windows.
  Future<void> copyLocally(String text) async {
    if (text.isEmpty) return;

    // 1. Tell ClipboardService to track this as last-synced so resume sync doesn't re-emit
    ClipboardService.instance.markAsSynced(text);

    // 2. Set native clipboard directly
    await SystemChannel.setClipboard(text);

    // 3. Also set Flutter platform clipboard for current Activity
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e) {
      debugPrint('[ClipboardHistory] Clipboard.setData error: $e');
    }

    debugPrint('[ClipboardHistory] Copied history item locally: "${text.length > 40 ? '${text.substring(0, 40)}…' : text}" (sync suppressed)');
  }

  Future<void> clear() async {
    items.value = const [];
    await _storage.delete(key: _kStorageKey);
  }

  Future<void> _save(List<ClipboardHistoryItem> list) async {
    try {
      final jsonList = list.map((e) => e.toJson()).toList();
      await _storage.write(key: _kStorageKey, value: jsonEncode(jsonList));
    } catch (e) {
      debugPrint('[ClipboardHistory] Error saving history: $e');
    }
  }
}
