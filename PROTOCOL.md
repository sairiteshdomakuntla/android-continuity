# Bridge Protocol

All messages between `bridge-agent` (Windows/Electron) and `bridge_app` (Android/Flutter) travel as a single Socket.IO event named **`bridge-message`** carrying a JSON payload described below.

---

## Envelope Schema

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

## Message Types

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

### `file` / `camera-signal`

Reserved for future use. Not implemented in v1.

---

## Socket.IO Event Name

All envelopes are sent using a single Socket.IO event: **`bridge-message`**

```typescript
socket.emit('bridge-message', envelope)
socket.on('bridge-message', (envelope) => { ... })
```

---

## Deduplication

Both sides maintain an in-memory `EventDedupe` store (capped at 200 entries, LRU eviction). Before processing an incoming message, the receiver checks `EventDedupe.has(eventId)`. Before emitting a self-originated outgoing message, it calls `EventDedupe.add(eventId)` so the echo-back from the loopback is suppressed.

---

## Adding New Message Types

1. Add the new `type` string to `MessageType` in `electron/types/protocol.ts` and to the `MessageType` enum in `lib/models/bridge_message.dart`.
2. Define a payload interface/class.
3. Create a `*Service` that calls `SocketService.broadcast()` / `SocketService.emit()`.
4. Wire the service in `main.ts` / `main.dart`.

---

## See Also

- [`DECISIONS.md`](./DECISIONS.md) — Architecture decisions and known limitations.
