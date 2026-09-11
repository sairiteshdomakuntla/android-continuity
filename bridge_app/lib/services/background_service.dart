import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:uuid/uuid.dart';

import '../models/bridge_message.dart';
import 'socket_service.dart';
import 'file_transfer_service.dart';
import 'pairing_storage_service.dart';
import 'event_dedupe.dart';
import 'system_channel.dart';
import 'notifications_channel.dart';

const String _kNotificationChannelId = 'bridge_foreground_service';
const String _kFileNotificationChannelId = 'bridge_file_transfers';

final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

class BackgroundService {
  BackgroundService._();
  static final instance = BackgroundService._();

  static Future<void> initialize() async {
    final service = FlutterBackgroundService();

    // Create Notification Channels for Android
    if (Platform.isAndroid) {
      const AndroidNotificationChannel serviceChannel = AndroidNotificationChannel(
        _kNotificationChannelId,
        'Bridge Background Service',
        description: 'Keeps Bridge connected to your PC for background file and clipboard sync',
        importance: Importance.low,
      );

      const AndroidNotificationChannel fileChannel = AndroidNotificationChannel(
        _kFileNotificationChannelId,
        'Bridge File Transfers',
        description: 'Notifications for completed incoming file transfers from your PC',
        importance: Importance.high,
      );

      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

      await androidPlugin?.createNotificationChannel(serviceChannel);
      await androidPlugin?.createNotificationChannel(fileChannel);

      const AndroidInitializationSettings initAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const InitializationSettings initSettings =
          InitializationSettings(android: initAndroid);
      await _localNotifications.initialize(settings: initSettings);
    }

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: _kNotificationChannelId,
        initialNotificationTitle: 'Bridge is running',
        initialNotificationContent: 'Ready to receive files and clipboard',
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  /// Starts the persistent background service if not running.
  static Future<bool> start() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      return await service.startService();
    }
    return true;
  }

  /// Stops the background service.
  static void stop() {
    final service = FlutterBackgroundService();
    service.invoke('stopService');
  }

  /// Tells the background service to reload pairing keys and reconnect the socket.
  static void restartSocket() {
    final service = FlutterBackgroundService();
    service.invoke('restart_socket');
  }

  /// Sends clipboard text to Windows through the background socket.
  static void sendClipboard(String text) {
    final service = FlutterBackgroundService();
    service.invoke('send_clipboard', {'text': text});
  }

  /// Requests the background service to stream files to Windows.
  static void sendFiles(List<String> paths) {
    final service = FlutterBackgroundService();
    service.invoke('send_files', {'paths': paths});
  }

  /// Sends a camera-signal payload to Windows through the background socket.
  static void sendCameraSignal(Map<String, dynamic> payload) {
    final service = FlutterBackgroundService();
    service.invoke('send_camera_signal', {'payload': payload});
  }

  /// Requests the background service to return the latest clipboard it holds.
  static void queryLatestClipboard() {
    final service = FlutterBackgroundService();
    service.invoke('query_latest_clipboard');
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

/// The main entrypoint for the background isolate.
/// Exclusively owns the single persistent Socket.IO connection.
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final dedupe = EventDedupe();
  debugPrint('[BackgroundService] Isolate started — initializing persistent socket & receiver');

  // Handle Foreground service state for Android
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  // Handle Service stop
  service.on('stopService').listen((event) async {
    debugPrint('[BackgroundService] stopService invoked. Disconnecting socket and stopping self.');
    SocketService.instance.disconnect();
    await service.stopSelf();
  });

  // Re-emit connection status to UI whenever socket connects/disconnects
  SocketService.instance.connected.addListener(() {
    final isConnected = SocketService.instance.isConnected;
    final url = SocketService.instance.currentUrl;
    debugPrint('[BackgroundService] Socket status changed -> connected: $isConnected, url: $url');
    service.invoke('connection_status', {
      'connected': isConnected,
      'url': url,
    });
  });

  // Function to establish persistent socket connection
  Future<void> connectPersistentSocket() async {
    final pairing = await PairingStorageService.instance.getPairing();
    if (pairing != null) {
      debugPrint('[BackgroundService] Found pairing for: ${pairing.serverUrl}. Connecting...');
      final keyBytes = Uint8List.fromList(base64Decode(pairing.pairingKey));
      SocketService.instance.setEncryptionKey(keyBytes);
      SocketService.instance.connect(pairing.serverUrl);
    } else {
      debugPrint('[BackgroundService] No active pairing stored.');
    }
  }

  // Initial connect
  await connectPersistentSocket();

  // Initialize background file transfer receiver
  FileTransferService.init(
    isBackgroundService: true,
    onReceiveProgress: (progress) {
      service.invoke('file_receive_progress', progress.toJson());
    },
    onFileReceived: (fileName, pcName) async {
      // Display native Android notification
      const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        _kFileNotificationChannelId,
        'Bridge File Transfers',
        channelDescription: 'Notifications for incoming file transfers',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      );
      const NotificationDetails notifDetails = NotificationDetails(android: androidDetails);

      await _localNotifications.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: 'File Received',
        body: 'Received "$fileName" from $pcName',
        notificationDetails: notifDetails,
      );
    },
  );

  // In-memory cache of latest clipboard text received from Windows
  String? latestClipboardText;
  String? latestClipboardEventId;
  String? latestClipboardTimestamp;

  // Incoming clipboard from Windows -> update Android clipboard & notify UI isolate
  SocketService.instance.onClipboardMessage((msg) async {
    final text = msg.payload['text'] as String?;
    final preview = text != null && text.length > 40 ? '${text.substring(0, 40)}…' : (text ?? '');
    debugPrint('[BackgroundService] [RECV] Received clipboard message: eventId=${msg.eventId}, timestamp=${msg.timestamp}, len=${text?.length ?? 0}');

    if (text == null || text.isEmpty) {
      debugPrint('[BackgroundService] [RECV] Empty clipboard payload — skipping');
      return;
    }

    if (dedupe.has(msg.eventId)) {
      debugPrint('[BackgroundService] [DEDUPE] Suppressed duplicate clipboard eventId: ${msg.eventId}');
      return;
    }

    dedupe.add(msg.eventId);
    debugPrint('[BackgroundService] [DEDUPE] Passed dedupe for eventId: ${msg.eventId}');

    latestClipboardText = text;
    latestClipboardEventId = msg.eventId;
    latestClipboardTimestamp = msg.timestamp;

    // 1. Native write directly via Kotlin foreground service / ClipboardManager.setPrimaryClip()
    try {
      final nativeSuccess = await SystemChannel.setClipboard(text);
      debugPrint('[BackgroundService] [NATIVE WRITE] setClipboard result: $nativeSuccess for "$preview"');
    } catch (e) {
      debugPrint('[BackgroundService] [NATIVE WRITE] setClipboard EXCEPTION: $e');
    }

    // 2. Also try standard Flutter Clipboard.setData for fallback/logging
    try {
      await Clipboard.setData(ClipboardData(text: text));
      debugPrint('[BackgroundService] [FLUTTER WRITE] Clipboard.setData succeeded');
    } catch (e) {
      debugPrint('[BackgroundService] [FLUTTER WRITE] Clipboard.setData failed (expected in background isolate): $e');
    }

    // 3. Forward to UI isolate with origin and timestamp
    service.invoke('clipboard_received', {
      'eventId': msg.eventId,
      'text': text,
      'timestamp': msg.timestamp,
      'origin': msg.origin.name,
    });
  });

  // Incoming camera-signal from Windows -> forward to UI isolate
  SocketService.instance.onMessage(MessageType.cameraSignal, (msg) {
    final event = msg.payload['event'] as String? ?? 'unknown';
    debugPrint('[BackgroundService] Incoming camera-signal [$event] from Windows -> forwarding to UI');
    service.invoke('camera_signal_received', {
      'eventId': msg.eventId,
      'payload': msg.payload,
    });
  });

  // ── Notification sync ──────────────────────────────────────────────────────
  // 1. Forward notifications captured by native BridgeNotificationListenerService to Windows
  NotificationsChannel.setEventListener((event) async {
    final eventType = event['event'] as String? ?? 'unknown';
    if (!SocketService.instance.isConnected) {
      debugPrint('[BackgroundService] [NOTIFICATION] Dropping notification [$eventType] — socket not connected');
      return;
    }

    final msg = BridgeMessage(
      eventId: const Uuid().v4(),
      type: MessageType.notification,
      origin: Origin.android,
      timestamp: DateTime.now().toUtc().toIso8601String(),
      payload: event,
    );

    debugPrint('[BackgroundService] [NOTIFICATION] [SEND] Outgoing notification [$eventType] for ${event['notificationId']} (${event['appName'] ?? ''})');
    await SocketService.instance.emit(msg);
  });

  // 2. Handle incoming notification actions from Windows (reply, dismiss-request)
  SocketService.instance.onMessage(MessageType.notification, (msg) async {
    final event = msg.payload['event'] as String?;
    final notificationId = msg.payload['notificationId'] as String?;

    if (notificationId == null || notificationId.isEmpty) {
      debugPrint('[BackgroundService] [NOTIFICATION] Received message with missing notificationId — dropped');
      return;
    }

    debugPrint('[BackgroundService] [NOTIFICATION] [RECV] Action [$event] for $notificationId');

    if (event == 'reply') {
      final replyText = msg.payload['replyText'] as String? ?? '';
      debugPrint('[BackgroundService] [NOTIFICATION] Executing reply on $notificationId: "$replyText"');
      final success = await NotificationsChannel.sendReply(notificationId, replyText);

      if (!success) {
        debugPrint('[BackgroundService] [NOTIFICATION] Reply failed for $notificationId — notifying Windows');
        final failMsg = BridgeMessage(
          eventId: const Uuid().v4(),
          type: MessageType.notification,
          origin: Origin.android,
          timestamp: DateTime.now().toUtc().toIso8601String(),
          payload: {
            'event': 'reply-failed',
            'notificationId': notificationId,
            'error': 'Reply failed (notification may have been updated or canceled)',
          },
        );
        await SocketService.instance.emit(failMsg);
      }
    } else if (event == 'dismiss-request') {
      debugPrint('[BackgroundService] [NOTIFICATION] Executing dismiss on $notificationId');
      await NotificationsChannel.dismissNotification(notificationId);
    }
  });

  // Cross-isolate UI command: Send clipboard to Windows
  service.on('send_clipboard').listen((data) {
    if (data == null) return;
    final text = data['text'] as String?;
    if (text != null && text.isNotEmpty) {
      SocketService.instance.emitClipboardMessage(text);
    }
  });

  // Cross-isolate UI command: Send camera-signal to Windows
  service.on('send_camera_signal').listen((data) async {
    if (data == null) return;
    final rawPayload = data['payload'];
    if (rawPayload == null) return;
    final payload = Map<String, dynamic>.from(rawPayload as Map);

    final event = payload['event'] as String? ?? 'unknown';
    if (!SocketService.instance.isConnected) {
      debugPrint('[BackgroundService] WARNING: Cannot send camera-signal [$event] — background socket not connected!');
      return;
    }

    final msg = BridgeMessage(
      eventId: const Uuid().v4(),
      type: MessageType.cameraSignal,
      origin: Origin.android,
      timestamp: DateTime.now().toUtc().toIso8601String(),
      payload: payload,
    );

    debugPrint('[BackgroundService] [SEND] Outgoing camera-signal [$event] sent over connected socket (socket id: ${SocketService.instance.rawSocket?.id})');
    await SocketService.instance.emit(msg);
  });

  // Cross-isolate UI command: Send files to Windows
  service.on('send_files').listen((data) async {
    if (data == null) return;
    final rawPaths = data['paths'] as List<dynamic>?;
    if (rawPaths == null || rawPaths.isEmpty) return;
    final paths = rawPaths.map((e) => e.toString()).toList();

    try {
      await FileTransferService.sendFiles(
        paths,
        onSendProgress: (progress) {
          service.invoke('file_send_progress', progress.toJson());
        },
      );
    } catch (e) {
      debugPrint('[BackgroundService] sendFiles error: $e');
      service.invoke('file_send_progress', {
        'transferId': '',
        'fileName': '',
        'bytesSent': 0,
        'totalBytes': 0,
        'done': true,
        'error': e.toString(),
      });
    }
  });

  // Cross-isolate UI command: Restart socket after pairing
  service.on('restart_socket').listen((_) async {
    debugPrint('[BackgroundService] restart_socket command received');
    await connectPersistentSocket();
  });

  // Cross-isolate UI command: Query current status
  service.on('query_status').listen((_) {
    service.invoke('connection_status', {
      'connected': SocketService.instance.isConnected,
      'url': SocketService.instance.currentUrl,
    });
  });

  // Cross-isolate UI command: Query latest received clipboard
  service.on('query_latest_clipboard').listen((_) {
    debugPrint('[BackgroundService] query_latest_clipboard received -> returning: "${latestClipboardText?.isNotEmpty == true ? (latestClipboardText!.length > 30 ? '${latestClipboardText!.substring(0, 30)}…' : latestClipboardText) : 'null'}"');
    service.invoke('latest_clipboard_response', {
      'text': latestClipboardText,
      'eventId': latestClipboardEventId,
      'timestamp': latestClipboardTimestamp,
    });
  });
}
