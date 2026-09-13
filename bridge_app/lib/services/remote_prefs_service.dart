import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Local preferences for the "Phone as Remote" feature.
///
/// Same storage pattern as [PairingStorageService]: singleton +
/// flutter_secure storage with plain string keys.
class RemotePrefsService {
  RemotePrefsService._();
  static final RemotePrefsService instance = RemotePrefsService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: true,
    ),
  );

  static const _keySensitivity = 'remote_trackpad_sensitivity';

  /// Cursor-movement sensitivity multiplier: default, and the slider range.
  /// The default matches the host's built-in 1.8x so behavior is unchanged
  /// until the user moves the slider.
  static const double defaultSensitivity = 1.8;
  static const double minSensitivity = 0.5;
  static const double maxSensitivity = 3.0;

  /// Persisted cursor-movement sensitivity multiplier.
  Future<double> loadSensitivity() async {
    try {
      final raw = await _storage.read(key: _keySensitivity);
      if (raw == null) return defaultSensitivity;
      final value = double.tryParse(raw);
      if (value == null || !value.isFinite) return defaultSensitivity;
      if (value < minSensitivity) return minSensitivity;
      if (value > maxSensitivity) return maxSensitivity;
      return value;
    } catch (e) {
      debugPrint('[RemotePrefsService] Error reading sensitivity: $e');
      return defaultSensitivity;
    }
  }

  Future<void> saveSensitivity(double value) async {
    try {
      await _storage.write(
          key: _keySensitivity, value: value.toStringAsFixed(2));
      debugPrint('[RemotePrefsService] Saved sensitivity: $value');
    } catch (e) {
      debugPrint('[RemotePrefsService] Error saving sensitivity: $e');
    }
  }
}
