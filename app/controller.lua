--[[
Claude Usage - app controller (standalone KUAL app)
Probes api.anthropic.com with max_tokens:1 and reads the
anthropic-ratelimit-unified-* response headers. Costs ~1 token per refresh.

Token: run `claude setup-token` on your PC and hand the sk-ant-oat01-... value to
the app over the LAN login page. Stored encrypted, behind a PIN.

Auto-refresh: each tick is one probe (~1 token) and one TLS handshake, which is
what actually drains the battery - the radio, not the CPU. Hence the intervals
start at 10s, and network failures back off instead of retrying at full rate.
]]--

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local UsageScreen = require("usagescreen")
local ModelScreen = require("modelsscreen")
local TrendScreen = require("trendscreen")
local History = require("history")
local Accounts = require("accounts")
local LoginModal = require("loginmodal")
local TokenServer = require("tokenserver")
local NetworkMgr = require("ui/network/manager")
local ButtonDialog = require("ui/widget/buttondialog")
local Powersave = require("powersave")
local Screen = require("device").screen
local Crypto = require("crypto")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local socket = require("socket")
local i18n = require("i18n")
local T = i18n.t

local ENDPOINT = "https://api.anthropic.com/v1/messages"
local STATUS_ENDPOINT = "https://status.claude.com/api/v2/incidents/unresolved.json"
local PROBE_MODEL = "claude-haiku-4-5-20251001"
local CHANGE_COOLDOWN = 2              -- seconds between interval changes
local LOGIN_PORT = 8099               -- LAN web receiver for the token
local MAX_FAILS = 8                   -- wrong PIN tries before wiping the token
-- One full-screen repaint in every FULL_EVERY is promoted to a flashing "full"
-- refresh, which is what clears accumulated e-ink ghosting. 6 is KOReader's own
-- default (DEFAULT_FULL_REFRESH_COUNT); at a 60s refresh interval that is a
-- flash about every 6 minutes.
local FULL_EVERY = 6
local ACTIVE_MARK = "• "              -- marks the selected account in the list
local IDLE_MARK   = "  "              -- keeps the other labels aligned with it

-- Models probed (rotated one-per-cycle) on the Models screen.
local MODELS = {
    { id = "claude-haiku-4-5-20251001", name = "Haiku"  },
    { id = "claude-sonnet-5",           name = "Sonnet" },
    { id = "claude-opus-4-8",           name = "Opus"   },
    { id = "claude-fable-5",            name = "Fable"  },
}
local PAGES_IMPL = 3                   -- navigable pages (dashboard, models, 5h trend)
local INTERVAL_CYCLE = { 0, 10, 30, 60, 300 }
local BACKOFF_MAX = 300                -- ceiling when the network keeps failing
local ROTA_PORTRAIT = Screen.DEVICE_ROTATED_UPRIGHT or 0
local IDLE_AFTER = 300                 -- seconds without a tap/swipe before we call it idle
local IDLE_MIN_REFRESH = 60            -- floor for the auto-refresh delay while idle

-- Every popup here opens over a page, and the pages set `modal = true` so the
-- framework routes gestures to them instead of the touch zones underneath.
-- UIManager:show inserts a NON-modal widget below any modal one, which for a
-- fullscreen opaque page means underneath it - shown, dirty, repainted, and
-- invisible. Marking our popups modal too puts them back on top.
local function showOver(widget)
    widget.modal = true
    UIManager:show(widget)
    return widget
end

-- InfoMessage draws a "notice-info" icon by default, and that goes IconWidget ->
-- ImageWidget:_loadfile -> document/documentregistry, which prune.txt strips
-- from the shipped runtime: every one of these popups threw instead of showing.
-- show_icon = false keeps them to text, which is all they ever needed.
local function notify(text)
    return showOver(InfoMessage:new{ text = text, show_icon = false })
end

local ClaudeUsage = {}
ClaudeUsage.__index = ClaudeUsage

-- Standalone app: no KOReader plugin host. The controller owns the settings,
-- the history and whichever screen is currently on the UIManager stack.
function ClaudeUsage.new()
    local self = setmetatable({}, ClaudeUsage)
    self:init()
    return self
end

-- App data lives outside the bundled runtime (see bin/claudeusage.sh) so that
-- replacing runtime/ never destroys the stored token or the history.
local DATA_DIR = os.getenv("CLAUDEUSAGE_DATA") or DataStorage:getSettingsDir()

function ClaudeUsage:init()
    self.settings = LuaSettings:open(DATA_DIR .. "/claudeusage.lua")
    -- "auto" (follow the environment), "pt" or "en".
    i18n.setLang(self.settings:readSetting("lang") or "auto")
    self.refresh_interval = self.settings:readSetting("refresh_interval") or 0
    -- Default ON: the mascot's animations. Off saves the per-frame widget-tree
    -- rebuild (see usagescreen.lua) - one more thing that keeps the CPU busy
    -- while the screensaver is held off all day.
    self.animations = self.settings:readSetting("animations") ~= false
    -- Default ON: keeps the Kindle from ever suspending while the app is open
    -- (see app.lua/powersave.lua). Off trades the always-visible dashboard for
    -- letting the device actually sleep - unvalidated on real hardware, but
    -- the escape hatch for anyone who'd rather have battery than uptime.
    self.prevent_screensaver = self.settings:readSetting("prevent_screensaver") ~= false
    self.last_activity = os.time()
    self.change_locked = false
    -- Exposed to the screens (page nav + model list).
    self.MODELS = MODELS
    self.PAGES_IMPL = PAGES_IMPL
    self._fail_streak = 0   -- drives the refresh backoff
    self._probe_idx = 0
    self._model_results = {}
    self._incidents = nil
    self._paints = 0        -- drives the periodic anti-ghosting full refresh
    -- Accounts first: it migrates the old single-token settings layout, and the
    -- history file to open depends on which account is active.
    self.accounts = Accounts.new(self.settings, DATA_DIR)
    self.history = History.new(self.accounts:histPath(self.accounts:active()))
    -- Which window the trend screen plots, "5h" or "7d". Lives here and not on
    -- the screen because openPage builds a fresh one on every navigation.
    self.trend_mode = "5h"
    -- Rotation is a KOReader screen mode: 0 portrait, 1 landscape,
    -- 2 portrait upside down, 3 landscape upside down. Remembered across runs.
    self.rotation_mode = self.settings:readSetting("rotation_mode") or ROTA_PORTRAIT
    self.cur_screen = nil
    -- Stable callback ref so UIManager:unschedule works.
    self.unlock_task = function() self.change_locked = false end
end

-- App entry point, called by app.lua before UIManager:run(). Something must be
-- on the stack before the loop starts, otherwise UIManager exits immediately.
--
-- `action` is the KUAL submenu deep link, arriving as the CU_ACTION environment
-- variable (see bin/claudeusage.sh). An unrecognised value must behave exactly
-- like no value at all: a stale shim left behind by a partial upgrade would
-- otherwise brick the launch, and there is no console on a Kindle to see why.
function ClaudeUsage:start(action)
    if action == "add-account" then
        self:webLogin()
        return
    end
    if not self:hasToken() then
        self:webLogin()
        return
    end
    self:showUsage()
    -- Over the dashboard, because a bare dialog on an empty stack leaves the
    -- app with nothing to fall back to when it closes.
    if action == "accounts" then
        self:showAccounts()
    elseif action == "remove-account" then
        self:showAccounts({ mode = "remove" })
    end
end

function ClaudeUsage:hasToken()
    return self.accounts:active() ~= nil
end

function ClaudeUsage:isUnlocked()
    return self.session_token ~= nil
end

-- Drop the ACTIVE account's record. Accounts:remove promotes whatever is left,
-- so an install with two accounts logs out of one and keeps the other.
function ClaudeUsage:logout()
    local acct = self.accounts:active()
    if acct then self.accounts:remove(acct.id) end
    self.session_token = nil
    notify(T("Token cleared."))
end

-- Clear the token and drop back to whatever is left: another account if there
-- is one, otherwise the login modal. Either way the app stays alive. Shared by
-- the settings dialog and the bottom-bar button, so both do the same thing.
function ClaudeUsage:doLogout()
    self:logout()
    self:_adoptActiveAccount()
    if self.accounts:active() then
        self:showUsage()
    else
        self:webLogin()
    end
end

-- Point the per-account state at whatever Accounts now calls active: its own
-- history file, and none of the previous account's cached probe results. The
-- token cache goes too, so the next showUsage() asks for that account's PIN.
function ClaudeUsage:_adoptActiveAccount()
    self.history:flush()   -- the outgoing account's samples, before the swap
    self.history = History.new(self.accounts:histPath(self.accounts:active()))
    self.session_token = nil
    self._fail_streak = 0
    self._probe_idx = 0
    self._model_results = {}
    self._incidents = nil
    if self.cur_screen then
        UIManager:close(self.cur_screen)
        self.cur_screen = nil
    end
end

-- Make `id` the active account and reopen the dashboard on it. showUsage() runs
-- through withUnlocked, so the PIN prompt is the existing one - each account
-- has its own PIN and its own failure counter.
function ClaudeUsage:switchAccount(id)
    local acct = self.accounts:byId(id)
    if not acct or acct.id == self.accounts.active_id then return end
    self.accounts:setActive(id)
    self:_adoptActiveAccount()
    self:showUsage()
end

-- Wrapped in a confirmation because the button sits one tap away on every
-- screen: logging out wipes the stored token, and getting back in means the
-- whole QR + PIN dance again.
--
-- ButtonDialog and not ConfirmBox: ConfirmBox draws an icon, which goes
-- IconWidget -> ImageWidget:_loadfile -> document/documentregistry, and that is
-- pruned from the shipped runtime. Same reason roticon.lua draws its own arrow.
function ClaudeUsage:confirmLogout()
    local dlg
    dlg = ButtonDialog:new{
        title = T("Log out and clear the stored token?"),
        title_align = "center",
        buttons = {{
            {
                text = T("Cancel"),
                callback = function() UIManager:close(dlg) end,
            },
            {
                text = T("Log out"),
                callback = function() UIManager:close(dlg); self:doLogout() end,
            },
        }},
    }
    showOver(dlg)
end

-- Ask for a numeric PIN; calls on_pin(pin) with the entered value.
function ClaudeUsage:promptPin(title, on_pin)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input_type = "number",
        buttons = {{
            { text = T("Cancel"), id = "close",
              callback = function() UIManager:close(dialog) end },
            { text = "OK", is_enter_default = true,
              callback = function()
                  local pin = dialog:getInputText()
                  UIManager:close(dialog)
                  on_pin(pin)
              end },
        }},
    }
    showOver(dialog)
    dialog:onShowKeyboard()
end

-- Ask for a free-text name; same shape as promptPin, minus the numeric keypad.
--
-- Starts EMPTY and skipping is a real option: a stored name is a literal string,
-- so pre-filling "Account 2" and letting it through would freeze that wording
-- into the file and a language switch would never reach it. An empty name is
-- kept as nil and rendered through T() on every draw instead.
--
-- Skip, not Cancel: by the time this dialog opens the token has already been
-- validated over the network, and throwing it away would mean redoing the whole
-- QR dance for what is a cosmetic field.
function ClaudeUsage:promptName(on_name)
    local dialog
    dialog = InputDialog:new{
        title = T("Name this account"),
        input = "",
        buttons = {{
            { text = T("Skip"), id = "close",
              callback = function()
                  UIManager:close(dialog)
                  on_name(nil)
              end },
            { text = "OK", is_enter_default = true,
              callback = function()
                  local name = dialog:getInputText()
                  UIManager:close(dialog)
                  on_name(name)
              end },
        }},
    }
    showOver(dialog)
    dialog:onShowKeyboard()
end

-- Decrypt the ACTIVE account's token with its PIN; caches it in RAM for this
-- session. The failure counter is per account, so wiping on MAX_FAILS takes out
-- the account under attack and leaves the others alone.
function ClaudeUsage:promptUnlock(on_ok)
    local acct = self.accounts:active()
    if not acct then return end
    self:promptPin(T("Locked — enter your PIN."), function(pin)
        local tok = acct.enc and Crypto.decrypt(acct.enc, pin)
        if tok then
            self.session_token = tok
            self.accounts:setPinFail(acct.id, 0)
            if on_ok then on_ok() end
        else
            local fails = (acct.pin_fail or 0) + 1
            if fails >= MAX_FAILS then
                self.accounts:remove(acct.id)
                self.session_token = nil
                notify(T("Too many attempts — token wiped."))
                self:_adoptActiveAccount()
                if self.accounts:active() then
                    self:showUsage()
                else
                    self:webLogin()
                end
            else
                self.accounts:setPinFail(acct.id, fails)
                notify(T("Wrong PIN."))
            end
        end
    end)
end

-- Encrypt a freshly-received token under a new PIN and store it as a new
-- account. `replace_id` instead updates that account's blob in place, keeping
-- its name, its history and its position - that is the token-expiry re-login.
function ClaudeUsage:addAccount(tok, replace_id)
    if not Crypto.available() then
        notify(T("Encryption unavailable — cannot store."))
        return
    end
    if not replace_id and self.accounts:count() >= Accounts.MAX_ACCOUNTS then
        notify(T("Account limit reached."))
        return
    end
    local function store(name)
        self:promptPin(T("Create a 4-digit PIN"), function(pin)
            if not pin or pin == "" then return end
            local blob = Crypto.encrypt(tok, pin)
            if not blob then
                notify(T("Encryption unavailable — cannot store."))
                return
            end
            if replace_id then
                self.accounts:setEnc(replace_id, blob)
            else
                self.accounts:add(name, blob)
                self:_adoptActiveAccount()   -- new account, its own history
            end
            self.session_token = tok
            self:showUsage()   -- success -> go straight to the dashboard
        end)
    end
    if replace_id then
        store(nil)
    else
        self:promptName(store)
    end
end

-- Show the QR login modal (LAN receiver + 5-min rotating URL/PIN/QR). Guards
-- against stacking (also called automatically by UsageScreen on token expiry).
--
-- `replace_id` re-authenticates an existing account instead of adding one: the
-- expiry path must not turn a renewed token into a duplicate entry that no
-- longer points at the account's own history.
function ClaudeUsage:webLogin(replace_id)
    if self.login_open then return end
    -- NetworkMgr is a KOReader-app service; outside its usual host it may throw.
    -- Only block on a *definite* "not connected" answer, never on an error.
    if NetworkMgr and NetworkMgr.isConnected then
        local ok, connected = pcall(function() return NetworkMgr:isConnected() end)
        if ok and not connected then
            notify(T("Connect the Kindle to WiFi first."))
            return
        end
    end
    local ip = TokenServer.get_ip()
    if not ip then
        notify(T("No network IP. Check WiFi."))
        return
    end
    self.login_open = true
    showOver(LoginModal:new{
        ip = ip,
        port = LOGIN_PORT,
        on_token = function(tok)
            -- Validate the token before storing it (reject junk/expired).
            if not self:probeToken(tok) then
                notify(T("Invalid token (rejected)."))
                return
            end
            self:addAccount(tok, replace_id)
        end,
        on_close = function() self.login_open = false end,
    })
end

-- Token expired (401/403): re-authenticate the ACTIVE account in place, so the
-- renewed token lands on the same record and keeps its name and history. Called
-- by all three pages, which is why it is a method and not the raw webLogin call.
function ClaudeUsage:reauth()
    local acct = self.accounts:active()
    self:webLogin(acct and acct.id or nil)
end

-- One probe with an explicit token; true if accepted (not 401/403).
function ClaudeUsage:probeToken(tok)
    local h, _err, auth = self:fetch(tok)
    return h ~= nil and not auth
end

-- Change the auto-refresh interval, rate-limited to once per CHANGE_COOLDOWN s.
-- Returns true if the interval actually changed, false if blocked by cooldown.
function ClaudeUsage:setRefreshInterval(secs)
    if self.change_locked then
        showOver(InfoMessage:new{
            text = string.format(T("Wait %d s before changing again."), CHANGE_COOLDOWN),
            timeout = 1,
            show_icon = false,
        })
        return false
    end
    self.change_locked = true
    UIManager:scheduleIn(CHANGE_COOLDOWN, self.unlock_task)

    self.refresh_interval = secs
    self.settings:saveSetting("refresh_interval", secs)
    self.settings:flush()
    return true
end

-- One probe against the messages endpoint. The response body is discarded - all
-- we want are the rate-limit headers - so this costs about one token.
--
-- The OAuth token only works alongside the anthropic-beta header and a
-- claude-code user agent; drop either and the API rejects the request.
local function probe(token, model_id, resp)
    local body = string.format(
        '{"model":"%s","max_tokens":1,"messages":[{"role":"user","content":"."}]}',
        model_id)
    return https.request{
        url = ENDPOINT,
        method = "POST",
        headers = {
            ["authorization"]     = "Bearer " .. token,
            ["anthropic-version"] = "2023-06-01",
            ["anthropic-beta"]    = "oauth-2025-04-20",
            ["content-type"]      = "application/json",
            ["user-agent"]        = "claude-code/2.1.5",
            ["content-length"]    = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(resp),
        protocol = "tlsv1_2",
    }
end

-- Fetch usage. Uses `arg_token` if given, else the unlocked session token.
--
-- Contract, relied on by every caller: on success (headers, nil, nil); on any
-- failure (nil, message, auth_expired). Anything other than 200 is a failure -
-- a 429 or 500 used to slip through as success and render as a silent "--%".
function ClaudeUsage:fetch(arg_token)
    local token = arg_token or self.session_token
    if not token or token == "" then
        return nil, T("no token")
    end

    local resp = {}
    local ok, code, headers = probe(token, PROBE_MODEL, resp)

    -- Validating a freshly pasted token is not part of the refresh rhythm, so
    -- it must not disturb the backoff.
    local function done(err, auth)
        if not arg_token then self:noteFetchResult(err == nil) end
        if err then return nil, err, auth end
        return headers
    end

    if not ok then return done(T("no network")) end
    if code == 401 or code == 403 then return done(T("token expired"), true) end
    if code ~= 200 or not headers then return done(T("error ") .. tostring(code)) end
    -- luasocket lowercases the header keys for us.
    return done()
end

-- Refresh pacing --------------------------------------------------------------
-- Every tick is a fresh TLS handshake, and the radio is what drains a Kindle
-- battery. So a network that keeps failing must not keep retrying at the user's
-- chosen rate: consecutive failures double the delay, up to BACKOFF_MAX.
function ClaudeUsage:noteFetchResult(ok)
    self._fail_streak = ok and 0 or (self._fail_streak + 1)
end

function ClaudeUsage:nextRefreshDelay()
    local base = self.refresh_interval
    if base <= 0 then return 0 end                    -- auto-refresh off
    local delay = base
    if self._fail_streak > 0 then
        delay = math.min(base * 2 ^ math.min(self._fail_streak, 6), BACKOFF_MAX)
    end
    -- Nobody is looking: no point refreshing (and handshaking the radio) at
    -- the user's chosen rate. The screensaver stays off regardless, so this is
    -- the only lever idle time gives us.
    if self:isIdle() then delay = math.max(delay, IDLE_MIN_REFRESH) end
    return delay
end

-- Idle tracking --------------------------------------------------------------
-- Taps and swipes report through screenbase.lua; nothing else counts (a
-- physical Back key bypasses this, which is fine - it also closes the app).
function ClaudeUsage:isIdle()
    return os.time() - self.last_activity >= IDLE_AFTER
end

-- Only reschedule on the IDLE -> active edge: doing it on every tap would push
-- the next fetch out indefinitely on a screen someone keeps prodding.
function ClaudeUsage:noteActivity()
    local was_idle = self:isIdle()
    self.last_activity = os.time()
    if was_idle and self.cur_screen then
        self.cur_screen:rescheduleRefresh()
        if self.animations and self.cur_screen.scheduleNextAnim then
            self.cur_screen:scheduleNextAnim()
        end
    end
end

-- Probe one specific model; returns { code, ms, auth, reason }.
function ClaudeUsage:fetchModelProbe(model_id)
    local token = self.session_token
    if not token or token == "" then return { code = 0 } end

    local t0 = socket.gettime()
    local resp = {}
    local ok, code = probe(token, model_id, resp)
    local ms = math.floor((socket.gettime() - t0) * 1000 + 0.5)

    if not ok then return { code = -1, ms = ms } end          -- network failure
    local auth = (code == 401 or code == 403)
    -- On any non-200, keep the API's error message so we can see WHY (e.g. a
    -- 429 that is really "model not available on your plan" vs a rate limit).
    local reason
    if code ~= 200 then
        local b = table.concat(resp)
        reason = b:match('"message"%s*:%s*"(.-)"') or b:match('"type"%s*:%s*"(.-)"')
        if reason and #reason > 60 then reason = reason:sub(1, 60) .. "…" end
    end
    return { code = code, ms = ms, auth = auth, reason = reason }
end

-- GET status.claude.com unresolved incidents; per-model up/down heuristic.
-- Returns { has_data = bool, up = { Haiku = bool, ... } }.
function ClaudeUsage:fetchIncidents()
    local resp = {}
    local ok, code = https.request{
        url = STATUS_ENDPOINT,
        method = "GET",
        headers = { ["user-agent"] = "claude-usage-reader/1.0" },
        sink = ltn12.sink.table(resp),
        protocol = "tlsv1_2",
    }
    if not ok or code ~= 200 then return { has_data = false, up = {} } end
    local body = table.concat(resp)
    -- Only look inside the incident titles and component names. Matching the
    -- whole document meant any stray "opus" in an unrelated field marked that
    -- model as down.
    local haystack = {}
    for s in body:gmatch('"name"%s*:%s*"(.-)"') do haystack[#haystack + 1] = s end
    for s in body:gmatch('"shortlink"%s*:%s*"(.-)"') do haystack[#haystack + 1] = s end
    local named = table.concat(haystack, "\n"):lower()

    local up = {}
    for _, m in ipairs(MODELS) do
        -- name absent from the incident feed => model is up
        up[m.name] = (named:find(m.name:lower(), 1, true) == nil)
    end
    return { has_data = true, up = up }
end

-- Refresh incidents at most every 5 minutes (they change rarely; a GET per
-- refresh cycle is wasted Kindle radio time).
local INCIDENTS_TTL = 300
function ClaudeUsage:maybeFetchIncidents()
    local now = os.time()
    if self._incidents and self._incidents_ts
       and now - self._incidents_ts < INCIDENTS_TTL then
        return
    end
    local inc = self:fetchIncidents()
    if inc.has_data or not self._incidents then
        self._incidents = inc
        self._incidents_ts = now
    end
end

-- Probe the next model in rotation. Returns auth.
function ClaudeUsage:refreshNextModel()
    local idx = (self._probe_idx % #MODELS) + 1
    self._probe_idx = idx
    local res = self:fetchModelProbe(MODELS[idx].id)
    self._model_results[idx] = res
    self:maybeFetchIncidents()
    return res.auth == true
end

-- Probe ALL models in one shot (eager). Returns auth.
-- ~4 tokens and several seconds on a Kindle: the requests are sequential and
-- synchronous, so the UI is unresponsive for the duration.
function ClaudeUsage:refreshAllModels()
    local auth = false
    for i, m in ipairs(MODELS) do
        local res = self:fetchModelProbe(m.id)
        self._model_results[i] = res
        if res.auth then auth = true end
    end
    self:maybeFetchIncidents()
    return auth
end

-- Models screen entry point: eager only while some model has never been probed;
-- after that, rotate one model per cycle (4x fewer tokens and requests).
-- Returns (auth_expired, err) - err drives the header label and the backoff.
function ClaudeUsage:refreshModels()
    local eager = false
    for i = 1, #MODELS do
        if not self._model_results[i] then eager = true; break end
    end
    local auth = eager and self:refreshAllModels() or self:refreshNextModel()

    -- "Every probe failed at the network level" is the one case worth surfacing;
    -- a single model being unavailable is normal and shown per card.
    local err
    local reachable = false
    for _, res in pairs(self._model_results) do
        if res.code and res.code > 0 then reachable = true end
    end
    if not reachable then err = T("no network") end
    self:noteFetchResult(err == nil)
    return auth, err
end

-- Ensure the token is unlocked, then run cb().
function ClaudeUsage:withUnlocked(cb)
    if not self:hasToken() then
        notify(T("Log in first."))
        return
    end
    if not self:isUnlocked() then
        self:promptUnlock(cb)
        return
    end
    cb()
end

-- Record a utilization sample of each window for the trend screen's history.
-- Either may be nil (a missing header); history.lua throttles the weekly one.
function ClaudeUsage:recordSample(v5, v7)
    if v5 or v7 then self.history:push(os.time(), v5, v7) end
end

-- The refresh mode the next repaint should use, and the app's answer to e-ink
-- ghosting after a long session.
--
-- KOReader already promotes every Nth repaint to a flashing refresh
-- (uimanager.lua), but it only counts repaints whose mode is "partial", and
-- this app has never issued one - every repaint it makes is "ui". So the
-- built-in mitigation never fired here, and hours of non-flashing updates is
-- exactly how ghost text builds up. We count our own.
--
-- Three things this must keep doing:
--   * The counter lives HERE and not on the screen: openPage() builds a fresh
--     screen on every navigation, so a per-screen counter would reset on each
--     swipe and never reach FULL_EVERY.
--   * Regional repaints are excluded. The mascot animates several times a
--     minute with a narrowed dirty region; counting those would flash the
--     screen constantly, and promoting one would flash the whole panel for a
--     26x18 sprite.
--   * "full" and not "flashui": UIManager silently downgrades flashui to ui
--     when avoid_flashing_ui is set, and this repaint exists precisely to
--     flash. A regionless "full" also resets KOReader's own counter.
function ClaudeUsage:paintType(regional)
    if regional then return "ui" end
    self._paints = (self._paints or 0) + 1
    if self._paints % FULL_EVERY == 0 then return "full" end
    return "ui"
end

-- Apply the app's rotation choice to the device (affects all pages).
-- Standalone: there is no reader view to handle a SetRotationMode event, so we
-- drive the Screen directly. The caller repaints; doing it here as well cost a
-- second full-screen flash on every tap.
function ClaudeUsage:applyRotation()
    if Screen:getRotationMode() ~= self.rotation_mode then
        Screen:setRotationMode(self.rotation_mode)
    end
end

-- Quarter turn per tap, all the way around: portrait -> landscape ->
-- portrait upside down -> landscape upside down -> portrait.
function ClaudeUsage:cycleRotation()
    self.rotation_mode = (self.rotation_mode + 1) % 4
    self.settings:saveSetting("rotation_mode", self.rotation_mode)
    self.settings:flush()
    self:applyRotation()
    if self.cur_screen then self.cur_screen:rebuild() end
    UIManager:setDirty("all", "full")   -- the whole geometry changed
end

-- Switch between Portuguese and English and redraw. Persisted as an explicit
-- choice, so it stops following the environment once the user has picked.
function ClaudeUsage:toggleLanguage()
    local nxt = (i18n.lang() == "pt") and "en" or "pt"
    i18n.setLang(nxt)
    self.settings:saveSetting("lang", nxt)
    self.settings:flush()
    if self.cur_screen then self.cur_screen:rebuild() end
end

-- Toggle the mascot's animations on/off and persist the choice. Only the
-- dashboard screen has any, hence the presence check before poking it.
function ClaudeUsage:toggleAnimations()
    self.animations = not self.animations
    self.settings:saveSetting("animations", self.animations)
    self.settings:flush()
    if self.cur_screen and self.cur_screen.onAnimSettingChanged then
        self.cur_screen:onAnimSettingChanged()
    end
end

-- Toggle whether the app holds off the Kindle's screensaver, applied
-- immediately (no restart needed) so the device can start sleeping the moment
-- the user turns it off.
function ClaudeUsage:togglePreventScreensaver()
    self.prevent_screensaver = not self.prevent_screensaver
    self.settings:saveSetting("prevent_screensaver", self.prevent_screensaver)
    self.settings:flush()
    Powersave.set(self.prevent_screensaver)
end

-- Advance the auto-refresh interval to the next value in the cycle.
function ClaudeUsage:cycleInterval()
    local cur = self.refresh_interval
    -- Default to the first entry when the persisted value is not in the cycle
    -- (an older build used different steps), rather than silently landing on
    -- whatever INTERVAL_CYCLE[1] happens to be after a failed search.
    local nxt = INTERVAL_CYCLE[2] or INTERVAL_CYCLE[1]
    for i, v in ipairs(INTERVAL_CYCLE) do
        if v == cur then nxt = INTERVAL_CYCLE[(i % #INTERVAL_CYCLE) + 1]; break end
    end
    if self:setRefreshInterval(nxt) and self.cur_screen then
        self._fail_streak = 0   -- an explicit change cancels any backoff
        self.cur_screen:rescheduleRefresh()
        self.cur_screen:rebuild()
    end
end

-- Quit the app: persist, tear down the screen, stop the UIManager loop so
-- app.lua can run Device:exit() and hand control back to KUAL.
function ClaudeUsage:closeUI()
    self.history:flush()   -- persist any samples held back by the throttle
    UIManager:unschedule(self.unlock_task)
    if self.cur_screen then
        UIManager:close(self.cur_screen)
        self.cur_screen = nil
    end
    UIManager:quit()
end

-- The account list, and the only place it is ever drawn. Three ways in: the
-- KUAL "Ver contas" entry, the KUAL "Excluir conta" entry (mode = "remove") and
-- the Account row in the settings dialog - so switching works whether the app
-- is already open or not.
--
-- The active account carries a leading "• ", the others two spaces so the names
-- stay in one column. That exact glyph is used because it already ships and
-- renders in the interval row above; a star or a filled circle is not verified
-- against the pruned NotoSans, and a missing glyph is a silent tofu box on
-- e-ink. ButtonDialog and not ConfirmBox: icons throw on the shipped runtime.
function ClaudeUsage:showAccounts(opts)
    local remove_mode = opts and opts.mode == "remove"
    local dlg
    local function close_dlg() if dlg then UIManager:close(dlg) end end
    local buttons = {}
    for _, acct in ipairs(self.accounts:list()) do
        local id = acct.id
        local mark = (id == self.accounts.active_id) and ACTIVE_MARK or IDLE_MARK
        table.insert(buttons, {{
            text = mark .. self.accounts:label(acct),
            callback = function()
                close_dlg()
                if remove_mode then
                    self:confirmRemoveAccount(id)
                else
                    self:switchAccount(id)   -- tapping the active one is a no-op
                end
            end,
        }})
    end
    if not remove_mode and self.accounts:count() < Accounts.MAX_ACCOUNTS then
        table.insert(buttons, {{
            text = T("Add account (web)"),
            callback = function() close_dlg(); self:webLogin() end,
        }})
    end
    table.insert(buttons, {{
        text = T("Cancel"),
        callback = function() close_dlg() end,
    }})

    dlg = ButtonDialog:new{
        title = remove_mode and T("Remove which account?") or T("Accounts"),
        title_align = "center",
        buttons = buttons,
    }
    showOver(dlg)
end

-- Removing an account deletes its token for good, so it is confirmed the same
-- way logging out is. The history file survives (see accounts.lua).
function ClaudeUsage:confirmRemoveAccount(id)
    local acct = self.accounts:byId(id)
    if not acct then return end
    local label = self.accounts:label(acct)
    local dlg
    dlg = ButtonDialog:new{
        title = string.format(T("Remove %s? The token is deleted."), label),
        title_align = "center",
        buttons = {{
            {
                text = T("Cancel"),
                callback = function() UIManager:close(dlg) end,
            },
            {
                text = T("Remove"),
                callback = function()
                    UIManager:close(dlg)
                    self:removeAccount(id)
                end,
            },
        }},
    }
    showOver(dlg)
end

-- Drop the record. Removing the account currently on screen has to reopen the
-- app on whatever is left, exactly like logging out of it.
function ClaudeUsage:removeAccount(id)
    local was_active = (id == self.accounts.active_id)
    if not self.accounts:remove(id) then return end
    if not was_active then return end   -- the screen still shows the right data
    self:_adoptActiveAccount()
    if self.accounts:active() then
        self:showUsage()
    else
        self:webLogin()
    end
end

-- Settings dialog, reached by tapping the version label: language, refresh
-- interval, accounts, login/logout, quit.
function ClaudeUsage:showSettings()
    local dlg
    local function close_dlg() if dlg then UIManager:close(dlg) end end
    local interval_row = {}
    for _, v in ipairs(INTERVAL_CYCLE) do
        local label = (v == 0) and T("Off") or (v .. "s")
        if v == self.refresh_interval then label = label .. " •" end
        table.insert(interval_row, {
            text = label,
            callback = function()
                close_dlg()
                if self:setRefreshInterval(v) and self.cur_screen then
                    self.cur_screen:rescheduleRefresh()
                    self.cur_screen:rebuild()
                end
            end,
        })
    end
    -- Which account is on screen, and the way to change it without leaving the
    -- app. Same dialog the KUAL "Ver contas" entry opens. Hidden when nothing is
    -- stored yet: there is nothing to switch between, and the row below already
    -- offers the login.
    local switch_row = nil
    local active = self.accounts:active()
    if active then
        switch_row = {{
            text = T("Account") .. ": " .. self.accounts:label(active),
            callback = function() close_dlg(); self:showAccounts() end,
        }}
    end

    -- Standalone app: this dialog replaces the KOReader plugin menu, so the
    -- account actions that used to live there hang off it now.
    local account_row = {}
    if self:hasToken() then
        table.insert(account_row, {
            text = T("Logout (clear token)"),
            -- No confirmation here: reaching this dialog is already deliberate.
            callback = function() close_dlg(); self:doLogout() end,
        })
    else
        table.insert(account_row, {
            text = T("Login (web)"),
            callback = function() close_dlg(); self:webLogin() end,
        })
    end

    local rows = {
        -- Rotation lives on the screen itself now (the arrow button).
        {{
            -- Shows the language in use; tapping switches to the other one.
            text = T("Language") .. ": "
                   .. (i18n.lang() == "pt" and "Português" or "English"),
            callback = function() close_dlg(); self:toggleLanguage() end,
        }},
        {{
            text = self.animations and T("Animations: on") or T("Animations: off"),
            callback = function() close_dlg(); self:toggleAnimations() end,
        }},
        {{
            text = self.prevent_screensaver and T("Keep awake: on") or T("Keep awake: off"),
            callback = function() close_dlg(); self:togglePreventScreensaver() end,
        }},
        interval_row,
    }
    if switch_row then table.insert(rows, switch_row) end
    table.insert(rows, account_row)
    table.insert(rows, {{
        text = T("Quit app"),
        callback = function() close_dlg(); self:closeUI() end,
    }})

    dlg = ButtonDialog:new{
        title = T("Settings"),
        title_align = "center",
        buttons = rows,
    }
    showOver(dlg)
end

-- Show a page by index (1 = dashboard, 2 = models, 3 = 5h trend). Assumes unlocked.
function ClaudeUsage:openPage(idx)
    if idx < 1 or idx > PAGES_IMPL then return end
    if self.cur_screen then
        UIManager:close(self.cur_screen)
        self.cur_screen = nil
    end
    local ScreenCls = (idx == 2) and ModelScreen
                   or (idx == 3) and TrendScreen
                   or UsageScreen
    self.cur_screen = ScreenCls:new{ plugin = self, page_idx = idx }
    UIManager:show(self.cur_screen)
    self:applyRotation()
end

-- Open the fullscreen dashboard, unlocking the token first if needed. The other
-- two pages are reached by swiping or by the nav buttons, both of which go
-- through openPage with the token already unlocked.
function ClaudeUsage:showUsage()
    self:withUnlocked(function() self:openPage(1) end)
end

return ClaudeUsage
