import 'package:flutter_test/flutter_test.dart';
import 'package:bridge_app/services/content_classifier.dart';

void main() {
  group('Content Classification Tests', () {
    test('URL classification', () {
      expect(classifyClipboardText('https://github.com/flutter/flutter'), equals('url'));
      expect(classifyClipboardText('http://localhost:3000/dashboard'), equals('url'));
      expect(classifyClipboardText('www.google.com'), equals('url'));
      expect(classifyClipboardText('subdomain.example.org/path/to/resource?query=1'), equals('url'));
    });

    test('OTP classification', () {
      expect(classifyClipboardText('482913'), equals('otp'));
      expect(classifyClipboardText('1234'), equals('otp'));
      expect(classifyClipboardText('98765432'), equals('otp'));
      expect(classifyClipboardText('Your code is 482913'), equals('otp'));
      expect(classifyClipboardText('Use OTP: 819203 to verify'), equals('otp'));
      expect(classifyClipboardText('verification pin: 654321'), equals('otp'));
    });

    test('Email classification', () {
      expect(classifyClipboardText('user@example.com'), equals('email'));
      expect(classifyClipboardText('first.last+tag@sub.domain.co.uk'), equals('email'));
      expect(classifyClipboardText('developer123@gmail.com'), equals('email'));
    });

    test('Phone classification', () {
      expect(classifyClipboardText('+1 (555) 123-4567'), equals('phone'));
      expect(classifyClipboardText('+91 98765 43210'), equals('phone'));
      expect(classifyClipboardText('080-12345678'), equals('phone'));
      expect(classifyClipboardText('123-456-7890'), equals('phone'));
    });

    test('Fallback text classification', () {
      expect(classifyClipboardText('Hello world! How are you doing today?'), equals('text'));
      expect(classifyClipboardText('Shopping list: 1. Apples 2. Bananas 3. Milk'), equals('text'));
      expect(classifyClipboardText(''), equals('text'));
      expect(classifyClipboardText('   '), equals('text'));
    });
  });
}
