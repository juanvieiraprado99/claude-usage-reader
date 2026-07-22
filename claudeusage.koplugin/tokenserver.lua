--[[
TokenServer — tiny non-blocking LAN HTTP receiver for the Claude token.

Lets the user paste a `claude setup-token` value (sk-ant-oat01-...) from a phone
or PC on the same WiFi, instead of typing it on the Kindle. A 4-digit PIN shown
on the Kindle gates the submit. Plaintext HTTP on the LAN only; the server is
transient (stop on success / cancel / timeout). KOReader's loop is single
threaded, so accept is non-blocking and polled via UIManager.

    local TokenServer = require("tokenserver")
    local srv = TokenServer:new{ port=8099, pin="1234",
        on_token = function(tok) ... end,
        on_error = function(msg) ... end }
    srv:start()
    ... srv:stop()
]]--

local socket = require("socket")
local UIManager = require("ui/uimanager")
local T = require("i18n").t

local TokenServer = {}
TokenServer.__index = TokenServer

local POLL_EVERY = 0.25

function TokenServer:new(o)
    o = o or {}
    o.port = o.port or 8099
    setmetatable(o, self)
    return o
end

-- Best-effort LAN IP via a UDP socket (no packet is actually sent).
function TokenServer.get_ip()
    local u = socket.udp()
    if not u then return nil end
    u:setpeername("8.8.8.8", 80)
    local ip = u:getsockname()
    u:close()
    if ip == "0.0.0.0" then return nil end
    return ip
end

local function urldecode(s)
    if not s then return "" end
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return s
end

local function form_field(body, name)
    -- application/x-www-form-urlencoded: name=val&name2=val2
    for k, v in body:gmatch("([^&=]+)=([^&]*)") do
        if urldecode(k) == name then return urldecode(v) end
    end
    return nil
end

local STYLE = "<style>body{font-family:sans-serif;max-width:34rem;margin:2rem auto;"
    .. "padding:0 1rem}textarea,input{width:100%;box-sizing:border-box;font-size:1rem;"
    .. "padding:.5rem}button{font-size:1rem;padding:.6rem 1.2rem;margin-top:1rem}"
    .. "small{color:#666}</style>"

local function html_escape(s)
    return (tostring(s or ""):gsub("[&<>\"]", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ["\""] = "&quot;" }))
end

-- Render the localized form page with an optional pre-filled PIN and message.
local function form_page(pin, msg)
    local title = T("Claude Usage — send token")
    return table.concat({
        "<!doctype html><html><head><meta charset=utf-8>",
        "<meta name=viewport content=\"width=device-width,initial-scale=1\">",
        "<title>", title, "</title>", STYLE, "</head><body>",
        "<h2>", title, "</h2>",
        "<p><small>", T("On your PC run <code>claude setup-token</code>, copy the <code>sk-ant-oat01-...</code>, paste it below and enter the PIN shown on the Kindle."), "</small></p>",
        "<form method=POST action=/save>",
        "<label>", T("Token"), "</label>",
        "<textarea name=token rows=4 placeholder=\"sk-ant-oat01-...\"></textarea>",
        "<label>", T("PIN (4 digits)"), "</label>",
        "<input name=pin inputmode=numeric maxlength=4 value=\"", html_escape(pin), "\">",
        "<button type=submit>", T("Submit"), "</button></form>",
        msg or "", "</body></html>",
    })
end

local function ok_page()
    return "<!doctype html><meta charset=utf-8>"
        .. "<body style=\"font-family:sans-serif;text-align:center;margin-top:3rem\">"
        .. "<h2>&#10003;</h2><p>"
        .. T("Token received. Return to the Kindle; you can close this page.")
        .. "</p></body>"
end

-- Pull the `k` query param from a GET path like "/?k=1234".
local function query_pin(path)
    return path and path:match("[?&]k=([^&]+)")
end

local function http_response(status, body, ctype)
    return "HTTP/1.1 " .. status .. "\r\n" ..
        "Content-Type: " .. (ctype or "text/html; charset=utf-8") .. "\r\n" ..
        "Content-Length: " .. tostring(#body) .. "\r\n" ..
        "Connection: close\r\n\r\n" .. body
end

function TokenServer:start()
    local srv, err = socket.bind("*", self.port)
    if not srv then
        if self.on_error then self.on_error("bind: " .. tostring(err)) end
        return false
    end
    srv:settimeout(0)
    self.server = srv
    self.running = true
    self.poll_task = function() self:poll() end
    UIManager:scheduleIn(POLL_EVERY, self.poll_task)
    return true
end

function TokenServer:stop()
    self.running = false
    if self.poll_task then UIManager:unschedule(self.poll_task) end
    if self.server then self.server:close(); self.server = nil end
end

-- Read one request (line + headers, and body for POST). Blocking up to 2s on the
-- accepted client only (connections are rare); returns method, path, body.
local function read_request(client)
    client:settimeout(2)
    local line = client:receive("*l")
    if not line then return nil end
    local method, path = line:match("^(%u+)%s+(%S+)")
    local clen = 0
    while true do
        local hl = client:receive("*l")
        if not hl or hl == "" then break end
        local n = hl:lower():match("^content%-length:%s*(%d+)")
        if n then clen = tonumber(n) end
    end
    local body = ""
    if method == "POST" and clen > 0 then
        body = client:receive(clen) or ""
    end
    return method, path, body
end

function TokenServer:poll()
    if not self.running or not self.server then return end
    local client = self.server:accept()
    if client then
        local method, path, body = read_request(client)
        if method == "POST" and path == "/save" then
            local token = (form_field(body, "token") or ""):gsub("^%s+", ""):gsub("%s+$", "")
            local pin = form_field(body, "pin") or ""
            if pin ~= tostring(self.pin) then
                client:send(http_response("200 OK",
                    form_page(pin, "<p style='color:#b00'>" .. T("Wrong PIN.") .. "</p>")))
                client:close()
            elseif token == "" then
                client:send(http_response("200 OK",
                    form_page(pin, "<p style='color:#b00'>" .. T("Empty token.") .. "</p>")))
                client:close()
            else
                client:send(http_response("200 OK", ok_page()))
                client:close()
                if self.on_token then self.on_token(token) end
                self:stop()
                return   -- do not reschedule
            end
        elseif method == "GET" and path
                and (path == "/" or path == "/index.html" or path:match("^/%?")) then
            client:send(http_response("200 OK", form_page(query_pin(path), "")))
            client:close()
        else
            client:send(http_response("404 Not Found", "not found", "text/plain"))
            client:close()
        end
    end
    if self.running then
        UIManager:scheduleIn(POLL_EVERY, self.poll_task)
    end
end

return TokenServer
