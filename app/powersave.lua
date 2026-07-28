--[[
Single place for the "hold off the Kindle screensaver" lipc call, shared by
app.lua (unconditional disable on every exit path) and controller.lua (the
live on/off toggle in the settings dialog). Not named screensaver.lua: the
runtime already ships frontend/ui/screensaver.lua (KOReader's own screensaver
widget) - same reason appversion.lua isn't called version.lua.
]]--

local Device = require("device")

local M = {}

function M.set(enable)
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (enable and 1 or 0))
    end
end

return M
