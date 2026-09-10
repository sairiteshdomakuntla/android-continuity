import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../models/bridge_message.dart';

typedef MessageHandler = void Function(BridgeMessage msg);

/// Singleton that owns the Socket.IO client connection.
/// All message dispatch goes through [onMessage] handlers.
class SocketService {
  SocketService._();
  static final SocketService instance = SocketService._();

  io.Socket? _socket;
  bool get isConnected => _socket?.connected ?? false;

  final Map<MessageType, List<MessageHandler>> _handlers = {};

  /// Notify listeners when connection state changes.
  final ValueNotifier<bool> connected = ValueNotifier(false);

  void connect(String serverUrl) {
    if (_socket != null) return;

    debugPrint('[SocketService] Connecting to $serverUrl ...');
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionDelay(500)       // retry after 500ms
          .setReconnectionDelayMax(3000)   // cap at 3s
          .setReconnectionAttempts(99999)  // effectively unlimited
          .build(),
    );

    _socket!.onConnect((_) {
      debugPrint('[SocketService] Connected: ${_socket?.id}');
      connected.value = true;
    });

    _socket!.onConnectError((data) {
      debugPrint('[SocketService] Connection error: $data');
    });

    _socket!.onError((data) {
      debugPrint('[SocketService] Error: $data');
    });

    _socket!.onDisconnect((reason) {
      debugPrint('[SocketService] Disconnected: $reason');
      connected.value = false;
    });

    _socket!.on('bridge-message', (data) {
      try {
        final msg = BridgeMessage.fromSocketData(data);
        debugPrint('[SocketService] [RECV] [${msg.type.name}] ${msg.eventId} from ${msg.origin.name}');
        final handlers = _handlers[msg.type] ?? [];
        for (final h in handlers) {
          h(msg);
        }
      } catch (e) {
        debugPrint('[SocketService] Failed to parse incoming message: $e');
      }
    });
  }

  void emit(BridgeMessage msg) {
    if (_socket == null || !_socket!.connected) {
      debugPrint('[SocketService] emit() called but not connected — message dropped');
      return;
    }
    debugPrint('[SocketService] [SEND] [${msg.type.name}] ${msg.eventId}');
    _socket!.emit('bridge-message', msg.toSocketData());
  }

  void onMessage(MessageType type, MessageHandler handler) {
    _handlers.putIfAbsent(type, () => []).add(handler);
  }

  void dispose() {
    _socket?.dispose();
    _socket = null;
    connected.dispose();
  }
}
