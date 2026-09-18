import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
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

    // Keep the screen on while the camera screen is visible — streaming
    // sessions run long and must not be interrupted by screen timeout.
    WakelockPlus.enable();

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
    // Screen may time out normally again once the camera screen is gone.
    WakelockPlus.disable();
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
          builder: (ctx) {
            final onSurface = Theme.of(ctx).colorScheme.onSurface;
            final soft = Theme.of(ctx).colorScheme.onSurfaceVariant;
            return AlertDialog(
              title: Row(
                children: [
                  const BridgeIcon('video',
                      color: BridgeColors.clay, size: 22),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text('Camera Access Needed',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: onSurface,
                        )),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Bridge needs access to your camera to stream video to your Windows PC.',
                    style: TextStyle(
                        fontSize: 14, height: 1.5, color: onSurface),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Microphone access is also requested — this is required internally by the WebRTC engine, even though Bridge streams video only and does not capture or transmit any audio.',
                    style: TextStyle(
                        fontSize: 13, color: soft, height: 1.45),
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
            );
          },
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
        backgroundColor: Colors.black,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_permissionsDenied) return _buildPermDenied();
    if (!_permissionsGranted) {
      return Container(
        color: Colors.black,
        child: SafeArea(child: _buildLoading('Requesting permissions…')),
      );
    }

    // Immersive pro camera: full-bleed preview, floating glass chrome.
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          color: Colors.black,
          child: RTCVideoView(
            _cam.localRenderer,
            objectFit:
                RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            mirror: _useFrontCamera,
          ),
        ),
        // Subtle top scrim for legibility.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 140,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withAlpha(170),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        // Subtle bottom scrim.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            height: 210,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withAlpha(190),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              _buildOverlayStatusBar(),
              const Spacer(),
              _buildOverlayHint(),
              const SizedBox(height: 14),
              _buildOverlayControls(),
            ],
          ),
        ),
        // Loading / connecting overlay.
        ValueListenableBuilder<bool>(
          valueListenable: _cam.isStreaming,
          builder: (context, streaming, _) {
            if (_starting || (!streaming && _permissionsGranted)) {
              return _buildConnectingOverlay();
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }

  Widget _buildOverlayStatusBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => _stopAndPop(reason: 'back'),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(28),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const BridgeIcon('arrowLeft',
                  color: Colors.white, size: 19),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ValueListenableBuilder<bool>(
              valueListenable: _cam.isConnectedToPeer,
              builder: (context, connected, _) {
                return ValueListenableBuilder<bool>(
                  valueListenable: _cam.isStreaming,
                  builder: (context, streaming, _) {
                    final text = connected
                        ? 'Live · ${widget.pcName}'
                        : streaming
                            ? 'Connecting · ${widget.pcName}'
                            : 'Starting camera…';
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: connected
                                    ? const Color(0xFF22C55E)
                                    : Colors.white70,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Text(
                                text,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.1,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          connected
                              ? 'Streaming to your PC — keep this screen open'
                              : 'Keep Bridge open while using the camera',
                          style: TextStyle(
                            color: Colors.white.withAlpha(170),
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(width: 10),
          ValueListenableBuilder<bool>(
            valueListenable: _cam.isConnectedToPeer,
            builder: (context, connected, _) {
              if (!connected) return const SizedBox.shrink();
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFDC2626),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _RecDot(),
                    SizedBox(width: 6),
                    Text(
                      'LIVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
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
  }

  Widget _buildOverlayHint() {
    return ValueListenableBuilder<bool>(
      valueListenable: _cam.isConnectedToPeer,
      builder: (context, connected, _) {
        if (connected) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 48),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(22),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            _starting ? 'Starting camera…' : 'Waiting for your PC…',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withAlpha(230),
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }

  Widget _buildOverlayControls() {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 22,
        left: 56,
        right: 56,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ControlButton(
            icon: 'switchCamera',
            label: 'Flip',
            onTap: _flipCamera,
            dark: true,
          ),
          _ControlButton(
            icon: 'square',
            label: 'Stop',
            onTap: () => _stopAndPop(reason: 'stop'),
            isPrimary: true,
            dark: true,
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
    // Camera screen is always black — use light text in both modes.
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: 16),
          Text(
            message,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermDenied() {
    // Camera screen is always black — use a dark-stage layout.
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
                  color: Colors.white.withAlpha(14),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const BridgeIcon('videoOff',
                    color: Colors.white70, size: 30),
              ),
              const SizedBox(height: 16),
              const Text(
                'Camera permission denied',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Please grant camera and microphone access in Settings to use Bridge as a webcam.',
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: 14,
                  height: 1.55,
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
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white70,
                ),
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

class _RecDot extends StatefulWidget {
  const _RecDot();
  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.35).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback onTap;
  final bool isPrimary;
  final bool dark;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isPrimary = false,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = isPrimary ? 72.0 : 58.0;
    final bg = isPrimary
        ? const Color(0xFFDC2626)
        : dark
            ? Colors.white.withAlpha(28)
            : BridgeColors.card;
    final fg = dark || isPrimary ? Colors.white : BridgeColors.ink;
    final labelColor =
        dark ? Colors.white.withAlpha(200) : BridgeColors.inkSoft;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(
                color: dark
                    ? Colors.white.withAlpha(30)
                    : (isPrimary
                        ? BridgeColors.clay
                        : BridgeColors.sand),
                width: 1,
              ),
              boxShadow: BridgeShadows.card,
            ),
            child: BridgeIcon(icon,
                color: fg, size: isPrimary ? 26 : 22),
          ),
          const SizedBox(height: 7),
          Text(label,
              style: TextStyle(
                color: labelColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}

