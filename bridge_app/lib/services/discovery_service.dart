import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class DiscoveredHost {
  final String ip;
  final int port;
  final String? hostname;

  const DiscoveredHost({
    required this.ip,
    required this.port,
    this.hostname,
  });

  String get serverUrl => 'http://$ip:$port';
}

class DiscoveryService {
  static const int discoveryUdpPort = 4001;
  static const int defaultHttpPort = 4000;

  /// Rapidly tests if a host is listening on the given port.
  static Future<bool> isHostReachable(
    String ip,
    int port, {
    Duration timeout = const Duration(milliseconds: 1800),
  }) async {
    try {
      final socket = await Socket.connect(ip, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends a UDP discovery broadcast on port 4001 to find Bridge Agent on the LAN.
  static Future<DiscoveredHost?> discoverViaUdp({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    RawDatagramSocket? socket;
    final completer = Completer<DiscoveredHost?>();

    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;

      final requestData = utf8.encode(jsonEncode({'type': 'bridge-discover'}));

      socket.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final dg = socket?.receive();
            if (dg == null) return;
            try {
              final text = utf8.decode(dg.data);
              final json = jsonDecode(text) as Map<String, dynamic>;
              final type = json['type'] as String?;
              if (type == 'bridge-announce' || type == 'bridge-beacon') {
                final ip = json['ip'] as String? ?? dg.address.address;
                final port = json['port'] as int? ?? defaultHttpPort;
                final hostname = json['hostname'] as String?;

                debugPrint('[DiscoveryService] Discovered Bridge Agent via UDP: $ip:$port ($hostname)');
                if (!completer.isCompleted) {
                  completer.complete(DiscoveredHost(
                    ip: ip,
                    port: port,
                    hostname: hostname,
                  ));
                }
              }
            } catch (_) {}
          }
        },
        onError: (e) {
          debugPrint('[DiscoveryService] UDP error: $e');
        },
      );

      // Send to global broadcast
      socket.send(requestData, InternetAddress('255.255.255.255'), discoveryUdpPort);

      // Also send to directed subnet broadcast addresses for each interface
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            final parts = addr.address.split('.');
            if (parts.length == 4) {
              final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
              try {
                socket.send(requestData, InternetAddress(subnetBroadcast), discoveryUdpPort);
              } catch (_) {}
            }
          }
        }
      } catch (_) {}

      // Timer to stop listening after timeout
      Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      final result = await completer.future;
      return result;
    } catch (e) {
      debugPrint('[DiscoveryService] UDP broadcast failed: $e');
      return null;
    } finally {
      socket?.close();
    }
  }

  /// Sweeps the local /24 subnet on port 4000 to find the Bridge PC if UDP broadcast is blocked by AP isolation.
  static Future<DiscoveredHost?> sweepSubnet({
    int port = defaultHttpPort,
    Duration perHostTimeout = const Duration(milliseconds: 600),
  }) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      final localIps = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.address.contains('.')) {
            localIps.add(addr.address);
          }
        }
      }

      if (localIps.isEmpty) return null;

      for (final localIp in localIps) {
        final parts = localIp.split('.');
        if (parts.length != 4) continue;
        final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
        final myHostNum = int.tryParse(parts[3]) ?? -1;

        debugPrint('[DiscoveryService] Sweeping subnet $prefix 1-254 on port $port ...');

        // Probe in parallel batches of 32
        const batchSize = 32;
        final hosts = List.generate(254, (i) => i + 1).where((h) => h != myHostNum).toList();

        for (var i = 0; i < hosts.length; i += batchSize) {
          final chunk = hosts.sublist(i, (i + batchSize > hosts.length) ? hosts.length : i + batchSize);
          final futures = chunk.map((h) async {
            final targetIp = '$prefix$h';
            try {
              final s = await Socket.connect(targetIp, port, timeout: perHostTimeout);
              s.destroy();
              return targetIp;
            } catch (_) {
              return null;
            }
          });

          final results = await Future.wait(futures);
          for (final reachableIp in results) {
            if (reachableIp != null) {
              // Verify by making a fast HTTP request to /bridge-info or /obs-camera
              final verified = await _verifyBridgeHttp(reachableIp, port);
              if (verified != null) {
                debugPrint('[DiscoveryService] Verified Bridge host via subnet sweep: $reachableIp:$port');
                return verified;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[DiscoveryService] Subnet sweep error: $e');
    }
    return null;
  }

  static Future<DiscoveredHost?> _verifyBridgeHttp(String ip, int port) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(milliseconds: 1200);
      final req = await client.getUrl(Uri.parse('http://$ip:$port/bridge-info'));
      final resp = await req.close().timeout(const Duration(milliseconds: 1200));

      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        try {
          final json = jsonDecode(body) as Map<String, dynamic>;
          if (json['app'] == 'bridge') {
            return DiscoveredHost(
              ip: ip,
              port: port,
              hostname: json['hostname'] as String?,
            );
          }
        } catch (_) {}
      }
    } catch (_) {
      // If /bridge-info fails, check /obs-camera as fallback
      try {
        final req2 = await client?.getUrl(Uri.parse('http://$ip:$port/obs-camera'));
        final resp2 = await req2?.close().timeout(const Duration(milliseconds: 1200));
        if (resp2?.statusCode == 200) {
          return DiscoveredHost(ip: ip, port: port);
        }
      } catch (_) {}
    } finally {
      client?.close(force: true);
    }
    return null;
  }

  /// High-level method: Tries lastKnownIp first, then UDP discovery, then subnet sweep.
  static Future<DiscoveredHost?> findBridgeHost({
    String? lastKnownIp,
    int port = defaultHttpPort,
  }) async {
    // 1. Fast probe on lastKnownIp
    if (lastKnownIp != null && lastKnownIp.isNotEmpty) {
      debugPrint('[DiscoveryService] Probing last known IP: $lastKnownIp:$port ...');
      final reachable = await isHostReachable(lastKnownIp, port, timeout: const Duration(milliseconds: 1500));
      if (reachable) {
        debugPrint('[DiscoveryService] Last known IP $lastKnownIp:$port is reachable!');
        return DiscoveredHost(ip: lastKnownIp, port: port);
      }
      debugPrint('[DiscoveryService] Last known IP $lastKnownIp:$port did not respond.');
    }

    // 2. Discover via UDP broadcast
    debugPrint('[DiscoveryService] Attempting LAN UDP discovery on port $discoveryUdpPort ...');
    final udpHost = await discoverViaUdp(timeout: const Duration(seconds: 2));
    if (udpHost != null) {
      return udpHost;
    }

    // 3. Fallback: Rapid subnet sweep
    debugPrint('[DiscoveryService] UDP discovery timed out. Falling back to subnet sweep on port $port ...');
    final sweepHost = await sweepSubnet(port: port);
    if (sweepHost != null) {
      return sweepHost;
    }

    debugPrint('[DiscoveryService] Bridge Agent could not be found on the current local network.');
    return null;
  }
}
