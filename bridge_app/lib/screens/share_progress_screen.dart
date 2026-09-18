import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/bridge_icons.dart';
import '../services/file_transfer_service.dart';
import '../services/pairing_storage_service.dart';
import '../services/socket_service.dart';
import '../services/background_service.dart';
import '../theme/bridge_theme.dart';

const _shareChannel = MethodChannel('bridge/share');

/// Bottom-sheet-style screen shown inside ShareTargetActivity.
/// Reads shared URIs from Kotlin and routes the transfer through BackgroundService.
class ShareProgressScreen extends StatefulWidget {
  const ShareProgressScreen({super.key});

  @override
  State<ShareProgressScreen> createState() => _ShareProgressScreenState();
}

class _ShareProgressScreenState extends State<ShareProgressScreen> {
  _Phase _phase = _Phase.loading;
  String _statusText = 'Preparing…';
  String _currentFileName = '';
  double _overallFraction = 0.0;
  int _sentCount = 0;
  int _totalCount = 0;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // 1. Check pairing
    final pairing = await PairingStorageService.instance.getPairing();
    if (pairing == null) {
      _setError('Bridge isn\'t paired.\nOpen Bridge and scan the QR code first.');
      return;
    }

    // 2. Get URIs from Kotlin
    List<String> uris;
    try {
      final raw = await _shareChannel.invokeMethod<List<dynamic>>('getSharedUris');
      uris = raw?.cast<String>() ?? [];
    } catch (e) {
      _setError('Couldn\'t read shared files.\n$e');
      return;
    }

    if (uris.isEmpty) {
      _setError('No files to send.');
      return;
    }

    // 3. Ensure background service is running & socket is connected
    setState(() {
      _phase = _Phase.connecting;
      _statusText = 'Connecting to PC…';
      _totalCount = uris.length;
    });

    try {
      await BackgroundService.start();
      await SocketService.instance.ensureConnected(timeout: const Duration(seconds: 8));
    } catch (_) {
      _setError('Couldn\'t reach your PC.\nIs Bridge running on Windows?');
      return;
    }

    // 4. Subscribe to send progress
    FileTransferService.sendProgress.addListener(_onProgress);

    // 5. Send files via BackgroundService cross-isolate command
    setState(() {
      _phase = _Phase.sending;
      _statusText = 'Sending…';
    });

    try {
      await FileTransferService.sendFiles(uris);
    } catch (e) {
      FileTransferService.sendProgress.removeListener(_onProgress);
      _setError('Transfer failed: $e');
      return;
    }
  }

  void _onProgress() {
    final p = FileTransferService.sendProgress.value;
    if (p == null || !mounted) return;

    if (p.error != null && p.error!.isNotEmpty) {
      FileTransferService.sendProgress.removeListener(_onProgress);
      _setError('Transfer failed: ${p.error}');
      return;
    }

    setState(() {
      _currentFileName = p.fileName;
      _overallFraction = (_sentCount + p.fraction) / (_totalCount > 0 ? _totalCount : 1);
      if (p.done) {
        _sentCount++;
        if (_sentCount >= _totalCount) {
          _phase = _Phase.done;
          _statusText = _totalCount > 1
              ? 'Sent $_totalCount files to PC ✓'
              : 'Sent to PC ✓';
          _overallFraction = 1.0;
          FileTransferService.sendProgress.removeListener(_onProgress);
          Future.delayed(const Duration(milliseconds: 1200), _finish);
        }
      }
    });
  }

  void _setError(String msg) {
    setState(() {
      _phase = _Phase.error;
      _errorText = msg;
    });
  }

  void _finish() {
    _shareChannel.invokeMethod('finish');
  }

  @override
  void dispose() {
    FileTransferService.sendProgress.removeListener(_onProgress);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: _BottomSheet(
          phase: _phase,
          statusText: _statusText,
          currentFileName: _currentFileName,
          overallFraction: _overallFraction,
          sentCount: _sentCount,
          totalCount: _totalCount,
          errorText: _errorText,
          onRetry: _start,
          onDismiss: _finish,
        ),
      ),
    );
  }
}

// ── Bottom sheet widget ───────────────────────────────────────────────────────

enum _Phase { loading, connecting, sending, done, error }

class _BottomSheet extends StatelessWidget {
  final _Phase phase;
  final String statusText;
  final String currentFileName;
  final double overallFraction;
  final int sentCount;
  final int totalCount;
  final String? errorText;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  const _BottomSheet({
    required this.phase,
    required this.statusText,
    required this.currentFileName,
    required this.overallFraction,
    required this.sentCount,
    required this.totalCount,
    required this.errorText,
    required this.onRetry,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 34),
      decoration: BoxDecoration(
        color: BridgeColors.card,
        border: Border.all(color: BridgeColors.sand),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: BridgeShadows.pop,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle pill
          Center(
            child: Container(
              width: 42, height: 5,
              decoration: BoxDecoration(
                color: BridgeColors.sand,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 18),
          // Icon + title
          Row(
            children: [
              _phaseIcon(phase),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _titleFor(phase, totalCount),
                      style: BridgeText.panelTitle,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusText,
                      style: BridgeText.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (phase == _Phase.sending) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 13, vertical: 11),
              decoration: BoxDecoration(
                color: BridgeColors.sandSoft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const BridgeIcon('fileUp',
                      size: 16, color: BridgeColors.inkSoft),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      currentFileName.isNotEmpty
                          ? currentFileName
                          : 'Sending…',
                      style: BridgeText.notifTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${(overallFraction * 100).clamp(0, 100).toStringAsFixed(0)}%',
                    style: BridgeText.count,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: overallFraction,
                backgroundColor: BridgeColors.sandSoft,
                valueColor: const AlwaysStoppedAnimation<Color>(
                    BridgeColors.ink),
                minHeight: 7,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              totalCount > 1
                  ? 'File $sentCount of $totalCount · encrypted over local Wi-Fi'
                  : 'Encrypted over local Wi-Fi',
              style: BridgeText.timestamp,
            ),
          ],
          if (phase == _Phase.error) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: BridgeColors.claySoft,
                border: Border.all(color: BridgeColors.sand),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                errorText ?? 'Unknown error',
                style: const TextStyle(
                  
                  color: BridgeColors.clayInk,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onDismiss,
                  child: const Text('Dismiss'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _titleFor(_Phase p, int total) {
    switch (p) {
      case _Phase.loading:
        return 'Preparing share…';
      case _Phase.connecting:
        return 'Connecting to PC…';
      case _Phase.sending:
        return total > 1 ? 'Sending to your PC' : 'Sending to your PC';
      case _Phase.done:
        return 'Sent to your PC';
      case _Phase.error:
        return 'Couldn’t send';
    }
  }

  Widget _phaseIcon(_Phase p) {
    switch (p) {
      case _Phase.loading:
      case _Phase.connecting:
        return const SizedBox(
          width: 26, height: 26,
          child: CircularProgressIndicator(
              strokeWidth: 2.5, color: BridgeColors.clay),
        );
      case _Phase.sending:
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: BridgeColors.sandSoft,
            borderRadius: BorderRadius.circular(13),
          ),
          child: BridgeIcon('fileUp',
              color: BridgeColors.clayInk, size: 20),
        );
      case _Phase.done:
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: BridgeColors.sageSoft,
            borderRadius: BorderRadius.circular(13),
          ),
          child: BridgeIcon('check',
              color: BridgeColors.sageDeep, size: 20),
        );
      case _Phase.error:
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: BridgeColors.errorSoft,
            borderRadius: BorderRadius.circular(13),
          ),
          child: const BridgeIcon('x',
              color: BridgeColors.error, size: 20),
        );
    }
  }
}
