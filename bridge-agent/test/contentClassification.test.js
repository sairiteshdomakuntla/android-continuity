import test from 'node:test'
import assert from 'node:assert/strict'

const URL_REGEX = /^(?:https?:\/\/[^\s]+|www\.[^\s]+|(?:[a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}(?:[/?#][^\s]*)?)$/i
const EMAIL_REGEX = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/
const STANDALONE_OTP_REGEX = /^\d{4,8}$/
const CONTEXTUAL_OTP_FORWARD = /(?:^|\b)(?:code|otp|verification|pin|password)\b[^\d\r\n]*?([0-9]{4,8})\b/i
const CONTEXTUAL_OTP_BACKWARD = /\b([0-9]{4,8})\b[^\d\r\n]*?(?:code|otp|verification|pin|password)\b/i
const PHONE_CHARS_REGEX = /^[+]?[\d\s().-]{7,25}$/

function classifyClipboardText(rawText) {
  if (!rawText) return 'text'
  const text = rawText.trim()
  if (!text) return 'text'

  if (URL_REGEX.test(text)) return 'url'
  if (EMAIL_REGEX.test(text)) return 'email'
  if (STANDALONE_OTP_REGEX.test(text)) return 'otp'
  if (text.length <= 120 && (CONTEXTUAL_OTP_FORWARD.test(text) || CONTEXTUAL_OTP_BACKWARD.test(text))) return 'otp'

  if (PHONE_CHARS_REGEX.test(text)) {
    const digitCount = (text.match(/\d/g) || []).length
    if (digitCount >= 7 && digitCount <= 15) return 'phone'
  }

  return 'text'
}

test('TypeScript Content Classifier Tests', async (t) => {
  await t.test('classify URL', () => {
    assert.equal(classifyClipboardText('https://github.com/electron/electron'), 'url')
    assert.equal(classifyClipboardText('http://localhost:5173'), 'url')
    assert.equal(classifyClipboardText('www.google.com'), 'url')
    assert.equal(classifyClipboardText('subdomain.example.org/path?q=test'), 'url')
  })

  await t.test('classify OTP', () => {
    assert.equal(classifyClipboardText('482913'), 'otp')
    assert.equal(classifyClipboardText('1234'), 'otp')
    assert.equal(classifyClipboardText('98765432'), 'otp')
    assert.equal(classifyClipboardText('Your code is 482913'), 'otp')
    assert.equal(classifyClipboardText('OTP: 918273 for login'), 'otp')
    assert.equal(classifyClipboardText('482913 is your verification code'), 'otp')
  })

  await t.test('classify Email', () => {
    assert.equal(classifyClipboardText('user@example.com'), 'email')
    assert.equal(classifyClipboardText('first.last+tag@sub.domain.co.uk'), 'email')
  })

  await t.test('classify Phone', () => {
    assert.equal(classifyClipboardText('+1 (555) 123-4567'), 'phone')
    assert.equal(classifyClipboardText('+91 98765 43210'), 'phone')
    assert.equal(classifyClipboardText('080-12345678'), 'phone')
    assert.equal(classifyClipboardText('123-456-7890'), 'phone')
  })

  await t.test('fallback Text', () => {
    assert.equal(classifyClipboardText('This is a plain message with some numbers 123.'), 'text')
    assert.equal(classifyClipboardText(''), 'text')
    assert.equal(classifyClipboardText('   '), 'text')
  })
})
