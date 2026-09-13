import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'theme/bridge_icons.dart';
import 'services/socket_service.dart';
import 'services/clipboard_service.dart';
import 'services/camera_service.dart';
import 'services/file_transfer_service.dart';
import 'services/pairing_storage_service.dart';
import 'services/background_service.dart';
import 'services/system_channel.dart';
import 'services/clipboard_history_service.dart';
import 'services/notification_history_service.dart';
import 'services/notifications_channel.dart';
import 'services/remote_input_service.dart';
import 'screens/scan_pair_screen.dart';
import 'screens/share_progress_screen.dart';
import 'screens/camera_screen.dart';
import 'screens/remote_screen.dart';
import 'theme/bridge_theme.dart';

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
  NotificationHistoryService.instance.init();
  FileTransferService.init(isBackgroundService: false);
  CameraService.instance.init();
  RemoteInputService.instance.init();

  RemoteInputService.instance.onOpenRemoteRequested = () {
    if (RemoteScreen.isShown) return;
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    debugPrint('[main] Remote open-remote received — pushing RemoteScreen');
    nav.push(
      MaterialPageRoute(
        builder: (_) => const RemoteScreen(),
      ),
    ).then((_) {
      debugPrint('[main] Returned from remote-launched RemoteScreen');
    });
  };

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
      theme: BridgeTheme.light(),
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
      theme: BridgeTheme.light(),
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
  bool _showNotifications = true;

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
            BridgeIcon('batteryCharging',
                color: BridgeColors.clay, size: 22),
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
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            SizedBox(height: 12),
            Text(
              'Note: On certain OEM devices (Xiaomi, Oppo, Vivo, Samsung), you may also need to allow "Autostart" in device app settings.',
              style: TextStyle(fontSize: 12, color: BridgeColors.muted),
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

  Future<void> _syncNow() async {
    final result = await ClipboardService.instance.syncNow(force: true);
    if (!mounted) return;
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

  Future<void> _sendFile() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    if (picked.isEmpty) return;
    final uris = picked.map((f) => f.path).whereType<String>().toList();
    if (!mounted) return;
    try {
      await FileTransferService.sendFiles(uris);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    }
  }

  void _openWebcam(bool isConnected) {
    if (!isConnected) return;
    final url = SocketService.instance.currentUrl ?? '';
    final pcName = url.isNotEmpty
        ? url.replaceFirst(RegExp(r'https?://'), '').split(':').first
        : 'Windows PC';
    debugPrint('[BridgeHome] Tapped "Use as Webcam" — pushing CameraScreen(pcName: $pcName)');
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => CameraScreen(pcName: pcName),
      ),
    )
        .then((_) {
      debugPrint('[BridgeHome] Returned from CameraScreen route to BridgeHome');
    });
  }

  void _openRemote(bool isConnected) {
    if (!isConnected) return;
    debugPrint('[BridgeHome] Tapped "Remote" — pushing RemoteScreen');
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => const RemoteScreen(),
      ),
    )
        .then((_) {
      debugPrint('[BridgeHome] Returned from RemoteScreen route to BridgeHome');
    });
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('[BridgeHome] build() executed — rendering home UI');

    return Scaffold(
      backgroundColor: BridgeColors.linen,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ─────────────────────────────────────────────
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: BridgeColors.clay,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: BridgeIcon('sprout',
                        color: BridgeColors.brandCream, size: 17),
                  ),
                  const SizedBox(width: 10),
                  const Text('Bridge', style: BridgeText.brand),
                  const Spacer(),
                  IconButton(
                    icon: BridgeIcon('qrCode', size: 20),
                    color: BridgeColors.inkSoft,
                    tooltip: 'Pair new device',
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ScanPairScreen()),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // ── Status hero ────────────────────────────────────────
              ValueListenableBuilder<bool>(
                valueListenable: SocketService.instance.connected,
                builder: (context, isConnected, _) {
                  return _StatusHero(
                    connected: isConnected,
                    serverUrl:
                        SocketService.instance.currentUrl ?? 'Not connected',
                    onReconnect: () {
                      BackgroundService.start();
                      BackgroundService.restartSocket();
                    },
                  );
                },
              ),
              const SizedBox(height: 16),

              // ── Quick actions (primary / secondary / ghost / danger)
              ValueListenableBuilder<bool>(
                valueListenable: SocketService.instance.connected,
                builder: (context, isConnected, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _openWebcam(isConnected),
                        icon: const BridgeIcon('camera', size: 17),
                        label: const Text('Use as Webcam'),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _sendFile,
                              icon: BridgeIcon('fileUp', size: 16),
                              label: const Text('Send File'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _syncNow,
                              icon:
                                  BridgeIcon('refreshCw', size: 16),
                              label: const Text('Sync Now'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _openRemote(isConnected),
                              icon: BridgeIcon('mouse', size: 16),
                              label: const Text('Remote'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: TextButton.icon(
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const ScanPairScreen()),
                                );
                              },
                              icon: BridgeIcon('plus', size: 16),
                              label: const Text('Pair New'),
                            ),
                          ),
                          Expanded(
                            child: TextButton(
                              onPressed: _unpair,
                              style: TextButton.styleFrom(
                                foregroundColor: BridgeColors.muted,
                              ),
                              child: const Text('Unpair'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),

              // ── Notification access banner (if not granted) ─────────
              if (!_notificationAccessGranted) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: BridgeColors.claySoft,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: BridgeColors.sand),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: BridgeColors.card,
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(color: BridgeColors.sand),
                        ),
                        child: BridgeIcon('bell',
                            color: BridgeColors.clayInk, size: 20),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Sync Phone Notifications',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'Fraunces',
                                color: BridgeColors.ink,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Show alerts & reply directly from your PC.',
                              style: TextStyle(
                                fontSize: 12,
                                color: BridgeColors.inkSoft,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () =>
                            NotificationsChannel.requestNotificationAccess(),
                        child: const Text('Enable'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // ── Incoming file receive progress ──────────────────────
              ValueListenableBuilder<FileReceiveProgress?>(
                valueListenable: FileTransferService.receiveProgress,
                builder: (context, rp, _) {
                  if (rp == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _FileReceiveCard(progress: rp),
                  );
                },
              ),

              // ── Segmented tabs ──────────────────────────────────────
              _SegmentedTabs(
                showNotifications: _showNotifications,
                onSelect: (v) => setState(() => _showNotifications = v),
              ),
              const SizedBox(height: 12),

              // ── Active panel ────────────────────────────────────────
              AnimatedSwitcher(
                duration: BridgeMotion.panelIn,
                child: _showNotifications
                    ? const _NotificationsPanel(key: ValueKey('notif'))
                    : const _ClipboardPanel(key: ValueKey('clip')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Status hero ──────────────────────────────────────────────────────────────

class _StatusHero extends StatelessWidget {
  final bool connected;
  final String serverUrl;
  final VoidCallback onReconnect;

  const _StatusHero({
    required this.connected,
    required this.serverUrl,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final host = serverUrl.replaceFirst(RegExp(r'https?://'), '');
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 4),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: connected
                      ? BridgeColors.sage
                      : BridgeColors.disconnectedDot,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 11),
              Flexible(
                child: Text(
                  connected ? 'Connected' : 'Not Connected',
                  style: BridgeText.statusMain,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            connected ? host : 'Pair your phone to start syncing',
            style: BridgeText.bodySoft,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          if (connected)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
              decoration: BoxDecoration(
                color: BridgeColors.sageSoft,
                border: Border.all(color: BridgeColors.sand),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BridgeIcon('shieldCheck',
                      size: 12, color: BridgeColors.sageDeep),
                  SizedBox(width: 6),
                  Text('ENCRYPTED · AES-256-GCM',
                      style: BridgeText.badgeCaps),
                ],
              ),
            )
          else
            TextButton.icon(
              onPressed: onReconnect,
              icon: BridgeIcon('refreshCw', size: 15),
              label: const Text('Reconnect'),
            ),
        ],
      ),
    );
  }
}

// ── Segmented tabs ───────────────────────────────────────────────────────────

class _SegmentedTabs extends StatelessWidget {
  final bool showNotifications;
  final ValueChanged<bool> onSelect;

  const _SegmentedTabs(
      {required this.showNotifications, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<NotificationHistoryItem>>(
      valueListenable: NotificationHistoryService.instance.items,
      builder: (context, notifs, _) {
        return ValueListenableBuilder<List<ClipboardHistoryItem>>(
          valueListenable: ClipboardHistoryService.instance.items,
          builder: (context, clips, _) {
            return Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: BridgeColors.sandSoft,
                border: Border.all(color: BridgeColors.sand),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  _Segment(
                    icon: 'bell',
                    label: 'Notifications',
                    count: notifs.length,
                    active: showNotifications,
                    onTap: () => onSelect(true),
                  ),
                  _Segment(
                    icon: 'clipboardList',
                    label: 'Clipboard',
                    count: clips.length,
                    active: !showNotifications,
                    onTap: () => onSelect(false),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _Segment extends StatelessWidget {
  final String icon;
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  const _Segment({
    required this.icon,
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: BridgeMotion.calm,
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
          decoration: BoxDecoration(
            color: active ? BridgeColors.card : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: active ? BridgeShadows.card : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              BridgeIcon(icon,
                  size: 15,
                  color: active
                      ? BridgeColors.ink
                      : BridgeColors.inkSoft),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'NunitoSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: active
                      ? BridgeColors.ink
                      : BridgeColors.inkSoft,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                  decoration: BoxDecoration(
                    color: BridgeColors.clay,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      fontFamily: 'NunitoSans',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: BridgeColors.creamText,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Notifications panel ──────────────────────────────────────────────────────

class _NotificationsPanel extends StatefulWidget {
  const _NotificationsPanel({super.key});

  @override
  State<_NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends State<_NotificationsPanel> {
  final Set<String> _expanded = {};
  final Map<String, String> _drafts = {};
  final Set<String> _sending = {};

  String _relative(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 5) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _submitReply(NotificationHistoryItem item) async {
    final text = (_drafts[item.notificationId] ?? '').trim();
    if (text.isEmpty || _sending.contains(item.notificationId)) return;
    setState(() => _sending.add(item.notificationId));
    try {
      final ok = await NotificationsChannel.sendReply(
          item.notificationId, text);
      if (!mounted) return;
      if (ok) {
        setState(() {
          _drafts.remove(item.notificationId);
          _expanded.remove(item.notificationId);
        });
      } else {
        await NotificationHistoryService.instance
            .setReplyError(item.notificationId, 'Reply failed — try again.');
      }
    } finally {
      if (mounted) setState(() => _sending.remove(item.notificationId));
    }
  }

  Future<void> _dismiss(NotificationHistoryItem item) async {
    await NotificationsChannel.dismissNotification(item.notificationId);
    await NotificationHistoryService.instance.remove(item.notificationId);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<NotificationHistoryItem>>(
      valueListenable: NotificationHistoryService.instance.items,
      builder: (context, notifs, _) {
        return BridgeCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Phone Notifications',
                      style: BridgeText.panelTitle),
                  const Spacer(),
                  if (notifs.isNotEmpty)
                    GestureDetector(
                      onTap: () =>
                          NotificationHistoryService.instance.clear(),
                      child: const Row(
                        children: [
                          BridgeIcon('trash',
                              size: 13, color: BridgeColors.inkSoft),
                          SizedBox(width: 4),
                          Text('Clear',
                              style: TextStyle(
                                fontFamily: 'NunitoSans',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: BridgeColors.inkSoft,
                              )),
                        ],
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: BridgeColors.sandSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('${notifs.length}/20',
                          style: BridgeText.count),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (notifs.isEmpty)
                const _EmptyPanel(
                  icon: 'bell',
                  message: 'No notifications yet.\nIncoming phone alerts will appear here.',
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: notifs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) =>
                      _notifItem(notifs[i]),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _notifItem(NotificationHistoryItem item) {
    final expanded = _expanded.contains(item.notificationId);
    final sending = _sending.contains(item.notificationId);
    final initial = item.appName.trim().isEmpty
        ? 'P'
        : item.appName.trim()[0].toUpperCase();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
      decoration: BoxDecoration(
        color: BridgeColors.card,
        border: Border.all(color: BridgeColors.sand),
        borderRadius: BorderRadius.circular(16),
      ),
      foregroundDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: BridgeColors.clay, width: 3),
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: BridgeColors.sandSoft,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: BridgeColors.clayInk,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.appName.isEmpty ? 'Phone' : item.appName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'NunitoSans',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: BridgeColors.ink,
                  ),
                ),
              ),
              Text(_relative(item.timestamp),
                  style: BridgeText.timestamp),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => _dismiss(item),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: BridgeIcon('x',
                      size: 14, color: BridgeColors.muted),
                ),
              ),
            ],
          ),
          if (item.title.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(item.title,
                style: BridgeText.notifTitle),
          ],
          if (item.text.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              item.text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: BridgeText.bodySoft,
            ),
          ],
          if (item.replyError != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: BridgeColors.claySoft,
                border: Border.all(color: BridgeColors.sand),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                item.replyError!,
                style: const TextStyle(
                  fontFamily: 'NunitoSans',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: BridgeColors.clayInk,
                ),
              ),
            ),
          ],
          if (item.hasReplyAction) ...[
            GestureDetector(
              onTap: () => setState(() {
                if (expanded) {
                  _expanded.remove(item.notificationId);
                } else {
                  _expanded.add(item.notificationId);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 2),
                child: Row(
                  children: [
                    BridgeIcon('messageCircle',
                        size: 14, color: BridgeColors.inkSoft),
                    const SizedBox(width: 6),
                    Text(
                      expanded ? 'Hide reply' : 'Reply',
                      style: const TextStyle(
                        fontFamily: 'NunitoSans',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: BridgeColors.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedContainer(
              duration: BridgeMotion.replyExpand,
              curve: BridgeMotion.calm,
              height: expanded ? 52 : 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: expanded ? 1 : 0,
                child: expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: ValueKey(
                                    'reply-${item.notificationId}'),
                                controller: TextEditingController(
                                    text: _drafts[item.notificationId]),
                                onChanged: (v) => _drafts[
                                    item.notificationId] = v,
                                onSubmitted: (_) => _submitReply(item),
                                decoration: InputDecoration(
                                  hintText:
                                      'Reply to ${item.appName.isEmpty ? 'notification' : item.appName}…',
                                  contentPadding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 9),
                                ),
                                style: const TextStyle(
                                  fontFamily: 'NunitoSans',
                                  fontSize: 13,
                                  color: BridgeColors.ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 11),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: sending
                                  ? null
                                  : () => _submitReply(item),
                              child: sending
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: BridgeColors.creamText,
                                      ),
                                    )
                                  : const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        BridgeIcon('send', size: 12),
                                        SizedBox(width: 5),
                                        Text('Send'),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Clipboard panel ──────────────────────────────────────────────────────────

class _ClipboardPanel extends StatefulWidget {
  const _ClipboardPanel({super.key});

  @override
  State<_ClipboardPanel> createState() => _ClipboardPanelState();
}

class _ClipboardPanelState extends State<_ClipboardPanel> {
  final Set<String> _copiedIds = {};

  String _relative(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 5) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _typeIcon(String type) {
    switch (type.toLowerCase()) {
      case 'url':
        return 'link';
      case 'otp':
        return 'key';
      case 'email':
        return 'mail';
      case 'phone':
        return 'phone';
      case 'image':
        return 'image';
      default:
        return 'fileText';
    }
  }

  Future<void> _copy(ClipboardHistoryItem item) async {
    await ClipboardHistoryService.instance.copyLocally(item);
    if (!mounted) return;
    setState(() => _copiedIds.add(item.id));
    await Future.delayed(BridgeMotion.copyFade);
    if (mounted) setState(() => _copiedIds.remove(item.id));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ClipboardHistoryItem>>(
      valueListenable: ClipboardHistoryService.instance.items,
      builder: (context, history, _) {
        return BridgeCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Clipboard History',
                      style: BridgeText.panelTitle),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: BridgeColors.sandSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('${history.length}/20',
                        style: BridgeText.count),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (history.isEmpty)
                const _EmptyPanel(
                  icon: 'clipboardList',
                  message: 'Nothing copied yet.\nCopy text on either device to sync it.',
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: history.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final item = history[i];
                    final isWindows = item.origin == 'windows';
                    final typeColor =
                        BridgeColors.typeColor(item.contentType);
                    final copied = _copiedIds.contains(item.id);

                    return GestureDetector(
                      onTap: () => _copy(item),
                      child: Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                            decoration: BoxDecoration(
                              color: BridgeColors.card,
                              border:
                                  Border.all(color: BridgeColors.sand),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    BridgeIcon(_typeIcon(item.contentType),
                                        size: 14, color: typeColor),
                                    const SizedBox(width: 6),
                                    Text(
                                      item.contentType.toUpperCase(),
                                      style: TextStyle(
                                        fontFamily: 'NunitoSans',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.6,
                                        color: typeColor,
                                      ),
                                    ),
                                    const Spacer(),
                                    BridgeIcon(
                                      isWindows
                                          ? 'monitor'
                                          : 'smartphone',
                                      size: 12,
                                      color: BridgeColors.muted,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      '${isWindows ? 'Windows' : 'Android'} · ${_relative(item.timestamp)}',
                                      style: BridgeText.timestamp,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                if (item.kind == 'image' &&
                                    item.imagePath != null &&
                                    File(item.imagePath!).existsSync())
                                  Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: BoxDecoration(
                                      color: BridgeColors.linen,
                                      border: Border.all(
                                          color: BridgeColors.sand),
                                      borderRadius:
                                          BorderRadius.circular(14),
                                    ),
                                    child: ClipRRect(
                                      borderRadius:
                                          BorderRadius.circular(11),
                                      child: ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(
                                                maxHeight: 150),
                                        child: Image.file(
                                          File(item.imagePath!),
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) =>
                                              const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: BridgeIcon(
                                                'imageOff',
                                                size: 28,
                                                color: BridgeColors.muted),
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                else
                                  Text(
                                    item.text ?? '',
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: BridgeText.body,
                                  ),
                              ],
                            ),
                          ),
                          // Calm copy confirmation: sage check fades in/out.
                          Positioned(
                            top: 12,
                            right: 14,
                            child: AnimatedOpacity(
                              duration:
                                  const Duration(milliseconds: 180),
                              opacity: copied ? 1 : 0,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 3),
                                decoration: BoxDecoration(
                                  color: BridgeColors.sageSoft,
                                  borderRadius:
                                      BorderRadius.circular(999),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    BridgeIcon('check',
                                        size: 12,
                                        color: BridgeColors.sageDeep),
                                    SizedBox(width: 4),
                                    Text(
                                      'Copied',
                                      style: TextStyle(
                                        fontFamily: 'NunitoSans',
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: BridgeColors.sageDeep,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
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

// ── Shared bits ──────────────────────────────────────────────────────────────

/// Calm empty state: sage tile + muted two-line message.
class _EmptyPanel extends StatelessWidget {
  final String icon;
  final String message;

  const _EmptyPanel({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Column(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: BridgeColors.sageSoft,
                borderRadius: BorderRadius.circular(18),
              ),
              child: BridgeIcon(icon,
                  size: 24, color: BridgeColors.sageDeep),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'NunitoSans',
                fontSize: 13,
                height: 1.6,
                color: BridgeColors.inkSoft,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows incoming file receive progress (Windows → Android) in BridgeHome.
class _FileReceiveCard extends StatelessWidget {
  final FileReceiveProgress progress;

  const _FileReceiveCard({required this.progress});

  @override
  Widget build(BuildContext context) {
    final isError = progress.error;
    final isDone = progress.done && !isError;

    return BridgeCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: isError
                      ? BridgeColors.claySoft
                      : isDone
                          ? BridgeColors.sageSoft
                          : BridgeColors.sandSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: BridgeIcon(
                  isError
                      ? 'x'
                      : isDone
                          ? 'check'
                          : 'download',
                  size: 15,
                  color: isError
                      ? BridgeColors.clayInk
                      : isDone
                          ? BridgeColors.sageDeep
                          : BridgeColors.ink,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isError
                      ? 'Receive failed: ${progress.fileName}'
                      : isDone
                          ? 'Received: ${progress.fileName}'
                          : 'Receiving: ${progress.fileName}',
                  style: BridgeText.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (!isDone && !isError) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.fraction,
                backgroundColor: BridgeColors.sandSoft,
                valueColor: const AlwaysStoppedAnimation<Color>(
                    BridgeColors.clay),
                minHeight: 6,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
