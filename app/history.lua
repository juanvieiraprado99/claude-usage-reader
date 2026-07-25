--[[
History — persisted ring buffers of utilization samples, used by the trend
screen (Page 3), which plots either window.

Two series, because the two rate-limit windows move at completely different
speeds:

  samples  5h-window utilization, every fetch, kept 5 hours
  weekly   7d-window utilization, at most hourly, kept 7 days

Each sample is { t = epoch_seconds, v = utilization_0_to_1 }. Persisted via
LuaSettings in its own file (claudeusage_history.lua) so it can be wiped without
touching the token.

No background loop: samples are only added when a screen fetches, i.e. while the
app is open. The weekly series is persisted across sessions so it does fill in
over days, but someone who opens the app once a day will see isolated points
rather than a curve, and the projection will say "collecting data" until two
samples land far enough apart inside the window.
]]--

local LuaSettings = require("luasettings")

local WINDOW = 5 * 3600         -- 5h series: keep at most the last 5 hours
local MAX = 160                 -- hard cap on stored 5h samples

local WINDOW_7D = 7 * 24 * 3600 -- weekly series: keep at most the last 7 days
local MAX_7D = 200              -- hourly over 7 days is 168, so this is slack
local MIN_GAP_7D = 3600         -- and this is what enforces "hourly"

local History = {}
History.__index = History
History.WINDOW = WINDOW           -- the trend screen plots exactly these spans
History.WINDOW_7D = WINDOW_7D

local FLUSH_EVERY = 60      -- max one flash write per minute (e-ink flash wear)

function History.new(path)
    local self = setmetatable({}, History)
    self.settings = LuaSettings:open(path)
    self.samples = self.settings:readSetting("samples") or {}
    -- Absent in files written before the weekly series existed.
    self.weekly = self.settings:readSetting("weekly") or {}
    -- Start the throttle now, not at the epoch: otherwise the very first push
    -- always writes to flash.
    self._last_flush = os.time()
    return self
end

-- Drop samples older than the window and enforce the size cap.
local function prune(list, window, max, now)
    local cutoff = now - window
    while list[1] and list[1].t < cutoff do
        table.remove(list, 1)
    end
    while #list > max do
        table.remove(list, 1)
    end
end

-- Force-write to disk (called on plugin close; throttled writes elsewhere).
function History:flush()
    self.settings:saveSetting("samples", self.samples)
    self.settings:saveSetting("weekly", self.weekly)
    self.settings:flush()
    self._last_flush = os.time()
end

-- Append a sample to each series. Persists at most once per FLUSH_EVERY
-- seconds — pushing on every fetch (as often as every 5s) would wear the
-- Kindle's flash.
function History:push(t, v5, v7)
    if not v5 and not v7 then return end
    t = t or os.time()

    if v5 then
        self.samples[#self.samples + 1] = { t = t, v = v5 }
        prune(self.samples, WINDOW, MAX, t)
    end

    -- The weekly number barely moves between fetches, so one point an hour is
    -- plenty and keeps the series inside MAX_7D. A negative gap means the clock
    -- jumped backwards (the Kindle syncs time on wake); accept the sample, or
    -- the series would stay wedged until real time caught up again.
    if v7 then
        local last = self.weekly[#self.weekly]
        local gap = last and (t - last.t) or nil
        if not gap or gap >= MIN_GAP_7D or gap < 0 then
            self.weekly[#self.weekly + 1] = { t = t, v = v7 }
            prune(self.weekly, WINDOW_7D, MAX_7D, t)
        end
    end

    -- Same backwards-clock guard, for the flush throttle itself.
    local since = t - self._last_flush
    if since >= FLUSH_EVERY or since < 0 then
        self:flush()
    end
end

-- Return samples at or after win_start (already chronological).
local function sliceFrom(list, win_start)
    local out = {}
    for _, s in ipairs(list) do
        if s.t >= win_start then out[#out + 1] = s end
    end
    return out
end

function History:windowSamples(win_start)
    return sliceFrom(self.samples, win_start)
end

function History:weeklySamples(win_start)
    return sliceFrom(self.weekly, win_start)
end

return History
