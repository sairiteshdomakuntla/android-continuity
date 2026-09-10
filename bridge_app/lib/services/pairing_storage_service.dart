import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class PairingData {
  final String ip;
  final int port;
  final String pairingKey;
  final String deviceId;

  const PairingData({
    required this.ip,
    required this.port,
    required this.pairingKey,
    required this.deviceId,
  });

  String get serverUrl => 'http://$ip:$port';
}

class PairingStorageService {
  PairingStorageService._();
  static final PairingStorageService instance = PairingStorageService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: true,
    ),
  );

  static const _keyIp = 'bridge_paired_ip';
  static const _keyPort = 'bridge_paired_port';
  static const _keyPairingKey = 'bridge_pairing_key';
  static const _keyDeviceId = 'bridge_device_id';

  Future<PairingData?> getPairing() async {
    try {
      final ip = await _storage.read(key: _keyIp);
      final portStr = await _storage.read(key: _keyPort);
      final pairingKey = await _storage.read(key: _keyPairingKey);
      final deviceId = await _storage.read(key: _keyDeviceId);

      if (ip == null || portStr == null || pairingKey == null || deviceId == null) {
        debugPrint('[PairingStorageService] getPairing(): No complete pairing found in storage');
        return null;
      }

      final port = int.tryParse(portStr) ?? 4000;
      debugPrint('[PairingStorageService] getPairing(): Found pairing for $ip:$port');
      return PairingData(
        ip: ip,
        port: port,
        pairingKey: pairingKey,
        deviceId: deviceId,
      );
    } catch (e) {
      debugPrint('[PairingStorageService] Error reading pairing: $e');
      return null;
    }
  }

  Future<void> savePairing({
    required String ip,
    required int port,
    required String pairingKey,
    required String deviceId,
  }) async {
    try {
      await _storage.write(key: _keyIp, value: ip);
      await _storage.write(key: _keyPort, value: port.toString());
      await _storage.write(key: _keyPairingKey, value: pairingKey);
      await _storage.write(key: _keyDeviceId, value: deviceId);
      debugPrint('[PairingStorageService] Successfully saved pairing for $ip:$port');
    } catch (e) {
      debugPrint('[PairingStorageService] Error saving pairing: $e');
    }
  }

  Future<void> clearPairing() async {
    await _storage.delete(key: _keyIp);
    await _storage.delete(key: _keyPort);
    await _storage.delete(key: _keyPairingKey);
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
