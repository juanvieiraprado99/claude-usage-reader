--[[
Battery — the Kindle's charge level, as a short string for the header.

The app holds the screensaver off by default (see powersave.lua), so it is the
app most likely to be draining the battery while you watch it, and the one place
that could not tell you how much was left.

TEXT ONLY, on purpose, twice over:

  * KOReader's own `powerd:getBatterySymbol()` returns a Nerd Font glyph, and
    fonts/nerdfonts is stripped by prune.txt - it would render as a tofu box on
    the device while looking fine in the emulator.
  * An IconWidget is worse: it goes IconWidget -> ImageWidget:_loadfile ->
    require("document/documentregistry"), and that module is deleted from the
    shipped runtime. It throws, it is not protected, and the crash is at paint
    time. Same reason roticon.lua draws its own arrow.

No throttle here. BasePowerD already caches the hardware read for 60 seconds,
which is what makes the Kindle path (lipc, then sysfs, then a `gasgauge-info`
popen) cheap enough to call from a rebuild.
]]--

local Device = require("device")

local Battery = {}

-- "87%", or "87%+" while charging. Returns nil when there is nothing honest to
-- show: the SDL build the smoke test runs against reports 0 for "this machine
-- has no battery", and a headless x86 container claiming 0% would be a lie on
-- screen. A real Kindle at 0% is a Kindle that is off.
--
-- pcall'd as a whole: a battery reading is not worth crashing a dashboard over.
function Battery.label()
    local ok, text = pcall(function()
        local powerd = Device:getPowerDevice()
        if not powerd then return nil end
        local pct = powerd:getCapacity()
        if not pct or pct <= 0 then return nil end
        return string.format("%d%%", pct) .. (powerd:isCharging() and "+" or "")
    end)
    if not ok then return nil end
    return text
end

return Battery
