import 'package:flutter/material.dart';
import 'services/socket_service.dart';
import 'services/clipboard_service.dart';

// ── Configuration ──────────────────────────────────────────────────────────
const String kServerUrl = 'http://192.168.0.112:4000';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Init services
  SocketService.instance.connect(kServerUrl);
  ClipboardService.instance.init();

  runApp(const BridgeApp());
}

// ── App ────────────────────────────────────────────────────────────────────
class BridgeApp extends StatelessWidget {
  const BridgeApp({super.key});

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
      home: const BridgeHome(),
    );
  }
}

// ── Home Screen ────────────────────────────────────────────────────────────
class BridgeHome extends StatefulWidget {
  const BridgeHome({super.key});

  @override
  State<BridgeHome> createState() => _BridgeHomeState();
}

class _BridgeHomeState extends State<BridgeHome> {
  @override
  void initState() {
    super.initState();
    // Sync clipboard on first launch (app is already in resumed state)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ClipboardService.instance.syncNow();
    });
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
              const SizedBox(height: 32),

              // ── Connection status card ──────────────────────────────────
              ValueListenableBuilder<bool>(
                valueListenable: SocketService.instance.connected,
                builder: (context, isConnected, _) {
                  return _StatusCard(
                    connected: isConnected,
                    serverUrl: kServerUrl,
                  );
                },
              ),
              const SizedBox(height: 24),

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

              // ── Manual sync button ──────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => ClipboardService.instance.syncNow(),
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

class _StatusCard extends StatelessWidget {
  final bool connected;
  final String serverUrl;

  const _StatusCard({required this.connected, required this.serverUrl});

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
          Column(
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
