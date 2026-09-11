import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'socket_service.dart';
import 'file_transfer_service.dart';
import 'pairing_storage_service.dart';
import 'event_dedupe.dart';

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

  // Incoming clipboard from Windows -> update Android clipboard & notify UI isolate
  SocketService.instance.onClipboardMessage((msg) async {
    final text = msg.payload['text'] as String?;
    if (text == null || text.isEmpty) return;

    dedupe.add(msg.eventId);
    debugPrint('[BackgroundService] Incoming clipboard from Windows: "${text.length > 40 ? '${text.substring(0, 40)}...' : text}"');

    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e) {
      debugPrint('[BackgroundService] Failed to set system clipboard: $e');
    }

    service.invoke('clipboard_received', {
      'eventId': msg.eventId,
      'text': text,
    });
  });

  // Cross-isolate UI command: Send clipboard to Windows
  service.on('send_clipboard').listen((data) {
    if (data == null) return;
    final text = data['text'] as String?;
    if (text != null && text.isNotEmpty) {
      SocketService.instance.emitClipboardMessage(text);
    }
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
}
