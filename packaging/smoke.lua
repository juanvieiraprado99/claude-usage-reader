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

-- The settings dialog is the only way to reach login/logout, and it went
-- unreachable once already because nothing called it.
try("settings dialog opens", function() app:showSettings() end)
check("settings dialog on screen", #UIManager._window_stack > 1)

-- fetch() must report failure as (nil, message), never as a truthy result: a
-- non-200 sneaking through renders as a silent "--%".
do
    local h, err = app:fetch("sk-ant-oat01-definitely-not-valid")
    check("fetch reports failure", h == nil and type(err) == "string", err)
end

-- Rasters are cached, so redrawing the same mascot must not re-rasterise.
do
    local Clawd = require("clawd")
    app:openPage(1)
    UIManager:_repaint()
    local before = Clawd.raster_count
    for _ = 1, 5 do
        app.cur_screen:rebuild()
        UIManager:_repaint()
    end
    local drawn = Clawd.raster_count - before
    check("mascot raster cached across rebuilds (" .. drawn .. " draws for 5 rebuilds)",
          drawn == 0, drawn)
end

-- Translation must actually translate, and switching must survive a rebuild.
-- The previous i18n was keyed the wrong way round and silently did nothing, so
-- assert on a real string rather than just "it did not crash".
do
    local i18n = require("i18n")
    i18n.setLang("pt")
    check("pt translates", i18n.t("CLOSE") == "FECHAR", i18n.t("CLOSE"))
    check("pt weekdays", i18n.weekdays()[1] == "DOM", i18n.weekdays()[1])
    i18n.setLang("en")
    check("en passes through", i18n.t("CLOSE") == "CLOSE", i18n.t("CLOSE"))
    check("en weekdays", i18n.weekdays()[1] == "SUN", i18n.weekdays()[1])
    check("unknown msgid falls back to English",
          i18n.t("not a real msgid") == "not a real msgid")

    for _, lang in ipairs({ "pt", "en" }) do
        i18n.setLang(lang)
        for page = 1, 3 do
            try("page " .. page .. " builds in " .. lang, function()
                app:openPage(page)
                UIManager:_repaint()
            end)
        end
    end

    try("language toggle", function() app:toggleLanguage() end)
    try("repaint after toggle", function() UIManager:_repaint() end)
end

-- The weekly series is stored next to the 5h one in the same file. Files
-- written before it existed have no "weekly" key at all and must still load.
do
    local History = require("history")
    local path = DataStorage:getDataDir() .. "/smoke_history.lua"
    os.remove(path)
    local f = assert(io.open(path, "w"))
    f:write('return {\n["samples"] = {\n{["t"] = 1000, ["v"] = 0.25},\n},\n}\n')
    f:close()

    local hist = History.new(path)
    check("old history file still loads", #hist.samples == 1, #hist.samples)
    check("missing weekly key defaults to empty",
          type(hist.weekly) == "table" and #hist.weekly == 0)

    -- The weekly number barely moves, so it is throttled to one sample an hour
    -- while the 5h series takes every fetch.
    local t0 = 2000000
    for i = 0, 4 do
        hist:push(t0 + i * 300, 0.5, 0.6)
    end
    -- 5, not 6: the seeded sample is far older than the 5h window and is pruned.
    check("5h series takes every push", #hist.samples == 5, #hist.samples)
    check("5h series pruned the out-of-window sample",
          hist.samples[1].t == t0, hist.samples[1].t)
    check("weekly series throttled to hourly", #hist.weekly == 1, #hist.weekly)
    hist:push(t0 + 3600, 0.5, 0.61)
    check("weekly series accepts a push an hour later", #hist.weekly == 2, #hist.weekly)
    check("weeklySamples slices on the window",
          #hist:weeklySamples(t0 + 1800) == 1, #hist:weeklySamples(t0 + 1800))
    os.remove(path)
end

-- Burn params are per-window on purpose. The same rising series must read as
-- "will exhaust" over 7d and would be wrongly called "stable" by the 5h floor -
-- 0.02/60 per minute is ~29% a day, which swallows any real weekly burn.
do
    local Burn = require("burn")
    local now = 3000000
    local rising = { { t = now - 24 * 3600, v = 0.4 } }
    local flat   = { { t = now - 24 * 3600, v = 0.499 } }
    local reset  = now + 3 * 24 * 3600

    local p7 = Burn.PARAMS["7d"]
    check("7d rising series projects exhaustion",
          Burn.project(rising, 0.8, now, reset, p7).status == "will_exhaust",
          Burn.project(rising, 0.8, now, reset, p7).status)
    check("7d flat series reads as stable",
          Burn.project(flat, 0.5, now, reset, p7).status == "stable",
          Burn.project(flat, 0.5, now, reset, p7).status)
    check("5h floor would have missed it (why the params are split)",
          Burn.project(rising, 0.8, now, reset, Burn.PARAMS["5h"]).status == "stable")
    check("no history yet says so",
          Burn.project({}, 0.8, now, reset, p7).status == "insufficient")
end

-- Page 3 renders either window, and the chart itself is the toggle.
do
    local i18n = require("i18n")
    for _, lang in ipairs({ "pt", "en" }) do
        i18n.setLang(lang)
        for _, mode in ipairs({ "5h", "7d" }) do
            app.trend_mode = mode
            try("trend page builds in " .. mode .. " / " .. lang, function()
                app:openPage(3)
                UIManager:_repaint()
            end)
        end
    end

    app.trend_mode = "5h"
    app:openPage(3)
    UIManager:_repaint()
    local screen = app.cur_screen
    local frame = screen._chart_frame
    check("chart frame was painted", frame ~= nil and frame.dimen ~= nil)
    if frame and frame.dimen then
        local d = frame.dimen
        local pos = { x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2) }
        try("tapping the chart toggles the window", function()
            screen:onExtraTap(pos, 0)
            UIManager:_repaint()
        end)
        check("toggle switched to 7d", app.trend_mode == "7d", app.trend_mode)
        -- The toggle is a three-state cycle since the heatmap landed, so the
        -- next stop is "heat", not back to "5h". Full cycle is covered below.
        UIManager:_repaint()
        screen:onExtraTap(pos, 0)
        check("toggle advances to the heatmap", app.trend_mode == "heat",
              app.trend_mode)
    end
end

-- Heatmap bucketing is pure, so the interesting cases are cheap to pin down.
-- Each of these encodes a decision that would otherwise be silently reversible.
do
    local Heatmap = require("heatmap")
    -- Anchor mid-block so nothing depends on the test running at midnight.
    local now = os.time{ year = 2026, month = 3, day = 15, hour = 13, min = 0, sec = 0 }
    local function midnight(t)
        local d = os.date("*t", t)
        return os.time{ year = d.year, month = d.month, day = d.day,
                        hour = 0, min = 0, sec = 0, isdst = d.isdst }
    end
    local today = midnight(now)

    -- One interval wholly inside today's 12-18h block (row 3, last column).
    do
        local s = { { t = today + 13 * 3600, v = 0.20 },
                    { t = today + 14 * 3600, v = 0.30 } }
        local cells, max, measured, total = Heatmap.bucket(s, now)
        check("consumption lands in the right block",
              cells[3] and math.abs((cells[3][7] or 0) - 0.10) < 1e-6,
              cells[3] and cells[3][7])
        check("only the covered block is measured", measured == 1, measured)
        check("grid is 7x4", total == 28, total)
        check("max is the busiest block", math.abs(max - 0.10) < 1e-6, max)
    end

    -- A gap spanning two blocks must be SPLIT, not dumped on one: we do not know
    -- when inside the gap the work happened, and a spike would be invented.
    do
        local s = { { t = today + 9 * 3600,  v = 0.0 },
                    { t = today + 15 * 3600, v = 0.60 } }
        local cells = Heatmap.bucket(s, now)
        -- 09:00-12:00 is 3h of row 2; 12:00-15:00 is 3h of row 3. Half each.
        check("a gap is split proportionally across blocks",
              math.abs((cells[2][7] or 0) - 0.30) < 1e-6
              and math.abs((cells[3][7] or 0) - 0.30) < 1e-6,
              (cells[2][7] or 0) .. " / " .. (cells[3][7] or 0))
    end

    -- Unmeasured must stay nil. If it collapsed to 0 the grid would claim the
    -- user was idle during hours nobody ever looked at.
    do
        local s = { { t = today + 13 * 3600, v = 0.2 },
                    { t = today + 14 * 3600, v = 0.3 } }
        local cells = Heatmap.bucket(s, now)
        check("unmeasured blocks are nil, not zero", cells[1][1] == nil)
        check("nil is distinguishable from a measured zero", (cells[1][1] or 0) == 0
              and cells[1][1] ~= 0)
    end

    -- A drop means the weekly window reset between samples; attribute what came
    -- after the reset rather than a negative number.
    do
        local s = { { t = today + 13 * 3600, v = 0.90 },
                    { t = today + 14 * 3600, v = 0.05 } }
        local cells, max = Heatmap.bucket(s, now)
        check("a reset counts as post-reset usage, never negative",
              (cells[3][7] or -1) >= 0 and math.abs(cells[3][7] - 0.05) < 1e-6,
              cells[3][7])
        check("max stays non-negative after a reset", max >= 0, max)
    end

    -- Empty input must not blow up or claim coverage.
    do
        local cells, max, measured = Heatmap.bucket({}, now)
        check("empty series measures nothing", measured == 0 and max == 0)
        check("empty series still returns a grid", cells[1] ~= nil)
    end

    try("heatmap widget builds", function()
        local cells, max = Heatmap.bucket({ { t = today, v = 0.1 },
                                            { t = today + 7200, v = 0.4 } }, now)
        local wg = Heatmap.makeWidget{ w = 210, h = 120, cells = cells, max = max }
        wg:free()
    end)
end

-- Page 3 renders the heatmap, and the tap cycles all three views.
do
    local i18n = require("i18n")
    for _, lang in ipairs({ "pt", "en" }) do
        i18n.setLang(lang)
        app.trend_mode = "heat"
        try("heatmap page builds in " .. lang, function()
            app:openPage(3)
            UIManager:_repaint()
        end)
    end

    i18n.setLang("pt")
    app.trend_mode = "heat"
    app:openPage(3)
    UIManager:_repaint()
    local screen = app.cur_screen
    check("heatmap coverage line is populated",
          type(screen:heatCoverage()) == "string" and #screen:heatCoverage() > 0)
    check("heatmap legend is populated",
          type(screen:heatLegend()) == "string" and #screen:heatLegend() > 0)

    -- The grid plus its gutter and weekday labels must not run off the screen -
    -- the same class of overflow the LOGOUT pill caused in the bottom bar.
    local d = screen._chart_frame and screen._chart_frame.dimen
    check("heatmap frame fits in portrait",
          d ~= nil and d.x >= 0 and d.x + d.w <= screen.width,
          d and (d.x .. "+" .. d.w .. " vs " .. screen.width))
    app:cycleRotation()
    UIManager:_repaint()
    screen = app.cur_screen
    d = screen._chart_frame and screen._chart_frame.dimen
    check("heatmap frame fits in landscape",
          d ~= nil and d.x >= 0 and d.x + d.w <= screen.width,
          d and (d.x .. "+" .. d.w .. " vs " .. screen.width))
    app:cycleRotation(); app:cycleRotation(); app:cycleRotation()
    UIManager:_repaint()
    screen = app.cur_screen

    app.trend_mode = "5h"
    screen:rebuild()
    UIManager:_repaint()
    -- rebuild() replaces the frame, and .dimen is only set by paintTo - so the
    -- repaint between taps is required, exactly as the real loop does it after
    -- setDirty. Without it the second tap hit-tests a frame that was never
    -- painted and silently misses.
    local function tapChart()
        local d = screen._chart_frame.dimen
        screen:onExtraTap({ x = d.x + math.floor(d.w / 2),
                            y = d.y + math.floor(d.h / 2) }, 0)
        UIManager:_repaint()
    end
    tapChart()
    check("tap 1 goes to 7d", app.trend_mode == "7d", app.trend_mode)
    tapChart()
    check("tap 2 goes to heatmap", app.trend_mode == "heat", app.trend_mode)
    tapChart()
    check("tap 3 wraps back to 5h", app.trend_mode == "5h", app.trend_mode)
end

-- Logout is reachable from the bottom bar, not only from the settings dialog
-- behind the version label. hasToken() reads the stored blob, so the button is
-- absent for the whole run above - stub the blob to get the other state.
do
    local i18n = require("i18n")
    i18n.setLang("pt")
    app.settings:saveSetting("enc", "not-a-real-blob")
    check("token now looks stored", app:hasToken())

    app:openPage(1)
    UIManager:_repaint()
    local screen = app.cur_screen
    check("logout button is built when a token exists", screen.logout_btn ~= nil)

    -- An extra pill in a bar that already carries rotate + 3 nav buttons + the
    -- version is exactly how a portrait layout starts overflowing off-screen.
    for _, what in ipairs({ "logout_btn", "ver_btn" }) do
        local w = screen[what]
        local d = w and w.dimen
        check(what .. " fits inside the screen",
              d ~= nil and d.x >= 0 and d.x + d.w <= screen.width,
              d and (d.x .. "+" .. d.w .. " vs " .. screen.width))
    end

    -- ...and again in landscape, where the bar is wider but the body is not.
    app:cycleRotation()
    UIManager:_repaint()
    screen = app.cur_screen
    do
        local d = screen.logout_btn and screen.logout_btn.dimen
        check("logout button fits in landscape too",
              d ~= nil and d.x + d.w <= screen.width,
              d and (d.x .. "+" .. d.w .. " vs " .. screen.width))
    end
    app:cycleRotation(); app:cycleRotation(); app:cycleRotation()
    UIManager:_repaint()
    screen = app.cur_screen

    -- Destructive and one tap from the nav buttons, so it must ask first.
    local d = screen.logout_btn.dimen
    local pos = { x = d.x + math.floor(d.w / 2), y = d.y + math.floor(d.h / 2) }
    local before = #UIManager._window_stack
    try("tapping logout opens a confirmation", function()
        screen:onTap({ pos = pos })
    end)
    check("confirmation is on screen", #UIManager._window_stack > before)
    check("token survives until confirmed", app:hasToken())

    -- Order matters, not just presence: the pages are modal, and UIManager puts
    -- a non-modal widget BELOW any modal one - i.e. under a fullscreen opaque
    -- frame, where it is painted and never seen. A popup must land on top.
    local top = UIManager._window_stack[#UIManager._window_stack].widget
    check("confirmation is above the page, not under it", top ~= screen,
          top == screen and "dialog went below the fullscreen page" or nil)

    -- ConfirmBox would have been the obvious widget, but it draws an icon and
    -- that path is pruned from the shipped runtime - hence a ButtonDialog with
    -- an explicit cancel/confirm row.
    local box = top
    local row = box and box.buttons and box.buttons[1]
    check("confirmation offers cancel and confirm", row ~= nil and #row == 2,
          row and #row)
    if row then
        try("cancelling leaves the token alone", function() row[1].callback() end)
        check("token survives a cancel", app:hasToken())

        screen:onTap({ pos = pos })
        local again = UIManager._window_stack[#UIManager._window_stack].widget
        try("confirming clears the token", function()
            again.buttons[1][2].callback()
        end)
        check("token is gone after confirming", not app:hasToken())
    end

    app.settings:delSetting("enc")
    app.settings:flush()
    app:openPage(1)
    UIManager:_repaint()
    check("logout button is absent without a token",
          app.cur_screen.logout_btn == nil)
end

print(failures == 0 and "SMOKE OK" or ("SMOKE FAILED (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
