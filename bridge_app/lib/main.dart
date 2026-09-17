import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:file_picker/file_picker.dart';
import 'theme/bridge_icons.dart';
import 'services/socket_service.dart';
import 'services/clipboard_service.dart';
import 'services/camera_service.dart';
// MIC PARKED — Phone as Microphone, revisit later:
// import 'services/mic_service.dart';
import 'services/file_transfer_service.dart';
import 'services/pairing_storage_service.dart';
import 'services/discovery_service.dart';
import 'services/background_service.dart';
import 'services/system_channel.dart';
import 'services/clipboard_history_service.dart';
import 'services/notification_history_service.dart';
import 'services/notifications_channel.dart';
import 'services/remote_input_service.dart';
import 'screens/scan_pair_screen.dart';
import 'screens/share_progress_screen.dart';
import 'screens/camera_screen.dart';
// MIC PARKED — Phone as Microphone, revisit later:
// import 'screens/mic_screen.dart';
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
  // MIC PARKED — Phone as Microphone, revisit later:
  // MicService.instance.init();
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

  /* MIC PARKED — Phone as Microphone, revisit later. Uncomment to restore.
  MicService.instance.onStartMicRequested = () {
    if (MicService.instance.isStreaming.value) return;
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    final url = SocketService.instance.currentUrl ?? '';
    final pcName = url.isNotEmpty
        ? url.replaceFirst(RegExp(r'https?://'), '').split(':').first
        : 'Windows PC';
    debugPrint('[main] Remote start-mic received — pushing MicScreen(pcName: $pcName)');
    nav.push(
      MaterialPageRoute(
        builder: (_) => MicScreen(pcName: pcName),
      ),
    ).then((_) {
      debugPrint('[main] Returned from remote-launched MicScreen');
    });
  };
  */

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
  int _tabIndex = 0;

  bool _notificationAccessGranted = false;
  bool _batteryUnrestricted = false;
  bool _screenshotGranted = false;

  bool _isReconnecting = false;
  String? _reconnectMessage;
  String? _lastKnownHost;
  StreamSubscription? _reconnectStateSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitialPairing();
    _listenToReconnectEvents();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkPermissionsAndBattery();
      await _refreshSetupState();
      ClipboardService.instance.syncNow();
    });
  }

  Future<void> _loadInitialPairing() async {
    await _refreshPairings();
  }

  Future<void> _refreshPairings() async {
    final active = await PairingStorageService.instance.getPairing();
    if (!mounted) return;
    setState(() {
      if (active != null) {
        _lastKnownHost = '${active.ip}:${active.port}';
      }
    });
  }

  void _listenToReconnectEvents() {
    final service = FlutterBackgroundService();
    _reconnectStateSub = service.on('reconnect_state').listen((event) {
      if (!mounted || event == null) return;
      final state = event['state'] as String?;
      setState(() {
        if (state == 'connecting') {
          _isReconnecting = true;
          _reconnectMessage = 'Connecting to ${event['ip'] ?? 'PC'}…';
          if (event['ip'] != null) {
            _lastKnownHost = '${event['ip']}:${event['port'] ?? 4000}';
          }
        } else if (state == 'searching_lan') {
          _isReconnecting = true;
          _reconnectMessage = 'Looking for your PC on this network…';
        } else if (state == 'found') {
          _isReconnecting = true;
          _reconnectMessage = 'Found your PC at ${event['ip']}. Connecting…';
          _lastKnownHost = '${event['ip']}:${event['port'] ?? 4000}';
        } else if (state == 'not_found') {
          _isReconnecting = false;
          _reconnectMessage = 'PC not reachable at ${event['lastKnownIp'] ?? 'last known address'}';
        } else if (state == 'unpaired') {
          _isReconnecting = false;
          _reconnectMessage = null;
        }
      });
    });

    SocketService.instance.connected.addListener(_onSocketConnectedChange);
  }

  void _onSocketConnectedChange() {
    if (mounted && SocketService.instance.isConnected) {
      setState(() {
        _isReconnecting = false;
        _reconnectMessage = null;
        if (SocketService.instance.currentUrl != null) {
          _lastKnownHost = SocketService.instance.currentUrl!.replaceFirst(RegExp(r'https?://'), '');
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reconnectStateSub?.cancel();
    SocketService.instance.connected.removeListener(_onSocketConnectedChange);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkNotificationAccess();
      _refreshSetupState();
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

  Future<void> _refreshSetupState() async {
    if (!Platform.isAndroid || !mounted) return;
    final notif = await NotificationsChannel.isNotificationAccessGranted().catchError((_) => false);
    final battery = await SystemChannel.isIgnoringBatteryOptimizations().catchError((_) => true);
    final shots = await ClipboardService.isScreenshotAccessGranted().catchError((_) => false);
    if (!mounted) return;
    setState(() {
      _notificationAccessGranted = notif;
      _batteryUnrestricted = battery;
      _screenshotGranted = shots;
    });
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
      if (mounted) {
        setState(() => _batteryUnrestricted = isIgnoring);
      }
      if (!isIgnoring && mounted) {
        await _showBatteryOptimizationDialog();
        await _refreshSetupState();
      }
    }
  }

  Future<void> _showBatteryOptimizationDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text('Keep Bridge running in background'),
        content: const Text(
          'To receive files, notifications and clipboard updates when your phone is idle or locked, allow Bridge to run unrestricted in the background.\n\nOn some devices (Xiaomi, Oppo, Vivo, Samsung) also enable Autostart in system settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              SystemChannel.requestIgnoreBatteryOptimizations().then((_) => _refreshSetupState());
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
        title: const Text('Remove this PC?'),
        content: const Text(
          'Bridge will forget this computer, delete encryption keys and stop background sync. You can pair again at any time by scanning a new QR code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: BridgeColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      BackgroundService.stop();
      await PairingStorageService.instance.clearAll();
      SocketService.instance.setEncryptionKey(null);
      SocketService.instance.disconnect();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ScanPairScreen()),
      );
    }
  }

  void _openPairNew() {
    Navigator.of(context)
        .push(
      MaterialPageRoute(builder: (_) => const ScanPairScreen()),
    )
        .then((_) {
      // ScanPairScreen replaces itself on success; a return means cancelled.
      _refreshPairings();
    });
  }

  Future<void> _handleReconnect() async {
    setState(() {
      _isReconnecting = true;
      _reconnectMessage = 'Connecting…';
    });
    await BackgroundService.start();
    BackgroundService.restartSocket(forceDiscovery: false);

    // If after 3.5s it's still disconnected and hasn't started searching, auto-trigger LAN search
    Future.delayed(const Duration(milliseconds: 3500), () {
      if (mounted && !SocketService.instance.isConnected && _isReconnecting) {
        if (_reconnectMessage != 'Looking for your PC on this network…') {
          setState(() {
            _reconnectMessage = 'Looking for your PC on this network…';
          });
          BackgroundService.restartSocket(forceDiscovery: true);
        }
      }
    });
  }

  Future<void> _showChangeIpDialog() async {
    final pairing = await PairingStorageService.instance.getPairing();
    final initialIp = pairing?.ip ?? (_lastKnownHost?.split(':').first ?? '');
    final initialPort = pairing?.port ?? 4000;

    final ipCtrl = TextEditingController(text: initialIp);
    final portCtrl = TextEditingController(text: initialPort.toString());
    bool isDetecting = false;

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('PC connection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'If your PC changed networks, enter its new address or detect it automatically.',
                style: BridgeText.bodySoft,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ipCtrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'PC IP address',
                  hintText: 'e.g. 192.168.1.43',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: portCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  hintText: '4000',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: isDetecting
                    ? null
                    : () async {
                        setDialogState(() => isDetecting = true);
                        final discovered = await DiscoveryService.findBridgeHost(
                          port: int.tryParse(portCtrl.text) ?? 4000,
                        );
                        setDialogState(() => isDetecting = false);
                        if (discovered != null) {
                          ipCtrl.text = discovered.ip;
                          portCtrl.text = discovered.port.toString();
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('Found PC at ${discovered.ip}:${discovered.port}')),
                            );
                          }
                        } else {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('No PC found. Make sure Bridge is open on your computer.')),
                            );
                          }
                        }
                      },
                icon: isDetecting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const BridgeIcon('refreshCw', size: 14),
                label: Text(isDetecting ? 'Searching…' : 'Find automatically'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final newIp = ipCtrl.text.trim();
                final newPort = int.tryParse(portCtrl.text.trim()) ?? 4000;
                if (newIp.isEmpty) return;

                Navigator.pop(ctx);
                setState(() {
                  _lastKnownHost = '$newIp:$newPort';
                  _isReconnecting = true;
                  _reconnectMessage = 'Connecting to $newIp…';
                });
                await BackgroundService.start();
                BackgroundService.restartSocket(manualIp: newIp, manualPort: newPort);
              },
              child: const Text('Save & connect'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _syncNow() async {
    await _ensureScreenshotAccess();
    final result = await ClipboardService.instance.syncNow(force: true);
    await _refreshSetupState();
    if (!mounted) return;
    String msg;
    switch (result) {
      case SyncDirectionResult.pulledFromWindows:
        msg = 'Clipboard updated from your PC';
        break;
      case SyncDirectionResult.sentToWindows:
        msg = 'Clipboard sent to your PC';
        break;
      case SyncDirectionResult.upToDate:
        msg = SocketService.instance.isConnected
            ? 'Already up to date with your PC'
            : 'Clipboard checked';
        break;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Explains screenshot sync and requests media access before a manual sync.
  /// Silent when access is already granted; never prompts on app resume
  /// (ClipboardService.syncNow only checks screenshots when already allowed).
  Future<void> _ensureScreenshotAccess() async {
    if (!Platform.isAndroid || !mounted) return;
    if (await ClipboardService.isScreenshotAccessGranted()) return;
    if (ClipboardService.screenshotRationaleDismissed) return;
    if (!mounted) return;

    final proceed = await showDialog<bool>(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => AlertDialog(
            title: const Text('Also sync screenshots?'),
            content: const Text(
              'Allow photo access and screenshots you take will paste directly on your PC. Text and copied images keep working either way.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Skip'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Allow'),
              ),
            ],
          ),
        ) ??
        false;

    if (!proceed) {
      ClipboardService.screenshotRationaleDismissed = true;
      return;
    }
    await ClipboardService.requestScreenshotAccess();
  }

  Future<void> _sendFile() async {
    final picked = await FilePicker.pickFiles(type: FileType.any);
    if (picked.isEmpty) return;
    final uris = picked.map((f) => f.path).whereType<String>().toList();
    if (!mounted) return;
    try {
      await FileTransferService.sendFiles(uris);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sending to your PC…')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send: $e')),
        );
      }
    }
  }

  void _openWebcam(bool isConnected) {
    if (!isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to your PC first')),
      );
      return;
    }
    final url = SocketService.instance.currentUrl ?? '';
    final pcName = url.isNotEmpty
        ? url.replaceFirst(RegExp(r'https?://'), '').split(':').first
        : 'Windows PC';
    debugPrint('[BridgeHome] Tapped webcam — pushing CameraScreen(pcName: $pcName)');
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
    if (!isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect to your PC first')),
      );
      return;
    }
    debugPrint('[BridgeHome] Tapped remote — pushing RemoteScreen');
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

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _buildHomeTab(),
          const _ClipboardTab(),
          const _NotificationsTab(),
          _buildSettingsTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: [
          const NavigationDestination(
            icon: BridgeIcon('smartphone', size: 20),
            selectedIcon: BridgeIcon('smartphone', size: 20, color: BridgeColors.clay),
            label: 'Home',
          ),
          NavigationDestination(
            icon: const BridgeIcon('clipboardList', size: 20),
            selectedIcon: const BridgeIcon('clipboardList', size: 20, color: BridgeColors.clay),
            label: 'Clipboard',
          ),
          NavigationDestination(
            icon: const BridgeIcon('bell', size: 20),
            selectedIcon: const BridgeIcon('bell', size: 20, color: BridgeColors.clay),
            label: 'Notifications',
          ),
          NavigationDestination(
            icon: const BridgeIcon('settings', size: 20),
            selectedIcon: const BridgeIcon('settings', size: 20, color: BridgeColors.clay),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final titles = ['Bridge', 'Clipboard', 'Notifications', 'Settings'];
    final subtitles = [
      _lastKnownHost ?? '',
      'Tap any item to copy it back',
      'Phone alerts, mirrored to PC',
      'Devices, permissions & about',
    ];
    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: BridgeColors.clay,
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: const BridgeIcon('link', size: 19, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titles[_tabIndex], style: BridgeText.brand),
                if (subtitles[_tabIndex].isNotEmpty)
                  Text(
                    _tabIndex == 0 && _lastKnownHost != null
                        ? 'Connected to ${_lastKnownHost!}'
                        : subtitles[_tabIndex],
                    style: BridgeText.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (_tabIndex == 0)
          IconButton(
            icon: const BridgeIcon('qrCode', size: 20),
            tooltip: 'Pair a new PC',
            onPressed: _openPairNew,
          ),
        if (_tabIndex == 2)
          ValueListenableBuilder<List<NotificationHistoryItem>>(
            valueListenable: NotificationHistoryService.instance.items,
            builder: (context, notifs, _) {
              if (notifs.isEmpty) return const SizedBox.shrink();
              return TextButton(
                onPressed: () => NotificationHistoryService.instance.clear(),
                child: const Text('Clear'),
              );
            },
          ),
      ],
    );
  }

  // ── Home tab ─────────────────────────────────────────────────────────────

  Widget _buildHomeTab() {
    return ValueListenableBuilder<bool>(
      valueListenable: SocketService.instance.connected,
      builder: (context, isConnected, _) {
        final displayUrl = isConnected
            ? (SocketService.instance.currentUrl ?? '')
            : (_lastKnownHost != null ? 'http://$_lastKnownHost' : '');
        return RefreshIndicator(
          onRefresh: () async {
            await _refreshSetupState();
            if (isConnected) await ClipboardService.instance.syncNow();
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ConnectionCard(
                  connected: isConnected,
                  serverUrl: displayUrl,
                  isReconnecting: _isReconnecting,
                  reconnectMessage: _reconnectMessage,
                  onReconnect: _handleReconnect,
                  onChangeIp: _showChangeIpDialog,
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<FileReceiveProgress?>(
                  valueListenable: FileTransferService.receiveProgress,
                  builder: (context, rp, _) {
                    if (rp == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _FileReceiveCard(progress: rp),
                    );
                  },
                ),
                _SetupChecklistCard(
                  notificationsOn: _notificationAccessGranted,
                  batteryOk: _batteryUnrestricted,
                  screenshotsOn: _screenshotGranted,
                  onEnableNotifications: () async {
                    await NotificationsChannel.requestNotificationAccess();
                    await _refreshSetupState();
                  },
                  onFixBattery: () async {
                    await SystemChannel.requestIgnoreBatteryOptimizations();
                    await _refreshSetupState();
                  },
                  onEnableScreenshots: () async {
                    await ClipboardService.requestScreenshotAccess();
                    await _refreshSetupState();
                  },
                ),
                const SizedBox(height: 12),
                _SectionHeader(
                  title: 'Control your PC',
                  subtitle: 'Needs the app open',
                ),
                const SizedBox(height: 8),
                _QuickActionsGrid(
                  isConnected: isConnected,
                  onWebcam: () => _openWebcam(isConnected),
                  onRemote: () => _openRemote(isConnected),
                  onSendFile: _sendFile,
                  onSync: _syncNow,
                ),
                const SizedBox(height: 12),
                const _HowItWorksCard(),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Settings tab ─────────────────────────────────────────────────────────

  Widget _buildSettingsTab() {
    return ValueListenableBuilder<bool>(
      valueListenable: SocketService.instance.connected,
      builder: (context, isConnected, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SectionHeader(title: 'This connection'),
              const SizedBox(height: 8),
              BridgeCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: 'monitor',
                      title: 'PC address',
                      subtitle: _lastKnownHost ?? 'Unknown',
                      trailing: _StatusPill(
                        text: isConnected ? 'Connected' : 'Offline',
                        ok: isConnected,
                      ),
                    ),
                    const Divider(height: 1, indent: 52),
                    _SettingsRow(
                      icon: 'refreshCw',
                      title: 'Reconnect',
                      subtitle: 'Retry the last known address',
                      onTap: _isReconnecting ? null : _handleReconnect,
                    ),
                    const Divider(height: 1, indent: 52),
                    _SettingsRow(
                      icon: 'settings',
                      title: 'Change PC address',
                      subtitle: 'Manual IP or auto-detect',
                      onTap: _showChangeIpDialog,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _SectionHeader(title: 'Background & permissions'),
              const SizedBox(height: 8),
              BridgeCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: 'bell',
                      title: 'Phone notifications',
                      subtitle: _notificationAccessGranted ? 'Mirrored to PC' : 'Not enabled',
                      trailing: _StatusPill(text: _notificationAccessGranted ? 'On' : 'Off', ok: _notificationAccessGranted),
                      onTap: () async {
                        await NotificationsChannel.requestNotificationAccess();
                        await _refreshSetupState();
                      },
                    ),
                    const Divider(height: 1, indent: 52),
                    _SettingsRow(
                      icon: 'batteryCharging',
                      title: 'Run in background',
                      subtitle: _batteryUnrestricted ? 'Unrestricted' : 'May stop when idle',
                      trailing: _StatusPill(text: _batteryUnrestricted ? 'On' : 'Fix', ok: _batteryUnrestricted),
                      onTap: () async {
                        if (_batteryUnrestricted) return;
                        await _showBatteryOptimizationDialog();
                        await _refreshSetupState();
                      },
                    ),
                    const Divider(height: 1, indent: 52),
                    _SettingsRow(
                      icon: 'image',
                      title: 'Screenshot sync',
                      subtitle: _screenshotGranted ? 'Screenshots paste on PC' : 'Optional',
                      trailing: _StatusPill(text: _screenshotGranted ? 'On' : 'Off', ok: _screenshotGranted),
                      onTap: () async {
                        await ClipboardService.requestScreenshotAccess();
                        await _refreshSetupState();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _SectionHeader(title: 'Devices'),
              const SizedBox(height: 8),
              BridgeCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: 'plus',
                      title: 'Pair a new PC',
                      subtitle: 'Scan a QR code',
                      onTap: _openPairNew,
                    ),
                    const Divider(height: 1, indent: 52),
                    _SettingsRow(
                      icon: 'x',
                      title: 'Remove this PC',
                      subtitle: 'Delete keys and stop sync',
                      onTap: _unpair,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              BridgeCard(
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: BridgeColors.sageSoft,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      alignment: Alignment.center,
                      child: const BridgeIcon('shieldCheck', size: 18, color: BridgeColors.sageDeep),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Private by design', style: BridgeText.notifTitle),
                          SizedBox(height: 2),
                          Text(
                            'AES-256 encrypted. Devices talk over your local network only — nothing leaves your Wi-Fi.',
                            style: BridgeText.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text('Bridge for Android · v1.0', style: BridgeText.timestamp),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── Connection card ────────────────────────────────────────────────────────

class _ConnectionCard extends StatelessWidget {
  final bool connected;
  final String serverUrl;
  final bool isReconnecting;
  final String? reconnectMessage;
  final VoidCallback onReconnect;
  final VoidCallback onChangeIp;

  const _ConnectionCard({
    required this.connected,
    required this.serverUrl,
    required this.isReconnecting,
    this.reconnectMessage,
    required this.onReconnect,
    required this.onChangeIp,
  });

  @override
  Widget build(BuildContext context) {
    final host = serverUrl.replaceFirst(RegExp(r'https?://'), '');
    final Color dot = connected
        ? BridgeColors.sage
        : (isReconnecting ? BridgeColors.warning : BridgeColors.disconnectedDot);
    final String title = connected
        ? 'Connected'
        : (isReconnecting ? 'Connecting…' : 'Not connected');
    final String subtitle = connected
        ? host
        : (reconnectMessage ?? (host.isNotEmpty ? 'Last PC: $host' : 'Pair once — stays connected'));

    return BridgeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusDot(color: dot, pulsing: isReconnecting && !connected),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: BridgeText.panelTitle),
                    const SizedBox(height: 1),
                    Text(subtitle, style: BridgeText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (connected)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: BridgeColors.sageSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      BridgeIcon('shieldCheck', size: 12, color: BridgeColors.sageDeep),
                      SizedBox(width: 5),
                      Text('ENCRYPTED', style: BridgeText.badgeCaps),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: BridgeColors.linen,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const BridgeIcon('check', size: 14, color: BridgeColors.sageDeep),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    connected
                        ? 'Background sync is on — you can close this app.'
                        : 'Bridge reconnects automatically when your PC is back on Wi-Fi.',
                    style: BridgeText.caption,
                  ),
                ),
              ],
            ),
          ),
          if (!connected) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isReconnecting ? null : onReconnect,
                    icon: isReconnecting
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const BridgeIcon('refreshCw', size: 15),
                    label: Text(isReconnecting ? 'Connecting…' : 'Reconnect'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isReconnecting ? null : onChangeIp,
                    icon: const BridgeIcon('settings', size: 15),
                    label: const Text('PC address'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusDot extends StatefulWidget {
  final Color color;
  final bool pulsing;
  const _StatusDot({required this.color, this.pulsing = false});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
    if (widget.pulsing) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusDot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.pulsing && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.pulsing) {
      return Container(width: 12, height: 12, decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle));
    }
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.35).animate(_c),
      child: Container(width: 12, height: 12, decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle)),
    );
  }
}

// ── Setup checklist ────────────────────────────────────────────────────────

class _SetupChecklistCard extends StatelessWidget {
  final bool notificationsOn;
  final bool batteryOk;
  final bool screenshotsOn;
  final VoidCallback onEnableNotifications;
  final VoidCallback onFixBattery;
  final VoidCallback onEnableScreenshots;

  const _SetupChecklistCard({
    required this.notificationsOn,
    required this.batteryOk,
    required this.screenshotsOn,
    required this.onEnableNotifications,
    required this.onFixBattery,
    required this.onEnableScreenshots,
  });

  @override
  Widget build(BuildContext context) {
    final done = (notificationsOn ? 1 : 0) + (batteryOk ? 1 : 0) + (screenshotsOn ? 1 : 0);
    final allDone = done == 3;
    return BridgeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(allDone ? 'You\'re all set' : 'Finish setup ($done of 3)', style: BridgeText.panelTitle),
                    const SizedBox(height: 2),
                    Text(
                      allDone
                          ? 'Scan once — everything runs automatically from here.'
                          : 'One-time setup. Afterwards you rarely need to open this app.',
                      style: BridgeText.caption,
                    ),
                  ],
                ),
              ),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: allDone ? BridgeColors.sageSoft : BridgeColors.claySoft,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: BridgeIcon(
                  allDone ? 'check' : 'bell',
                  size: 19,
                  color: allDone ? BridgeColors.sageDeep : BridgeColors.clay,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: done / 3,
              minHeight: 6,
              backgroundColor: BridgeColors.sandSoft,
              valueColor: AlwaysStoppedAnimation<Color>(allDone ? BridgeColors.sage : BridgeColors.clay),
            ),
          ),
          const SizedBox(height: 4),
          _CheckRow(
            done: notificationsOn,
            icon: 'bell',
            title: 'Phone notifications on PC',
            subtitle: 'See and reply from your computer',
            actionLabel: notificationsOn ? null : 'Enable',
            onAction: onEnableNotifications,
          ),
          _CheckRow(
            done: batteryOk,
            icon: 'batteryCharging',
            title: 'Run in background',
            subtitle: 'Keeps working when phone is locked',
            actionLabel: batteryOk ? null : 'Allow',
            onAction: onFixBattery,
          ),
          _CheckRow(
            done: screenshotsOn,
            icon: 'image',
            title: 'Screenshot sync',
            subtitle: 'Screenshots paste straight to PC',
            actionLabel: screenshotsOn ? null : 'Enable',
            onAction: onEnableScreenshots,
            last: true,
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final bool done;
  final String icon;
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback onAction;
  final bool last;

  const _CheckRow({
    required this.done,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onAction,
    this.actionLabel,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: done ? BridgeColors.sageSoft : BridgeColors.linen,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: BridgeIcon(
                  done ? 'check' : icon,
                  size: 16,
                  color: done ? BridgeColors.sageDeep : BridgeColors.inkSoft,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: BridgeText.notifTitle),
                    Text(subtitle, style: BridgeText.caption),
                  ],
                ),
              ),
              if (!done && actionLabel != null)
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onAction,
                  child: Text(actionLabel!),
                )
              else if (done)
                const BridgeIcon('check', size: 16, color: BridgeColors.sage),
            ],
          ),
        ),
        if (!last) const Divider(height: 1, indent: 46),
      ],
    );
  }
}

// ── Quick actions ──────────────────────────────────────────────────────────

class _QuickActionsGrid extends StatelessWidget {
  final bool isConnected;
  final VoidCallback onWebcam;
  final VoidCallback onRemote;
  final VoidCallback onSendFile;
  final VoidCallback onSync;

  const _QuickActionsGrid({
    required this.isConnected,
    required this.onWebcam,
    required this.onRemote,
    required this.onSendFile,
    required this.onSync,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.35,
      children: [
        _ActionTile(
          icon: 'camera',
          title: 'Webcam',
          subtitle: 'Use phone camera',
          primary: true,
          enabled: isConnected,
          onTap: onWebcam,
        ),
        _ActionTile(
          icon: 'mouse',
          title: 'Remote',
          subtitle: 'Trackpad + keys',
          enabled: isConnected,
          onTap: onRemote,
        ),
        _ActionTile(
          icon: 'fileUp',
          title: 'Send file',
          subtitle: 'To your PC',
          onTap: onSendFile,
        ),
        _ActionTile(
          icon: 'refreshCw',
          title: 'Sync clipboard',
          subtitle: 'Push latest copy',
          onTap: onSync,
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  final String icon;
  final String title;
  final String subtitle;
  final bool primary;
  final bool enabled;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.primary = false,
    this.enabled = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final double opacity = enabled ? 1 : 0.55;
    return Opacity(
      opacity: opacity,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: primary ? BridgeColors.clay : BridgeColors.card,
            border: Border.all(color: primary ? BridgeColors.clay : BridgeColors.sand),
            borderRadius: BorderRadius.circular(16),
            boxShadow: BridgeShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: primary ? Colors.white.withAlpha(38) : BridgeColors.claySoft,
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: BridgeIcon(icon, size: 18, color: primary ? Colors.white : BridgeColors.clay),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: BridgeText.notifTitle.copyWith(
                      color: primary ? Colors.white : BridgeColors.ink,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: BridgeText.caption.copyWith(
                      color: primary ? Colors.white.withAlpha(210) : BridgeColors.inkSoft,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard();

  @override
  Widget build(BuildContext context) {
    return BridgeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text('No need to keep opening this app', style: BridgeText.panelTitle),
          SizedBox(height: 4),
          Text(
            'After this one-time setup, Bridge works quietly in the background.',
            style: BridgeText.caption,
          ),
          SizedBox(height: 12),
          _HowRow(icon: 'clipboardList', text: 'Copy on either device — open Bridge to push it to your PC.'),
          SizedBox(height: 8),
          _HowRow(icon: 'bell', text: 'Phone notifications appear on your PC automatically.'),
          SizedBox(height: 8),
          _HowRow(icon: 'fileUp', text: 'Share from any app to send files straight to your PC.'),
        ],
      ),
    );
  }
}

class _HowRow extends StatelessWidget {
  final String icon;
  final String text;
  const _HowRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: BridgeColors.linen,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: BridgeIcon(icon, size: 14, color: BridgeColors.inkSoft),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: BridgeText.bodySoft)),
      ],
    );
  }
}

// ── Shared bits ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  const _SectionHeader({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: BridgeText.panelTitle),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!, style: BridgeText.caption),
        ],
      ],
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: BridgeColors.linen,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: BridgeIcon(icon, size: 16, color: BridgeColors.inkSoft),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: BridgeText.notifTitle,
                  ),
                  Text(subtitle, style: BridgeText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            trailing ?? const SizedBox.shrink(),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              const BridgeIcon('arrowLeft', size: 0, color: Colors.transparent),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String text;
  final bool ok;
  const _StatusPill({required this.text, required this.ok});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: ok ? BridgeColors.sageSoft : BridgeColors.linen,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: ok ? BridgeColors.sageDeep : BridgeColors.inkSoft,
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: isError
                      ? BridgeColors.errorSoft
                      : isDone
                          ? BridgeColors.sageSoft
                          : BridgeColors.claySoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: BridgeIcon(
                  isError
                      ? 'x'
                      : isDone
                          ? 'check'
                          : 'download',
                  size: 16,
                  color: isError
                      ? BridgeColors.error
                      : isDone
                          ? BridgeColors.sageDeep
                          : BridgeColors.clay,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isError
                          ? 'Could not receive file'
                          : isDone
                              ? 'Received from PC'
                              : 'Receiving from PC…',
                      style: BridgeText.caption,
                    ),
                    Text(
                      progress.fileName,
                      style: BridgeText.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Text(
                '${(progress.fraction * 100).clamp(0, 100).toStringAsFixed(0)}%',
                style: BridgeText.count,
              ),
            ],
          ),
          if (!isDone && !isError) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 6,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Clipboard tab ──────────────────────────────────────────────────────────

class _ClipboardTab extends StatefulWidget {
  const _ClipboardTab();

  @override
  State<_ClipboardTab> createState() => _ClipboardTabState();
}

class _ClipboardTabState extends State<_ClipboardTab> {
  final Set<String> _copiedIds = {};
  String _query = '';

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
        final q = _query.trim().toLowerCase();
        final visible = q.isEmpty
            ? history
            : history.where((i) => (i.text ?? '').toLowerCase().contains(q)).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search clipboard',
                  prefixIcon: const Padding(
                    padding: EdgeInsets.all(12),
                    child: BridgeIcon('fileText', size: 16),
                  ),
                  filled: true,
                  fillColor: BridgeColors.card,
                ),
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? _EmptyState(
                      icon: 'clipboardList',
                      title: q.isEmpty ? 'Nothing here yet' : 'No matches',
                      message: q.isEmpty
                          ? 'Copy text on either device and it will show up here.'
                          : 'Try a different search.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final item = visible[i];
                        final typeColor = BridgeColors.typeColor(item.contentType);
                        final copied = _copiedIds.contains(item.id);
                        return GestureDetector(
                          onTap: () => _copy(item),
                          child: BridgeCard(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    BridgeIcon(_typeIcon(item.contentType), size: 13, color: typeColor),
                                    const SizedBox(width: 6),
                                    Text(
                                      item.contentType.toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.6,
                                        color: typeColor,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                if (item.kind == 'image' && item.imagePath != null && File(item.imagePath!).existsSync())
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(maxHeight: 160),
                                      child: Image.file(
                                        File(item.imagePath!),
                                        fit: BoxFit.cover,
                                        width: double.infinity,
                                        errorBuilder: (_, _, _) => const Padding(
                                          padding: EdgeInsets.all(12),
                                          child: BridgeIcon('imageOff', size: 28, color: BridgeColors.muted),
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
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    BridgeIcon(copied ? 'check' : 'copy', size: 13, color: copied ? BridgeColors.sageDeep : BridgeColors.inkSoft),
                                    const SizedBox(width: 6),
                                    Text(
                                      copied ? 'Copied to this phone' : 'Tap to copy to this phone',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: copied ? BridgeColors.sageDeep : BridgeColors.inkSoft,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

// ── Notifications tab ──────────────────────────────────────────────────────

class _NotificationsTab extends StatefulWidget {
  const _NotificationsTab();

  @override
  State<_NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends State<_NotificationsTab> {
  final Set<String> _expanded = {};
  final Map<String, String> _drafts = {};
  final Set<String> _sending = {};

  String _relative(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 5) return 'Just now';
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
      final ok = await NotificationsChannel.sendReply(item.notificationId, text);
      if (!mounted) return;
      if (ok) {
        setState(() {
          _drafts.remove(item.notificationId);
          _expanded.remove(item.notificationId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reply sent'), duration: Duration(seconds: 1)),
        );
      } else {
        await NotificationHistoryService.instance.setReplyError(item.notificationId, 'Could not send reply — try again.');
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
        if (notifs.isEmpty) {
          return const _EmptyState(
            icon: 'bell',
            title: 'No notifications yet',
            message: 'Phone alerts will appear here and on your PC automatically.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: notifs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _notifItem(notifs[i]),
        );
      },
    );
  }

  Widget _notifItem(NotificationHistoryItem item) {
    final expanded = _expanded.contains(item.notificationId);
    final sending = _sending.contains(item.notificationId);
    final initial = item.appName.trim().isEmpty ? '•' : item.appName.trim()[0].toUpperCase();

    return BridgeCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: BridgeColors.linen,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(initial, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: BridgeColors.ink)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.appName.isEmpty ? 'Phone' : item.appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: BridgeColors.ink),
                    ),
                    Text(_relative(item.timestamp), style: BridgeText.timestamp),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const BridgeIcon('x', size: 15, color: BridgeColors.muted),
                tooltip: 'Dismiss',
                onPressed: () => _dismiss(item),
              ),
            ],
          ),
          if (item.title.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(item.title, style: BridgeText.notifTitle),
          ],
          if (item.text.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(item.text, maxLines: 4, overflow: TextOverflow.ellipsis, style: BridgeText.bodySoft),
          ],
          if (item.replyError != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: BridgeColors.errorSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(item.replyError!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: BridgeColors.error)),
            ),
          ],
          if (item.hasReplyAction) ...[
            const SizedBox(height: 8),
            if (!expanded)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _expanded.add(item.notificationId)),
                icon: const BridgeIcon('messageCircle', size: 14),
                label: const Text('Reply'),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: ValueKey('reply-${item.notificationId}'),
                      controller: TextEditingController(text: _drafts[item.notificationId]),
                      onChanged: (v) => _drafts[item.notificationId] = v,
                      onSubmitted: (_) => _submitReply(item),
                      decoration: const InputDecoration(hintText: 'Type a reply…'),
                      style: const TextStyle(fontSize: 14, color: BridgeColors.ink),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: sending ? null : () => _submitReply(item),
                    child: sending
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const BridgeIcon('send', size: 14),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String icon;
  final String title;
  final String message;
  const _EmptyState({required this.icon, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: BridgeColors.card,
                border: Border.all(color: BridgeColors.sand),
                borderRadius: BorderRadius.circular(20),
                boxShadow: BridgeShadows.card,
              ),
              alignment: Alignment.center,
              child: BridgeIcon(icon, size: 26, color: BridgeColors.inkSoft),
            ),
            const SizedBox(height: 14),
            Text(title, style: BridgeText.panelTitle, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(message, style: BridgeText.caption, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
