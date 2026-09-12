import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'clipboard_history_service.dart';
import 'pairing_storage_service.dart';
import 'widget_channel.dart';

/// Name of the snapshot file read directly by the native widget provider.
/// Lives in the Flutter documents dir (`app_flutter/`), which native code
/// locates via `applicationInfo.dataDir + "/app_flutter/<name>"`.
const String kWidgetSnapshotFileName = 'widget_snapshot.json';

/// Maximum items rendered by the widget (RemoteViews uses fixed slots).
const int kWidgetMaxItems = 4;

/// Maximum preview length stored per item.
const int kWidgetPreviewMaxLength = 120;

/// Snapshot older than this is treated as stale (service force-killed).
const Duration kWidgetStaleAfter = Duration(minutes: 15);

/// Writes the compact clipboard snapshot consumed by the native
/// `BridgeClipboardWidgetProvider`, then asks native to re-render.
///
/// Two entry points, one file (last-writer-wins; both write the same shape
/// so races are benign and self-healing):
/// - [syncFromItems] — UI isolate after history mutations (authoritative).
/// - [syncFromStorage] — background isolate so the widget refreshes even
///   when the app UI process is dead (e.g. copy on Windows → widget
///   updates without opening Bridge).
class WidgetSnapshotService {
  WidgetSnapshotService._();

  static const _storage = FlutterSecureStorage();

  static Future<File> _snapshotFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$kWidgetSnapshotFileName');
  }

  static String _previewOf(String? text) {
    final flat = (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= kWidgetPreviewMaxLength) return flat;
    return '${flat.substring(0, kWidgetPreviewMaxLength)}…';
  }

  static Map<String, dynamic> _itemJson(ClipboardHistoryItem item) => {
        'id': item.id,
        'kind': item.kind,
        'contentType': item.contentType,
        'preview': item.kind == 'image' ? '' : _previewOf(item.text),
        'imagePath': item.imagePath,
        'timestamp': item.timestamp.toUtc().toIso8601String(),
        'origin': item.origin,
      };

  /// UI-isolate path: call after every history mutation.
  static Future<void> syncFromItems(List<ClipboardHistoryItem> items) async {
    try {
      final pairing = await PairingStorageService.instance.getPairing();
      await _write(
        items: items.take(kWidgetMaxItems).map(_itemJson).toList(),
        serviceAlive: true,
        paired: pairing != null,
      );
    } catch (e) {
      debugPrint('[WidgetSnapshot] syncFromItems failed: $e');
    }
  }

  /// Background-isolate path: re-reads secure storage directly (no UI
  /// singletons involved) so the widget updates while the app is closed.
  static Future<void> syncFromStorage() async {
    try {
      final pairing = await PairingStorageService.instance.getPairing();
      final raw = await _storage.read(key: 'clipboard_history');
      final List<Map<String, dynamic>> items = [];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final e in decoded.take(kWidgetMaxItems)) {
          final m = Map<String, dynamic>.from(e as Map);
          final kind = m['kind'] as String? ?? 'text';
          items.add({
            'id': m['id'],
            'kind': kind,
            'contentType': m['contentType'] ??
                (kind == 'image' ? 'image' : 'text'),
            'preview': kind == 'image' ? '' : _previewOf(m['text'] as String?),
            'imagePath': m['imagePath'],
            'timestamp': m['timestamp'],
            'origin': m['origin'] ?? 'android',
          });
        }
      }
      await _write(
        items: items,
        serviceAlive: true,
        paired: pairing != null,
      );
    } catch (e) {
      debugPrint('[WidgetSnapshot] syncFromStorage failed: $e');
    }
  }

  /// Called on `stopService` (best-effort; force-kill is covered by the
  /// staleness check on the native side).
  static Future<void> markServiceStopped() async {
    try {
      final file = await _snapshotFile();
      List<dynamic> items = const [];
      if (await file.exists()) {
        try {
          final current =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          items = current['items'] as List<dynamic>? ?? const [];
        } catch (_) {}
      }
      final pairing = await PairingStorageService.instance.getPairing();
      await _write(
        items: items,
        serviceAlive: false,
        paired: pairing != null,
      );
    } catch (e) {
      debugPrint('[WidgetSnapshot] markServiceStopped failed: $e');
    }
  }

  static Future<void> _write({
    required List<dynamic> items,
    required bool serviceAlive,
    required bool paired,
  }) async {
    final file = await _snapshotFile();
    await file.writeAsString(jsonEncode({
      'version': 1,
      'serviceAlive': serviceAlive,
      'paired': paired,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'items': items,
    }));
    await WidgetChannel.updateWidget();
  }
}
