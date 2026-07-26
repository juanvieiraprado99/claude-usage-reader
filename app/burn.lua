--[[
Burn — the rate-at-which-you-are-spending-the-window projection behind the
trend screen's verdict line.

Fits a straight line through two points of the stored history (the current
sample and the newest one at least `rate_window` old), extrapolates to 100%, and
compares that against the window's reset. Two points, not a least-squares fit:
the series is short, noisy and sometimes has holes, and the extra precision
would not survive being rendered as one sentence.

Returned status is one of:

  insufficient   not enough history yet to say anything
  exhausted      already at (effectively) 100%
  stable         barely moving; no useful ETA
  will_exhaust   runs out BEFORE the window resets  -> .eta, .mins
  safe           reset arrives first                -> .eta, .end_pct

Both windows share this code but NOT its constants — see PARAMS. A 5h window
moves in minutes and a 7d window in days, so a threshold tuned for one is
meaningless for the other.
]]--

local Burn = {}

Burn.PARAMS = {
    -- 45 min of history, and a rate under ~1.2%/h counts as flat.
    ["5h"] = { rate_window = 2700, min_span = 300, stable_rate = 0.02 / 60 },
    -- The weekly series is only sampled hourly, so a 45-minute lookback would
    -- never find a reference sample and every verdict would be "insufficient".
    -- The stable floor drops by the same factor: 0.02/60 per minute is ~29% a
    -- day, which would call almost any real burn rate "steady" while the week
    -- drains. 0.02/3600 is ~0.5% a day.
    ["7d"] = { rate_window = 12 * 3600, min_span = 2 * 3600, stable_rate = 0.02 / 3600 },
}

-- samples: chronological { t = epoch, v = 0..1 }, as returned by history.lua.
function Burn.project(samples, cur_pct, cur_epoch, reset_epoch, opts)
    opts = opts or Burn.PARAMS["5h"]
    if not cur_pct or not cur_epoch then return { status = "insufficient" } end

    local ref
    for i = #samples, 1, -1 do
        if samples[i].t <= cur_epoch - opts.rate_window then ref = samples[i]; break end
    end
    if not ref or (cur_epoch - ref.t) < opts.min_span then
        return { status = "insufficient" }
    end
    if cur_pct >= 0.995 then return { status = "exhausted" } end

    local dt_min = (cur_epoch - ref.t) / 60
    local rate = (cur_pct - ref.v) / dt_min      -- fraction per minute
    if rate <= opts.stable_rate then return { status = "stable" } end

    local mins_left = (1.0 - cur_pct) / rate
    local eta = cur_epoch + mins_left * 60
    if reset_epoch and eta <= reset_epoch then
        return { status = "will_exhaust", eta = eta, mins = math.floor(mins_left) }
    end
    local end_pct = cur_pct
    if reset_epoch then end_pct = cur_pct + rate * ((reset_epoch - cur_epoch) / 60) end
    return { status = "safe", eta = reset_epoch, end_pct = math.min(1, end_pct) }
end

return Burn
