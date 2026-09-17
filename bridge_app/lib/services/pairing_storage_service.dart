import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// One paired PC. `deviceId` is this phone's own stable id (shared across
/// pairings so each PC keeps recognizing the same phone).
class PairingData {
  final String id;
  final String name;
  final String ip;
  final int port;
  final String pairingKey;
  final String deviceId;

  const PairingData({
    required this.id,
    this.name = '',
    required this.ip,
    required this.port,
    required this.pairingKey,
    required this.deviceId,
  });

  String get serverUrl => 'http://$ip:$port';

  String get displayName => name.isEmpty ? 'Windows PC' : name;

  String get address => '$ip:$port';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ip': ip,
        'port': port,
        'pairingKey': pairingKey,
        'deviceId': deviceId,
      };

  factory PairingData.fromJson(Map<String, dynamic> json) {
    return PairingData(
      id: json['id'] as String? ?? const Uuid().v4(),
      name: json['name'] as String? ?? '',
      ip: json['ip'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 4000,
      pairingKey: json['pairingKey'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
    );
  }
}

class PairingStorageService {
  PairingStorageService._();
  static final PairingStorageService instance = PairingStorageService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: true,
    ),
  );

  // Legacy single-pairing keys (migrated once into the list below).
  static const _keyIp = 'bridge_paired_ip';
  static const _keyPort = 'bridge_paired_port';
  static const _keyPairingKey = 'bridge_pairing_key';
  static const _keyDeviceId = 'bridge_device_id';

  // Multi-PC storage: JSON array + active entry id.
  static const _keyPairings = 'bridge_pairings_json';
  static const _keyActiveId = 'bridge_active_pairing_id';

  bool _migrated = false;

  Future<void> _migrateIfNeeded() async {
    if (_migrated) return;
    _migrated = true;
    try {
      final existing = await _storage.read(key: _keyPairings);
      if (existing != null && existing.isNotEmpty) return;

      final ip = await _storage.read(key: _keyIp);
      final portStr = await _storage.read(key: _keyPort);
      final pairingKey = await _storage.read(key: _keyPairingKey);
      final deviceId = await _storage.read(key: _keyDeviceId);
      if (ip == null || portStr == null || pairingKey == null || deviceId == null) {
        return;
      }
      final entry = PairingData(
        id: const Uuid().v4(),
        name: ip,
        ip: ip,
        port: int.tryParse(portStr) ?? 4000,
        pairingKey: pairingKey,
        deviceId: deviceId,
      );
      await _writeList([entry]);
      await _storage.write(key: _keyActiveId, value: entry.id);
      await _storage.delete(key: _keyIp);
      await _storage.delete(key: _keyPort);
      await _storage.delete(key: _keyPairingKey);
      debugPrint('[PairingStorageService] Migrated legacy single pairing into multi-PC list');
    } catch (e) {
      debugPrint('[PairingStorageService] Migration error: $e');
    }
  }

  Future<List<PairingData>> _readList() async {
    await _migrateIfNeeded();
    try {
      final raw = await _storage.read(key: _keyPairings);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => PairingData.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((p) => p.ip.isNotEmpty && p.pairingKey.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[PairingStorageService] Error reading pairings: $e');
      return const [];
    }
  }

  Future<void> _writeList(List<PairingData> list) async {
    try {
      final raw = jsonEncode(list.map((e) => e.toJson()).toList());
      await _storage.write(key: _keyPairings, value: raw);
    } catch (e) {
      debugPrint('[PairingStorageService] Error saving pairings: $e');
    }
  }

  /// All paired PCs, active first.
  Future<List<PairingData>> getPairings() async {
    final list = await _readList();
    if (list.isEmpty) return const [];
    final activeId = await _storage.read(key: _keyActiveId);
    if (activeId == null) return list;
    list.sort((a, b) {
      if (a.id == activeId) return -1;
      if (b.id == activeId) return 1;
      return 0;
    });
    return list;
  }

  Future<String?> getActiveId() async {
    await _migrateIfNeeded();
    return _storage.read(key: _keyActiveId);
  }

  /// The currently active pairing (what the socket connects to).
  /// Legacy-compatible: everything that used the single pairing keeps working.
  Future<PairingData?> getPairing() async {
    final list = await _readList();
    if (list.isEmpty) {
      debugPrint('[PairingStorageService] getPairing(): No pairings found in storage');
      return null;
    }
    final activeId = await _storage.read(key: _keyActiveId);
    final active = list.where((p) => p.id == activeId);
    final pairing = active.isNotEmpty ? active.first : list.first;
    debugPrint('[PairingStorageService] getPairing(): Active pairing for ${pairing.ip}:${pairing.port} (${list.length} total)');
    return pairing;
  }

  /// Adds a PC (or refreshes the key if its address is already paired)
  /// and makes it active. Scanning a second QR appends — it never
  /// discards previously paired PCs.
  Future<PairingData> addPairing({
    required String ip,
    required int port,
    required String pairingKey,
    required String deviceId,
    String? name,
  }) async {
    final list = await _readList();
    final idx = list.indexWhere((p) => p.ip == ip && p.port == port);
    late final PairingData entry;
    if (idx >= 0) {
      entry = PairingData(
        id: list[idx].id,
        name: (name != null && name.isNotEmpty) ? name : list[idx].name,
        ip: ip,
        port: port,
        pairingKey: pairingKey,
        deviceId: deviceId.isNotEmpty ? deviceId : list[idx].deviceId,
      );
      list[idx] = entry;
      debugPrint('[PairingStorageService] Refreshed pairing key for $ip:$port');
    } else {
      entry = PairingData(
        id: const Uuid().v4(),
        name: (name != null && name.isNotEmpty) ? name : '',
        ip: ip,
        port: port,
        pairingKey: pairingKey,
        deviceId: deviceId,
      );
      list.add(entry);
      debugPrint('[PairingStorageService] Added pairing for $ip:$port (${list.length} total)');
    }
    await _writeList(list);
    await _storage.write(key: _keyActiveId, value: entry.id);
    return entry;
  }

  /// Legacy-compatible save: upserts and activates.
  Future<void> savePairing({
    required String ip,
    required int port,
    required String pairingKey,
    required String deviceId,
    String? name,
  }) async {
    try {
      await addPairing(ip: ip, port: port, pairingKey: pairingKey, deviceId: deviceId, name: name);
      debugPrint('[PairingStorageService] Successfully saved pairing for $ip:$port');
    } catch (e) {
      debugPrint('[PairingStorageService] Error saving pairing: $e');
    }
  }

  /// Switches the active PC. Callers restart the socket afterwards.
  /// Returns false when the id is unknown.
  Future<bool> setActivePairing(String id) async {
    final list = await _readList();
    if (list.every((p) => p.id != id)) return false;
    await _storage.write(key: _keyActiveId, value: id);
    final next = list.firstWhere((p) => p.id == id);
    debugPrint('[PairingStorageService] Active pairing switched to ${next.ip}:${next.port}');
    return true;
  }

  /// Renames a paired PC. Returns false when the id is unknown.
  Future<bool> renamePairing(String id, String name) async {
    final list = await _readList();
    final idx = list.indexWhere((p) => p.id == id);
    if (idx < 0) return false;
    final p = list[idx];
    list[idx] = PairingData(
      id: p.id,
      name: name.trim(),
      ip: p.ip,
      port: p.port,
      pairingKey: p.pairingKey,
      deviceId: p.deviceId,
    );
    await _writeList(list);
    return true;
  }

  /// Updates the active PC's host IP and port without discarding credentials.
  Future<void> updateHost(String newIp, int newPort) async {
    try {
      final list = await _readList();
      if (list.isEmpty) return;
      final activeId = await _storage.read(key: _keyActiveId);
      final idx = list.indexWhere((p) => p.id == activeId);
      final target = idx >= 0 ? idx : 0;
      final p = list[target];
      list[target] = PairingData(
        id: p.id,
        name: p.name,
        ip: newIp,
        port: newPort,
        pairingKey: p.pairingKey,
        deviceId: p.deviceId,
      );
      await _writeList(list);
      debugPrint('[PairingStorageService] Successfully updated paired host to $newIp:$newPort');
    } catch (e) {
      debugPrint('[PairingStorageService] Error updating paired host: $e');
    }
  }

  /// Removes one PC. If it was active, the next remaining PC becomes active.
  /// Returns the remaining pairings.
  Future<List<PairingData>> removePairing(String id) async {
    final list = await _readList();
    list.removeWhere((p) => p.id == id);
    await _writeList(list);
    final activeId = await _storage.read(key: _keyActiveId);
    if (activeId == id) {
      if (list.isEmpty) {
        await _storage.delete(key: _keyActiveId);
      } else {
        await _storage.write(key: _keyActiveId, value: list.first.id);
      }
    }
    debugPrint('[PairingStorageService] Removed pairing ($id), ${list.length} remaining');
    return list;
  }

  /// Legacy-compatible: removes the active PC (what "Remove this PC" means).
  Future<void> clearPairing() async {
    final pairing = await getPairing();
    if (pairing == null) return;
    await removePairing(pairing.id);
  }

  /// Removes every paired PC. Used by the single-PC UI: removing the PC
  /// means "forget everything and start over".
  Future<void> clearAll() async {
    await _migrateIfNeeded();
    await _writeList(const []);
    await _storage.delete(key: _keyActiveId);
    debugPrint('[PairingStorageService] Cleared all pairings');
  }

  /// Replaces the whole list with a single PC and makes it active.
  /// Used by the single-PC UI: pairing a new QR swaps to the new PC.
  Future<PairingData> replacePairing({
    required String ip,
    required int port,
    required String pairingKey,
    required String deviceId,
    String? name,
  }) async {
    await _migrateIfNeeded();
    final entry = PairingData(
      id: const Uuid().v4(),
      name: (name != null && name.isNotEmpty) ? name : '',
      ip: ip,
      port: port,
      pairingKey: pairingKey,
      deviceId: deviceId,
    );
    await _writeList([entry]);
    await _storage.write(key: _keyActiveId, value: entry.id);
    debugPrint('[PairingStorageService] Replaced pairings with single PC $ip:$port');
    return entry;
  }

  Future<String> getOrCreateDeviceId() async {
    var deviceId = await _storage.read(key: _keyDeviceId);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await _storage.write(key: _keyDeviceId, value: deviceId);
    }
    return deviceId;
  }
}
