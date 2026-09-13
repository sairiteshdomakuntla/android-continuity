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

Valid `type` values: `clipboard | file | camera-signal | ping | notification | device | remote-input`.

---

## 4. Message Types

### `clipboard`

Sent when clipboard text or image is detected and needs to be synced.

**Text Clipboard:**
```json
{
  "eventId": "a1b2c3d4-...",
  "type": "clipboard",
  "origin": "android",
  "timestamp": "2026-09-10T11:00:00.000Z",
  "payload": {
    "kind": "text",
    "text": "Hello from Android clipboard"
  }
}
```

**Image Clipboard Announcement:**
```json
{
  "eventId": "b2c3d4e5-...",
  "type": "clipboard",
  "origin": "windows",
  "timestamp": "2026-09-10T11:00:00.000Z",
  "payload": {
    "kind": "image",
    "transferId": "b2c3d4e5-...",
    "mimeType": "image/png"
  }
}
```

Image payloads are streamed chunk-by-chunk using the chunked `file` transport tagged with `"transferType": "clipboard-image"` (64KB chunks + incremental SHA-256 validation).

**Payload fields:**

| Field | Type | Description |
|---|---|---|
| `kind` | `'text' \| 'image'` | Type of clipboard content (defaults to `'text'`). |
| `text` | `string?` | Plain text clipboard content (when `kind === 'text'`). |
| `transferId` | `string?` | Matching chunked transfer UUID (when `kind === 'image'`). |
| `mimeType` | `string?` | Image MIME type, e.g. `'image/png'`. |

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

### `device`

Device-status and find-my-phone signalling. No history is kept — each side
retains only the most recent value.

**Battery update (Android → Windows):**

Sent on service start, on socket (re)connect, when the level moves by more
than ~2%, or when charging state flips. Event-driven via
`ACTION_BATTERY_CHANGED`, never polled.

```json
{
  "eventId": "...",
  "type": "device",
  "origin": "android",
  "timestamp": "...",
  "payload": {
    "event": "battery-update",
    "level": 78,
    "isCharging": false
  }
}
```

**Ring (Windows → Android):**

Windows sends this when the user clicks "Ring Phone". Android plays an
alarm-stream ringtone at max volume for ~15s (even on silent) and shows a
full-screen ringing overlay with a Stop action.

```json
{
  "eventId": "...",
  "type": "device",
  "origin": "windows",
  "timestamp": "...",
  "payload": {
    "event": "ring"
  }
}
```

---

### `remote-input`

"Phone as Remote" — Android used as a remote input device for Windows.
No history, no acknowledgements; events are fire-and-forget and processed
in order of arrival.

**Mouse move (Android → Windows):** relative cursor movement deltas in
logical pixels. Emitted at a throttled rate (~60 Hz max) while a finger
drags across the trackpad surface; the host scales deltas by a cursor
sensitivity multiplier (default 1.8, overridable via `set-sensitivity`).

```json
{
  "eventId": "...",
  "type": "remote-input",
  "origin": "android",
  "timestamp": "...",
  "payload": {
    "event": "mouse-move",
    "dx": 12,
    "dy": -7
  }
}
```

**Mouse click (Android → Windows):** a single click (button down + up) of
the given button. `right` should behave like a real right click (open a
context menu).

```json
{
  "eventId": "...",
  "type": "remote-input",
  "origin": "android",
  "timestamp": "...",
  "payload": {
    "event": "mouse-click",
    "button": "left"
  }
}
```

**Scroll (Android → Windows):** vertical scroll amount in logical pixels,
accumulated from a two-finger drag. Positive `dy` means fingers moved
down. The host applies *natural* scrolling (like a laptop touchpad):
moving fingers down scrolls content up (reveals content above), moving
fingers up scrolls content down. Pixels are converted into
high-resolution wheel units (120 units per notch, ~2.4 per pixel) and
emitted continuously as sub-notch deltas — the same kind of stream a
precision touchpad produces — so scrolling is smooth rather than
notch-by-notch. Fractional `dy` values are allowed.

```json
{
  "eventId": "...",
  "type": "remote-input",
  "origin": "android",
  "timestamp": "...",
  "payload": {
    "event": "scroll",
    "dy": 34.5
  }
}
```

**Set sensitivity (Android → Windows):** cursor-movement sensitivity
multiplier for subsequent `mouse-move` events. Affects cursor movement
only — never scroll speed or clicks. The phone sends it when the Remote
screen opens, whenever the user moves the sensitivity slider, and after
a reconnect. Range 0.5–3.0; default 1.8.

```json
{
  "eventId": "...",
  "type": "remote-input",
  "origin": "android",
  "timestamp": "...",
  "payload": {
    "event": "set-sensitivity",
    "value": 1.8
  }
}
```

**Key input (Android → Windows):** typed text from the Remote keyboard
tab — usually a single character per keystroke, streamed as typed. The
host commits the characters to whatever window currently has focus.
No modifier keys (Ctrl/Alt/Shift combos) in this pass.

```json
{
  "eventId": "...",
  "type": "remote-input",
  "origin": "android",
  "timestamp": "...",
  "payload": {
    "event": "key-input",
    "text": "h"
  }
}
```

**Key special (Android → Windows):** a non-character key tap. Currently
`enter`, `backspace`, and `space`.

```json
{
  "eventId": "...",
  "type": "remote-input",
  "origin": "android",
  "timestamp": "...",
  "payload": {
    "event": "key-special",
    "key": "enter"
  }
}
```

**Media command (Android → Windows):** a media key tap. The host injects
the corresponding media/volume key, which applies to whatever app
currently has media focus (volume keys go to the OS mixer). Commands:
`play-pause`, `next`, `previous`, `volume-up`, `volume-down`, `mute`.

```json
{
  "eventId": "...",
  "type": "remote-input",
  "origin": "android",
  "timestamp": "...",
  "payload": {
    "event": "media-command",
    "command": "play-pause"
  }
}
```

**Open remote (Windows → Android):** Windows asks the phone to open the
Remote screen (trackpad). Sent when the user taps "Remote" in the Windows
action row.

```json
{
  "eventId": "...",
  "type": "remote-input",
  "origin": "windows",
  "timestamp": "...",
  "payload": {
    "event": "open-remote"
  }
}
```

---

## 5. Deduplication

Both sides maintain an in-memory `EventDedupe` store (capped at 200 entries, LRU eviction). Before processing an incoming message, the receiver checks `EventDedupe.has(eventId)`. Before emitting a self-originated outgoing message, it calls `EventDedupe.add(eventId)` so the echo-back from the loopback is suppressed.

---

## 6. See Also

- [`DECISIONS.md`](./DECISIONS.md) — Architecture decisions, ADR-004 (Pairing & Encryption).
