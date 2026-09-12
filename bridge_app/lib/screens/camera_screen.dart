import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme/bridge_icons.dart';
import '../services/camera_service.dart';
import '../services/socket_service.dart';
import '../theme/bridge_theme.dart';

/// Foreground screen shown when the user taps "Use as Webcam".
///
/// Handles:
///   • Runtime permission requests (camera + microphone — with clear rationale)
///   • Local camera preview via RTCVideoView
///   • "You're live — streaming to PC" status banner
///   • Front/back camera toggle
///   • Stop button and back-press teardown
///   • Lifecycle: pauses camera if app is backgrounded
class CameraScreen extends StatefulWidget {
  final String pcName;

  const CameraScreen({super.key, required this.pcName});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  final _cam = CameraService.instance;

  bool _permissionsGranted = false;
  bool _permissionsDenied = false;
  bool _starting = false;
  bool _useFrontCamera = true;
  bool _canPop = false;
  bool _isStopping = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Lock to portrait by default (user can rotate if they want)
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _requestPermissionsWithRationale();
    });

    // Listen for socket disconnect → camera stopped via service; pop screen.
    SocketService.instance.connected.addListener(_onConnectionChanged);

    // Listen for remote stop command from Windows
    CameraService.instance.onStopCameraRequested = () {
      debugPrint('[CameraScreen] onStopCameraRequested received from Windows');
      if (mounted) {
        _stopAndPop(reason: 'windows_remote');
      }
    };
  }

  @override
  void dispose() {
    debugPrint('[CameraScreen] dispose() called — route unmounting');
    WidgetsBinding.instance.removeObserver(this);
    SocketService.instance.connected.removeListener(_onConnectionChanged);
    CameraService.instance.onStopCameraRequested = null;
    _cam.stopCamera();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    debugPrint('[CameraScreen] dispose() completed');
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Camera access is foreground-only; stop cleanly when backgrounded.
      _stopAndPop(reason: 'backgrounded');
    }
  }

  void _onConnectionChanged() {
    if (!SocketService.instance.isConnected && mounted) {
      _stopAndPop(reason: 'disconnected');
    }
  }

  // ── Permissions ──────────────────────────────────────────────────────────────

  Future<void> _requestPermissionsWithRationale() async {
    // Show rationale before requesting — especially for the microphone.
    final proceed = await _showPermissionRationale();
    if (!proceed || !mounted) return;

    final granted = await _cam.requestPermissions();
    if (!mounted) return;

    if (granted) {
      setState(() => _permissionsGranted = true);
      await _startStreaming();
    } else {
      setState(() => _permissionsDenied = true);
    }
  }

  Future<bool> _showPermissionRationale() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                BridgeIcon('video', color: BridgeColors.clay, size: 22),
                SizedBox(width: 10),
                Text('Camera Access Needed'),
              ],
            ),
            content: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bridge needs access to your camera to stream video to your Windows PC.',
                  style: TextStyle(fontSize: 14, height: 1.5),
                ),
                SizedBox(height: 12),
                Text(
                  'Microphone access is also requested — this is required internally by the WebRTC engine, even though Bridge streams video only and does not capture or transmit any audio.',
                  style: TextStyle(fontSize: 13, color: BridgeColors.muted, height: 1.4),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Allow'),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ── Stream control ───────────────────────────────────────────────────────────

  Future<void> _startStreaming() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      await _cam.startCamera(useFrontCamera: _useFrontCamera);
    } catch (e) {
      debugPrint('[CameraScreen] startCamera error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start camera: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stopAndPop({String reason = 'user'}) async {
    if (_isStopping) {
      debugPrint('[CameraScreen] _stopAndPop already in progress — ignoring (reason: $reason)');
      return;
    }
    _isStopping = true;
    debugPrint('[CameraScreen] _stopAndPop starting (reason: $reason)');

    try {
      await _cam.stopCamera();
      debugPrint('[CameraScreen] Camera fully stopped in _stopAndPop (reason: $reason)');
    } catch (e) {
      debugPrint('[CameraScreen] Error during stopCamera in _stopAndPop: $e');
    }

    if (!mounted) {
      debugPrint('[CameraScreen] Screen not mounted after stopCamera');
      return;
    }

    setState(() {
      _canPop = true;
    });

    debugPrint('[CameraScreen] Popping CameraScreen route now (reason: $reason)');
    Navigator.of(context).pop();
    debugPrint('[CameraScreen] Navigator.pop() called successfully');
  }

  Future<void> _flipCamera() async {
    setState(() => _useFrontCamera = !_useFrontCamera);
    await _cam.flipCamera();
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) async {
        debugPrint('[CameraScreen] PopScope onPopInvokedWithResult (didPop: $didPop, canPop: $_canPop)');
        if (didPop) return;
        await _stopAndPop(reason: 'back');
      },
      child: Scaffold(
        backgroundColor: BridgeColors.linen,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_permissionsDenied) return _buildPermDenied();
    if (!_permissionsGranted) {
      return SafeArea(child: _buildLoading('Requesting permissions…'));
    }

    return SafeArea(
      child: Column(
        children: [
          // ── Linen top chrome ──────────────────────────────────────
          _buildStatusBar(),

          // ── Video well ────────────────────────────────────────────
          Expanded(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Container(
                decoration: BoxDecoration(
                  color: BridgeColors.card,
                  border: Border.all(color: BridgeColors.sand),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: BridgeShadows.card,
                ),
                padding: const EdgeInsets.all(8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        color: BridgeColors.videoWell,
                        child: RTCVideoView(
                          _cam.localRenderer,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitCover,
                          mirror: _useFrontCamera,
                        ),
                      ),
                      // ── Loading / connecting overlay ──────────────
                      ValueListenableBuilder<bool>(
                        valueListenable: _cam.isStreaming,
                        builder: (context, streaming, _) {
                          if (_starting ||
                              (!streaming && _permissionsGranted)) {
                            return _buildConnectingOverlay();
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Linen bottom controls ─────────────────────────────────
          _buildBottomControls(),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          // Back / close button
          GestureDetector(
            onTap: () => _stopAndPop(reason: 'back'),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: BridgeColors.card,
                border: Border.all(color: BridgeColors.sand),
                borderRadius: BorderRadius.circular(12),
              ),
              child: BridgeIcon('arrowLeft',
                  color: BridgeColors.ink, size: 18),
            ),
          ),
          const SizedBox(width: 12),

          // Status text
          Expanded(
            child: ValueListenableBuilder<bool>(
              valueListenable: _cam.isConnectedToPeer,
              builder: (context, connected, _) {
                return ValueListenableBuilder<bool>(
                  valueListenable: _cam.isStreaming,
                  builder: (context, streaming, _) {
                    String text;
                    Color dotColor;

                    if (connected) {
                      text = 'You\'re live — streaming to ${widget.pcName}';
                      dotColor = BridgeColors.sage;
                    } else if (streaming) {
                      text = 'Connecting to ${widget.pcName}…';
                      dotColor = BridgeColors.clay;
                    } else {
                      text = 'Starting camera…';
                      dotColor = BridgeColors.disconnectedDot;
                    }

                    return Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            text,
                            style: const TextStyle(
                              fontFamily: 'NunitoSans',
                              color: BridgeColors.ink,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),

          // LIVE badge
          ValueListenableBuilder<bool>(
            valueListenable: _cam.isConnectedToPeer,
            builder: (context, connected, _) {
              if (!connected) return const SizedBox.shrink();
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                decoration: BoxDecoration(
                  color: BridgeColors.clay,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'LIVE',
                  style: TextStyle(
                    fontFamily: 'NunitoSans',
                    color: BridgeColors.creamText,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 20,
        left: 40,
        right: 40,
        top: 12,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Flip camera
          _ControlButton(
            icon: 'switchCamera',
            label: 'Flip',
            onTap: _flipCamera,
          ),

          // Stop
          _ControlButton(
            icon: 'square',
            label: 'Stop',
            onTap: () => _stopAndPop(reason: 'stop'),
            isPrimary: true,
          ),
        ],
      ),
    );
  }

  Widget _buildConnectingOverlay() {
    return Container(
      color: BridgeColors.videoWell.withAlpha(200),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: BridgeColors.clay),
            SizedBox(height: 16),
            Text(
              'Starting camera…',
              style: TextStyle(
                fontFamily: 'NunitoSans',
                color: BridgeColors.brandCream,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: BridgeColors.clay),
          const SizedBox(height: 16),
          Text(message, style: BridgeText.bodySoft),
        ],
      ),
    );
  }

  Widget _buildPermDenied() {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: BridgeColors.sageSoft,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: BridgeIcon('videoOff',
                    color: BridgeColors.sageDeep, size: 30),
              ),
              const SizedBox(height: 16),
              const Text(
                'Camera permission denied',
                style: TextStyle(
                  fontFamily: 'Fraunces',
                  color: BridgeColors.ink,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Please grant camera and microphone access in Settings to use Bridge as a webcam.',
                style: TextStyle(
                  fontFamily: 'NunitoSans',
                  color: BridgeColors.inkSoft,
                  fontSize: 14,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => openAppSettings(),
                icon: BridgeIcon('settings', size: 17),
                label: const Text('Open Settings'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── _ControlButton ─────────────────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = isPrimary ? 68.0 : 56.0;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: isPrimary ? BridgeColors.clay : BridgeColors.card,
              shape: BoxShape.circle,
              border: Border.all(
                color: isPrimary ? BridgeColors.clay : BridgeColors.sand,
                width: isPrimary ? 0 : 1,
              ),
              boxShadow: BridgeShadows.card,
            ),
            child: BridgeIcon(icon,
                color: isPrimary
                    ? BridgeColors.creamText
                    : BridgeColors.ink,
                size: isPrimary ? 26 : 22),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(
                fontFamily: 'NunitoSans',
                color: BridgeColors.inkSoft,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}

