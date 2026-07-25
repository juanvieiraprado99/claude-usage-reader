--[[
Formatting helpers shared by the screens: reading numbers out of the rate-limit
headers, and turning epochs into the short strings the e-ink layout has room for.

Everything here tolerates nil, because a header can be missing (or the whole
response can have failed) and the screens render "--" rather than crashing.
]]--

local i18n = require("i18n")
local T = i18n.t

local M = {}

-- Read a numeric rate-limit header out of the lowercased headers table.
function M.num(h, key)
    local v = h and h[key]
    return v and tonumber(v) or nil
end

-- 0..1 fraction -> "37%"
function M.pct(frac)
    if not frac then return "--%" end
    return string.format("%d%%", math.floor(frac * 100 + 0.5))
end

function M.hm(epoch)
    if not epoch then return "--" end
    return os.date("%H:%M", epoch)
end

-- "THU 18:30" / "QUI 18:30" - the weekday names follow the current language.
function M.resetDate(epoch)
    if not epoch then return "--" end
    local t = os.date("*t", epoch)
    return string.format("%s %02d:%02d", i18n.weekdays()[t.wday] or "--", t.hour, t.min)
end

-- Countdown to a reset: "2H 15M", or "1D 4H" once a day or more is left.
function M.resetIn(epoch)
    if not epoch then return "--" end
    local secs = epoch - os.time()
    if secs < 0 then return T("now") end
    local hrs = math.floor(secs / 3600)
    local mins = math.floor((secs % 3600) / 60)
    if hrs >= 24 then
        return string.format("%dD %dH", math.floor(hrs / 24), hrs % 24)
    end
    return string.format("%dH %dM", hrs, mins)
end

return M
