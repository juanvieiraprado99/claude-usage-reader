# claude-usage-reader

Show Claude Code **session (5h)** and **weekly (7d)** rate-limit usage on a
jailbroken Kindle, as a KOReader plugin. See [PLAN.md](PLAN.md) for design.

Inspired by [claude-usage-stick-SVGL](https://github.com/benevid/claude-usage-stick-SVGL).

## How it works

One HTTPS request to `api.anthropic.com/v1/messages` with `max_tokens:1`
(costs ~1 token). Response **body is ignored** — usage comes from headers:

- `anthropic-ratelimit-unified-status` → allowed / allowed_warning / rejected
- `anthropic-ratelimit-unified-5h-utilization` → 0–1 (session)
- `anthropic-ratelimit-unified-7d-utilization` → 0–1 (weekly)
- `anthropic-ratelimit-unified-5h-reset` / `-7d-reset` → epoch reset time

Auth uses a Claude Code OAuth token (`sk-ant-oat01-...`) + the
`anthropic-beta: oauth-2025-04-20` header.

## Setup

1. PC: `claude setup-token` → copy the `sk-ant-oat01-...` value.
2. Copy `claudeusage.koplugin/` into KOReader on the Kindle:
   `koreader/plugins/claudeusage.koplugin/`.
3. Restart KOReader.
4. Get a token: on any PC run `claude setup-token` (browser OAuth to *your*
   account) → copy the `sk-ant-oat01-...` value.
5. Menu → **Claude Usage** → **Login (web)**. A modal shows a **QR code**, the
   URL `http://<ip>:8099/?k=<PIN>`, and the PIN. **Scan the QR** with a phone on
   the same WiFi (the form opens with the PIN pre-filled) → paste the token →
   submit. The URL/PIN/QR **rotate every 5 minutes**; a stale QR stops working.
   The token is **validated** (a probe call) before it is stored.
6. You are then asked to **create a 4-digit PIN**; the token is **encrypted** with
   it and saved. On later KOReader sessions, **Show usage** asks that PIN once to
   unlock (cached in RAM for the session).
7. **Show usage** is disabled until a token exists. If the token later **expires**
   while the dashboard is open, the QR login modal pops automatically.
8. **Logout (clear token)** wipes the stored token (e.g. before lending the device).

There is no bundled token — each user logs in with their own account.

## Security

- **At rest:** the token is stored **encrypted** (ChaCha20 stream cipher; key
  derived from your PIN via iterated SHA-256; the PIN is never stored; a verifier
  detects a wrong PIN; after 8 wrong tries the token is wiped). Implemented for
  KOReader's LuaJIT and self-tested against the RFC 8439 / FIPS-180 vectors at
  load — if the self-test fails the plugin refuses to store rather than fall back
  to plaintext.
- **Honest limit:** a 4-digit PIN is only 10,000 combinations. The KDF slows
  guessing and the lockout stops on-device tries, but **someone who copies the
  settings file can brute-force 4 digits offline**. Encryption defeats casual file
  reading and anyone without the PIN — not a determined attacker with the file.
  **If the device is lost, revoke the token at console.anthropic.com.** A longer
  passphrase would resist offline brute force (not offered yet).
- **In transit:** the web login is plaintext **HTTP on your LAN** (no TLS on
  e-ink); the PIN gates the submit and the server is transient. **Use a trusted
  WiFi** for login.
- Confidentiality-only (no MAC): tampering corrupts the blob but cannot reveal the
  token.

## Status

Fullscreen dashboard: two cards (session 5h / weekly 7d) with %, progress bar,
reset date + countdown; Clawd pixel-art mascot with emotions + occasional
singing animation; tappable interval label (Off/5/10/15/30 s); tap top-right to
close. Grayscale (device has no color). Auto-refresh runs while the screen is
open. Next: PIN-gate token, optional PC bridge for exact token counts.
See PLAN.md milestones.

Files: `main.lua` (plumbing/fetch), `usagescreen.lua` (dashboard),
`clawd.lua` (mascot pixel-art).

## Notes

- Token stored plaintext in `koreader/settings/claudeusage.lua`. PIN/encrypt = TODO.
- API returns utilization **%** only (subscription accounts), not raw token counts.
- Not yet tested on a real device — validate TLS 1.2 reach to api.anthropic.com.
