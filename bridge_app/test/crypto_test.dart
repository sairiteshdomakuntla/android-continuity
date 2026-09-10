import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bridge_app/services/crypto_service.dart';

void main() {
  test('Cross-platform AES-256-GCM compatibility with Node.js', () async {
    final fixedKeyBytes = Uint8List.fromList(utf8.encode('01234567890123456789012345678901'));

    // 1. Decrypt Node-encrypted payload:
    // Node script encrypted: '{"eventId":"test-123","text":"Hello Cross-Platform Crypto!"}'
    const nodePayload = 'TlxZrbgdiD+ZGcvciLOJGlt83G7UxQGFH7tCpzgthRzS8zlHplZj7J5EDghcygDyAdd3mjZOke/c1iEQLULDjI+odbnBRPd+fR1M5AwTiC7QaldAWaWR8A==';

    final decrypted = await CryptoService.decrypt(fixedKeyBytes, nodePayload);
    expect(decrypted, contains('"eventId":"test-123"'));
    expect(decrypted, contains('"Hello Cross-Platform Crypto!"'));

    // 2. Encrypt in Dart, decrypt in Dart
    const testMsg = 'Hello from Flutter AES-GCM!';
    final encrypted = await CryptoService.encrypt(fixedKeyBytes, testMsg);
    final decryptedBack = await CryptoService.decrypt(fixedKeyBytes, encrypted);
    expect(decryptedBack, equals(testMsg));
  });
}
