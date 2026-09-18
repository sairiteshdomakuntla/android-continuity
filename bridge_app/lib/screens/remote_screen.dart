import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/remote_input_service.dart';
import '../services/remote_prefs_service.dart';
import '../services/socket_service.dart';
import '../theme/bridge_icons.dart';
import '../theme/bridge_theme.dart';

/// "Phone as Remote" — trackpad, keyboard, and media control.
///
/// Trackpad tab:
///   • Single-finger drag on the surface  → relative mouse movement
///   • Two-finger drag on the surface     → vertical scroll (natural
///     direction: fingers down scrolls content up, like a laptop)
///   • Quick single-finger tap             → left click
///   • Quick two-finger tap                → right click
///   • Left Click / Right Click buttons    → mouse clicks (always available)
///
/// Keyboard tab:
///   • A focused, minimal text field streams each character to the PC as
///     it is typed; Enter/Backspace are sent as key specials. The field
///     stays cleared — there's no persistent visible text.
///
/// Media tab:
///   • Play/pause, next, previous, volume up/down, mute — sent as media
///     key commands for whatever app has media focus on the PC.
///
/// Trackpad pointer events are read raw (Listener, no gesture arena) for
/// the lowest possible latency, coalesced to one wire message per ~16 ms
/// flush.
///
/// Taps are told apart from drags/scrolls with a slop + time window:
/// nothing is emitted until finger travel exceeds [_tapSlopPx], and a
/// click only fires after the whole gesture ends within
/// [_tapMaxDuration] — so a deliberate drag/scroll can never also fire a
/// click at its start, and a tap never moves the cursor or scrolls first.
enum _RemoteTabId { trackpad, keyboard, media }

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

  // ── Tabs ────────────────────────────────────────────────────────────────────
  _RemoteTabId _selectedTab = _RemoteTabId.trackpad;

  // ── Keyboard tab state ──────────────────────────────────────────────────────
  final TextEditingController _kbController = TextEditingController();
  final FocusNode _kbFieldFocus = FocusNode();
  final FocusNode _kbRawKeys = FocusNode(debugLabel: 'kb-raw-keys');
  String _lastKbText = '';
  bool _clearingKbField = false;

  // Dedup guard: one physical key press can surface both as a raw
  // KeyEvent and as a text/action event; drop the echo within 50 ms.
  // Auto-repeat (KeyRepeatEvent) bypasses this on purpose.
  String? _lastSpecialKey;
  int _lastSpecialAt = 0;

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
    _kbController.dispose();
    _kbFieldFocus.dispose();
    _kbRawKeys.dispose();
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

  // ── Tab switching ───────────────────────────────────────────────────────────

  void _selectTab(_RemoteTabId tab) {
    if (tab == _selectedTab) return;
    setState(() {
      _selectedTab = tab;
      if (tab != _RemoteTabId.trackpad) {
        // End any in-flight trackpad gesture cleanly so nothing dangles.
        _pointers.clear();
        _scrollAvgY = null;
        _resetGesture();
        _dragging = false;
      }
    });
    _flushNow();
    _flushTimer?.cancel();
    _flushTimer = null;
    if (tab == _RemoteTabId.keyboard) {
      // Focus the field (opens the soft keyboard) once the tab has built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedTab == _RemoteTabId.keyboard) {
          _kbFieldFocus.requestFocus();
        }
      });
    } else {
      // Leaving the keyboard tab: dismiss the soft keyboard.
      _kbFieldFocus.unfocus();
    }
  }

  // ── Keyboard tab ────────────────────────────────────────────────────────────

  void _sendKeySpecial(String key, {bool repeat = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!repeat && key == _lastSpecialKey && now - _lastSpecialAt < 50) {
      return; // echo of the same physical press (KeyEvent + action)
    }
    _lastSpecialKey = key;
    _lastSpecialAt = now;
    RemoteInputService.instance.sendKeySpecial(key);
  }

  /// Raw key events — catches Backspace/Enter while the field is empty
  /// (the text-diff path can't see those, since there is no text to
  /// change). Events bubble up from the focused field, so these only
  /// arrive when the field itself left them unhandled.
  void _onRawKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      _sendKeySpecial('backspace', repeat: event is KeyRepeatEvent);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _sendKeySpecial('enter', repeat: event is KeyRepeatEvent);
    }
  }

  /// Streams each typed character to the PC as it arrives; the field is
  /// cleared immediately afterwards so no visible text accumulates.
  void _onKbFieldChanged(String value) {
    if (_clearingKbField) return;
    if (value == _lastKbText) return;

    final prev = _lastKbText;
    _lastKbText = value;

    if (value.length > prev.length && value.startsWith(prev)) {
      // Characters inserted at the end — the normal typing path.
      final inserted = value.substring(prev.length);
      final pending = StringBuffer();
      for (final ch in inserted.runes) {
        if (ch == 0x0A || ch == 0x0D) {
          // Some IMEs commit Enter as a newline character.
          if (pending.isNotEmpty) {
            RemoteInputService.instance.sendKeyInput(pending.toString());
            pending.clear();
          }
          _sendKeySpecial('enter');
        } else {
          pending.writeCharCode(ch);
        }
      }
      if (pending.isNotEmpty) {
        RemoteInputService.instance.sendKeyInput(pending.toString());
      }
    } else if (value.length < prev.length && prev.startsWith(value)) {
      // Characters deleted from the end (field still had text).
      for (var i = 0; i < prev.length - value.length; i++) {
        _sendKeySpecial('backspace');
      }
    }
    // Anything else (mid-word autocorrect replacement etc.) is ignored —
    // the field is cleared immediately so state never accumulates.

    _clearKbField();
  }

  void _clearKbField() {
    _clearingKbField = true;
    _kbController.clear();
    _lastKbText = '';
    _clearingKbField = false;
  }

  void _onKbFieldSubmitted(String value) {
    _sendKeySpecial('enter');
    _clearKbField();
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
            Expanded(
              child: switch (_selectedTab) {
                _RemoteTabId.trackpad => _buildTrackpadTab(),
                _RemoteTabId.keyboard => _buildKeyboardTab(),
                _RemoteTabId.media => _buildMediaTab(),
              },
            ),
            _buildTabBar(),
          ],
        ),
      ),
    );
  }

  /// Trackpad tab: surface + sensitivity + click buttons, unchanged.
  Widget _buildTrackpadTab() {
    return Column(
      children: [
        Expanded(child: _buildSurface()),
        _buildSensitivityRow(),
        _buildClickButtons(),
      ],
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
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: BridgeColors.ink,
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Center(
                child: BridgeIcon('arrowLeft',
                    color: Colors.white, size: 18),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ValueListenableBuilder<bool>(
              valueListenable: SocketService.instance.connected,
              builder: (context, isConnected, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Remote · $_host',
                      style: BridgeText.notifTitle,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: isConnected
                                ? BridgeColors.sage
                                : BridgeColors.disconnectedDot,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isConnected
                              ? 'Live — moves your PC cursor'
                              : 'Offline — reconnect to continue',
                          style: BridgeText.caption,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
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
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: BridgeColors.ink,
                              borderRadius: BorderRadius.circular(19),
                            ),
                            child: const BridgeIcon('hand',
                                size: 25, color: Colors.white),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Precision trackpad',
                            style: BridgeText.panelTitle,
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Tap to click · Drag to move\nTwo-finger drag to scroll · Two-finger tap for right-click',
                            textAlign: TextAlign.center,
                            style: TextStyle(
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

  // ── Keyboard tab ────────────────────────────────────────────────────────────

  /// Keyboard tab: a large tappable area that keeps a minimal, focused
  /// text field alive so the OS soft keyboard opens. Every keystroke is
  /// streamed to the PC immediately; the field stays cleared, so only the
  /// status indicator is persistently visible.
  Widget _buildKeyboardTab() {
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
          child: KeyboardListener(
            focusNode: _kbRawKeys,
            onKeyEvent: _onRawKeyEvent,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _kbFieldFocus.requestFocus,
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: SocketService.instance.connected,
                        builder: (context, isConnected, _) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: BridgeColors.sageSoft,
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: const BridgeIcon('keyboard',
                                    size: 24, color: BridgeColors.sageDeep),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisSize: MainAxisSize.min,
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
                                  Text(
                                    isConnected
                                        ? 'Connected — type to send to PC'
                                        : 'Not connected',
                                    style: const TextStyle(
                                      
                                      fontSize: 13,
                                      height: 1.6,
                                      color: BridgeColors.inkSoft,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _kbController,
                            focusNode: _kbFieldFocus,
                            onChanged: _onKbFieldChanged,
                            onSubmitted: _onKbFieldSubmitted,
                            onEditingComplete: () {},
                            autocorrect: false,
                            enableSuggestions: false,
                            smartDashesType: SmartDashesType.disabled,
                            smartQuotesType: SmartQuotesType.disabled,
                            textInputAction: TextInputAction.send,
                            maxLines: 1,
                            style: const TextStyle(
                              
                              fontSize: 15,
                              color: BridgeColors.ink,
                            ),
                            cursorColor: BridgeColors.clay,
                            decoration: const InputDecoration(
                              hintText: 'Type to send to PC…',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        _KbIconButton(
                          icon: 'cornerDownLeft',
                          onTap: () => _sendKeySpecial('enter'),
                        ),
                        const SizedBox(width: 8),
                        _KbIconButton(
                          icon: 'delete',
                          onTap: () => _sendKeySpecial('backspace'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Media tab ───────────────────────────────────────────────────────────────

  void _sendMedia(String command) {
    RemoteInputService.instance.sendMediaCommand(command);
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: BridgeText.badgeCaps.copyWith(color: BridgeColors.inkSoft),
    );
  }

  /// Media tab: six large buttons delivering media-key commands to
  /// whatever app has media focus on the PC.
  Widget _buildMediaTab() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: BridgeColors.card,
          border: Border.all(color: BridgeColors.sand),
          borderRadius: BorderRadius.circular(18),
          boxShadow: BridgeShadows.card,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionLabel('PLAYBACK'),
            const SizedBox(height: 10),
            // IntrinsicHeight gives the Row a bounded cross extent so
            // CrossAxisAlignment.stretch can equalize button heights —
            // stretch inside an unbounded-height Column would otherwise
            // force infinite heights and blank the tab.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _MediaButton(
                      icon: 'skipBack',
                      label: 'Previous',
                      onTap: () => _sendMedia('previous'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: _MediaButton(
                      icon: 'play',
                      label: 'Play / Pause',
                      hero: true,
                      onTap: () => _sendMedia('play-pause'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MediaButton(
                      icon: 'skipForward',
                      label: 'Next',
                      onTap: () => _sendMedia('next'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _sectionLabel('VOLUME'),
            const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _MediaButton(
                      icon: 'volumeDown',
                      label: 'Volume Down',
                      onTap: () => _sendMedia('volume-down'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MediaButton(
                      icon: 'volumeX',
                      label: 'Mute',
                      onTap: () => _sendMedia('mute'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _MediaButton(
                      icon: 'volumeUp',
                      label: 'Volume Up',
                      onTap: () => _sendMedia('volume-up'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Bottom tab bar: Trackpad / Keyboard / Media.
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
              active: _selectedTab == _RemoteTabId.trackpad,
              onTap: () => _selectTab(_RemoteTabId.trackpad),
            ),
            _RemoteTab(
              icon: 'keyboard',
              label: 'Keyboard',
              active: _selectedTab == _RemoteTabId.keyboard,
              onTap: () => _selectTab(_RemoteTabId.keyboard),
            ),
            _RemoteTab(
              icon: 'play',
              label: 'Media',
              active: _selectedTab == _RemoteTabId.media,
              onTap: () => _selectTab(_RemoteTabId.media),
            ),
          ],
        ),
      ),
    );
  }
}

class _RemoteTab extends StatelessWidget {
  final String icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _RemoteTab({
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? BridgeColors.ink : BridgeColors.inkSoft;
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

/// Small square icon button (Enter / Backspace) next to the keyboard
/// tab's text field — styled like the status-bar back button.
class _KbIconButton extends StatelessWidget {
  final String icon;
  final VoidCallback onTap;

  const _KbIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: BridgeColors.card,
          border: Border.all(color: BridgeColors.sand),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: BridgeIcon(icon, size: 18, color: BridgeColors.ink),
        ),
      ),
    );
  }
}

/// A media-tab command button — styled like the tab pills (card surface,
/// sand border, soft shadow); the hero variant is clay with cream text.
class _MediaButton extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback onTap;
  final bool hero;

  const _MediaButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.hero = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = hero ? BridgeColors.clay : BridgeColors.card;
    final fg = hero ? BridgeColors.creamText : BridgeColors.ink;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: BridgeMotion.calm,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 8),
        decoration: BoxDecoration(
          color: bg,
          border: hero ? null : Border.all(color: BridgeColors.sand),
          borderRadius: BorderRadius.circular(16),
          boxShadow: hero ? BridgeShadows.card : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BridgeIcon(icon, size: hero ? 26 : 22, color: fg),
            const SizedBox(height: 10),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
