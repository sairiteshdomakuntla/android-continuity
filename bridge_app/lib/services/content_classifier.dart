final _urlRegex = RegExp(
  r'^(?:https?://[^\s]+|www\.[^\s]+|(?:[a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}(?:[/?#][^\s]*)?)$',
  caseSensitive: false,
);

final _emailRegex = RegExp(
  r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
  caseSensitive: false,
);

final _standaloneOtpRegex = RegExp(r'^\d{4,8}$');

final _contextualOtpForward = RegExp(
  r'(?:^|\b)(?:code|otp|verification|pin|password)\b[^\d\r\n]*?([0-9]{4,8})\b',
  caseSensitive: false,
);

final _contextualOtpBackward = RegExp(
  r'\b([0-9]{4,8})\b[^\d\r\n]*?(?:code|otp|verification|pin|password)\b',
  caseSensitive: false,
);

final _phoneCharsRegex = RegExp(r'^[+]?[\d\s().-]{7,25}$');
final _digitsOnly = RegExp(r'\d');

/// Classifies raw text clipboard content into:
/// 'url' | 'otp' | 'email' | 'phone' | 'text'
String classifyClipboardText(String rawText) {
  if (rawText.isEmpty) return 'text';
  final text = rawText.trim();
  if (text.isEmpty) return 'text';

  // 1. URL pattern
  if (_urlRegex.hasMatch(text)) {
    return 'url';
  }

  // 2. Email pattern
  if (_emailRegex.hasMatch(text)) {
    return 'email';
  }

  // 3. OTP pattern
  if (_standaloneOtpRegex.hasMatch(text)) {
    return 'otp';
  }
  if (text.length <= 120 &&
      (_contextualOtpForward.hasMatch(text) || _contextualOtpBackward.hasMatch(text))) {
    return 'otp';
  }

  // 4. Phone number pattern
  if (_phoneCharsRegex.hasMatch(text)) {
    final digitCount = _digitsOnly.allMatches(text).length;
    if (digitCount >= 7 && digitCount <= 15) {
      return 'phone';
    }
  }

  // 5. Default fallback
  return 'text';
}
