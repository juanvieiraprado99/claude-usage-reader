# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A KOReader plugin (Lua) for jailbroken Kindles that displays Claude Code
rate-limit usage — the current session (5h) and weekly (7d) windows. There is
no build step and no test suite; the plugin is the `claudeusage.koplugin/`
folder, deployed by copying it into KOReader.

## The core mechanism (read before editing `main.lua`)

Usage is obtained WITHOUT any PC server or log parsing on-device. One HTTPS
`POST` to `https://api.anthropic.com/v1/messages` with `max_tokens:1` (costs
~1 token). The response **body is intentionally discarded** — all data comes
from the `anthropic-ratelimit-unified-*` **response headers**:

- `-status` → allowed / allowed_warning / rejected
- `-5h-utilization` / `-7d-utilization` → 0–1 floats (session / weekly)
- `-5h-reset` / `-7d-reset` → epoch reset timestamps

Auth is a Claude Code OAuth token (`sk-ant-oat01-...` from `claude setup-token`)
sent as `Authorization: Bearer`, and it only works alongside the
`anthropic-beta: oauth-2025-04-20` header plus a `claude-code/*` User-Agent.
Changing/removing those headers breaks the probe. This technique is derived from
github.com/benevid/claude-usage-stick-SVGL.

Key constraint: the API returns utilization **percentages only** for
subscription accounts — never raw token counts. Any feature needing exact token
counts must parse `~/.claude/projects/**/*.jsonl` on a PC (e.g. `ccusage`), not
on the Kindle.

## Why KOReader plugin (not bash + eips)

KOReader bundles luasec, giving real TLS 1.2 + SNI to reach api.anthropic.com.
Stock Kindle `curl` usually cannot. Deploy/test path:

1. `claude setup-token` on PC → copy `sk-ant-oat01-...`.
2. Copy `claudeusage.koplugin/` → `koreader/plugins/claudeusage.koplugin/` on device.
3. Restart KOReader → Menu → Claude Usage → Set token → Show usage.

Token is persisted via `LuaSettings` at `koreader/settings/claudeusage.lua`
(currently plaintext — PIN/encryption is a planned milestone).

## Plugin structure

- `claudeusage.koplugin/_meta.lua` — plugin manifest (name/fullname/description).
- `claudeusage.koplugin/main.lua` — `WidgetContainer` subclass (plumbing). `init()`
  opens settings + registers the menu and a dispatcher action (`ClaudeUsageShow`).
  `fetch()` does the probe and returns the lowercased headers table.
  `setRefreshInterval()` persists the interval (2s cooldown, returns bool).
  `showUsage()` opens the fullscreen `UsageScreen`. No background loop — the
  screen owns the refresh loop while open.
- `claudeusage.koplugin/usagescreen.lua` — `InputContainer` fullscreen dashboard.
  **`self.modal = true`** so KOReader skips the underlying touch zones and routes
  all input here (without it the screen traps taps). `rebuild()` reconstructs
  `self[1]` from `self.data` each fetch/anim frame, reading **live** Screen dims
  (portrait vs landscape branch), then `setDirty(self,"ui")`. Owns the auto-refresh
  loop (`doFetch`) and a **random** animation scheduler (`scheduleNextAnim` →
  `pickAnim` weighted by usage → `playRandomAnim`). Tap targets are the real
  `close_btn` / `rotate_btn` / `interval_btn` FrameContainers — hit-tested via
  their `.dimen` (set by paintTo), NOT fixed fractions. `toggleRotation()`
  broadcasts `Event("SetRotationMode")`; `onCloseWidget` restores `orig_rotation`.
  Frees Clawd Blitbuffers each rebuild via `self._disposables`.
- `claudeusage.koplugin/crypto.lua` (+ `sha256.lua`, `chacha20.lua`) — token
  encryption at rest. `Crypto.encrypt(token,pin)`/`decrypt(blob,pin)`:
  key = iterated SHA-256(salt..pin), `check = SHA-256(key.."cu-verify")` verifier,
  `ct = ChaCha20(key,nonce) XOR token`; PIN never stored; base64 fields.
  `sha256.lua`/`chacha20.lua` are LuaJIT (`bit`) implementations **self-tested vs
  RFC 8439 / FIPS vectors** (`.ok` flags); `Crypto.available()` gates storage —
  callers must **fail closed** (never store plaintext). Confidentiality-only (no
  MAC). Storage: `settings "enc"` blob (no plaintext `token`), `settings "pin_fail"`
  counter; `main.lua` caches the decrypted token in RAM (`self.session_token`) for
  the KOReader session and gates `showUsage` behind `promptUnlock`. HONEST LIMIT:
  a 4-digit PIN is offline-brute-forceable by someone with the file — documented,
  not overclaimed.
- `claudeusage.koplugin/tokenserver.lua` — transient non-blocking LAN HTTP
  receiver (luasocket, polled via `UIManager:scheduleIn`). Serves a form (PIN
  pre-filled from `/?k=<PIN>`); a `POST /save` with the correct PIN delivers the
  token via `on_token`, then `stop()`s. `get_ip()` finds the LAN IP.
- `claudeusage.koplugin/loginmodal.lua` — modal shown by `main.lua:webLogin()`.
  Owns a `TokenServer` and renders a **QR** (`ui/widget/qrwidget`) of
  `http://<ip>:<port>/?k=<PIN>` + the URL + PIN. **Rotates the PIN/URL/QR every
  5 min**. `on_token` → save; `on_close` clears the plugin's `login_open` guard.
  The menu's **Show usage** is gated by `enabled_func = hasToken()`; when
  `fetch()` returns the auth-expired flag (HTTP 401/403), `usagescreen.doFetch`
  calls `plugin:webLogin()` to pop this modal. There is NO bundled token (the old
  `DEV_TOKEN` is gone); each user supplies their own `claude setup-token` value.
- `claudeusage.koplugin/clawd.lua` — Clawd mascot as Lua pixel-art (26x18 grid,
  **built procedurally** in `makeBase()` for exact geometry): wide solid body,
  side ear nubs, two central legs + notch, big square eyes, dark 1px outline
  (the sticker's white outline is invisible on the white page).
  `makeWidget(emotion,scale,opts,bg)` where `opts={anim,phase}`;
  `emotionFor(max_pct,status)`. Resting faces: `love`(<50)/`neutral`(50-75)
  square eyes, `strain`(75-90) `>_<`, `dizzy`(>=90/rejected) spiral. Animations
  (`Clawd.ANIMS`): `blink`, `shy` (`>_<` + blush), `heart` (rises), `sparkle`
  (arm + twinkle). NOTE: device is grayscale — no color.

## Roadmap

See `PLAN.md` for milestones. Current state is M0 (text dashboard). Planned:
`ProgressWidget` bars + warn colors (M1), timer auto-refresh (M2), ambient
screensaver/status-bar widget (M3), PIN/encrypt token (M4), optional PC bridge
for exact counts (M5).
