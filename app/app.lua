--[[
Claude Usage - standalone entry point (KUAL app).

Boots the bundled KOReader runtime the way `reader.lua` does, but without the
document engine: set up the environment, init the Device, hand control to the
app Controller, then run the UIManager loop until the app quits.

`bin/claudeusage.sh` sets LUA_PATH/LUA_CPATH/LD_LIBRARY_PATH and chdir's into
runtime/ before exec'ing luajit on this file.
]]--

io.stdout:setvbuf("line")
os.setlocale("C", "numeric")   -- reliable number formatting, same as reader.lua

-- setupkoenv only fixes up package.path/cpath and the ffi loader.
require("setupkoenv")

-- The globals every KOReader module assumes exist. Device probing reads
-- G_reader_settings the moment `device` is required, so these come first.
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

-- `frontend/device.lua` probes the hardware and calls `dev:init()` itself, so
-- requiring it is enough - do NOT init again (see runtime/reader.lua).
-- Every request runs on the UI thread, so without this a server that accepts
-- the connection and then goes quiet freezes the whole app until LuaSocket's
-- own (much longer) default gives up. ssl.https reads this value too.
require("socket.http").TIMEOUT = 10

local Device = require("device")

-- `ui/font` -> `fontlist` asks CanvasContext for two device capabilities while
-- building the font list, and the real module pulls in ffi/mupdf (and with it
-- ~15MB of document-engine libraries we otherwise prune). Preload a stub with
-- exactly what fontlist uses.
-- These are safe to copy because they never touch self - upstream relies on the
-- same property when it assigns them in CanvasContext:init().
package.loaded["document/canvascontext"] = {
    isKindle       = Device.isKindle,
    isAndroid      = Device.isAndroid,
    isDesktop      = Device.isDesktop,
    isEmulator     = Device.isEmulator,
    isPocketBook   = Device.isPocketBook,
    hasSystemFonts = Device.hasSystemFonts,
}

-- reader.lua sets up Bidi before touching any widget, because widgets cache the
-- mirroring flag on first load.
pcall(function() require("ui/bidi").setup() end)

-- The runtime ships with most of its font families pruned, but KOReader's font
-- map and fallback chain still name them - every missing file turns into a
-- freetype error on each repaint. Point anything missing at the one family we
-- do bundle, and drop dead fallbacks. cwd is the runtime root (see the launcher).
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
local Powersave = require("powersave")

-- The UIManager loop does not stop on its own when the last widget closes, and
-- several exit paths (login modal dismissed, error message tapped away) leave
-- an empty stack. A 1s poll used to catch that, but it meant waking the CPU
-- every second for the app's entire lifetime - on top of preventScreenSaver
-- already keeping the Kindle from ever suspending. Every stack removal goes
-- through UIManager:close (openPage's own show happens synchronously right
-- after, so a nextTick recheck won't fire mid-transition), so hook that
-- instead and only fall back to polling - at a much longer interval - for any
-- exotic removal path that bypasses close().
local orig_close = UIManager.close
UIManager.close = function(mgr, ...)
    orig_close(mgr, ...)
    if #mgr._window_stack == 0 then
        mgr:nextTick(function()
            if #mgr._window_stack == 0 then mgr:quit() end
        end)
    end
end

local WATCHDOG_FALLBACK = 15
local function watchEmptyStack()
    if not UIManager._running then return end
    local stack = UIManager._window_stack
    if stack and #stack == 0 then
        UIManager:quit()
        return
    end
    UIManager:scheduleIn(WATCHDOG_FALLBACK, watchEmptyStack)
end

-- Hold off the stock Kindle screensaver while the app is up - the same lipc
-- property KOReader's keepalive plugin sets (app/powersave.lua). Whether to
-- enable it at all is now a setting (default on, same behavior as before);
-- but the disable-on-exit call stays unconditional and lives here regardless,
-- because UIManager:run() returning is the one point every exit passes
-- through (clean quit, empty-stack watchdog, or the xpcall below) - doing it
-- from the controller would leak the flag on a crash and leave the
-- screensaver off until the next reboot. Calling it with 0 when the setting
-- was already off is a harmless no-op.
local app = Controller.new()
Powersave.set(app.prevent_screensaver)
-- Which KUAL menu entry launched us, if any (bin/claudeusage.sh exports it).
-- An unknown value is treated as a plain open, never as an error.
app:start(os.getenv("CU_ACTION"))
UIManager:scheduleIn(WATCHDOG_FALLBACK, watchEmptyStack)

local ok, err = xpcall(function() UIManager:run() end, debug.traceback)

Powersave.set(false)
Device:exit()

if not ok then
    -- The framebuffer is already released here, so print to stderr; the
    -- launcher redirects it to crash.log inside the extension directory.
    io.stderr:write("claudeusage crashed:\n" .. tostring(err) .. "\n")
    os.exit(1)
end
os.exit(0)
