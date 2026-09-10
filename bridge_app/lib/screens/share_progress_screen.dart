import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/file_transfer_service.dart';
import '../services/pairing_storage_service.dart';
import '../services/socket_service.dart';

const _shareChannel = MethodChannel('bridge/share');

/// Bottom-sheet-style screen shown inside ShareTargetActivity.
/// Reads shared URIs from Kotlin, streams them via FileTransferService.
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

    // 3. Connect socket
    setState(() {
      _phase = _Phase.connecting;
      _statusText = 'Connecting to PC…';
      _totalCount = uris.length;
    });

    try {
      await SocketService.instance.ensureConnected(timeout: const Duration(seconds: 8));
    } catch (_) {
      _setError('Couldn\'t reach your PC.\nIs Bridge running on Windows?');
      return;
    }

    // 4. Subscribe to send progress
    FileTransferService.sendProgress.addListener(_onProgress);

    // 5. Send files
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

    FileTransferService.sendProgress.removeListener(_onProgress);

    setState(() {
      _phase = _Phase.done;
      _statusText = _totalCount > 1
          ? 'Sent $_totalCount files to PC ✓'
          : 'Sent to PC ✓';
      _overallFraction = 1.0;
    });

    await Future.delayed(const Duration(milliseconds: 1200));
    _finish();
  }

  void _onProgress() {
    final p = FileTransferService.sendProgress.value;
    if (p == null || !mounted) return;
    setState(() {
      _currentFileName = p.fileName;
      _overallFraction = (_sentCount + p.fraction) / _totalCount;
      if (p.done) _sentCount++;
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
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle pill
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Icon + title
          Row(
            children: [
              _phaseIcon(phase),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  statusText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (phase == _Phase.sending) ...[
            const SizedBox(height: 16),
            if (currentFileName.isNotEmpty)
              Text(
                currentFileName,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: overallFraction,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6366F1)),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              totalCount > 1 ? '$sentCount / $totalCount files' : '',
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
            ),
          ],
          if (phase == _Phase.error) ...[
            const SizedBox(height: 12),
            Text(
              errorText ?? 'Unknown error',
              style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 14),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onDismiss,
                  child: const Text('Dismiss', style: TextStyle(color: Color(0xFF94A3B8))),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: onRetry,
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _phaseIcon(_Phase p) {
    switch (p) {
      case _Phase.loading:
      case _Phase.connecting:
        return const SizedBox(
          width: 24, height: 24,
          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6366F1)),
        );
      case _Phase.sending:
        return const Icon(Icons.upload_rounded, color: Color(0xFF6366F1), size: 24);
      case _Phase.done:
        return const Icon(Icons.check_circle_rounded, color: Color(0xFF22C55E), size: 24);
      case _Phase.error:
        return const Icon(Icons.error_rounded, color: Color(0xFFF87171), size: 24);
    }
  }
}
