import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' hide MessageType;
import 'package:permission_handler/permission_handler.dart';
import 'background_service.dart';

/// Manages the Android side of the WebRTC microphone stream.
///
/// Role: OFFERER (audio-only, separate peer connection from [CameraService]
/// so camera and mic can run independently).
///   1. Receives [event: 'start-mic'] from Windows (via BackgroundService cross-isolate signal).
///   2. Opens microphone, creates RTCPeerConnection, sends offer.
///   3. Handles incoming answer and ICE candidates from Windows.
///   4. Cleans up on [event: 'stop-mic'] from Windows or explicit [stopMic].
///
/// Mirrors [CameraService] cleanup patterns exactly: stop on either side,
/// socket disconnect, or app close tears down the peer connection and
/// releases the microphone (mic indicator off).
class MicService {
  MicService._();
  static final MicService instance = MicService._();

  // ── Public state ─────────────────────────────────────────────────────────────

  /// True while the WebRTC mic session is active (offer sent and not yet stopped).
  final ValueNotifier<bool> isStreaming = ValueNotifier(false);

  /// True after the peer connection reaches 'connected' state.
  final ValueNotifier<bool> isConnectedToPeer = ValueNotifier(false);

  /// Callbacks invoked when remote Windows commands arrive.
  VoidCallback? onStartMicRequested;
  VoidCallback? onStopMicRequested;

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

  // ── Lifecycle ─────────────────────────────────────────────────────────────────

  /// Call once at app start to register the mic-signal message handler
  /// forwarded from the background service isolate.
  void init() {
    final service = FlutterBackgroundService();
    service.on('mic_signal_received').listen((event) {
      if (event == null) return;
      final rawPayload = event['payload'];
      if (rawPayload == null) return;
      final payload = Map<String, dynamic>.from(rawPayload as Map);
      _handleSignal(payload);
    });
    debugPrint('[MicService] Initialized — listening for mic_signal_received from BackgroundService');
  }

  // ── Permission handling ───────────────────────────────────────────────────────

  /// Requests RECORD_AUDIO permission.
  ///
  /// Returns true if granted. Shows no UI — callers should show
  /// a rationale dialog before calling this if needed.
  Future<bool> requestPermissions() async {
    final status = await Permission.microphone.request();
    final micOk = status.isGranted;
    if (!micOk) {
      debugPrint('[MicService] Microphone permission denied');
    }
    return micOk;
  }

  // ── Start / Stop ──────────────────────────────────────────────────────────────

  /// Starts the mic stream and initiates a WebRTC audio-only offer towards Windows.
  ///
  /// Awaits any in-flight [stopMic] operation to ensure the previous audio
  /// session is fully closed before opening the new one.
  Future<void> startMic() async {
    // 1. If currently stopping, wait for prior teardown to complete completely
    if (_isStopping && _stopCompleter != null) {
      debugPrint('[MicService] Teardown in progress — awaiting prior stopMic() completion before starting…');
      await _stopCompleter!.future;
    }

    // 2. If already starting, join the in-flight start operation
    if (_isStarting && _startCompleter != null) {
      debugPrint('[MicService] startMic() already in progress — awaiting…');
      await _startCompleter!.future;
      return;
    }

    if (isStreaming.value) {
      debugPrint('[MicService] Already streaming — ignoring startMic()');
      return;
    }

    _isStarting = true;
    final completer = Completer<void>();
    _startCompleter = completer;

    try {
      await _doStartMic();
      completer.complete();
    } catch (e) {
      debugPrint('[MicService] Failed to start mic: $e');
      completer.completeError(e);
      await _doStopMic(notifyWindows: false);
      rethrow;
    } finally {
      _isStarting = false;
      _startCompleter = null;
    }
  }

  Future<void> _doStartMic() async {
    debugPrint('[MicService] Opening microphone…');

    // Open mic stream — audio only, no video track.
    _localStream = await navigator.mediaDevices.getUserMedia({
      'video': false,
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
    });

    isStreaming.value = true;
    debugPrint('[MicService] Mic stream acquired.');

    // Create peer connection as OFFERER
    await _createPeerConnection();

    // Add all audio tracks to the connection
    for (final track in _localStream!.getAudioTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    // Create and send offer to Windows (audio-only)
    final offer = await _pc!.createOffer({
      'offerToReceiveVideo': 0,
      'offerToReceiveAudio': 0,
    });
    await _pc!.setLocalDescription(offer);

    debugPrint('[MicService] Sending offer to Windows via BackgroundService…');
    await _emitSignal({'event': 'offer', 'sdp': offer.sdp});
  }

  /// Stops the mic stream and tears down the peer connection.
  /// Sends [stop-mic] to Windows unless [notifyWindows] is false.
  ///
  /// Guarantees that the MediaStream tracks and RTCPeerConnection
  /// are fully disposed before returning (mic indicator off).
  Future<void> stopMic({bool notifyWindows = true}) async {
    // If a start operation is in progress, wait for it before stopping
    if (_isStarting && _startCompleter != null) {
      debugPrint('[MicService] startMic() in progress — awaiting before stopping…');
      try {
        await _startCompleter!.future;
      } catch (_) {}
    }

    // If a stop operation is already underway, await it
    if (_isStopping && _stopCompleter != null) {
      debugPrint('[MicService] stopMic() already in progress — awaiting…');
      await _stopCompleter!.future;
      return;
    }

    if (!isStreaming.value && _pc == null && _localStream == null) {
      debugPrint('[MicService] stopMic() called but already stopped.');
      return;
    }

    _isStopping = true;
    final completer = Completer<void>();
    _stopCompleter = completer;

    try {
      await _doStopMic(notifyWindows: notifyWindows);
      completer.complete();
    } catch (e) {
      debugPrint('[MicService] Error during stopMic: $e');
      completer.completeError(e);
      rethrow;
    } finally {
      _isStopping = false;
      _stopCompleter = null;
    }
  }

  Future<void> _doStopMic({bool notifyWindows = true}) async {
    debugPrint('[MicService] Stopping mic — beginning full disposal…');

    isStreaming.value = false;
    isConnectedToPeer.value = false;

    // 1. Notify Windows if requested
    if (notifyWindows) {
      await _emitSignal({'event': 'stop-mic'});
    }

    // 2. Close and dispose the peer connection
    if (_pc != null) {
      try {
        debugPrint('[MicService] Closing and disposing RTCPeerConnection…');
        await _pc!.close();
        await _pc!.dispose();
      } catch (e) {
        debugPrint('[MicService] Error disposing RTCPeerConnection: $e');
      }
      _pc = null;
    }

    // 3. Stop and dispose all media stream tracks, then dispose the MediaStream
    if (_localStream != null) {
      debugPrint('[MicService] Stopping all local stream tracks…');
      for (final track in _localStream!.getTracks()) {
        try {
          await track.stop();
        } catch (e) {
          debugPrint('[MicService] Error stopping track ${track.id}: $e');
        }
      }
      try {
        debugPrint('[MicService] Disposing MediaStream…');
        await _localStream!.dispose();
      } catch (e) {
        debugPrint('[MicService] Error disposing MediaStream: $e');
      }
      _localStream = null;
    }

    // 4. Short hardware cooldown pause so Android audio HAL fully releases the mic
    await Future.delayed(const Duration(milliseconds: 300));

    debugPrint('[MicService] Mic fully released.');
  }

  // ── Signal handling ───────────────────────────────────────────────────────────

  Future<void> _handleSignal(Map<String, dynamic> payload) async {
    final event = payload['event'] as String?;
    debugPrint('[MicService] Received mic-signal event: $event');

    switch (event) {
      case 'start-mic':
        debugPrint('[MicService] Start mic requested by Windows');
        onStartMicRequested?.call();
        break;

      case 'stop-mic':
        debugPrint('[MicService] Stop mic requested by Windows — stopping mic…');
        await stopMic(notifyWindows: false);
        debugPrint('[MicService] stopMic finished — notifying onStopMicRequested');
        onStopMicRequested?.call();
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
      debugPrint('[MicService] Received answer but _pc is null — ignoring');
      return;
    }
    debugPrint('[MicService] Received answer — setting remote description');
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
      debugPrint('[MicService] Added ICE candidate');
    } catch (e) {
      debugPrint('[MicService] addIceCandidate error: $e');
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
      debugPrint('[MicService] Sending ICE candidate to Windows');
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
      debugPrint('[MicService] ICE state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        isConnectedToPeer.value = true;
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                 state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        debugPrint('[MicService] ICE failed/disconnected — stopping mic');
        isConnectedToPeer.value = false;
        stopMic(notifyWindows: false);
      }
    };

    _pc!.onConnectionState = (state) {
      debugPrint('[MicService] Connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        isConnectedToPeer.value = false;
        stopMic(notifyWindows: false);
      }
    };

    _pc!.onSignalingState = (state) {
      debugPrint('[MicService] Signaling state: $state');
    };
  }

  // ── Emit helper ───────────────────────────────────────────────────────────────

  Future<void> _emitSignal(Map<String, dynamic> payload) async {
    final event = payload['event'] as String? ?? 'unknown';
    debugPrint('[MicService] [SEND] Routing mic-signal [$event] to BackgroundService');
    BackgroundService.sendMicSignal(payload);
  }

  // ── Dispose ───────────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await stopMic(notifyWindows: false);
    isStreaming.dispose();
    isConnectedToPeer.dispose();
  }
}
