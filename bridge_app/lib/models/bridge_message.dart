import 'dart:convert';

enum MessageType {
  clipboard,
  file,
  cameraSignal,
  ping,
  notification;

  String toJson() {
    return switch (this) {
      MessageType.cameraSignal => 'camera-signal',
      _ => name,
    };
  }

  static MessageType fromJson(String value) {
    return switch (value) {
      'clipboard' => MessageType.clipboard,
      'file' => MessageType.file,
      'camera-signal' => MessageType.cameraSignal,
      'ping' => MessageType.ping,
      'notification' => MessageType.notification,
      _ => throw ArgumentError('Unknown MessageType: $value'),
    };
  }
}

enum Origin {
  android,
  windows;

  String toJson() => name;

  static Origin fromJson(String value) {
    return switch (value) {
      'android' => Origin.android,
      'windows' => Origin.windows,
      _ => throw ArgumentError('Unknown Origin: $value'),
    };
  }
}

class BridgeMessage {
  final String eventId;
  final MessageType type;
  final Origin origin;
  final String timestamp;
  final Map<String, dynamic> payload;

  const BridgeMessage({
    required this.eventId,
    required this.type,
    required this.origin,
    required this.timestamp,
    required this.payload,
  });

  factory BridgeMessage.fromJson(Map<String, dynamic> json) {
    return BridgeMessage(
      eventId: json['eventId'] as String,
      type: MessageType.fromJson(json['type'] as String),
      origin: Origin.fromJson(json['origin'] as String),
      timestamp: json['timestamp'] as String,
      payload: json['payload'] as Map<String, dynamic>? ?? {},
    );
  }

  Map<String, dynamic> toJson() => {
        'eventId': eventId,
        'type': type.toJson(),
        'origin': origin.toJson(),
        'timestamp': timestamp,
        'payload': payload,
      };

  /// Convenience: encode to a raw Map for socket_io_client emit.
  Map<String, dynamic> toSocketData() => toJson();

  /// Convenience: decode from raw socket_io_client data.
  static BridgeMessage fromSocketData(dynamic data) {
    final map = data is String
        ? jsonDecode(data) as Map<String, dynamic>
        : Map<String, dynamic>.from(data as Map);
    return BridgeMessage.fromJson(map);
  }
}
