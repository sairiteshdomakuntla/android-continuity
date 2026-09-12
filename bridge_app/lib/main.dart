import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'services/socket_service.dart';
import 'services/clipboard_service.dart';
import 'services/camera_service.dart';
import 'services/file_transfer_service.dart';
import 'services/pairing_storage_service.dart';
import 'services/background_service.dart';
import 'services/system_channel.dart';
import 'services/clipboard_history_service.dart';
import 'services/notifications_channel.dart';
import 'screens/scan_pair_screen.dart';
import 'screens/share_progress_screen.dart';
import 'screens/camera_screen.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize Foreground Background Service configuration
  await BackgroundService.initialize();

  // 2. Check existing pairing in secure storage
  final pairing = await PairingStorageService.instance.getPairing();

  if (pairing != null) {
    // Start persistent background service (which owns the single socket)
    await BackgroundService.start();
  }

  // 3. Init UI proxy services
  SocketService.instance.initUiProxy();
  ClipboardService.instance.init();
  FileTransferService.init(isBackgroundService: false);
  CameraService.instance.init();

  CameraService.instance.onStartCameraRequested = () {
    if (CameraService.instance.isStreaming.value) return;
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    final url = SocketService.instance.currentUrl ?? '';
    final pcName = url.isNotEmpty
        ? url.replaceFirst(RegExp(r'https?://'), '').split(':').first
        : 'Windows PC';
    debugPrint('[main] Remote start-camera received — pushing CameraScreen(pcName: $pcName)');
    nav.push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(pcName: pcName),
      ),
    ).then((_) {
      debugPrint('[main] Returned from remote-launched CameraScreen');
    });
  };

  runApp(BridgeApp(isPaired: pairing != null));
}

/// Dedicated entrypoint for Android Share Sheet (ShareTargetActivity)
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

// ── App ────────────────────────────────────────────────────────────────────
class BridgeApp extends StatelessWidget {
  final bool isPaired;

  const BridgeApp({super.key, required this.isPaired});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: isPaired ? const BridgeHome() : const ScanPairScreen(),
    );
  }
}

// ── Home Screen ────────────────────────────────────────────────────────────
class BridgeHome extends StatefulWidget {
  const BridgeHome({super.key});

  @override
  State<BridgeHome> createState() => _BridgeHomeState();
}

class _BridgeHomeState extends State<BridgeHome> with WidgetsBindingObserver {
  static bool _hasPromptedBattery = false;
  bool _notificationAccessGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkPermissionsAndBattery();
      ClipboardService.instance.syncNow();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkNotificationAccess();
      ClipboardService.instance.syncNow();
    }
  }

  Future<void> _checkNotificationAccess() async {
    if (!Platform.isAndroid || !mounted) return;
    final granted = await NotificationsChannel.isNotificationAccessGranted();
    if (mounted && granted != _notificationAccessGranted) {
      setState(() {
        _notificationAccessGranted = granted;
      });
    }
  }

  Future<void> _checkPermissionsAndBattery() async {
    if (!Platform.isAndroid || !mounted) return;

    // 1. Request POST_NOTIFICATIONS runtime permission on Android 13+ (API 33+)
    final notifGranted = await SystemChannel.isNotificationPermissionGranted();
    if (!notifGranted) {
      await SystemChannel.requestNotificationPermission();
    }

    // 2. Check NotificationListenerService access
    await _checkNotificationAccess();

    // 3. Prompt user once for Battery Optimization exemption
    if (!_hasPromptedBattery) {
      _hasPromptedBattery = true;
      final isIgnoring = await SystemChannel.isIgnoringBatteryOptimizations();
      if (!isIgnoring && mounted) {
        await _showBatteryOptimizationDialog();
      }
    }
  }

  Future<void> _showBatteryOptimizationDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.battery_charging_full_rounded, color: Color(0xFF6366F1)),
            SizedBox(width: 10),
            Expanded(child: Text('Keep Bridge Alive')),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Allow Bridge to ignore battery optimizations so you can receive files and sync clipboard even when your phone is idle or locked.',
              style: TextStyle(fontSize: 14, height: 1.4),
            ),
            SizedBox(height: 12),
            Text(
              'Note: On certain OEM devices (Xiaomi, Oppo, Vivo, Samsung), you may also need to allow "Autostart" in device app settings.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              SystemChannel.requestIgnoreBatteryOptimizations();
            },
            child: const Text('Allow'),
          ),
        ],
      ),
    );
  }

  Future<void> _unpair() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair Device?'),
        content: const Text(
          'This will remove stored encryption keys and stop the background service. You will need to scan the QR code again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      BackgroundService.stop();
      await PairingStorageService.instance.clearPairing();
      SocketService.instance.setEncryptionKey(null);
      SocketService.instance.disconnect();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ScanPairScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[BridgeHome] build() executed — rendering home UI');
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ─────────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.swap_horiz_rounded,
                          color: colorScheme.primary, size: 32),
                      const SizedBox(width: 12),
                      Text(
                        'Bridge',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.qr_code_rounded),
                    tooltip: 'Pair / Unpair',
                    onPressed: _unpair,
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Connection status card ──────────────────────────────────
              ValueListenableBuilder<bool>(
                valueListenable: SocketService.instance.connected,
                builder: (context, isConnected, _) {
                  return _StatusCard(
                    connected: isConnected,
                    serverUrl: SocketService.instance.currentUrl ?? 'Connecting to PC...',
                    onScanAgain: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ScanPairScreen()),
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 16),

              // ── Security & Background Service Badges ───────────────────
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.greenAccent.withAlpha(20),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.greenAccent.withAlpha(60)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.lock_outline_rounded, size: 14, color: Colors.greenAccent),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'AES-256-GCM',
                              style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6366F1).withAlpha(20),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF6366F1).withAlpha(60)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.notifications_active_outlined, size: 14, color: Color(0xFF818CF8)),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Background Sync',
                              style: TextStyle(
                                color: Color(0xFF818CF8),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // ── Notification Access Banner (if not granted) ─────────────
              if (!_notificationAccessGranted) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withAlpha(22),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF6366F1).withAlpha(80)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_active_rounded,
                          color: Color(0xFF818CF8), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Sync Phone Notifications',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Show alerts & reply directly from Windows PC.',
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () =>
                            NotificationsChannel.requestNotificationAccess(),
                        child: const Text('Enable',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // ── How it works ────────────────────────────────────────────
              _InfoCard(
                icon: Icons.phone_android_rounded,
                title: 'Android → Windows',
                body:
                    'Share files from any app (Gallery, Files) via the Share Sheet, or copy text and open Bridge.',
                color: colorScheme.primaryContainer,
                onColor: colorScheme.onPrimaryContainer,
              ),
              const SizedBox(height: 12),
              _InfoCard(
                icon: Icons.computer_rounded,
                title: 'Windows → Android',
                body:
                    'Send files or copy text on Windows. Bridge receives files into Downloads even when closed.',
                color: colorScheme.secondaryContainer,
                onColor: colorScheme.onSecondaryContainer,
              ),
              const SizedBox(height: 8),

              // ── Use as Webcam button ─────────────────────────────────────
              ValueListenableBuilder<bool>(
                valueListenable: SocketService.instance.connected,
                builder: (context, isConnected, _) {
                  return SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: isConnected
                          ? () async {
                              final url = SocketService.instance.currentUrl ?? '';
                              // Extract host portion for display
                              final pcName = url.isNotEmpty
                                  ? url.replaceFirst(RegExp(r'https?://'), '').split(':').first
                                  : 'Windows PC';
                              debugPrint('[BridgeHome] Tapped "Use as Webcam" — pushing CameraScreen(pcName: $pcName)');
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => CameraScreen(pcName: pcName),
                                ),
                              );
                              debugPrint('[BridgeHome] Returned from CameraScreen route to BridgeHome');
                            }
                          : null,
                      icon: const Icon(Icons.videocam_rounded),
                      label: const Text('Use as Webcam'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),

              // ── Incoming file receive progress ──────────────────────────
              ValueListenableBuilder<FileReceiveProgress?>(
                valueListenable: FileTransferService.receiveProgress,
                builder: (context, rp, _) {
                  if (rp == null) return const SizedBox.shrink();
                  return _FileReceiveCard(progress: rp);
                },
              ),
              const SizedBox(height: 12),

              // ── Send File button ─────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await FilePicker.pickFiles(
                      type: FileType.any,
                    );
                    if (picked.isEmpty) return;
                    final uris = picked.map((f) => f.path).whereType<String>().toList();
                    if (!context.mounted) return;
                    try {
                      await FileTransferService.sendFiles(uris);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Send failed: $e')),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('Send File to Windows'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Manual sync button ──────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    final result = await ClipboardService.instance.syncNow(force: true);
                    if (context.mounted) {
                      String msg;
                      switch (result) {
                        case SyncDirectionResult.pulledFromWindows:
                          msg = 'Pulled latest clipboard from Windows!';
                          break;
                        case SyncDirectionResult.sentToWindows:
                          msg = 'Sent clipboard to Windows!';
                          break;
                        case SyncDirectionResult.upToDate:
                          msg = SocketService.instance.isConnected
                              ? 'Clipboard is up to date with Windows'
                              : 'Clipboard synchronized via Background Service';
                          break;
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('Sync Clipboard Now'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── Clipboard History ────────────────────────────────────────
              const _ClipboardHistoryCard(),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Widgets ─────────────────────────────────────────────────────────────────

/// Displays the last 20 clipboard history entries with relative timestamps and local copy-back.
class _ClipboardHistoryCard extends StatelessWidget {
  const _ClipboardHistoryCard();

  String _formatRelativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 5) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Color _badgeColor(String type) {
    switch (type.toLowerCase()) {
      case 'url':
        return const Color(0xFF38BDF8);
      case 'otp':
        return const Color(0xFFFB923C);
      case 'email':
        return const Color(0xFFC084FC);
      case 'phone':
        return const Color(0xFF4ADE80);
      case 'image':
        return const Color(0xFFF472B6);
      default:
        return const Color(0xFF94A3B8);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ValueListenableBuilder<List<ClipboardHistoryItem>>(
      valueListenable: ClipboardHistoryService.instance.items,
      builder: (context, history, _) {
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withAlpha(50),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colorScheme.outlineVariant.withAlpha(70)),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.history_rounded, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Clipboard History',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withAlpha(25),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${history.length}/20',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (history.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      'No history yet. Copy text or image to sync.',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant.withAlpha(150),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: history.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = history[index];
                    final isWindows = item.origin == 'windows';

                    return Material(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () async {
                          await ClipboardHistoryService.instance.copyLocally(item);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(item.kind == 'image'
                                    ? 'Image copied to clipboard! Ready to paste.'
                                    : 'Text copied to clipboard! Ready to paste.'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    isWindows ? Icons.computer_rounded : Icons.phone_android_rounded,
                                    size: 13,
                                    color: isWindows ? const Color(0xFF38BDF8) : const Color(0xFF34D399),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    isWindows ? 'Windows' : 'Android',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isWindows ? const Color(0xFF38BDF8) : const Color(0xFF34D399),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                    decoration: BoxDecoration(
                                      color: _badgeColor(item.contentType).withAlpha(35),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      item.contentType.toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        color: _badgeColor(item.contentType),
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    _formatRelativeTime(item.timestamp),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colorScheme.onSurfaceVariant.withAlpha(140),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(Icons.copy_rounded, size: 12, color: colorScheme.primary.withAlpha(160)),
                                ],
                              ),
                              if (item.kind == 'image' &&
                                  item.imagePath != null &&
                                  File(item.imagePath!).existsSync()) ...[
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Container(
                                    constraints: const BoxConstraints(maxHeight: 120, maxWidth: 180),
                                    decoration: BoxDecoration(
                                      color: Colors.black26,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: colorScheme.outlineVariant.withAlpha(60)),
                                    ),
                                    child: Image.file(
                                      File(item.imagePath!),
                                      fit: BoxFit.contain,
                                      errorBuilder: (context, error, stackTrace) => const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: Icon(Icons.broken_image_rounded, size: 32),
                                      ),
                                    ),
                                  ),
                                ),
                              ] else ...[
                                const SizedBox(height: 6),
                                Text(
                                  item.text ?? '',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.3,
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Shows incoming file receive progress (Windows → Android) in BridgeHome.
class _FileReceiveCard extends StatelessWidget {
  final FileReceiveProgress progress;

  const _FileReceiveCard({required this.progress});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isError = progress.error;
    final isDone = progress.done && !isError;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isError
            ? Colors.redAccent.withAlpha(25)
            : colorScheme.primaryContainer.withAlpha(60),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? Colors.redAccent.withAlpha(75)
              : colorScheme.primary.withAlpha(75),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isError
                    ? Icons.error_outline_rounded
                    : isDone
                        ? Icons.check_circle_outline_rounded
                        : Icons.download_rounded,
                size: 16,
                color: isError ? Colors.redAccent : colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isError
                      ? 'Receive failed: ${progress.fileName}'
                      : isDone
                          ? 'Received: ${progress.fileName}'
                          : 'Receiving: ${progress.fileName}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isError ? Colors.redAccent : colorScheme.onSurface,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (!isDone && !isError) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.fraction,
                backgroundColor: Colors.white12,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                minHeight: 4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final bool connected;
  final String serverUrl;
  final VoidCallback onScanAgain;

  const _StatusCard({
    required this.connected,
    required this.serverUrl,
    required this.onScanAgain,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dotColor = connected ? Colors.greenAccent : Colors.redAccent;
    final label = connected ? 'Connected' : 'Disconnected';
    final host = serverUrl.replaceFirst('http://', '');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: connected
                  ? [BoxShadow(color: dotColor.withAlpha(150), blurRadius: 8)]
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        )),
                Text(host,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        )),
              ],
            ),
          ),
          if (!connected) ...[
            TextButton.icon(
              onPressed: () {
                BackgroundService.start();
                BackgroundService.restartSocket();
              },
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Reconnect'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
            IconButton(
              onPressed: onScanAgain,
              icon: const Icon(Icons.qr_code, size: 18),
              tooltip: 'Scan New QR',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color color;
  final Color onColor;

  const _InfoCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
    required this.onColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: onColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: onColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 14)),
                const SizedBox(height: 4),
                Text(body,
                    style: TextStyle(
                        color: onColor.withAlpha(210), fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
