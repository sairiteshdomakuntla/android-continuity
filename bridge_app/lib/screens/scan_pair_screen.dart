import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../theme/bridge_icons.dart';
import '../services/pairing_storage_service.dart';
import '../services/socket_service.dart';
import '../services/background_service.dart';
import '../main.dart';
import '../theme/bridge_theme.dart';

class ScanPairScreen extends StatefulWidget {
  const ScanPairScreen({super.key});

  @override
  State<ScanPairScreen> createState() => _ScanPairScreenState();
}

class _ScanPairScreenState extends State<ScanPairScreen> {
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _isProcessing = false;
  String? _statusText;
  bool _torchOn = false;
  bool _showHelp = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_isProcessing) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && raw.isNotEmpty) {
        _processScannedData(raw);
        break;
      }
    }
  }

  Future<void> _processScannedData(String raw) async {
    setState(() {
      _isProcessing = true;
      _statusText = 'Verifying QR code…';
    });

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      final String? ip = data['ip'];
      final int port = data['port'] is int ? data['port'] : int.tryParse(data['port']?.toString() ?? '4000') ?? 4000;
      final String? pairingKey = data['pairingKey'];

      if (ip == null || pairingKey == null || pairingKey.isEmpty) {
        throw Exception('This QR code is not a Bridge pairing code.');
      }

      await _performPairing(ip, port, pairingKey);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not pair: ${e.toString().replaceAll('Exception: ', '')}'),
        ),
      );
      setState(() {
        _isProcessing = false;
        _statusText = null;
      });
    }
  }

  Future<void> _performPairing(String ip, int port, String pairingKey) async {
    debugPrint('[ScanPair] Parsed QR code: target host=$ip:$port, key=${pairingKey.substring(0, 8)}...');
    setState(() {
      _statusText = 'Connecting to $ip…';
    });

    final serverUrl = 'http://$ip:$port';
    final deviceId = await PairingStorageService.instance.getOrCreateDeviceId();

    setState(() {
      _statusText = 'Securing connection…';
    });

    debugPrint('[ScanPair] Starting performPairHandshake to $serverUrl with deviceId $deviceId');
    await SocketService.instance.performPairHandshake(
      serverUrl: serverUrl,
      pairingKey: pairingKey,
      deviceId: deviceId,
      deviceName: 'Android Phone',
    );
    debugPrint('[ScanPair] performPairHandshake completed successfully!');

    // Single-PC UI: this QR replaces any previous pairing.
    await PairingStorageService.instance.replacePairing(
      ip: ip,
      port: port,
      pairingKey: pairingKey,
      deviceId: deviceId,
    );

    // Start background service to maintain persistent socket
    await BackgroundService.start();
    BackgroundService.restartSocket();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Connected — setup continues on the next screen')),
    );

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const BridgeHome()),
    );
  }

  Future<void> _toggleTorch() async {
    try {
      await _scannerController.toggleTorch();
      if (mounted) setState(() => _torchOn = !_torchOn);
    } catch (_) {}
  }

  void _showManualEntryDialog() {
    final ipController = TextEditingController();
    final portController = TextEditingController(text: '4000');
    final keyController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            const Text('Enter code manually', style: BridgeText.panelTitle),
            const SizedBox(height: 4),
            const Text(
              'Find the IP, port and pairing key in the Bridge app on your PC.',
              style: BridgeText.caption,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ipController,
              decoration: const InputDecoration(labelText: 'PC IP address', hintText: 'e.g. 192.168.1.43'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyController,
              decoration: const InputDecoration(labelText: 'Pairing key'),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                final ip = ipController.text.trim();
                final port = int.tryParse(portController.text.trim()) ?? 4000;
                final key = keyController.text.trim();
                if (ip.isNotEmpty && key.isNotEmpty) {
                  _performPairing(ip, port, key);
                }
              },
              child: const Text('Connect'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: BridgeColors.linen,
      appBar: AppBar(
        automaticallyImplyLeading: canPop,
        title: const Text('Pair with your PC'),
        actions: [
          IconButton(
            icon: const BridgeIcon('keyboard', size: 20),
            tooltip: 'Enter manually',
            onPressed: _isProcessing ? null : _showManualEntryDialog,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Hero ──
            BridgeCard(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: BridgeColors.ink,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    alignment: Alignment.center,
                    child: const BridgeIcon('link',
                        size: 23, color: Colors.white),
                  ),
                  const SizedBox(width: 13),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Scan once — then forget it',
                            style: BridgeText.panelTitle),
                        SizedBox(height: 3),
                        Text(
                          'Under a minute. After this, everything runs in the background — you rarely open this app again.',
                          style: BridgeText.caption,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // ── How pairing works ──
            const BridgeCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('How it works',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.0,
                          color: BridgeColors.muted)),
                  SizedBox(height: 10),
                  _StepRow(n: '1', text: 'Open Bridge on your computer'),
                  SizedBox(height: 8),
                  _StepRow(n: '2', text: 'Choose “Pair new” to show the code'),
                  SizedBox(height: 8),
                  _StepRow(n: '3', text: 'Point this camera at the code'),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── Scanner ──
            Container(
              decoration: BoxDecoration(
                color: BridgeColors.card,
                border: Border.all(color: BridgeColors.sand),
                borderRadius: BorderRadius.circular(20),
                boxShadow: BridgeShadows.card,
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      height: 300,
                      width: double.infinity,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MobileScanner(
                            controller: _scannerController,
                            onDetect: _onDetect,
                          ),
                          // Dim + corner brackets for a native scanner feel
                          IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Colors.black.withAlpha(20)),
                              ),
                            ),
                          ),
                          Center(
                            child: SizedBox(
                              width: 210,
                              height: 210,
                              child: CustomPaint(painter: _CornerPainter()),
                            ),
                          ),
                          Positioned(
                            top: 10,
                            right: 10,
                            child: Material(
                              color: Colors.black.withAlpha(140),
                              borderRadius: BorderRadius.circular(999),
                              child: InkWell(
                                onTap: _toggleTorch,
                                borderRadius: BorderRadius.circular(999),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _torchOn ? Icons.flash_on : Icons.flash_off,
                                        size: 15,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        _torchOn ? 'On' : 'Light',
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (_isProcessing)
                            Container(
                              color: Colors.black.withAlpha(120),
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    _statusText ?? 'Pairing…',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: BridgeColors.sageSoft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      children: [
                        BridgeIcon('shieldCheck',
                            size: 15, color: BridgeColors.sageDeep),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Private by design — AES-256, local Wi-Fi only. Nothing leaves your network.',
                            style: BridgeText.caption,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            OutlinedButton.icon(
              onPressed: _isProcessing ? null : _showManualEntryDialog,
              icon: const BridgeIcon('keyboard', size: 16),
              label: const Text('Can\'t scan? Enter code manually'),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _showHelp = !_showHelp),
              icon: BridgeIcon(_showHelp ? 'x' : 'fileText', size: 14),
              label: Text(_showHelp ? 'Hide help' : 'QR code won\'t scan?'),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: const BridgeCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Make sure:', style: BridgeText.notifTitle),
                    SizedBox(height: 8),
                    Text('• Phone and PC are on the same Wi-Fi network\n• The QR code on your PC is fully visible and bright\n• Bridge is open on your PC while you scan', style: BridgeText.bodySoft),
                  ],
                ),
              ),
              crossFadeState: _showHelp ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 180),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final String n;
  final String text;
  const _StepRow({required this.n, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(color: BridgeColors.claySoft, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text(n, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: BridgeColors.clay)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: BridgeText.bodySoft)),
      ],
    );
  }
}

class _CornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const l = 28.0;
    // top-left
    canvas.drawPath(_corner(const Offset(0, 0), l, 0), paint);
    // top-right
    canvas.drawPath(_corner(Offset(size.width, 0), l, 1), paint);
    // bottom-right
    canvas.drawPath(_corner(Offset(size.width, size.height), l, 2), paint);
    // bottom-left
    canvas.drawPath(_corner(Offset(0, size.height), l, 3), paint);
  }

  Path _corner(Offset o, double l, int quadrant) {
    final p = Path();
    if (quadrant == 0) {
      p.moveTo(o.dx, o.dy + l);
      p.lineTo(o.dx, o.dy);
      p.lineTo(o.dx + l, o.dy);
    } else if (quadrant == 1) {
      p.moveTo(o.dx - l, o.dy);
      p.lineTo(o.dx, o.dy);
      p.lineTo(o.dx, o.dy + l);
    } else if (quadrant == 2) {
      p.moveTo(o.dx, o.dy - l);
      p.lineTo(o.dx, o.dy);
      p.lineTo(o.dx - l, o.dy);
    } else {
      p.moveTo(o.dx + l, o.dy);
      p.lineTo(o.dx, o.dy);
      p.lineTo(o.dx, o.dy - l);
    }
    return p;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
