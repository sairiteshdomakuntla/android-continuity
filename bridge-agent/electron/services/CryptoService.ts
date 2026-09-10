import crypto from 'node:crypto'

const ALGORITHM = 'aes-256-gcm'
const NONCE_LENGTH = 12
const TAG_LENGTH = 16

export class CryptoService {
  /**
   * Encrypts plaintext using AES-256-GCM with a fresh random 12-byte nonce.
   * Wire format: [12-byte nonce][ciphertext][16-byte auth tag] -> Base64 string
   */
  static encrypt(key: Buffer, plaintext: string): string {
    const nonce = crypto.randomBytes(NONCE_LENGTH)
    const cipher = crypto.createCipheriv(ALGORITHM, key, nonce)
    
    const ciphertext = Buffer.concat([
      cipher.update(plaintext, 'utf8'),
      cipher.final(),
    ])
    const tag = cipher.getAuthTag()

    const combined = Buffer.concat([nonce, ciphertext, tag])
    return combined.toString('base64')
  }

  /**
   * Decrypts a Base64-encoded payload formatted as [12-byte nonce][ciphertext][16-byte auth tag].
   */
  static decrypt(key: Buffer, base64Payload: string): string {
    const raw = Buffer.from(base64Payload, 'base64')
    if (raw.length < NONCE_LENGTH + TAG_LENGTH) {
      throw new Error(`Encrypted payload too short (${raw.length} bytes)`)
    }

    const nonce = raw.subarray(0, NONCE_LENGTH)
    const tag = raw.subarray(raw.length - TAG_LENGTH)
    const ciphertext = raw.subarray(NONCE_LENGTH, raw.length - TAG_LENGTH)

    const decipher = crypto.createDecipheriv(ALGORITHM, key, nonce)
    decipher.setAuthTag(tag)

    const decrypted = Buffer.concat([
      decipher.update(ciphertext),
      decipher.final(),
    ])

    return decrypted.toString('utf8')
  }
}
