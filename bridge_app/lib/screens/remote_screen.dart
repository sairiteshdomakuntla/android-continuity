import 'dart:async';

import 'package:flutter/material.dart';

import '../services/remote_input_service.dart';
import '../services/remote_prefs_service.dart';
import '../services/socket_service.dart';
import '../theme/bridge_icons.dart';
import '../theme/bridge_theme.dart';

/// "Phone as Remote" — stage 1: trackpad surface.
///
///   • Single-finger drag on the surface  → relative mouse movement
///   • Two-finger drag on the surface     → vertical scroll
///   • Quick single-finger tap             → left click
///   • Quick two-finger tap                → right click
///   • Left Click / Right Click buttons    → mouse clicks (always available)
///
/// Pointer events are read raw (Listener, no gesture arena) for the lowest
/// possible latency, coalesced to one wire message per ~16 ms flush.
///
/// Taps are told apart from drags/scrolls with a slop + time window:
/// nothing is emitted until finger travel exceeds [_tapSlopPx], and a
/// click only fires after the whole gesture ends within
/// [_tapMaxDuration] — so a deliberate drag/scroll can never also fire a
/// click at its start, and a tap never moves the cursor or scrolls first.
///
/// The bottom tab bar is the shell for the later Keyboard and Media passes;
/// both are visibly greyed out as placeholders for now.
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});

  /// True while a RemoteScreen route is on the navigator — lets the
  /// open-remote handler avoid stacking a duplicate.
  static bool isShown = false;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  /// Max wire rate for move/scroll messages (~60 Hz). Pointer bursts within
  /// a window are summed into a single delta message.
  static const _flushInterval = Duration(milliseconds: 16);

  // ── Tap gesture classification ──────────────────────────────────────────────
  /// Finger travel (logical px) beyond which a gesture counts as a
  /// drag/scroll instead of a tap. Nothing is emitted on the wire until
  /// the slop is crossed.
  static const _tapSlopPx = 10.0;

  /// A tap must fully complete (last finger up) within this window of the
  /// first finger landing.
  static const _tapMaxDuration = Duration(milliseconds: 200);

  // ── Pointer tracking (surface-local logical px) ─────────────────────────────
  final Map<int, Offset> _pointers = {};

  /// Average Y of the two-finger baseline; null = needs re-baseline.
  double? _scrollAvgY;

  // Gesture bookkeeping: a gesture runs from the first finger down to the
  // last finger up. Tap candidates are the 1- and 2-finger gestures that
  // stay under the slop for their entire duration.
  final Map<int, Offset> _downPos = {};
  Duration? _gestureStart;
  bool _gestureEmitted = false; // slop crossed → drag/scroll underway
  bool _tapCancelled = false; // slop/cancel/3+ fingers → no tap

  // ── Pending deltas waiting for the next flush ───────────────────────────────
  double _pendDx = 0;
  double _pendDy = 0;
  double _pendScroll = 0;
  Timer? _flushTimer;

  bool _dragging = false;

  // ── Cursor sensitivity (movement only; persisted locally) ───────────────────
  double _sensitivity = RemotePrefsService.defaultSensitivity;
  Timer? _sensSendTimer;
  late final VoidCallback _onConnectionChanged;

  @override
  void initState() {
    super.initState();
    RemoteScreen.isShown = true;
    _loadSensitivity();
    // (Re)send the sensitivity whenever the socket (re)connects, so a host
    // restart mid-session still ends up with the user's chosen multiplier.
    _onConnectionChanged = () {
      if (SocketService.instance.connected.value) {
        _sendSensitivity();
      }
    };
    SocketService.instance.connected.addListener(_onConnectionChanged);
  }

  Future<void> _loadSensitivity() async {
    final value = await RemotePrefsService.instance.loadSensitivity();
    if (!mounted) return;
    setState(() => _sensitivity = value);
    _sendSensitivity();
  }

  @override
  void dispose() {
    RemoteScreen.isShown = false;
    SocketService.instance.connected.removeListener(_onConnectionChanged);
    _flushTimer?.cancel();
    _flushTimer = null;
    _sensSendTimer?.cancel();
    _sensSendTimer = null;
    super.dispose();
  }

  // ── Wire flush ──────────────────────────────────────────────────────────────

  void _scheduleFlush() {
    _flushTimer ??= Timer(_flushInterval, _flushNow);
  }

  void _flushNow() {
    _flushTimer = null;
    if (_pendDx != 0 || _pendDy != 0) {
      RemoteInputService.instance.sendMouseMove(_pendDx, _pendDy);
      _pendDx = 0;
      _pendDy = 0;
    }
    if (_pendScroll != 0) {
      RemoteInputService.instance.sendScroll(_pendScroll);
      _pendScroll = 0;
    }
  }

  // ── Raw pointer handling ────────────────────────────────────────────────────

  void _onPointerDown(int pointerId, Offset position, Duration timestamp) {
    _pointers[pointerId] = position;
    if (_pointers.length == 2) {
      // Entering two-finger mode: re-baseline so no jump is sent.
      _scrollAvgY = null;
    }
    _downPos[pointerId] = position;
    _gestureStart ??= timestamp;
    if (_downPos.length > 2) {
      // Three or more fingers can never be a tap.
      _tapCancelled = true;
    }
    if (!_dragging) {
      setState(() => _dragging = true);
    }
  }

  double? _twoFingerAvgY() {
    if (_pointers.length < 2) return null;
    final firstTwo = _pointers.values.take(2).toList();
    return (firstTwo[0].dy + firstTwo[1].dy) / 2;
  }

  /// True once any active finger has traveled beyond the slop from where
  /// it landed — the gesture is then locked in as a drag/scroll.
  bool _travelBeyondSlop() {
    for (final id in _pointers.keys) {
      final down = _downPos[id];
      final current = _pointers[id];
      if (down == null || current == null) continue;
      if ((current - down).distance >= _tapSlopPx) return true;
    }
    return false;
  }

  void _onPointerMove(int pointerId, Offset position) {
    final last = _pointers[pointerId];
    if (last == null) return;

    if (!_gestureEmitted) {
      // Tap window: hold off emitting anything until finger travel rules
      // out a tap, so a tap never moves the cursor or scrolls first.
      // Positions/baselines are still kept fresh so the transition into
      // drag/scroll starts cleanly from the current spot.
      _pointers[pointerId] = position;
      if (_pointers.length >= 2) {
        _scrollAvgY = _twoFingerAvgY();
      }
      if (_travelBeyondSlop()) {
        _gestureEmitted = true;
        _tapCancelled = true;
      }
      return;
    }

    if (_pointers.length == 1) {
      // Single finger: relative mouse movement.
      _pendDx += position.dx - last.dx;
      _pendDy += position.dy - last.dy;
      _pointers[pointerId] = position;
    } else if (_pointers.length >= 2) {
      // Two fingers: vertical scroll from the average of both pointers.
      _pointers[pointerId] = position;
      final avgY = _twoFingerAvgY();
      final base = _scrollAvgY;
      if (base != null && avgY != null) {
        _pendScroll += avgY - base;
      }
      _scrollAvgY = avgY;
    }
    _scheduleFlush();
  }

  void _onPointerUp(int pointerId, Offset position, Duration timestamp,
      {required bool cancelled}) {
    // Final travel check for the lifting finger (tap eligibility).
    final down = _downPos[pointerId];
    if (down != null && (position - down).distance >= _tapSlopPx) {
      _tapCancelled = true;
    }
    if (cancelled) _tapCancelled = true;

    _pointers.remove(pointerId);
    if (_pointers.length < 2) {
      _scrollAvgY = null;
    }
    if (_pointers.isEmpty) {
      _flushNow();
      _maybeFireTap(timestamp);
      _resetGesture();
      if (_dragging) {
        setState(() => _dragging = false);
      }
    }
  }

  /// Fires the click only after the gesture completes and qualifies as a
  /// tap: one finger → left click, two fingers → right click.
  void _maybeFireTap(Duration now) {
    if (_tapCancelled || _gestureEmitted) return;
    final start = _gestureStart;
    if (start == null) return;
    if (now - start > _tapMaxDuration) return;

    if (_downPos.length == 1) {
      RemoteInputService.instance.sendMouseClick('left');
    } else if (_downPos.length == 2) {
      RemoteInputService.instance.sendMouseClick('right');
    }
  }

  void _resetGesture() {
    _downPos.clear();
    _gestureStart = null;
    _gestureEmitted = false;
    _tapCancelled = false;
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  String get _host {
    final url = SocketService.instance.currentUrl ?? '';
    final host = url.replaceFirst(RegExp(r'https?://'), '').split(':').first;
    return host.isEmpty ? 'Windows PC' : host;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BridgeColors.linen,
      body: SafeArea(
        child: Column(
          children: [
            _buildStatusBar(),
            Expanded(child: _buildSurface()),
            _buildSensitivityRow(),
            _buildClickButtons(),
            _buildTabBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: BridgeColors.card,
                border: Border.all(color: BridgeColors.sand),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const BridgeIcon('arrowLeft',
                  color: BridgeColors.ink, size: 18),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ValueListenableBuilder<bool>(
              valueListenable: SocketService.instance.connected,
              builder: (context, isConnected, _) {
                return Row(
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: isConnected
                            ? BridgeColors.sage
                            : BridgeColors.disconnectedDot,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        isConnected
                            ? 'Controlling $_host'
                            : 'Not connected to $_host',
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSurface() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Container(
        decoration: BoxDecoration(
          color: BridgeColors.card,
          border: Border.all(color: BridgeColors.sand),
          borderRadius: BorderRadius.circular(18),
          boxShadow: BridgeShadows.card,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) =>
                    _onPointerDown(e.pointer, e.localPosition, e.timeStamp),
                onPointerMove: (e) => _onPointerMove(e.pointer, e.localPosition),
                onPointerUp: (e) => _onPointerUp(e.pointer, e.localPosition,
                    e.timeStamp,
                    cancelled: false),
                onPointerCancel: (e) => _onPointerUp(
                    e.pointer, e.localPosition, e.timeStamp,
                    cancelled: true),
                child: const SizedBox.expand(),
              ),
              // Usage hint — fades out while dragging.
              IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  curve: BridgeMotion.calm,
                  opacity: _dragging ? 0 : 1,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: BridgeColors.sageSoft,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: const BridgeIcon('hand',
                              size: 24, color: BridgeColors.sageDeep),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Tap to click • Drag to move\nTwo-finger drag to scroll\nTwo-finger tap = right click',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'NunitoSans',
                            fontSize: 13,
                            height: 1.6,
                            color: BridgeColors.inkSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Offline notice.
              ValueListenableBuilder<bool>(
                valueListenable: SocketService.instance.connected,
                builder: (context, isConnected, _) {
                  if (isConnected) return const SizedBox.shrink();
                  return Container(
                    color: BridgeColors.linen.withAlpha(210),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(24),
                    child: const Text(
                      'Not connected\nReconnect Bridge on your PC to continue',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'NunitoSans',
                        fontSize: 13,
                        height: 1.6,
                        color: BridgeColors.inkSoft,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Cursor sensitivity ──────────────────────────────────────────────────────

  void _sendSensitivity() {
    RemoteInputService.instance.sendSensitivity(_sensitivity);
  }

  /// Live-applies slider drags. Wire sends are lightly throttled — the
  /// host only ever needs the latest value.
  void _onSensitivityChanged(double value) {
    setState(() => _sensitivity = value);
    _sensSendTimer?.cancel();
    _sensSendTimer = Timer(const Duration(milliseconds: 60), _sendSensitivity);
  }

  /// Persists the chosen value once the drag (or track tap) settles.
  void _onSensitivityChangeEnd(double value) {
    RemotePrefsService.instance.saveSensitivity(value);
    _sensSendTimer?.cancel();
    _sendSensitivity();
  }

  /// Cursor-movement sensitivity slider — movement only, never scroll
  /// speed or clicks. Styled like the tab bar: card surface, sand border.
  Widget _buildSensitivityRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 2, 10, 2),
        decoration: BoxDecoration(
          color: BridgeColors.card,
          border: Border.all(color: BridgeColors.sand),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            const BridgeIcon('mouse', size: 15, color: BridgeColors.inkSoft),
            const SizedBox(width: 7),
            const Text(
              'Sensitivity',
              style: TextStyle(
                fontFamily: 'NunitoSans',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: BridgeColors.ink,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: BridgeColors.clay,
                  inactiveTrackColor: BridgeColors.sandSoft,
                  thumbColor: BridgeColors.clay,
                  overlayColor: BridgeColors.claySoft,
                  activeTickMarkColor: Colors.transparent,
                  inactiveTickMarkColor: Colors.transparent,
                ),
                child: Slider(
                  min: RemotePrefsService.minSensitivity,
                  max: RemotePrefsService.maxSensitivity,
                  divisions:
                      ((RemotePrefsService.maxSensitivity -
                                  RemotePrefsService.minSensitivity) *
                              10)
                          .round(),
                  value: _sensitivity,
                  onChanged: _onSensitivityChanged,
                  onChangeEnd: _onSensitivityChangeEnd,
                ),
              ),
            ),
            SizedBox(
              width: 38,
              child: Text(
                '${_sensitivity.toStringAsFixed(1)}×',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontFamily: 'NunitoSans',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: BridgeColors.clayDeep,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClickButtons() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _click('left'),
              icon: const BridgeIcon('mousePointerClick', size: 16),
              label: const Text('Left Click'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _click('right'),
              icon: const BridgeIcon('menu', size: 16),
              label: const Text('Right Click'),
            ),
          ),
        ],
      ),
    );
  }

  VoidCallback _click(String button) {
    return () {
      RemoteInputService.instance.sendMouseClick(button);
    };
  }

  /// Bottom tab bar shell — Trackpad active; Keyboard and Media arrive in a
  /// later pass and are greyed out as placeholders.
  Widget _buildTabBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: BridgeColors.sandSoft,
          border: Border.all(color: BridgeColors.sand),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            _RemoteTab(
              icon: 'hand',
              label: 'Trackpad',
              active: true,
            ),
            _RemoteTab(
              icon: 'keyboard',
              label: 'Keyboard',
              enabled: false,
              onTap: () => _showComingSoon('Keyboard'),
            ),
            _RemoteTab(
              icon: 'play',
              label: 'Media',
              enabled: false,
              onTap: () => _showComingSoon('Media'),
            ),
          ],
        ),
      ),
    );
  }

  void _showComingSoon(String feature) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$feature remote is coming in a later update'),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

class _RemoteTab extends StatelessWidget {
  final String icon;
  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback? onTap;

  const _RemoteTab({
    required this.icon,
    required this.label,
    this.active = false,
    this.enabled = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active
        ? BridgeColors.ink
        : enabled
            ? BridgeColors.inkSoft
            : BridgeColors.muted;
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
              BridgeIcon(icon, size: 15, color: color),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'NunitoSans',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
