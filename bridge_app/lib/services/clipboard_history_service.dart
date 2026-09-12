import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'system_channel.dart';
import 'clipboard_service.dart';
import 'content_classifier.dart';

const int kMaxClipboardHistory = 20;
const String _kStorageKey = 'clipboard_history';

class ClipboardHistoryItem {
  final String id;
  final String kind; // 'text' | 'image'
  final String contentType; // 'url' | 'otp' | 'email' | 'phone' | 'text' | 'image'
  final String? text;
  final String? imageThumbnail; // Base64 thumbnail or null
  final String? imagePath;      // Absolute local cache path
  final DateTime timestamp;
  final String origin; // 'android' | 'windows'

  const ClipboardHistoryItem({
    required this.id,
    this.kind = 'text',
    this.contentType = 'text',
    this.text,
    this.imageThumbnail,
    this.imagePath,
    required this.timestamp,
    required this.origin,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'contentType': contentType,
        'text': text,
        'imageThumbnail': imageThumbnail,
        'imagePath': imagePath,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'origin': origin,
      };

  factory ClipboardHistoryItem.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String? ?? 'text';
    final rawText = json['text'] as String?;
    final contentType = json['contentType'] as String? ??
        (kind == 'image' ? 'image' : classifyClipboardText(rawText ?? ''));

    return ClipboardHistoryItem(
      id: json['id'] as String? ?? const Uuid().v4(),
      kind: kind,
      contentType: contentType,
      text: rawText,
      imageThumbnail: json['imageThumbnail'] as String?,
      imagePath: json['imagePath'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String)?.toLocal() ?? DateTime.now()
          : DateTime.now(),
      origin: json['origin'] as String? ?? 'android',
    );
  }
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
    await _pruneOrphanedImages();
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
    String? contentType,
  }) async {
    if (text.trim().isEmpty) return;

    final currentList = List<ClipboardHistoryItem>.from(items.value);

    // Suppress consecutive identical text item at the top
    if (currentList.isNotEmpty &&
        currentList.first.kind == 'text' &&
        currentList.first.text == text &&
        currentList.first.origin == origin) {
      return;
    }

    final resolvedContentType = contentType ?? classifyClipboardText(text);

    final newItem = ClipboardHistoryItem(
      id: id ?? const Uuid().v4(),
      kind: 'text',
      contentType: resolvedContentType,
      text: text,
      timestamp: timestamp ?? DateTime.now(),
      origin: origin,
    );

    _insertAndTrim(newItem, currentList);
  }

  Future<void> addImageEntry({
    required String imagePath,
    required String origin,
    String? id,
    String? imageThumbnail,
    DateTime? timestamp,
  }) async {
    final currentList = List<ClipboardHistoryItem>.from(items.value);

    // Suppress consecutive identical image item at the top
    if (currentList.isNotEmpty &&
        currentList.first.kind == 'image' &&
        currentList.first.imagePath == imagePath &&
        currentList.first.origin == origin) {
      return;
    }

    final newItem = ClipboardHistoryItem(
      id: id ?? const Uuid().v4(),
      kind: 'image',
      contentType: 'image',
      imagePath: imagePath,
      imageThumbnail: imageThumbnail,
      timestamp: timestamp ?? DateTime.now(),
      origin: origin,
    );

    _insertAndTrim(newItem, currentList);
  }

  void _insertAndTrim(ClipboardHistoryItem newItem, List<ClipboardHistoryItem> currentList) async {
    // Prepend to list without reordering or removing existing items
    currentList.insert(0, newItem);

    // Cap at 20 entries (oldest drops off)
    if (currentList.length > kMaxClipboardHistory) {
      final evicted = currentList.sublist(kMaxClipboardHistory);
      for (final ev in evicted) {
        _deleteImageFile(ev.imagePath);
      }
    }

    final capped = currentList.take(kMaxClipboardHistory).toList();
    items.value = List.unmodifiable(capped);

    await _save(capped);
    debugPrint('[ClipboardHistory] Added new ${newItem.kind} entry (${newItem.origin}): ${newItem.contentType} (${capped.length}/20)');
  }

  /// Copies an item back to Android's local clipboard without re-syncing to Windows.
  Future<void> copyLocally(ClipboardHistoryItem item) async {
    if (item.kind == 'image' && item.imagePath != null) {
      ClipboardService.instance.markImageAsSynced(item.imagePath!);
      await SystemChannel.setClipboardImage(item.imagePath!);
      debugPrint('[ClipboardHistory] Copied image history item locally: ${item.imagePath} (sync suppressed)');
      return;
    }

    final text = item.text ?? '';
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

  /// Backward-compatible string copy helper
  Future<void> copyLocallyText(String text) async {
    if (text.isEmpty) return;
    ClipboardService.instance.markAsSynced(text);
    await SystemChannel.setClipboard(text);
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e) {
      debugPrint('[ClipboardHistory] Clipboard.setData error: $e');
    }
  }

  Future<void> clear() async {
    for (final item in items.value) {
      _deleteImageFile(item.imagePath);
    }
    items.value = const [];
    await _storage.delete(key: _kStorageKey);
  }

  void _deleteImageFile(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (f.existsSync()) {
        f.deleteSync();
        debugPrint('[ClipboardHistory] Evicted & deleted image file: $path');
      }
    } catch (e) {
      debugPrint('[ClipboardHistory] Failed to delete image file $path: $e');
    }
  }

  Future<void> _pruneOrphanedImages() async {
    try {
      final cacheDir = await SystemChannel.getClipboardCacheDir();
      if (cacheDir == null) return;
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) return;

      final activePaths = items.value
          .where((i) => i.kind == 'image' && i.imagePath != null)
          .map((i) => File(i.imagePath!).absolute.path)
          .toSet();

      final entities = dir.listSync();
      for (final entity in entities) {
        if (entity is File && !activePaths.contains(entity.absolute.path)) {
          try {
            entity.deleteSync();
            debugPrint('[ClipboardHistory] Pruned orphaned cached image: ${entity.path}');
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('[ClipboardHistory] Error during orphaned image prune: $e');
    }
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
