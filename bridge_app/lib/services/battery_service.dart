import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/bridge_message.dart';
import 'socket_service.dart';
import 'system_channel.dart';

/// Sends phone battery status to Windows over the persistent background
/// socket. Event-driven only: the native ACTION_BATTERY_CHANGED receiver
/// pushes changes; this service throttles (>2% move or charging flip),
/// sends once at service start, and resends on socket reconnect so
/// Windows never shows blank/stale status after a restart.
class BatteryService {
  BatteryService._();
  static bool _initialized = false;
  static int? _lastSentLevel;
  static bool? _lastSentCharging;

  static void initBackground() {
    if (_initialized) return;
    _initialized = true;

    // 1. Send current state once at service start.
    _resendCurrent(force: true);

    // 2. Stream native battery-change events with throttle.
    SystemChannel.setBatteryListener((event) async {
      final level = (event['level'] as num?)?.toInt();
      final isCharging = event['isCharging'] as bool?;
      if (level == null || isCharging == null) return;
      if (_shouldSend(level, isCharging)) {
        await _emit(level, isCharging);
      }
    });

    // 3. Resend on socket (re)connect — covers restarts on both ends.
    SocketService.instance.connected.addListener(() {
      if (SocketService.instance.isConnected) {
        _resendCurrent(force: true);
      }
    });

    debugPrint('[BatteryService] Initialized (background isolate)');
  }

  static bool _shouldSend(int level, bool isCharging) {
    if (_lastSentLevel == null || _lastSentCharging == null) return true;
    if (isCharging != _lastSentCharging) return true;
    return (level - _lastSentLevel!).abs() > 2;
  }

  static Future<void> _resendCurrent({required bool force}) async {
    try {
      final state = await SystemChannel.getBatteryState();
      if (state == null) return;
      final level = (state['level'] as num?)?.toInt();
      final isCharging = state['isCharging'] as bool?;
      if (level == null || isCharging == null) return;
      if (force || _shouldSend(level, isCharging)) {
        await _emit(level, isCharging);
      }
    } catch (e) {
      debugPrint('[BatteryService] resend error: $e');
    }
  }

  static Future<void> _emit(int level, bool isCharging) async {
    if (!SocketService.instance.isConnected) {
      debugPrint('[BatteryService] Socket not connected — dropping update (reconnect will resend)');
      return;
    }
    _lastSentLevel = level;
    _lastSentCharging = isCharging;
    final msg = BridgeMessage(
      eventId: const Uuid().v4(),
      type: MessageType.device,
      origin: Origin.android,
      timestamp: DateTime.now().toUtc().toIso8601String(),
      payload: {
        'event': 'battery-update',
        'level': level,
        'isCharging': isCharging,
      },
    );
    debugPrint('[BatteryService] [SEND] battery-update: $level%${isCharging ? ' (charging)' : ''}');
    await SocketService.instance.emit(msg);
  }
}
