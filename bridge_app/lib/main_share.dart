import 'package:flutter/material.dart';
import 'services/socket_service.dart';
import 'services/file_transfer_service.dart';
import 'services/pairing_storage_service.dart';
import 'services/background_service.dart';
import 'screens/share_progress_screen.dart';
import 'theme/bridge_theme.dart';

/// Cold-start entry point for ShareTargetActivity.
@pragma('vm:entry-point')
void mainShare() async {
  WidgetsFlutterBinding.ensureInitialized();

  await BackgroundService.initialize();

  final pairing = await PairingStorageService.instance.getPairing();
  if (pairing != null) {
    await BackgroundService.start();
  }

  SocketService.instance.initUiProxy();
  FileTransferService.init(isBackgroundService: false);

  runApp(const ShareApp());
}

class ShareApp extends StatelessWidget {
  const ShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bridge Share',
      debugShowCheckedModeBanner: false,
      theme: BridgeTheme.light(),
      home: const Scaffold(
        backgroundColor: Colors.transparent,
        body: ShareProgressScreen(),
      ),
    );
  }
}
