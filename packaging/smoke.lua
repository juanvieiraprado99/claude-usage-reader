--[[
Headless smoke test. Boots the app exactly like app/app.lua does, then drives
the parts a plain startup never touches: all three pages, a forced repaint of
each, and a full rotation cycle.

Booting alone is not enough - with no token the app stops at the login modal, so
a broken dashboard, models or trend page ships unnoticed. That is how a module
name colliding with KOReader's own `version` got through.

Run it the way the Kindle launcher runs app.lua (see packaging/run-docker.sh).
Exits non-zero on the first failure, so CI only has to check the status.
]]--

io.stdout:setvbuf("line")
os.setlocale("C", "numeric")
require("setupkoenv")

G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")

package.loaded["document/canvascontext"] = {
    isKindle       = Device.isKindle,
    isAndroid      = Device.isAndroid,
    isDesktop      = Device.isDesktop,
    isEmulator     = Device.isEmulator,
    isPocketBook   = Device.isPocketBook,
    hasSystemFonts = Device.hasSystemFonts,
}
pcall(function() require("ui/bidi").setup() end)

do
    local Font = require("ui/font")
    local BASE = "NotoSans-Regular.ttf"
    local function present(name)
        local f = io.open("fonts/" .. name, "r")
        if f then f:close() return true end
        return false
    end
    for key, name in pairs(Font.fontmap) do
        if not present(name) then Font.fontmap[key] = BASE end
    end
    local kept = {}
    for _, name in ipairs(Font.fallbacks) do
        if present(name) then kept[#kept + 1] = name end
    end
    Font.fallbacks = kept
end

local UIManager = require("ui/uimanager")
local Controller = require("controller")

local failures = 0
local function check(what, ok, err)
    if ok then
        print("ok   " .. what)
    else
        failures = failures + 1
        print("FAIL " .. what .. ": " .. tostring(err))
    end
end

local function try(what, fn)
    local ok, err = pcall(fn)
    check(what, ok, err)
    return ok
end

local app = Controller.new()

-- No token stored, so this lands on the login modal (QR + LAN receiver).
try("start", function() app:start() end)
check("something on screen", #UIManager._window_stack > 0)
try("repaint login", function() UIManager:_repaint() end)

-- A fake token gets us past the unlock gate; the probe request will fail, and
-- the screens are expected to render their error state rather than blow up.
app.session_token = "sk-ant-oat01-smoke"

for page = 1, 3 do
    try("open page " .. page, function() app:openPage(page) end)
    try("repaint page " .. page, function() UIManager:_repaint() end)
end

for step = 1, 4 do
    try("rotate " .. step, function() app:cycleRotation() end)
    try("repaint after rotate " .. step, function() UIManager:_repaint() end)
end
check("rotation returned to portrait", app.rotation_mode == 0, app.rotation_mode)

local screen = app.cur_screen
check("rotate button built", screen ~= nil and screen.rot_btn ~= nil)
check("version label is a string", type(require("appversion")) == "string")

print(failures == 0 and "SMOKE OK" or ("SMOKE FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
