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
      _statusText = 'Verifying QR code...';
    });

    try {
      final Map<String, dynamic> data = jsonDecode(raw);
      final String? ip = data['ip'];
      final int port = data['port'] is int ? data['port'] : int.tryParse(data['port']?.toString() ?? '4000') ?? 4000;
      final String? pairingKey = data['pairingKey'];

      if (ip == null || pairingKey == null || pairingKey.isEmpty) {
        throw Exception('Invalid QR code content. Expected Bridge pairing data.');
      }

      await _performPairing(ip, port, pairingKey);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Pairing failed: ${e.toString().replaceAll('Exception: ', '')}'),
        ),
      );
      setState(() {
        _isProcessing = false;
        _statusText = null;
      });
    }
  }

  Future<void> _performPairing(String ip, int port, String pairingKey) async {
    setState(() {
      _statusText = 'Connecting to $ip:$port...';
    });

    final serverUrl = 'http://$ip:$port';
    final deviceId = await PairingStorageService.instance.getOrCreateDeviceId();

    setState(() {
      _statusText = 'Exchanging pairing handshake...';
    });

    await SocketService.instance.performPairHandshake(
      serverUrl: serverUrl,
      pairingKey: pairingKey,
      deviceId: deviceId,
      deviceName: 'Android Phone',
    );

    // Save pairing credentials in secure storage
    await PairingStorageService.instance.savePairing(
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
      const SnackBar(
        content: Text('Paired successfully with Windows Bridge!'),
      ),
    );

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const BridgeHome()),
    );
  }

  void _showManualEntryDialog() {
    final ipController = TextEditingController();
    final portController = TextEditingController(text: '4000');
    final keyController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Manual Pairing'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ipController,
                decoration: const InputDecoration(
                  labelText: 'Host IP Address',
                  hintText: 'e.g. 192.168.0.112',
                ),
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
                decoration: const InputDecoration(
                  labelText: 'Pairing Key (Base64)',
                  hintText: 'Paste pairing key',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
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
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BridgeColors.linen,
      appBar: AppBar(
        title: const Text('Pair with Bridge', style: BridgeText.panelTitle),
        backgroundColor: BridgeColors.linen,
        foregroundColor: BridgeColors.ink,
        elevation: 0,
        actions: [
          IconButton(
            icon: BridgeIcon('keyboard', size: 20),
            color: BridgeColors.inkSoft,
            tooltip: 'Manual Entry',
            onPressed: _isProcessing ? null : _showManualEntryDialog,
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── QR Scanner Camera ──────────────────────────────────────────
          MobileScanner(
            controller: _scannerController,
            onDetect: _onDetect,
          ),

          // ── Scanner Overlay Frame ─────────────────────────────────────
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: BridgeColors.clay, width: 3),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),

          // ── Guidance Banner ────────────────────────────────────────────
          Positioned(
            bottom: 60,
            left: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: BridgeColors.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: BridgeColors.sand),
                boxShadow: BridgeShadows.card,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isProcessing) ...[
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: BridgeColors.clay,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _statusText ?? 'Pairing...',
                      textAlign: TextAlign.center,
                      style: BridgeText.body,
                    ),
                  ] else ...[
                    BridgeIcon('scanLine',
                        color: BridgeColors.clay, size: 28),
                    const SizedBox(height: 8),
                    const Text(
                      'Point camera at the QR code on your PC screen',
                      textAlign: TextAlign.center,
                      style: BridgeText.body,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
