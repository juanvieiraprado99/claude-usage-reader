# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A standalone Lua app for jailbroken Kindles, launched from **KUAL**, that
displays Claude Code rate-limit usage — the current session (5h) and weekly (7d)
windows. It does NOT require KOReader to be installed: the release bundles a
trimmed KOReader runtime (LuaJIT + luasec/luasocket + e-ink widget frontend +
fonts) inside the extension. It used to be a KOReader plugin; that form is
retired.

There is no test suite. Official artifacts come from CI: every push to `main`
runs `.github/workflows/release.yml`, which smoke-boots the app headless, builds
the matrix `[kindlepw2, kindlehf]` and publishes a release `v<VERSION>.<run>`
with four files. Version sources: `VERSION` (app, major.minor) and
`packaging/KOREADER_VERSION` (which KOReader release the runtime is cut from) —
both single-line, both the only place to bump.

Locally the build is `packaging/fetch-runtime.sh` (once) then
`packaging/build.sh`, producing TWO artifacts from one staged tree:
a KUAL zip (unzip into `/mnt/us/extensions/`) and a **KPM** `.kpkg`
(`;kpm install claudeusage` after `;kpm add-repo`). KPM is the path for
Springbreak/Winterbreak jailbreaks.

App data is `/mnt/us/claudeusage/` — deliberately outside the install dir,
because `kpm upgrade` replaces the whole package directory.

## The core mechanism (read before editing `controller.lua`)

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

## Why a bundled KOReader runtime (not bash + eips)

The KOReader runtime bundles luasec, giving real TLS 1.2 + SNI to reach
api.anthropic.com; stock Kindle `curl` usually cannot. It also supplies the
e-ink widget toolkit, fonts, input/gesture handling and framebuffer refresh —
reimplementing those on raw `/dev/fb0` was rejected as too costly. Bundling it
means the project is **AGPL-3.0** (see `LICENSE`) and must keep attribution.

Deploy/test path:

1. `claude setup-token` on PC → copy `sk-ant-oat01-...`.
2. `packaging/fetch-runtime.sh` + `packaging/build.sh` → unzip into `/mnt/us/extensions/`.
3. KUAL → Claude Usage → Login (web) → PIN → dashboard.

Fast iteration without a Kindle, in order of setup cost:

- `packaging/run-docker.sh [--pruned]` — boots the app headless against the
  Linux x86_64 KOReader build in Docker (SDL dummy driver). Needs nothing but
  Docker; `--pruned` applies `prune.txt` first, which is how the shipped tree is
  validated. This is what caught every boot bug so far.
- `packaging/run-emulator.sh [koreader-checkout]` — same env against a local
  `./kodev build` emulator, when you want a real window.

App data (`claudeusage.lua`, `claudeusage_history.lua`) lives in
`extensions/claudeusage/settings/`, addressed by the `CLAUDEUSAGE_DATA` env var
that `bin/claudeusage.sh` exports — deliberately OUTSIDE `runtime/` so bumping
the runtime cannot destroy the stored token. The launcher also does a one-time
import from `koreader/settings/` for users of the old plugin.

## Structure

- `app/app.lua` — entry point. `require("setupkoenv")` → `require("device")`
  (which self-inits — do NOT call `Device:init()`) → `Bidi.setup()` before any
  widget loads → `Controller.new():start()` → `UIManager:run()` →
  `Device:exit()`. `CanvasContext` is skipped on purpose (document engine).
  Also runs a
  1s watchdog that calls `UIManager:quit()` when the window stack empties
  (the loop does not stop on its own), and wraps the loop in `xpcall` writing a
  traceback to `crash.log`.
- `extensions/claudeusage/config.xml` + `menu.json` + `bin/claudeusage.sh` —
  KUAL entry and
  launcher: framework stop/restore (`STOP_FRAMEWORK` toggle), `LUA_PATH`/
  `LUA_CPATH`/`LD_LIBRARY_PATH`, settings import, `cd runtime && ./luajit`.
  Keep it in sync with `runtime/koreader.sh` when bumping the runtime.
  KUAL discovers an extension through `config.xml` (which points at
  `menu.json`); a folder with only `menu.json` never shows up in the menu.
  In menu items, `status` is a command-or-`false` field, not a description —
  the description goes in `internal`.
  By default (`STOP_FRAMEWORK="no"`) the Amazon framework is left **running** —
  restarting it replays the whole Kindle boot animation on every exit. Instead
  the chrome is hidden (`pillow disableEnablePillow disable`) and the window
  manager frozen (`killall -STOP awesome`), undone on exit along with restoring
  the saved `/dev/fb0` dump and `appmgrd start app://com.lab126.booklet.home`.
  The `STOP_FRAMEWORK="yes"` path is kept for debugging; it needs `trap "" TERM`
  around `stop lab126_gui`, which **sends SIGTERM to the caller** — without it
  the launcher dies there and leaves a blank screen.
  Also copied from `koreader.sh`: the script re-execs a copy of itself from
  `/var/tmp` (`/mnt/us` is vfat+fuse). Failures are reported on screen via
  `fbink` (also copied to `/var/tmp`), and both stdout and stderr go to
  `crash.log`. A pre-flight check compares the ELF interpreter `luajit` needs
  against the device, because a wrong-platform build only says "not found".
- `.github/workflows/release.yml` — the `smoke` job is the real gate: it boots
  `app/app.lua` against the **linux x86_64** KOReader build of the same pinned
  version, with `prune.txt` applied and `SDL_VIDEODRIVER=dummy`, and fails on a
  traceback or on never reaching device init. The `build` job additionally
  asserts each package's `luajit` asks for the right ELF interpreter
  (`ld-linux.so.3` vs `ld-linux-armhf.so.3`).
- `packaging/` — `fetch-runtime.sh` (download release; writes `runtime/.platform`
  used to name artifacts and fill the KPM manifest), `prune.txt` (what gets
  stripped, ordered least→most risky), `build.sh` (stage + prune + zip + kpkg),
  `run-emulator.sh` (dev loop), `kpkg/` (KPM `manifest.json.in` +
  `install.sh`/`launch.sh`/`uninstall.sh` hooks — `sh`, not bash).
  KPM specifics: `manifest_version: 2`, version as `[maj,min,patch]`,
  `supported_platforms` from `kindle|kindle5|kindlepw2|kindlehf`, artifact named
  `<id>_<ver>_<platforms>.kpkg` (tar.gz). `install.sh` drops a KUAL shim that
  calls `kpm launch claudeusage` instead of hardcoding the install path, and
  `uninstall.sh` **keeps** the user data rather than deleting the token.
- `app/controller.lua` — plain Lua class (`Controller.new()`), NOT a
  `WidgetContainer`. Opens settings/history, owns the pages, the refresh
  interval and rotation. `start()` picks the first screen (login vs dashboard).
  `fetch()` does the probe and returns the lowercased headers table.
  `setRefreshInterval()` persists the interval (2s cooldown, returns bool).
  `showUsage()` opens the fullscreen `UsageScreen`. No background loop — the
  screen owns the refresh loop while open. `openPage(idx)` closes the previous
  screen before showing the new one. Rotation is `self.rotation_mode`, a
  KOReader screen mode 0-3 persisted in settings; `cycleRotation()` adds a
  quarter turn (portrait → landscape → portrait upside down → landscape upside
  down) and `applyRotation()` calls `Screen:setRotationMode()` directly
  (standalone: no reader view to receive a `SetRotationMode` event).
  `closeUI()` flushes history, closes the screen and
  calls `UIManager:quit()` — i.e. it QUITS THE APP; every exit path leads here.
  `showSettings()` (the gear dialog) is the only entry point for what used to be
  the KOReader menu: rotation, interval, Login/Logout, Fechar app.
- `app/usagescreen.lua` — `InputContainer` fullscreen dashboard.
  **`self.modal = true`** so the framework skips underlying touch zones and routes
  all input here (without it the screen traps taps). `rebuild()` reconstructs
  `self[1]` from `self.data` each fetch/anim frame, reading **live** Screen dims
  (portrait vs landscape branch), then `setDirty(self,"ui")`. Owns the auto-refresh
  loop (`doFetch`) and a **random** animation scheduler (`scheduleNextAnim` →
  `pickAnim` weighted by usage → `playRandomAnim`). Tap targets are the real
  `close_btn` / `refresh_btn` / `rot_btn` / `nav_btns` FrameContainers —
  hit-tested via their `.dimen` (set by paintTo), NOT fixed fractions.
  `rot_btn` → `plugin:cycleRotation()`; `onClose` → `plugin:closeUI()` quits.
  Frees Clawd Blitbuffers each rebuild via `self._disposables`.
  `modelsscreen.lua` / `trendscreen.lua` follow the same shape (page 2 and 3 of
  the swipe carousel); `trendscreen` renders via `chart.lua` over `history.lua`.
  `pill()`, `rotPill()`, `makeNav()`, `makeBottomBar()`, `onTap`/`onSwipe` and
  `_screenFrame()` are near-identical copies in all three files — a change to
  one usually has to be made three times.
- `app/roticon.lua` — the rotate button's circular arrow, drawn into a
  Blitbuffer. Deliberately NOT `IconWidget`: rendering KOReader's SVG icons goes
  through `ImageWidget:_loadfile` → `document/documentregistry`, which registers
  crengine/mupdf/djvu — everything the packaged runtime prunes.
- `app/crypto.lua` (+ `sha256.lua`, `chacha20.lua`) — token
  encryption at rest. `Crypto.encrypt(token,pin)`/`decrypt(blob,pin)`:
  key = iterated SHA-256(salt..pin), `check = SHA-256(key.."cu-verify")` verifier,
  `ct = ChaCha20(key,nonce) XOR token`; PIN never stored; base64 fields.
  `sha256.lua`/`chacha20.lua` are LuaJIT (`bit`) implementations **self-tested vs
  RFC 8439 / FIPS vectors** (`.ok` flags); `Crypto.available()` gates storage —
  callers must **fail closed** (never store plaintext). Confidentiality-only (no
  MAC). Storage: `settings "enc"` blob (no plaintext `token`), `settings "pin_fail"`
  counter; `controller.lua` caches the decrypted token in RAM (`self.session_token`)
  while the app is open and gates `showUsage` behind `promptUnlock`. HONEST LIMIT:
  a 4-digit PIN is offline-brute-forceable by someone with the file — documented,
  not overclaimed.
- `app/tokenserver.lua` — transient non-blocking LAN HTTP
  receiver (luasocket, polled via `UIManager:scheduleIn`). Serves a form (PIN
  pre-filled from `/?k=<PIN>`); a `POST /save` with the correct PIN delivers the
  token via `on_token`, then `stop()`s. `get_ip()` finds the LAN IP.
- `app/loginmodal.lua` — modal shown by `controller.lua:webLogin()`, and the
  first screen when no token is stored.
  Owns a `TokenServer` and renders a **QR** (`ui/widget/qrwidget`) of
  `http://<ip>:<port>/?k=<PIN>` + the URL + PIN. **Rotates the PIN/URL/QR every
  5 min**. `on_token` → save; `on_close` clears the controller's `login_open`
  guard. When
  `fetch()` returns the auth-expired flag (HTTP 401/403), `usagescreen.doFetch`
  calls `plugin:webLogin()` to pop this modal. There is NO bundled token (the old
  `DEV_TOKEN` is gone); each user supplies their own `claude setup-token` value.
- `app/clawd.lua` — Clawd mascot as Lua pixel-art (26x18 grid,
  **built procedurally** in `makeBase()` for exact geometry): wide solid body,
  side ear nubs, two central legs + notch, big square eyes, dark 1px outline
  (the sticker's white outline is invisible on the white page).
  `makeWidget(emotion,scale,opts,bg)` where `opts={anim,phase}`;
  `emotionFor(max_pct,status)`. Resting faces: `love`(<50)/`neutral`(50-75)
  square eyes, `strain`(75-90) `>_<`, `dizzy`(>=90/rejected) spiral. Animations
  (`Clawd.ANIMS`): `blink`, `shy` (`>_<` + blush), `heart` (rises), `sparkle`
  (arm + twinkle). NOTE: device is grayscale — no color.

## Boot prologue — hard-won details

Validated headless against KOReader **v2026.03**, both full and pruned trees
(`packaging/run-docker.sh --pruned`): boot, login modal, all three pages, and a
forced repaint of each. Re-verify these when bumping the runtime:

1. `setupkoenv` only fixes `package.path`/`cpath` — it does NOT create
   `G_reader_settings`. `reader.lua` builds `G_defaults` and `G_reader_settings`
   itself, and `device.lua` reads them at require time. Skipping that step
   crashes in `device/sdl/device.lua`.
2. `require("device")` already calls `dev:init()`. Never init again.
3. `ui/font` → `fontlist` calls `CanvasContext:isKindle()`, and the real
   `document/canvascontext` pulls in `ffi/mupdf` → `libwrap-mupdf.so`. `app.lua`
   preloads a stub so the whole document engine can stay pruned.
4. Pruned font families still appear in `Font.fontmap`/`Font.fallbacks` and
   raise a freetype error on every repaint. `app.lua` remaps missing entries to
   `NotoSans-Regular.ttf` and drops dead fallbacks.

## Still unvalidated (needs the device)

1. Whether freezing `awesome` is enough to stop the Amazon status bar and clock
   repainting over the app. If not, `STOP_FRAMEWORK="yes"` in the launcher goes
   back to the old behaviour (at the cost of the boot animation on exit).
2. Real e-ink refresh and touch input — the smoke test uses SDL's dummy video
   driver, so nothing about painting to a real screen is proven.
