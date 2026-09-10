import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:uuid/uuid.dart';
import '../models/bridge_message.dart';
import 'crypto_service.dart';
import 'pairing_storage_service.dart';

typedef MessageHandler = void Function(BridgeMessage msg);

/// Singleton that owns the Socket.IO client connection.
/// All message dispatch goes through [onMessage] handlers.
class SocketService {
  SocketService._();
  static final SocketService instance = SocketService._();

  io.Socket? _socket;
  String? _currentUrl;
  Uint8List? _encKey;

  bool get isConnected => _socket?.connected ?? false;
  String? get currentUrl => _currentUrl;
  io.Socket? get rawSocket => _socket;

  final Map<MessageType, List<MessageHandler>> _handlers = {};

  /// Notify listeners when connection state changes.
  final ValueNotifier<bool> connected = ValueNotifier(false);

  void setEncryptionKey(Uint8List? key) {
    _encKey = key;
    if (key != null) {
      debugPrint('[SocketService] Encryption key set (${key.length} bytes). AES-256-GCM active.');
    } else {
      debugPrint('[SocketService] Encryption key cleared.');
    }
  }

  Uint8List? get encryptionKey => _encKey;

  void connect(String serverUrl) {
    if (_socket != null && _currentUrl == serverUrl && _socket!.connected) {
      return;
    }

    disconnect();
    _currentUrl = serverUrl;

    debugPrint('[SocketService] Connecting to $serverUrl ...');
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableForceNew()
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

    _socket!.on('bridge-message', (data) async {
      try {
        BridgeMessage msg;
        if (_encKey != null) {
          if (data is! String) {
            debugPrint('[SocketService] Expected encrypted base64 payload string, got ${data.runtimeType}. Dropping.');
            return;
          }

          final preview = data.length > 32 ? data.substring(0, 32) : data;
          debugPrint('[SocketService] [RECV ENCRYPTED] Raw wire payload: $preview... (len: ${data.length})');

          final decryptedJson = await CryptoService.decrypt(_encKey!, data);
          final decoded = jsonDecode(decryptedJson);
          msg = BridgeMessage.fromSocketData(decoded);
        } else {
          msg = BridgeMessage.fromSocketData(data);
        }

        debugPrint('[SocketService] [RECV] [${msg.type.name}] ${msg.eventId} from ${msg.origin.name}');
        final handlers = _handlers[msg.type] ?? [];
        for (final h in handlers) {
          h(msg);
        }
      } catch (e) {
        debugPrint('[SocketService] Failed to process incoming message: $e');
      }
    });

    _socket!.connect();
  }

  Completer<void>? _pendingConnectCompleter;

  /// Ensures that the socket is connected. Reconnects if disconnected and awaits connection.
  Future<void> ensureConnected({Duration timeout = const Duration(seconds: 8)}) async {
    if (isConnected) return;

    if (_currentUrl == null || _encKey == null) {
      final pairing = await PairingStorageService.instance.getPairing();
      if (pairing != null) {
        final keyBytes = Uint8List.fromList(base64Decode(pairing.pairingKey));
        setEncryptionKey(keyBytes);
        _currentUrl = pairing.serverUrl;
      }
    }

    if (_currentUrl == null) {
      debugPrint('[SocketService] ensureConnected(): No paired server URL available');
      throw Exception('No paired server URL available');
    }

    if (isConnected) return;

    if (_pendingConnectCompleter != null && !_pendingConnectCompleter!.isCompleted) {
      try {
        await _pendingConnectCompleter!.future.timeout(timeout);
      } catch (e) {
        // timeout or error
      }
      return;
    }

    final completer = Completer<void>();
    _pendingConnectCompleter = completer;

    void onConnectListener() {
      if (isConnected && !completer.isCompleted) {
        connected.removeListener(onConnectListener);
        completer.complete();
      }
    }

    connected.addListener(onConnectListener);

    if (_socket == null || !_socket!.connected) {
      debugPrint('[SocketService] ensureConnected(): socket not connected, connecting to $_currentUrl ...');
      connect(_currentUrl!);
    }

    try {
      await completer.future.timeout(timeout);
    } catch (e) {
      connected.removeListener(onConnectListener);
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    } finally {
      if (_pendingConnectCompleter == completer) {
        _pendingConnectCompleter = null;
      }
    }
  }

  /// Performs the pairing handshake on this socket connection without tearing it down.
  Future<void> performPairHandshake({
    required String serverUrl,
    required String pairingKey,
    required String deviceId,
    required String deviceName,
  }) async {
    connect(serverUrl);

    final completer = Completer<void>();
    Timer? timeoutTimer;

    void onPairSuccess(dynamic data) {
      timeoutTimer?.cancel();
      debugPrint('[SocketService] Handshake confirmed by host: $data');
      final keyBytes = Uint8List.fromList(base64Decode(pairingKey));
      setEncryptionKey(keyBytes);
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    void onPairError(dynamic data) {
      timeoutTimer?.cancel();
      debugPrint('[SocketService] Handshake rejected by host: $data');
      final msg = data is Map ? data['message'] ?? 'Handshake rejected' : 'Pairing handshake error';
      disconnect();
      if (!completer.isCompleted) {
        completer.completeError(Exception(msg));
      }
    }

    void sendHandshake() {
      debugPrint('[SocketService] Sending pair-handshake to $serverUrl ...');
      _socket!.emit('pair-handshake', {
        'pairingKey': pairingKey,
        'deviceId': deviceId,
        'deviceName': deviceName,
      });
    }

    _socket!.once('pair-success', onPairSuccess);
    _socket!.once('pair-error', onPairError);

    timeoutTimer = Timer(const Duration(seconds: 12), () {
      if (!completer.isCompleted) {
        disconnect();
        completer.completeError(Exception('Pairing timed out. Host did not respond in 12s.'));
      }
    });

    if (isConnected) {
      sendHandshake();
    } else {
      _socket!.once('connect', (_) {
        sendHandshake();
      });
      _socket!.connect();
    }

    return completer.future;
  }

  Future<void> emit(BridgeMessage msg) async {
    if (_socket == null || !_socket!.connected) {
      debugPrint('[SocketService] emit() called but not connected — message dropped');
      return;
    }

    if (_encKey != null) {
      final jsonStr = jsonEncode(msg.toSocketData());
      final ciphertext = await CryptoService.encrypt(_encKey!, jsonStr);

      final preview = ciphertext.length > 32 ? ciphertext.substring(0, 32) : ciphertext;
      debugPrint('[SocketService] [SEND ENCRYPTED] [${msg.type.name}] ${msg.eventId}');
      debugPrint('[SocketService] Raw wire payload: $preview... (len: ${ciphertext.length})');

      _socket!.emit('bridge-message', ciphertext);
    } else {
      debugPrint('[SocketService] [SEND] [${msg.type.name}] ${msg.eventId}');
      _socket!.emit('bridge-message', msg.toSocketData());
    }
  }

  void onMessage(MessageType type, MessageHandler handler) {
    _handlers.putIfAbsent(type, () => []).add(handler);
  }

  /// Registers a handler for file-type messages.
  /// The handler receives the decoded payload map directly.
  void onFileMessage(void Function(Map<String, dynamic> payload) handler) {
    onMessage(MessageType.file, (msg) => handler(Map<String, dynamic>.from(msg.payload)));
  }

  /// Emits a file-type BridgeMessage with [payload] as the envelope payload.
  Future<void> emitFileMessage(Map<String, dynamic> payload) async {
    final msg = BridgeMessage(
      eventId: const Uuid().v4(),
      type: MessageType.file,
      origin: Origin.android,
      timestamp: DateTime.now().toUtc().toIso8601String(),
      payload: payload,
    );
    await emit(msg);
  }

  void disconnect() {
    if (_socket != null) {
      _socket!.dispose();
      _socket = null;
      _currentUrl = null;
      connected.value = false;
    }
  }

  void dispose() {
    disconnect();
    connected.dispose();
  }
}
