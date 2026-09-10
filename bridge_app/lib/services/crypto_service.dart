import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class CryptoService {
  static final _algorithm = AesGcm.with256bits();
  static const int nonceLength = 12;
  static const int tagLength = 16;

  /// Encrypts plaintext using AES-256-GCM with a fresh random 12-byte nonce.
  /// Wire format: [12-byte nonce][ciphertext][16-byte mac tag] -> Base64 string
  static Future<String> encrypt(Uint8List keyBytes, String plaintext) async {
    final secretKey = SecretKey(keyBytes);
    final secretBox = await _algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: _algorithm.newNonce(),
    );

    final nonce = secretBox.nonce;
    final cipherText = secretBox.cipherText;
    final macBytes = secretBox.mac.bytes;

    final combined = Uint8List(nonce.length + cipherText.length + macBytes.length);
    combined.setRange(0, nonce.length, nonce);
    combined.setRange(nonce.length, nonce.length + cipherText.length, cipherText);
    combined.setRange(nonce.length + cipherText.length, combined.length, macBytes);

    return base64Encode(combined);
  }

  /// Decrypts a Base64-encoded payload formatted as [12-byte nonce][ciphertext][16-byte mac tag].
  static Future<String> decrypt(Uint8List keyBytes, String base64Payload) async {
    final raw = base64Decode(base64Payload);

    if (raw.length < nonceLength + tagLength) {
      throw Exception('Encrypted payload too short: ${raw.length} bytes');
    }

    final nonce = raw.sublist(0, nonceLength);
    final mac = Mac(raw.sublist(raw.length - tagLength));
    final cipherText = raw.sublist(nonceLength, raw.length - tagLength);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: mac,
    );

    final decryptedBytes = await _algorithm.decrypt(
      secretBox,
      secretKey: SecretKey(keyBytes),
    );

    return utf8.decode(decryptedBytes);
  }
}
