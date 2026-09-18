import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' hide MessageType;
import 'package:permission_handler/permission_handler.dart';
import 'background_service.dart';

/// Manages the Android side of the WebRTC camera stream.
///
/// Role: OFFERER
///   1. Receives [event: 'start-camera'] from Windows (via BackgroundService cross-isolate signal).
///   2. Opens camera, creates RTCPeerConnection, sends offer.
///   3. Handles incoming answer and ICE candidates from Windows.
///   4. Supports camera flip via Helper.switchCamera / replaceTrack.
///   5. Cleans up on [event: 'stop-camera'] from Windows or explicit [stopCamera].
///
/// Fully guarded against re-entrancy and concurrent start/stop operations to ensure
/// the hardware camera capturer is fully released by Android before reopening.
class CameraService {
  CameraService._();
  static final CameraService instance = CameraService._();

  // ── Public state ─────────────────────────────────────────────────────────────

  /// True while the WebRTC session is active (offer sent and not yet stopped).
  final ValueNotifier<bool> isStreaming = ValueNotifier(false);

  /// True after the peer connection reaches 'connected' state.
  final ValueNotifier<bool> isConnectedToPeer = ValueNotifier(false);

  /// Local camera renderer — bind this to an RTCVideoView in the UI.
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();

  /// Callbacks invoked when remote Windows commands arrive.
  VoidCallback? onStartCameraRequested;
  VoidCallback? onStopCameraRequested;

  bool _rendererInitialized = false;

  // ── Concurrency & state guards ───────────────────────────────────────────────
  Completer<void>? _startCompleter;
  Completer<void>? _stopCompleter;
  bool _isStarting = false;
  bool _isStopping = false;

  // ── ICE configuration ────────────────────────────────────────────────────────
  // LAN-local peers — host candidates should negotiate directly.
  // Google STUN is a cheap fallback for unusual router/NAT setups.
  static const Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  };

  // ── Internal state ────────────────────────────────────────────────────────────
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  bool _useFrontCamera = true;

  // ── Lifecycle ─────────────────────────────────────────────────────────────────

  /// Call once at app start to register the camera-signal message handler
  /// forwarded from the background service isolate.
  void init() {
    final service = FlutterBackgroundService();
    service.on('camera_signal_received').listen((event) {
      if (event == null) return;
      final rawPayload = event['payload'];
      if (rawPayload == null) return;
      final payload = Map<String, dynamic>.from(rawPayload as Map);
      _handleSignal(payload);
    });
    debugPrint('[CameraService] Initialized — listening for camera_signal_received from BackgroundService');
  }

  Future<void> _ensureRendererInitialized() async {
    if (!_rendererInitialized) {
      await localRenderer.initialize();
      _rendererInitialized = true;
    }
  }

  // ── Permission handling ───────────────────────────────────────────────────────

  /// Requests CAMERA permission.
  ///
  /// Returns true if granted. Shows no UI — callers should show
  /// a rationale dialog before calling this if needed.
  Future<bool> requestPermissions() async {
    final status = await Permission.camera.request();
    final cameraOk = status.isGranted;

    if (!cameraOk) {
      debugPrint('[CameraService] Camera permission denied');
    }

    return cameraOk;
  }

  // ── Start / Stop ──────────────────────────────────────────────────────────────

  /// Starts the camera stream and initiates WebRTC offer towards Windows.
  /// [useFrontCamera] selects front or back camera.
  ///
  /// Awaits any in-flight [stopCamera] operation to ensure previous camera hardware
  /// session is fully closed before opening the new one.
  Future<void> startCamera({bool useFrontCamera = true}) async {
    // 1. If currently stopping, wait for prior teardown to complete completely
    if (_isStopping && _stopCompleter != null) {
      debugPrint('[CameraService] Teardown in progress — awaiting prior stopCamera() completion before starting…');
      await _stopCompleter!.future;
    }

    // 2. If already starting, join the in-flight start operation
    if (_isStarting && _startCompleter != null) {
      debugPrint('[CameraService] startCamera() already in progress — awaiting…');
      await _startCompleter!.future;
      return;
    }

    if (isStreaming.value) {
      debugPrint('[CameraService] Already streaming — ignoring startCamera()');
      return;
    }

    _isStarting = true;
    final completer = Completer<void>();
    _startCompleter = completer;

    try {
      await _doStartCamera(useFrontCamera: useFrontCamera);
      completer.complete();
    } catch (e) {
      debugPrint('[CameraService] Failed to start camera: $e');
      completer.completeError(e);
      await _doStopCamera(notifyWindows: false);
      rethrow;
    } finally {
      _isStarting = false;
      _startCompleter = null;
    }
  }

  Future<void> _doStartCamera({required bool useFrontCamera}) async {
    _useFrontCamera = useFrontCamera;
    await _ensureRendererInitialized();

    debugPrint('[CameraService] Opening camera (front: $useFrontCamera)…');

    // Open camera stream — video only, no audio track.
    _localStream = await navigator.mediaDevices.getUserMedia({
      'video': {
        'facingMode': useFrontCamera ? 'user' : 'environment',
        'width': {'ideal': 1280, 'max': 1280},
        'height': {'ideal': 720, 'max': 720},
        'frameRate': {'ideal': 30, 'max': 30},
      },
      'audio': false, // Video-only — we do not transmit audio.
    });

    localRenderer.srcObject = _localStream;
    isStreaming.value = true;
    debugPrint('[CameraService] Camera stream acquired. Local preview active.');

    // Create peer connection as OFFERER
    await _createPeerConnection();

    // Add all video tracks to the connection
    for (final track in _localStream!.getVideoTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // Set sender parameters to lock 30 FPS and 3.0 Mbps bitrate
    try {
      final senders = await _pc!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          final params = sender.parameters;
          if (params.encodings != null && params.encodings!.isNotEmpty) {
            for (final enc in params.encodings!) {
              enc.maxBitrate = 3000000;
              enc.minBitrate = 1000000;
              enc.maxFramerate = 30;
            }
            await sender.setParameters(params);
            debugPrint('[CameraService] Applied high-bitrate encoding parameters (30 FPS, 3 Mbps)');
          }
          break;
        }
      }
    } catch (e) {
      debugPrint('[CameraService] setParameters notice: $e');
    }

    // Create and send offer to Windows with H.264 prioritization
    final offer = await _pc!.createOffer({
      'offerToReceiveVideo': 0,
      'offerToReceiveAudio': 0,
    });
    final mungedSdp = _preferH264(offer.sdp ?? '');
    final mungedOffer = RTCSessionDescription(mungedSdp, offer.type);
    await _pc!.setLocalDescription(mungedOffer);

    debugPrint('[CameraService] Sending offer to Windows via BackgroundService…');
    await _emitSignal({'event': 'offer', 'sdp': mungedOffer.sdp});
  }

  /// Stops the camera stream and tears down the peer connection.
  /// Sends [stop-camera] to Windows unless [notifyWindows] is false.
  ///
  /// Guarantees that the camera capturer, MediaStream tracks, and RTCPeerConnection
  /// are fully disposed before returning.
  Future<void> stopCamera({bool notifyWindows = true}) async {
    // If a start operation is in progress, wait for it before stopping
    if (_isStarting && _startCompleter != null) {
      debugPrint('[CameraService] startCamera() in progress — awaiting before stopping…');
      try {
        await _startCompleter!.future;
      } catch (_) {}
    }

    // If a stop operation is already underway, await it
    if (_isStopping && _stopCompleter != null) {
      debugPrint('[CameraService] stopCamera() already in progress — awaiting…');
      await _stopCompleter!.future;
      return;
    }

    if (!isStreaming.value && _pc == null && _localStream == null) {
      debugPrint('[CameraService] stopCamera() called but already stopped.');
      return;
    }

    _isStopping = true;
    final completer = Completer<void>();
    _stopCompleter = completer;

    try {
      await _doStopCamera(notifyWindows: notifyWindows);
      completer.complete();
    } catch (e) {
      debugPrint('[CameraService] Error during stopCamera: $e');
      completer.completeError(e);
      rethrow;
    } finally {
      _isStopping = false;
      _stopCompleter = null;
    }
  }

  Future<void> _doStopCamera({bool notifyWindows = true}) async {
    debugPrint('[CameraService] Stopping camera — beginning full disposal…');

    isStreaming.value = false;
    isConnectedToPeer.value = false;

    // 1. Notify Windows if requested
    if (notifyWindows) {
      await _emitSignal({'event': 'stop-camera'});
    }

    // 2. Detach renderer srcObject immediately to avoid frozen frame rendering
    localRenderer.srcObject = null;

    // 3. Close and dispose the peer connection
    if (_pc != null) {
      try {
        debugPrint('[CameraService] Closing and disposing RTCPeerConnection…');
        await _pc!.close();
        await _pc!.dispose();
      } catch (e) {
        debugPrint('[CameraService] Error disposing RTCPeerConnection: $e');
      }
      _pc = null;
    }

    // 4. Stop and dispose all media stream tracks, then dispose the MediaStream
    if (_localStream != null) {
      debugPrint('[CameraService] Stopping all local stream tracks…');
      for (final track in _localStream!.getTracks()) {
        try {
          await track.stop();
        } catch (e) {
          debugPrint('[CameraService] Error stopping track ${track.id}: $e');
        }
      }
      try {
        debugPrint('[CameraService] Disposing MediaStream…');
        await _localStream!.dispose();
      } catch (e) {
        debugPrint('[CameraService] Error disposing MediaStream: $e');
      }
      _localStream = null;
    }

    // 5. Short hardware cooldown pause so Android Camera2 HAL fully releases the camera device
    await Future.delayed(const Duration(milliseconds: 300));

    debugPrint('[CameraService] Camera fully released and hardware session closed.');
  }

  /// Flips the camera between front and back while streaming.
  /// Prefers Helper.switchCamera, with a clean replaceTrack fallback.
  Future<void> flipCamera() async {
    if (!isStreaming.value || _pc == null || _localStream == null || _isStopping || _isStarting) {
      debugPrint('[CameraService] Cannot flip camera: not streaming or operation in progress');
      return;
    }

    final videoTrack = _localStream!.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      try {
        debugPrint('[CameraService] Flipping camera using Helper.switchCamera…');
        await Helper.switchCamera(videoTrack);
        _useFrontCamera = !_useFrontCamera;
        debugPrint('[CameraService] Camera flipped successfully via Helper.switchCamera → front: $_useFrontCamera');
        return;
      } catch (e) {
        debugPrint('[CameraService] Helper.switchCamera failed ($e), attempting replaceTrack fallback…');
      }
    }

    // Fallback: replaceTrack with sequential release to avoid open camera device collision
    _useFrontCamera = !_useFrontCamera;
    debugPrint('[CameraService] Flipping camera via replaceTrack fallback → front: $_useFrontCamera');

    final oldTracks = _localStream!.getVideoTracks();

    // Stop existing track first so hardware camera device is freed
    for (final track in oldTracks) {
      await _localStream!.removeTrack(track);
      await track.stop();
    }
    await Future.delayed(const Duration(milliseconds: 200));

    final newStream = await navigator.mediaDevices.getUserMedia({
      'video': {
        'facingMode': _useFrontCamera ? 'user' : 'environment',
        'width': {'ideal': 1280, 'max': 1280},
        'height': {'ideal': 720, 'max': 720},
        'frameRate': {'ideal': 30, 'max': 30},
      },
      'audio': false,
    });

    final newVideoTrack = newStream.getVideoTracks().first;
    final senders = await _pc!.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        await sender.replaceTrack(newVideoTrack);
        break;
      }
    }

    await _localStream!.addTrack(newVideoTrack);
    localRenderer.srcObject = _localStream;
    debugPrint('[CameraService] Camera flipped via replaceTrack completed.');
  }

  // ── Signal handling ───────────────────────────────────────────────────────────

  Future<void> _handleSignal(Map<String, dynamic> payload) async {
    final event = payload['event'] as String?;
    debugPrint('[CameraService] Received camera-signal event: $event');

    switch (event) {
      case 'start-camera':
        debugPrint('[CameraService] Start camera requested by Windows');
        onStartCameraRequested?.call();
        break;

      case 'stop-camera':
        debugPrint('[CameraService] Stop camera requested by Windows — stopping camera…');
        await stopCamera(notifyWindows: false);
        debugPrint('[CameraService] stopCamera finished — notifying onStopCameraRequested');
        onStopCameraRequested?.call();
        break;

      case 'answer':
        final sdp = payload['sdp'] as String?;
        if (sdp != null) {
          await _handleAnswer(sdp);
        }
        break;

      case 'ice-candidate':
        await _handleIceCandidate(payload['candidate']);
        break;
    }
  }

  Future<void> _handleAnswer(String sdp) async {
    if (_pc == null) {
      debugPrint('[CameraService] Received answer but _pc is null — ignoring');
      return;
    }
    debugPrint('[CameraService] Received answer — setting remote description');
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  Future<void> _handleIceCandidate(dynamic candidateData) async {
    if (_pc == null || candidateData == null) return;
    try {
      final map = Map<String, dynamic>.from(candidateData as Map);
      final candidate = RTCIceCandidate(
        map['candidate'] as String,
        map['sdpMid'] as String?,
        map['sdpMLineIndex'] as int?,
      );
      await _pc!.addCandidate(candidate);
      debugPrint('[CameraService] Added ICE candidate');
    } catch (e) {
      debugPrint('[CameraService] addIceCandidate error: $e');
    }
  }

  // ── RTCPeerConnection ─────────────────────────────────────────────────────────

  Future<void> _createPeerConnection() async {
    if (_pc != null) {
      try {
        await _pc!.close();
        await _pc!.dispose();
      } catch (_) {}
      _pc = null;
    }

    _pc = await createPeerConnection(_iceConfig);

    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) {
        // null = gathering complete; notify Windows
        _emitSignal({'event': 'ice-candidate', 'candidate': null});
        return;
      }
      debugPrint('[CameraService] Sending ICE candidate to Windows');
      _emitSignal({
        'event': 'ice-candidate',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    _pc!.onIceConnectionState = (state) {
      debugPrint('[CameraService] ICE state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        isConnectedToPeer.value = true;
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                 state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        debugPrint('[CameraService] ICE failed/disconnected — stopping camera');
        isConnectedToPeer.value = false;
        stopCamera(notifyWindows: false);
      }
    };

    _pc!.onConnectionState = (state) {
      debugPrint('[CameraService] Connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        isConnectedToPeer.value = false;
        stopCamera(notifyWindows: false);
      }
    };

    _pc!.onSignalingState = (state) {
      debugPrint('[CameraService] Signaling state: $state');
    };
  }

  // ── SDP munging ─────────────────────────────────────────────────────────────

  /// Reorders payload types in the SDP offer so H.264 appears first before VP8.
  /// Samsung Exynos hardware H.264 encoder is stable and smooth, preventing
  /// the c2.exynos.vp8.encoder rapid reconfiguration/crash loop.
  String _preferH264(String sdp) {
    final lines = sdp.split('\r\n');
    String? h264Payload;

    for (final line in lines) {
      final match = RegExp(r'^a=rtpmap:(\d+)\s+H264/90000', caseSensitive: false).firstMatch(line);
      if (match != null) {
        h264Payload = match.group(1);
        break;
      }
    }

    if (h264Payload == null) {
      debugPrint('[CameraService] No H.264 codec found in SDP, keeping default order');
      return sdp;
    }

    debugPrint('[CameraService] Prioritizing H.264 codec (payload: $h264Payload) over VP8');

    final newLines = <String>[];
    for (final line in lines) {
      if (line.startsWith('m=video ')) {
        final parts = line.split(' ');
        if (parts.length > 3) {
          final prefix = parts.sublist(0, 3);
          final payloads = parts.sublist(3);
          payloads.remove(h264Payload);
          payloads.insert(0, h264Payload);
          newLines.add('${prefix.join(' ')} ${payloads.join(' ')}');
          newLines.add('b=AS:3500');
          continue;
        }
      }
      newLines.add(line);
    }

    return newLines.join('\r\n');
  }

  // ── Emit helper ───────────────────────────────────────────────────────────────

  Future<void> _emitSignal(Map<String, dynamic> payload) async {
    final event = payload['event'] as String? ?? 'unknown';
    debugPrint('[CameraService] [SEND] Routing camera-signal [$event] to BackgroundService');
    BackgroundService.sendCameraSignal(payload);
  }

  // ── Dispose ───────────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await stopCamera(notifyWindows: false);
    if (_rendererInitialized) {
      await localRenderer.dispose();
      _rendererInitialized = false;
    }
    isStreaming.dispose();
    isConnectedToPeer.dispose();
  }
}
