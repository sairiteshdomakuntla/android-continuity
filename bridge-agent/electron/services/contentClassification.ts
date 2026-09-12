import type { ClipboardContentType } from '../types/protocol.js'

const URL_REGEX = /^(?:https?:\/\/[^\s]+|www\.[^\s]+|(?:[a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}(?:[/?#][^\s]*)?)$/i
const EMAIL_REGEX = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/
const STANDALONE_OTP_REGEX = /^\d{4,8}$/
const CONTEXTUAL_OTP_FORWARD = /(?:^|\b)(?:code|otp|verification|pin|password)\b[^\d\r\n]*?([0-9]{4,8})\b/i
const CONTEXTUAL_OTP_BACKWARD = /\b([0-9]{4,8})\b[^\d\r\n]*?(?:code|otp|verification|pin|password)\b/i
const PHONE_CHARS_REGEX = /^[+]?[\d\s().-]{7,25}$/

export function classifyClipboardText(rawText: string): ClipboardContentType {
  if (!rawText) return 'text'
  const text = rawText.trim()
  if (!text) return 'text'

  // 1. URL pattern
  if (URL_REGEX.test(text)) {
    return 'url'
  }

  // 2. Email pattern
  if (EMAIL_REGEX.test(text)) {
    return 'email'
  }

  // 3. OTP pattern: standalone 4-8 digit number or near OTP keywords
  if (STANDALONE_OTP_REGEX.test(text)) {
    return 'otp'
  }
  if (text.length <= 120 && (CONTEXTUAL_OTP_FORWARD.test(text) || CONTEXTUAL_OTP_BACKWARD.test(text))) {
    return 'otp'
  }

  // 4. Phone number pattern: only digits, spaces, parens, hyphens, dots and optional leading +
  if (PHONE_CHARS_REGEX.test(text)) {
    const digitCount = (text.match(/\d/g) || []).length
    if (digitCount >= 7 && digitCount <= 15) {
      return 'phone'
    }
  }

  // 5. Default fallback
  return 'text'
}
