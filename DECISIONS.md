# Architecture Decisions

---

## ADR-001 — Android Clipboard: Foreground-Only Reads (v1)

**Decision:** v1 reads the Android clipboard only when `bridge_app` has a focused foreground Activity. No Accessibility Service, no Foreground Service, no background clipboard polling.

**Context:** Android 10+ restricts `ClipboardManager.getPrimaryClip()` to processes whose UID owns the currently focused window. This was confirmed by reading the AOSP `ClipboardService.java` source (`android14-release` branch). The gate check in `clipboardAccessAllowed()` is:

```java
allowed = isDefaultDeviceAndUidFocused(intendingDeviceId, uid)   // WindowManager.isUidFocused()
       || isVirtualDeviceAndUidFocused(intendingDeviceId, uid)
       || isInternalSysWindowAppWithWindowFocus(callingPackage);  // signature-level system apps
```

`WindowManagerInternal.isUidFocused(uid)` returns `true` **only** if the UID owns the currently focused window — not if it has a running Foreground Service, not if it is in `ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND`. Process importance and foreground service status are irrelevant to this check.

**Rejected approaches:**

| Approach | Reason rejected |
|---|---|
| Foreground Service reads clipboard | `isUidFocused` is false without a focused window — returns `null` on Android 10+. |
| AccessibilityService + LocalBroadcast → ForegroundService reads | Same: the read still happens outside a focused window. |
| `READ_CLIPBOARD_IN_BACKGROUND` permission | `protectionLevel="signature"` — unavailable to any third-party or sideloaded app. |
| Default IME (custom keyboard) | Works, but extreme UX friction. Not appropriate for this tool. |

**Consequence / User-facing behavior:**

The user experience for Android→Windows clipboard sync is:

> Copy in any app → Open Bridge → (Bridge reads clipboard on resume) → Paste on Windows

Bridge communicates this explicitly in its UI. There is no implication that background sync is active.

**TODO (future):** True background clipboard access for third-party apps may be investigated using privileged mechanisms (e.g., Shizuku + shell `appops set <package> READ_CLIPBOARD allow`). Do not implement in v1.

---

## ADR-002 — Single Socket.IO Event Name

**Decision:** All messages use the event name `bridge-message` regardless of type, with the `type` field inside the envelope discriminating the message kind.

**Reason:** Keeps Socket.IO routing trivial (one listener on each side), and type dispatch is then explicit application-level logic that is easy to test and extend.

---

## ADR-003 — Echo Prevention via EventDedupe

**Decision:** Both sides maintain a capped in-memory `EventDedupe` store. When side A receives a message from side B, it adds the `eventId` to its dedupe store *and* writes to its own clipboard with the same value. When side A's clipboard read fires on next resume (Android) or next poll tick (Windows), it detects the value matches the last-synced value and suppresses re-emission. The dedupe store provides a second layer of protection covering edge cases where timing could cause a re-read before `_lastSyncedText` is updated.

---
