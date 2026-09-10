import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'services/socket_service.dart';
import 'services/file_transfer_service.dart';
import 'services/pairing_storage_service.dart';
import 'screens/share_progress_screen.dart';

/// Cold-start entry point for ShareTargetActivity.
/// Only called when MainActivity is NOT running (engine cache is empty).
/// When the main app IS alive, ShareTargetActivity reuses its cached engine
/// and this function is never called.
@pragma('vm:entry-point')
void mainShare() async {
  WidgetsFlutterBinding.ensureInitialized();

  final pairing = await PairingStorageService.instance.getPairing();
  if (pairing != null) {
    final keyBytes = Uint8List.fromList(base64Decode(pairing.pairingKey));
    SocketService.instance.setEncryptionKey(keyBytes);
    // Don't connect yet — ShareProgressScreen calls ensureConnected()
  }

  FileTransferService.init();

  runApp(const ShareApp());
}

class ShareApp extends StatelessWidget {
  const ShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const Scaffold(
        backgroundColor: Colors.transparent,
        body: ShareProgressScreen(),
      ),
    );
  }
}
