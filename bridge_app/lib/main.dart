import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'services/socket_service.dart';
import 'services/clipboard_service.dart';
import 'services/file_transfer_service.dart';
import 'services/pairing_storage_service.dart';
import 'screens/scan_pair_screen.dart';
import 'screens/share_progress_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Check existing pairing in secure storage
  final pairing = await PairingStorageService.instance.getPairing();

  if (pairing != null) {
    final keyBytes = Uint8List.fromList(base64Decode(pairing.pairingKey));
    SocketService.instance.setEncryptionKey(keyBytes);
    SocketService.instance.connect(pairing.serverUrl);
  }

  // Init clipboard service
  ClipboardService.instance.init();

  // Init file transfer service (handles incoming Windows→Android files)
  FileTransferService.init();

  runApp(BridgeApp(isPaired: pairing != null));
}

/// Dedicated entrypoint for Android Share Sheet (ShareTargetActivity)
@pragma('vm:entry-point')
void mainShare() async {
  WidgetsFlutterBinding.ensureInitialized();

  final pairing = await PairingStorageService.instance.getPairing();
  if (pairing != null) {
    final keyBytes = Uint8List.fromList(base64Decode(pairing.pairingKey));
    SocketService.instance.setEncryptionKey(keyBytes);
  }

  FileTransferService.init();

  runApp(const ShareApp());
}

class ShareApp extends StatelessWidget {
  const ShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bridge Share',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const Scaffold(
        backgroundColor: Colors.transparent,
        body: ShareProgressScreen(),
      ),
    );
  }
}

// ── App ────────────────────────────────────────────────────────────────────
class BridgeApp extends StatelessWidget {
  final bool isPaired;

  const BridgeApp({super.key, required this.isPaired});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: isPaired ? const BridgeHome() : const ScanPairScreen(),
    );
  }
}

// ── Home Screen ────────────────────────────────────────────────────────────
class BridgeHome extends StatefulWidget {
  const BridgeHome({super.key});

  @override
  State<BridgeHome> createState() => _BridgeHomeState();
}

class _BridgeHomeState extends State<BridgeHome> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Ensure connection is active and sync clipboard on first launch
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await SocketService.instance.ensureConnected();
      ClipboardService.instance.syncNow();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('[BridgeHome] App resumed, ensuring socket connection...');
      SocketService.instance.ensureConnected();
    }
  }

  Future<void> _unpair() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpair Device?'),
        content: const Text(
          'This will remove stored encryption keys and connection settings. You will need to scan the QR code again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await PairingStorageService.instance.clearPairing();
      SocketService.instance.setEncryptionKey(null);
      SocketService.instance.disconnect();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ScanPairScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ─────────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.swap_horiz_rounded,
                          color: colorScheme.primary, size: 32),
                      const SizedBox(width: 12),
                      Text(
                        'Bridge',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.qr_code_rounded),
                    tooltip: 'Pair / Unpair',
                    onPressed: _unpair,
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // ── Connection status card ──────────────────────────────────
              ValueListenableBuilder<bool>(
                valueListenable: SocketService.instance.connected,
                builder: (context, isConnected, _) {
                  return _StatusCard(
                    connected: isConnected,
                    serverUrl: SocketService.instance.currentUrl ?? 'Not connected',
                    onScanAgain: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ScanPairScreen()),
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 24),

              // ── Security Badge ──────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withAlpha(25),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.greenAccent.withAlpha(75)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 16, color: Colors.greenAccent),
                    SizedBox(width: 8),
                    Text(
                      'End-to-End Encrypted (AES-256-GCM)',
                      style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // ── How it works ────────────────────────────────────────────
              _InfoCard(
                icon: Icons.phone_android_rounded,
                title: 'Android → Windows',
                body:
                    'Copy text in any app, then open Bridge. '
                    'Bridge reads your clipboard the moment it comes to the foreground and sends it to Windows.',
                color: colorScheme.primaryContainer,
                onColor: colorScheme.onPrimaryContainer,
              ),
              const SizedBox(height: 12),
              _InfoCard(
                icon: Icons.computer_rounded,
                title: 'Windows → Android',
                body:
                    'Copy text on Windows. Bridge writes it to your Android clipboard instantly.',
                color: colorScheme.secondaryContainer,
                onColor: colorScheme.onSecondaryContainer,
              ),
              const SizedBox(height: 12),

              // ── Limitation notice ───────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.outlineVariant,
                    width: 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 18, color: colorScheme.outline),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Android → Windows sync requires Bridge to be open. '
                        'Background clipboard monitoring is not available (Android OS restriction).',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // ── Incoming file receive progress ──────────────────────────
              ValueListenableBuilder<FileReceiveProgress?>(
                valueListenable: FileTransferService.receiveProgress,
                builder: (context, rp, _) {
                  if (rp == null) return const SizedBox.shrink();
                  return _FileReceiveCard(progress: rp);
                },
              ),
              const SizedBox(height: 12),

              // ── Send File button ─────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await FilePicker.pickFiles(
                      type: FileType.any,
                    );
                    if (picked.isEmpty) return;
                    final uris = picked.map((f) => f.path).whereType<String>().toList();
                    if (!context.mounted) return;
                    try {
                      await SocketService.instance.ensureConnected();
                      await FileTransferService.sendFiles(uris);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Send failed: $e')),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('Send File to Windows'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Manual sync button ──────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    await SocketService.instance.ensureConnected();
                    await ClipboardService.instance.syncNow(force: true);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            SocketService.instance.isConnected
                                ? 'Clipboard synchronized with Windows!'
                                : 'Connecting to Windows... clipboard will sync upon connection.',
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('Sync Clipboard Now'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
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

// ── Widgets ─────────────────────────────────────────────────────────────────

/// Shows incoming file receive progress (Windows → Android) in BridgeHome.
class _FileReceiveCard extends StatelessWidget {
  final FileReceiveProgress progress;

  const _FileReceiveCard({required this.progress});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isError = progress.error;
    final isDone  = progress.done && !isError;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isError
            ? Colors.redAccent.withAlpha(25)
            : colorScheme.primaryContainer.withAlpha(60),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? Colors.redAccent.withAlpha(75)
              : colorScheme.primary.withAlpha(75),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isError
                    ? Icons.error_outline_rounded
                    : isDone
                        ? Icons.check_circle_outline_rounded
                        : Icons.download_rounded,
                size: 16,
                color: isError ? Colors.redAccent : colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isError
                      ? 'Receive failed: ${progress.fileName}'
                      : isDone
                          ? 'Received: ${progress.fileName}'
                          : 'Receiving: ${progress.fileName}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isError ? Colors.redAccent : colorScheme.onSurface,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (!isDone && !isError) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.fraction,
                backgroundColor: Colors.white12,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                minHeight: 4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final bool connected;
  final String serverUrl;
  final VoidCallback onScanAgain;

  const _StatusCard({
    required this.connected,
    required this.serverUrl,
    required this.onScanAgain,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dotColor = connected ? Colors.greenAccent : Colors.redAccent;
    final label = connected ? 'Connected' : 'Disconnected';
    final host = serverUrl.replaceFirst('http://', '');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: connected
                  ? [BoxShadow(color: dotColor.withAlpha(150), blurRadius: 8)]
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        )),
                Text(host,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        )),
              ],
            ),
          ),
          if (!connected) ...[
            TextButton.icon(
              onPressed: () => SocketService.instance.ensureConnected(),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Reconnect'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
            IconButton(
              onPressed: onScanAgain,
              icon: const Icon(Icons.qr_code, size: 18),
              tooltip: 'Scan New QR',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color color;
  final Color onColor;

  const _InfoCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
    required this.onColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: onColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: onColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 14)),
                const SizedBox(height: 4),
                Text(body,
                    style: TextStyle(
                        color: onColor.withAlpha(210), fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
