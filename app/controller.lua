--[[
Claude Usage - app controller (standalone KUAL app)
Probes api.anthropic.com with max_tokens:1 and reads the
anthropic-ratelimit-unified-* response headers. Costs ~1 token per refresh.

Token: run `claude setup-token` on your PC, paste the sk-ant-oat01-... value
into the plugin (Menu -> Claude Usage -> Set token). Stored locally.

Auto-refresh: pick 5/10/15/30s. Each tick is one probe (~1 token). Changing the
interval is rate-limited to once per 2 seconds.
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
local LoginModal = require("loginmodal")
local TokenServer = require("tokenserver")
local NetworkMgr = require("ui/network/manager")
local ButtonDialog = require("ui/widget/buttondialog")
local Screen = require("device").screen
local Crypto = require("crypto")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local socket = require("socket")
local T = require("i18n").t

local ENDPOINT = "https://api.anthropic.com/v1/messages"
local STATUS_ENDPOINT = "https://status.claude.com/api/v2/incidents/unresolved.json"
local PROBE_MODEL = "claude-haiku-4-5-20251001"
local CHANGE_COOLDOWN = 2              -- seconds between interval changes
local LOGIN_PORT = 8099               -- LAN web receiver for the token
local MAX_FAILS = 8                   -- wrong PIN tries before wiping the token

-- Models probed (rotated one-per-cycle) on the Models screen.
local MODELS = {
    { id = "claude-haiku-4-5-20251001", name = "Haiku"  },
    { id = "claude-sonnet-5",           name = "Sonnet" },
    { id = "claude-opus-4-8",           name = "Opus"   },
    { id = "claude-fable-5",            name = "Fable"  },
}
local PAGES_IMPL = 3                   -- navigable pages (dashboard, models, 5h trend)
local DOTS_TOTAL = 4                   -- carousel dots shown (extra = placeholder)
local INTERVAL_CYCLE = { 0, 5, 10, 15, 30 }
local ROTA_PORTRAIT = Screen.DEVICE_ROTATED_UPRIGHT or 0

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
    self.refresh_interval = self.settings:readSetting("refresh_interval") or 0
    self.change_locked = false
    -- Exposed to the screens (page nav + model list).
    self.MODELS = MODELS
    self.PAGES_IMPL = PAGES_IMPL
    self.DOTS_TOTAL = DOTS_TOTAL
    self._probe_idx = 0
    self._model_results = {}
    self._incidents = nil
    self.history = History.new(DATA_DIR .. "/claudeusage_history.lua")
    -- Rotation is a KOReader screen mode: 0 portrait, 1 landscape,
    -- 2 portrait upside down, 3 landscape upside down. Remembered across runs.
    self.rotation_mode = self.settings:readSetting("rotation_mode") or ROTA_PORTRAIT
    self.cur_screen = nil
    -- Stable callback ref so UIManager:unschedule works.
    self.unlock_task = function() self.change_locked = false end
end

-- App entry point, called by app.lua before UIManager:run(). Something must be
-- on the stack before the loop starts, otherwise UIManager exits immediately.
function ClaudeUsage:start()
    if not self:hasToken() then
        self:webLogin()
    else
        self:showUsage()
    end
end

function ClaudeUsage:hasToken()
    return self.settings:readSetting("enc") ~= nil
end

function ClaudeUsage:isUnlocked()
    return self.session_token ~= nil
end

function ClaudeUsage:logout()
    self.settings:delSetting("enc")
    self.settings:delSetting("pin_fail")
    self.settings:flush()
    self.session_token = nil
    UIManager:show(InfoMessage:new{ text = T("Token cleared.") })
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
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Decrypt the stored token with a PIN; caches it in RAM for this session.
function ClaudeUsage:promptUnlock(on_ok)
    self:promptPin(T("Locked — enter your PIN."), function(pin)
        local blob = self.settings:readSetting("enc")
        local tok = Crypto.decrypt(blob, pin)
        if tok then
            self.session_token = tok
            self.settings:saveSetting("pin_fail", 0)
            self.settings:flush()
            if on_ok then on_ok() end
        else
            local fails = (self.settings:readSetting("pin_fail") or 0) + 1
            if fails >= MAX_FAILS then
                self:logout()
                UIManager:show(InfoMessage:new{ text = T("Too many attempts — token wiped.") })
            else
                self.settings:saveSetting("pin_fail", fails)
                self.settings:flush()
                UIManager:show(InfoMessage:new{ text = T("Wrong PIN.") })
            end
        end
    end)
end

-- Encrypt a freshly-received token under a new PIN and store it.
function ClaudeUsage:setPinAndStore(tok)
    if not Crypto.available() then
        UIManager:show(InfoMessage:new{ text = T("Encryption unavailable — cannot store.") })
        return
    end
    self:promptPin(T("Create a 4-digit PIN"), function(pin)
        if not pin or pin == "" then return end
        local blob = Crypto.encrypt(tok, pin)
        if not blob then
            UIManager:show(InfoMessage:new{ text = T("Encryption unavailable — cannot store.") })
            return
        end
        self.settings:saveSetting("enc", blob)
        self.settings:saveSetting("pin_fail", 0)
        self.settings:delSetting("token")   -- drop any legacy plaintext
        self.settings:flush()
        self.session_token = tok
        self:showUsage()   -- success -> go straight to the dashboard
    end)
end

-- Show the QR login modal (LAN receiver + 5-min rotating URL/PIN/QR). Guards
-- against stacking (also called automatically by UsageScreen on token expiry).
function ClaudeUsage:webLogin()
    if self.login_open then return end
    -- NetworkMgr is a KOReader-app service; outside its usual host it may throw.
    -- Only block on a *definite* "not connected" answer, never on an error.
    if NetworkMgr and NetworkMgr.isConnected then
        local ok, connected = pcall(function() return NetworkMgr:isConnected() end)
        if ok and not connected then
            UIManager:show(InfoMessage:new{ text = T("Connect the Kindle to WiFi first.") })
            return
        end
    end
    local ip = TokenServer.get_ip()
    if not ip then
        UIManager:show(InfoMessage:new{ text = T("No network IP. Check WiFi.") })
        return
    end
    self.login_open = true
    UIManager:show(LoginModal:new{
        ip = ip,
        port = LOGIN_PORT,
        on_token = function(tok)
            -- Validate the token before storing it (reject junk/expired).
            if not self:probeToken(tok) then
                UIManager:show(InfoMessage:new{ text = T("Invalid token (rejected).") })
                return
            end
            self:setPinAndStore(tok)
        end,
        on_close = function() self.login_open = false end,
    })
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
        UIManager:show(InfoMessage:new{
            text = string.format(T("Wait %d s before changing again."), CHANGE_COOLDOWN),
            timeout = 1,
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

-- Fetch usage. Uses `arg_token` if given, else the unlocked session token.
-- Returns (headers, code) on success, or (nil, err, auth_expired) where
-- auth_expired is true when the token is rejected (401/403).
function ClaudeUsage:fetch(arg_token)
    local token = arg_token or self.session_token
    if not token or token == "" then
        return nil, T("No token. Use 'Login (web)'.")
    end

    local body = string.format(
        '{"model":"%s","max_tokens":1,"messages":[{"role":"user","content":"."}]}',
        PROBE_MODEL)

    local resp = {}
    local ok, code, headers = https.request{
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

    if not ok then
        return nil, T("Request failed: ") .. tostring(code)
    end
    if code == 401 or code == 403 then
        return nil, T("token expired"), true   -- auth_expired
    end
    -- headers has lowercased keys per luasocket
    return headers, code
end

-- Probe one specific model; returns { code, ms, auth }. Body discarded (~1 token).
function ClaudeUsage:fetchModelProbe(model_id)
    local token = self.session_token
    if not token or token == "" then return { code = 0 } end

    local body = string.format(
        '{"model":"%s","max_tokens":1,"messages":[{"role":"user","content":"."}]}',
        model_id)

    local t0 = socket.gettime()
    local resp = {}
    local ok, code = https.request{
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
    local body = table.concat(resp):lower()
    local up = {}
    for _, m in ipairs(MODELS) do
        -- name absent from the incident feed => model is up
        up[m.name] = (body:find(m.name:lower(), 1, true) == nil)
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

-- Probe the next model in rotation. Returns (idx, auth).
function ClaudeUsage:refreshNextModel()
    local idx = (self._probe_idx % #MODELS) + 1
    self._probe_idx = idx
    local res = self:fetchModelProbe(MODELS[idx].id)
    self._model_results[idx] = res
    self:maybeFetchIncidents()
    return idx, res.auth == true
end

-- Probe ALL models in one shot (eager). Returns auth.
-- ~4 tokens and ~6-12s on a Kindle (sequential HTTPS), so the UI blocks briefly.
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

-- Models screen entry point: eager only while some model has never been
-- probed; after that, rotate one model per cycle (4x fewer tokens/requests).
function ClaudeUsage:refreshModels()
    for i = 1, #MODELS do
        if not self._model_results[i] then
            return self:refreshAllModels()
        end
    end
    local _idx, auth = self:refreshNextModel()
    return auth
end

-- Ensure the token is unlocked, then run cb().
function ClaudeUsage:withUnlocked(cb)
    if not self:hasToken() then
        UIManager:show(InfoMessage:new{ text = T("Please log in first.") })
        return
    end
    if not self:isUnlocked() then
        self:promptUnlock(cb)
        return
    end
    cb()
end

-- Record a 5h-utilization sample for the trend screen's history.
function ClaudeUsage:recordSample(v)
    if v then self.history:push(os.time(), v) end
end

-- Apply the app's rotation choice to the device (affects all pages).
-- Standalone: there is no reader view to handle a SetRotationMode event, so we
-- drive the Screen directly and force a full repaint.
function ClaudeUsage:applyRotation()
    if Screen:getRotationMode() ~= self.rotation_mode then
        Screen:setRotationMode(self.rotation_mode)
    end
    UIManager:setDirty("all", "full")
end

-- Quarter turn per tap, all the way around: portrait -> landscape ->
-- portrait upside down -> landscape upside down -> portrait.
function ClaudeUsage:cycleRotation()
    self.rotation_mode = (self.rotation_mode + 1) % 4
    self.settings:saveSetting("rotation_mode", self.rotation_mode)
    self.settings:flush()
    self:applyRotation()
    if self.cur_screen then self.cur_screen:rebuild() end
end

-- Advance the auto-refresh interval to the next value in the cycle.
function ClaudeUsage:cycleInterval()
    local cur = self.refresh_interval
    local nxt = INTERVAL_CYCLE[1]
    for i, v in ipairs(INTERVAL_CYCLE) do
        if v == cur then nxt = INTERVAL_CYCLE[(i % #INTERVAL_CYCLE) + 1]; break end
    end
    if self:setRefreshInterval(nxt) and self.cur_screen then
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

-- Settings dialog (gear icon): rotation, refresh interval, close app.
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
    -- Standalone app: this dialog replaces the KOReader plugin menu, so the
    -- account actions that used to live there hang off it now.
    local account_row = {}
    if self:hasToken() then
        table.insert(account_row, {
            text = T("Logout (clear token)"),
            callback = function()
                close_dlg()
                self:logout()
                if self.cur_screen then
                    UIManager:close(self.cur_screen)
                    self.cur_screen = nil
                end
                self:webLogin()   -- back to the login modal, app stays alive
            end,
        })
    else
        table.insert(account_row, {
            text = T("Login (web)"),
            callback = function() close_dlg(); self:webLogin() end,
        })
    end

    dlg = ButtonDialog:new{
        title = T("Configuracoes"),
        title_align = "center",
        buttons = {
            -- Rotation lives on the screen itself now (the arrow button).
            interval_row,
            account_row,
            {{
                text = T("Fechar app"),
                callback = function() close_dlg(); self:closeUI() end,
            }},
        },
    }
    UIManager:show(dlg)
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

-- Open the fullscreen dashboard, unlocking the token first if needed.
function ClaudeUsage:showUsage()
    self:withUnlocked(function() self:openPage(1) end)
end

-- Open the Models screen, unlocking the token first if needed.
function ClaudeUsage:showModels()
    self:withUnlocked(function() self:openPage(2) end)
end

-- Open the 5h-window trend screen, unlocking the token first if needed.
function ClaudeUsage:showTrend()
    self:withUnlocked(function() self:openPage(3) end)
end

return ClaudeUsage
