--[[
History — a small persisted ring buffer of 5h-window utilization samples,
used by the "Janela de 5h" trend screen (Page 3).

Each sample is { t = epoch_seconds, v = utilization_0_to_1 }. Samples are
pruned to the last 5 hours and capped at MAX entries. Persisted via LuaSettings
in its own file (claudeusage_history.lua) so it can be wiped without touching
the token. No background loop: samples are only added when a screen fetches.
]]--

local LuaSettings = require("luasettings")

local WINDOW = 5 * 3600     -- keep at most the last 5 hours
local MAX = 160             -- hard cap on stored samples

local History = {}
History.__index = History

local FLUSH_EVERY = 60      -- max one flash write per minute (e-ink flash wear)

function History.new(path)
    local self = setmetatable({}, History)
    self.settings = LuaSettings:open(path)
    self.samples = self.settings:readSetting("samples") or {}
    self._last_flush = 0
    return self
end

-- Drop samples older than the 5h window and enforce the size cap.
function History:_prune(now)
    local cutoff = now - WINDOW
    while self.samples[1] and self.samples[1].t < cutoff do
        table.remove(self.samples, 1)
    end
    while #self.samples > MAX do
        table.remove(self.samples, 1)
    end
end

-- Force-write to disk (called on plugin close; throttled writes elsewhere).
function History:flush()
    self.settings:saveSetting("samples", self.samples)
    self.settings:flush()
    self._last_flush = os.time()
end

-- Append a sample. Persists at most once per FLUSH_EVERY seconds — pushing on
-- every fetch (as often as every 5s) would wear the Kindle's flash.
function History:push(t, v)
    if not v then return end
    t = t or os.time()
    self.samples[#self.samples + 1] = { t = t, v = v }
    self:_prune(t)
    if t - self._last_flush >= FLUSH_EVERY then
        self:flush()
    end
end

-- Return samples at or after win_start (already chronological).
function History:windowSamples(win_start)
    local out = {}
    for _, s in ipairs(self.samples) do
        if s.t >= win_start then out[#out + 1] = s end
    end
    return out
end

return History
