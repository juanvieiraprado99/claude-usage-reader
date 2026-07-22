--[[
Claude Usage - KOReader plugin
Probes api.anthropic.com with max_tokens:1 and reads the
anthropic-ratelimit-unified-* response headers. Costs ~1 token per refresh.

Token: run `claude setup-token` on your PC, paste the sk-ant-oat01-... value
into the plugin (Menu -> Claude Usage -> Set token). Stored locally.

Auto-refresh: pick 5/10/15/30s. Each tick is one probe (~1 token). Changing the
interval is rate-limited to once per 2 seconds.
]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UsageScreen = require("usagescreen")
local LoginModal = require("loginmodal")
local TokenServer = require("tokenserver")
local NetworkMgr = require("ui/network/manager")
local Crypto = require("crypto")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local T = require("i18n").t

local ENDPOINT = "https://api.anthropic.com/v1/messages"
local PROBE_MODEL = "claude-haiku-4-5-20251001"
local CHANGE_COOLDOWN = 2              -- seconds between interval changes
local LOGIN_PORT = 8099               -- LAN web receiver for the token
local MAX_FAILS = 8                   -- wrong PIN tries before wiping the token

local ClaudeUsage = WidgetContainer:extend{
    name = "claudeusage",
    is_doc_only = false,
}

function ClaudeUsage:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/claudeusage.lua")
    self.refresh_interval = self.settings:readSetting("refresh_interval") or 0
    self.change_locked = false
    -- Stable callback ref so UIManager:unschedule works.
    self.unlock_task = function() self.change_locked = false end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function ClaudeUsage:onDispatcherRegisterActions()
    Dispatcher:registerAction("claudeusage_show", {
        category = "none",
        event = "ClaudeUsageShow",
        title = T("Show Claude usage"),
        general = true,
    })
end

function ClaudeUsage:addToMainMenu(menu_items)
    menu_items.claudeusage = {
        text = "Claude Usage",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = T("Show usage"),
                keep_menu_open = true,
                enabled_func = function() return self:hasToken() end,
                callback = function() self:showUsage() end,
            },
            {
                text = T("Login (web)"),
                keep_menu_open = true,
                callback = function() self:webLogin() end,
            },
            {
                text = T("Logout (clear token)"),
                keep_menu_open = true,
                enabled_func = function() return self:hasToken() end,
                callback = function() self:logout() end,
            },
        },
    }
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
    if NetworkMgr and NetworkMgr.isConnected and not NetworkMgr:isConnected() then
        UIManager:show(InfoMessage:new{ text = T("Connect the Kindle to WiFi first.") })
        return
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

function ClaudeUsage:onClaudeUsageShow()
    self:showUsage()
    return true
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

function ClaudeUsage:onCloseWidget()
    UIManager:unschedule(self.unlock_task)
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

-- Open the fullscreen dashboard, unlocking the token first if needed.
function ClaudeUsage:showUsage()
    if not self:hasToken() then
        UIManager:show(InfoMessage:new{ text = T("Please log in first.") })
        return
    end
    if not self:isUnlocked() then
        self:promptUnlock(function()
            UIManager:show(UsageScreen:new{ plugin = self })
        end)
        return
    end
    UIManager:show(UsageScreen:new{ plugin = self })
end

return ClaudeUsage
