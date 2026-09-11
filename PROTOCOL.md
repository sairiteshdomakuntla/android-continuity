# Bridge Protocol

All communication between `bridge-agent` (Windows/Electron) and `bridge_app` (Android/Flutter) takes place over a local WebSocket connection (Socket.IO, port 4000).

---

## 1. Pairing Handshake Protocol

Before features (like clipboard sync) communicate, devices establish pairing via an out-of-band QR code scan.

### QR Code Content

The host (Electron/Windows) displays a QR code encoding a JSON payload:

```json
{
  "ip": "192.168.0.112",
  "port": 4000,
  "pairingKey": "<256-bit base64 random secret>"
}
```

### Handshake Flow

1. **Client Handshake (`pair-handshake`)**:
   Android connects to `http://<ip>:<port>` and emits:
   ```json
   {
     "pairingKey": "<pairingKey from QR code>",
     "deviceId": "<client UUID v4>",
     "deviceName": "Android Phone"
   }
   ```
2. **Host Verification**:
   Windows verifies `pairingKey` matches the current active pairing session. If invalid, it emits `pair-error` and disconnects.
3. **Success Confirmation (`pair-success`)**:
   If valid, Windows marks the device as paired in its encrypted storage, closes the temporary pairing listener, sets its symmetric AES-GCM key, and responds:
   ```json
   {
     "deviceId": "<client UUID v4>",
     "status": "ok"
   }
   ```
4. **Encryption Key Activation**:
   Both sides derive/use the 256-bit secret from `pairingKey` for AES-256-GCM symmetric encryption.

---

## 2. Encrypted Transport Layer

Once paired, **all** subsequent messages over Socket.IO event **`bridge-message`** are encrypted with AES-256-GCM:

### Wire Format

```
+------------------+------------------------------+--------------------+
| 12-byte IV/Nonce |       Ciphertext bytes       | 16-byte GCM Tag    |
+------------------+------------------------------+--------------------+
```

The combined binary buffer is transmitted as a standard **Base64 string**:

```typescript
// Sending
socket.emit('bridge-message', base64Ciphertext)

// Receiving
socket.on('bridge-message', (base64Ciphertext: string) => {
  const plaintext = decrypt(base64Ciphertext)
  const envelope = JSON.parse(plaintext)
})
```

---

## 3. Message Envelope Schema

Inside the decrypted plaintext, messages follow the standard envelope schema:

```json
{
  "eventId": "<uuid-v4>",
  "type": "clipboard | file | camera-signal | ping",
  "origin": "android | windows",
  "timestamp": "<ISO 8601>",
  "payload": { }
}
```

| Field | Type | Description |
|---|---|---|
| `eventId` | `string` (UUID v4) | Unique ID for this message. Used for deduplication on both ends. |
| `type` | `MessageType` | Feature domain of this message. |
| `origin` | `Origin` | Who sent it. |
| `timestamp` | `string` | ISO 8601 UTC timestamp of when the message was created. |
| `payload` | `object` | Type-specific data (see below). |

---

## 4. Message Types

### `clipboard`

Sent when clipboard text is detected and needs to be synced.

```json
{
  "eventId": "a1b2c3d4-...",
  "type": "clipboard",
  "origin": "android",
  "timestamp": "2026-09-10T11:00:00.000Z",
  "payload": {
    "text": "Hello from Android clipboard"
  }
}
```

**Payload fields:**

| Field | Type | Description |
|---|---|---|
| `text` | `string` | Plain text clipboard content. |

### `ping`

Reserved for keep-alive / connection testing.

```json
{
  "eventId": "...",
  "type": "ping",
  "origin": "windows",
  "timestamp": "...",
  "payload": {}
}
```

### `notification`

Transfers notification events between Android and Windows:
- `posted`: Android posts notification details (including Direct Reply support).
- `dismissed`: Android notifies Windows that user dismissed on phone.
- `reply`: Windows instructs Android to execute `RemoteInput` reply on notification.
- `reply-failed`: Android notifies Windows that executing reply failed (e.g. `PendingIntent.CanceledException`).
- `dismiss-request`: Windows instructs Android to cancel/dismiss notification.

```json
{
  "eventId": "...",
  "type": "notification",
  "origin": "android",
  "timestamp": "...",
  "payload": {
    "event": "posted",
    "notificationId": "0|com.whatsapp|1|null|10123",
    "packageName": "com.whatsapp",
    "appName": "WhatsApp",
    "title": "Alice",
    "text": "Hey!",
    "timestamp": "2026-09-11T18:20:00.000Z",
    "hasReplyAction": true,
    "hasQuickActions": []
  }
}
```

---

## 5. Deduplication

Both sides maintain an in-memory `EventDedupe` store (capped at 200 entries, LRU eviction). Before processing an incoming message, the receiver checks `EventDedupe.has(eventId)`. Before emitting a self-originated outgoing message, it calls `EventDedupe.add(eventId)` so the echo-back from the loopback is suppressed.

---

## 6. See Also

- [`DECISIONS.md`](./DECISIONS.md) — Architecture decisions, ADR-004 (Pairing & Encryption).
