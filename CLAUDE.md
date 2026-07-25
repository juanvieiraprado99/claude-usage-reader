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
the matrix `[kindlepw2, kindlehf]` and publishes a release `v<VERSION>` with four
files. Version sources: `VERSION` (the app, full `major.minor.patch`) and
`packaging/KOREADER_VERSION` (which KOReader release the runtime is cut from) —
both single-line, both the only place to bump.

**`VERSION` is the single source and nothing derives from it.** `build.sh` reads
it, CI reads it, the release tag is it. Bump it in the same commit as the change
you want released. A push that does not bump it still builds and smoke-tests,
but the release step sees the tag already exists and skips with a notice — so
main never goes red just because the version did not move. The patch digit used
to be `github.run_number`, which meant a release said `v0.1.2` while the repo
said `0.1` and a local build said `0.1.0`; three answers, none of them
authoritative.

Locally the build is `packaging/fetch-runtime.sh` (once) then
`packaging/build.sh`, producing TWO artifacts from one staged tree:
a KUAL zip (unzip into `/mnt/us/extensions/`) and a **KPM** `.kpkg`
(`;kpm install claudeusage` after `;kpm add-repo`). KPM is the path for
Springbreak/Winterbreak jailbreaks.

On Windows use **`packaging/build-docker.sh`** instead — the same script in a
container. `build.sh` needs `zip` and a real `python3`, and a Windows checkout
usually has neither (the WindowsApps `python3` is a Store stub that exits
non-zero). It does not fail on that: it stages `dist/claudeusage/` and skips
both archives, so a `dist/` with only the folder in it means the tools were
missing, not that the build broke.

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
- `.github/workflows/release.yml` — the `smoke` job is the real gate: it runs
  `packaging/smoke.lua` against the **linux x86_64** KOReader build of the same
  pinned version, with `prune.txt` applied and `SDL_VIDEODRIVER=dummy`. Booting
  alone proves little — with no token the app stops at the login modal — so the
  smoke script also opens all three pages, repaints each and cycles rotation.
  The `build` job additionally
  asserts each package's `luajit` asks for the right ELF interpreter
  (`ld-linux.so.3` vs `ld-linux-armhf.so.3`).
- `packaging/` — `fetch-runtime.sh` (download release; writes `runtime/.platform`
  used to name artifacts and fill the KPM manifest), `prune.txt` (what gets
  stripped, ordered least→most risky), `build.sh` (stage + prune + zip + kpkg),
  `build-docker.sh` (the same, in a container, for hosts without zip/python3),
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
  **`fetch()` contract:** `(headers, nil, nil)` on 200, `(nil, message, auth)`
  on ANYTHING else. Non-200 used to be returned as success, which rendered a
  rate-limited account as a silent `--%`.
  `nextRefreshDelay()` applies an exponential backoff after failures (the radio,
  not the CPU, is what drains the battery), reset by an explicit interval change.
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
  `showSettings()` is where Login/Logout/interval/quit live; it is reached by
  **tapping the version label** in the bottom-right corner. Logout also has a
  visible **LOGOUT pill** in the bottom bar (`screenbase.lua`), shown only while
  a token exists and confirmed through `confirmLogout()`; both routes go through
  `doLogout()`.
- **Popups must be marked modal, and must not draw icons.** Two traps, both of
  which silently broke every dialog in the app until the logout button forced
  them out:
  1. `UIManager:show` inserts a non-modal widget *below* any modal one. The
     pages are `modal = true` and fullscreen opaque, so a plain
     `UIManager:show(dialog)` puts the dialog **underneath** the page — shown,
     repainted, invisible. `controller.lua`'s `showOver()` sets `modal = true`
     first; use it for anything popped over a page.
  2. `InfoMessage` and `ConfirmBox` draw an icon by default → `IconWidget` →
     `ImageWidget:_loadfile` → `document/documentregistry`, which `prune.txt`
     strips. They **throw** on the shipped runtime. Use `notify()` (InfoMessage
     with `show_icon = false`) and `ButtonDialog` instead of `ConfirmBox`. Same
     reason `roticon.lua` draws its own arrow.
- **A tap target must be a `FrameContainer`, not a bare `TextWidget`.**
  `hit()` tests `widget.dimen`, and `TextWidget:paintTo` never assigns it, so a
  bare TextWidget can never be tapped. The version label was one, which is why
  the settings dialog had been unreachable.
- `app/screenbase.lua` — the base every page extends. Owns the fullscreen frame,
  header, bottom bar, navigation, tap/swipe handling and refresh scheduling.
  Subclasses define `rebuild()` and `doFetch()`, may define `setup()` (extra
  state, before the first build) and `onExtraTap(pos, slop)` (page-specific
  targets). `beginRebuild()` frees the previous frame's buffers and returns
  `landscape, base, lw`. Before this existed the three screens carried ~570
  lines of byte-identical copy. `app/theme.lua` holds the palette and metrics,
  `app/fmt.lua` the header/epoch formatting.
- **Text colours vs structure colours.** In `theme.lua`, `fg`/`active`/`muted`/
  `faint` are for text; `border`/`rule`/`fill` are for lines and backgrounds and
  must never be passed as an `fgcolor`. That mistake is why several captions
  shipped nearly unreadable — e-ink has no backlight and far less usable
  contrast than the emulator implies, so a grey that merely looks soft on a
  monitor disappears on the device. Small captions also take `bold = true`,
  which buys more legibility on e-ink than another shade of grey. When
  bolding text, re-run the smoke geometry checks: bold is **wider**, and the
  header, bottom bar and heatmap gutter are all laid out from measured widths.
- `app/usagescreen.lua` — the dashboard. **`self.modal = true`** (set by the
  base) so the framework skips underlying touch zones and routes all input here.
  `rebuild()` reconstructs `self[1]` from `self.data`, reading **live** Screen
  dims (portrait vs landscape branch), then `setDirty(self,"ui")`; passing
  `anim_only` narrows the repaint to the mascot. Owns a **random** animation
  scheduler (`scheduleNextAnim` → `pickAnim` weighted by usage → `runAnim`).
  Tap targets are the real FrameContainers, hit-tested via their `.dimen` (set
  by paintTo), NOT fixed fractions.
  `modelsscreen.lua` / `trendscreen.lua` are pages 2 and 3 of the swipe
  carousel; `trendscreen` renders via `chart.lua` over `history.lua`.
- `app/history.lua` — **two** persisted ring buffers in one settings file:
  `samples` (5h utilization, every fetch, kept 5h) and `weekly` (7d
  utilization, throttled to hourly by `MIN_GAP_7D`, kept 7 days). Files written
  before the weekly series existed have no `weekly` key and must keep loading.
  Samples are only recorded while a screen is fetching, so the weekly series is
  sparse — it survives across sessions and fills in over days.
- `app/heatmap.lua` — the week as a 7×4 grid (a column per day, a row per 6h
  block), cell darkness = quota consumed in that block. Third state of page 3's
  tap toggle (`5h → 7d → heat`), reusing the same `weekly` series.
  **Read the module docstring before trusting a cell.** In short: the stored
  value is *cumulative* utilization, so a cell is a **derived delta spread over
  the interval between two samples**, not an observation; shading is **relative
  to that week's busiest block**; and unmeasured blocks are `nil`, rendered
  differently from zero, because "idle" and "app was closed" must not look alike.
  Resolution is 7×4 and not 7×24 **because of the sampling rate, not the
  layout**: samples only accrue while the app is open, at most one an hour
  (`MIN_GAP_7D`), so 168 cells could never be filled. The only way to improve
  the picture is keeping the app open with auto-refresh on — there is no
  background collection, and adding one would mean shipping a daemon this
  project deliberately avoids. The screen therefore always prints what the
  darkest cell is worth and how many blocks were actually measured.
- `app/burn.lua` — the burn-rate projection behind the trend page's verdict
  line (two-point slope → ETA vs the window's reset). Extracted from
  `trendscreen.lua` so both windows can use it. `Burn.PARAMS` is per-window and
  **must stay split**: the 5h "stable" floor of `0.02/60` per minute is ~29% a
  day, which would report a draining week as steady, and its 45-min lookback
  finds no reference sample in an hourly series.
- Page 3 plots **either** window; tapping the chart toggles. The mode is
  `controller.trend_mode`, not screen state, because `openPage` builds a fresh
  screen on every navigation.
- `app/i18n.lua` — PT/EN. The **msgid is the English text**, so a missing entry
  degrades to English instead of to a key. (An earlier version had the table
  keyed on English while every call site passed Portuguese: it never matched,
  and the app was simply Portuguese pretending to be bilingual. The smoke test
  now asserts a real translation.) Language is `auto`/`pt`/`en`, persisted as
  `lang` and toggled from the settings dialog; `auto` reads `LANG`/`LANGUAGE`
  and falls back to **pt**. NEVER call `T()` at module load — a constant built
  then freezes the language and a switch would not reach it (see `navLabels()`
  in `screenbase.lua`). Weekday names come from `i18n.weekdays()`.
- `app/appversion.lua` — returns the version string shown in the bottom-right of
  every screen. `packaging/build.sh` overwrites it in the staged package with
  `APP_VERSION`; the copy in the repo stays `"dev"`. **Not** named `version.lua`:
  KOReader ships its own `version` module and wins the `require` cache.
- `app/roticon.lua` — the rotate button's circular arrow, drawn into a
  Blitbuffer. Deliberately NOT `IconWidget`: rendering KOReader's SVG icons goes
  through `ImageWidget:_loadfile` → `document/documentregistry`, which registers
  crengine/mupdf/djvu — everything the packaged runtime prunes.
- **Raster caching.** `clawd.lua` and `roticon.lua` cache their Blitbuffers and
  own them, so their widgets are `image_disposable = false` and must NOT be put
  in a screen's `_disposables` — freeing one leaves the cache holding a dangling
  buffer. `Clawd.clearCache()` is called when the scale changes (rotation).
  Only `chart.lua` stays disposable, since its pixels change with the data.
  Without this an animation frame re-rasterised ~160k pixels every 120-300ms.
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
