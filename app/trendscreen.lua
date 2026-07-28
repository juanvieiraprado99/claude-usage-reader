--[[
TrendScreen - page 3, a rate-limit window over time.

A graph of the window's utilization: a solid line for the real history kept in
the local ring buffer, plus a dashed burn-rate projection and a one-line verdict
("esgota às X" / "uso estável" / "coletando dados"). The graph is redrawn only on
fetch. Everything shared with the other pages lives in screenbase.lua.

Tapping the chart toggles between the 5h and 7d windows. Both are the same
layout over a different series, so the mode only picks which headers, history
and Burn params to read. The mode lives on the controller because openPage
builds a fresh screen every time and screen-local state would reset on every
navigation.
]]--

local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Chart = require("chart")
local Heatmap = require("heatmap")
local History = require("history")
local Burn = require("burn")
local ScreenBase = require("screenbase")
local Theme = require("theme")
local Fmt = require("fmt")
local T = require("i18n").t

local sb, face, C = Theme.sb, Theme.face, Theme.color
local H5_PCT = "anthropic-ratelimit-unified-5h-utilization"
local H5_RESET = "anthropic-ratelimit-unified-5h-reset"
local H7_PCT = "anthropic-ratelimit-unified-7d-utilization"
local H7_RESET = "anthropic-ratelimit-unified-7d-reset"

local TrendScreen = ScreenBase:extend{
    page_idx = 3,
    data = nil,
    err = nil,
}

-- Everything that differs between the two windows. Titles are msgids, resolved
-- at build time - never at load, or a language switch would not reach them.
local MODES = {
    ["5h"] = {
        pct_key = H5_PCT, reset_key = H5_RESET,
        window = History.WINDOW, title = "5H WINDOW", burn = "5h",
        samples = function(hist, from) return hist:windowSamples(from) end,
        -- A 5h window fits inside a day, so clock times read fine on the axis.
        axis = function(epoch) return Fmt.hm(epoch) end,
    },
    ["7d"] = {
        pct_key = H7_PCT, reset_key = H7_RESET,
        window = History.WINDOW_7D, title = "7D WINDOW", burn = "7d",
        samples = function(hist, from) return hist:weeklySamples(from) end,
        -- "%H:%M" is meaningless across seven days; resetDate adds the weekday.
        axis = function(epoch) return Fmt.resetDate(epoch) end,
    },
    -- Same 7d data, drawn as a grid of consumption per 6h block instead of a
    -- cumulative line. Everything below the graph (percentage, reset, verdict)
    -- is the weekly window either way, so only the graph and axis differ.
    ["heat"] = {
        pct_key = H7_PCT, reset_key = H7_RESET,
        window = History.WINDOW_7D, title = "7D HEATMAP", burn = "7d",
        samples = function(hist, from) return hist:weeklySamples(from) end,
        heatmap = true,
    },
}

-- Tap order. A list, not a pair flip, so adding a fourth view stays a one-liner.
local MODE_CYCLE = { "5h", "7d", "heat" }

function TrendScreen:mode()
    return MODES[self.plugin.trend_mode] or MODES["5h"]
end

-- data ----------------------------------------------------------------------
function TrendScreen:doFetch()
    if self.closed then return end
    local h, err, auth = self.plugin:fetch()
    if h then
        self.data, self.err = h, nil
        self.last_ok = os.time()
        self.plugin:recordSample(Fmt.num(h, H5_PCT), Fmt.num(h, H7_PCT))
    else
        self.err = err
    end
    self:rebuild()
    if auth then self.plugin:reauth() end
    self:rescheduleRefresh()
end

-- layout --------------------------------------------------------------------
function TrendScreen:statusText(proj)
    local s = proj and proj.status
    if s == "exhausted" then return T("Exhausted - resets in ") .. Fmt.resetIn(self._reset) end
    if s == "stable" then return T("Steady at this pace") end
    if s == "will_exhaust" then
        return string.format(T("At this pace, exhausted %s (in %dm)"),
                             Fmt.resetDate(proj.eta), proj.mins or 0)
    end
    if s == "safe" then
        return string.format(T("Safe - ~%d%% at reset"),
                             math.floor((proj.end_pct or 0) * 100 + 0.5))
    end
    return T("Collecting data...")
end

function TrendScreen:mkChart(w, h, pct, reset_epoch)
    local mode = self:mode()
    local now = os.time()
    local win_end = reset_epoch or now
    local win_start = win_end - mode.window
    local samples = mode.samples(self.plugin.history, win_start)
    -- Keyed on mode.burn, not on trend_mode: "heat" has no PARAMS entry of its
    -- own and would silently fall back to the 5h constants, which is exactly the
    -- mis-scaling those split params exist to prevent.
    local proj = Burn.project(samples, pct, now, reset_epoch,
                              Burn.PARAMS[mode.burn])
    self._proj = proj
    self._win_start, self._win_end = win_start, win_end

    local widget
    if mode.heatmap then
        -- Grid height is derived from the cell size so the row labels beside it
        -- line up with the rows instead of drifting a pixel per row.
        local cells, max, measured, total, start = Heatmap.bucket(samples, now)
        self._heat = { max = max, measured = measured, total = total, start = start }
        widget = Heatmap.makeWidget{ w = w, h = h, cells = cells, max = max }
    else
        widget = Chart.makeWidget{
            w = w, h = h,
            samples = samples,
            win_start = win_start, win_end = win_end,
            cur_pct = pct, cur_epoch = now,
            projection = (proj.eta and proj.end_pct) and proj or nil,
        }
    end
    table.insert(self._disposables, widget)
    return widget
end

-- gestures ------------------------------------------------------------------
-- The graph is the toggle: tapping it advances 5h -> 7d -> heatmap. The subtitle
-- carries the only affordance there is on a screen with no hover state.
function TrendScreen:onExtraTap(pos, slop)
    local frame = self._chart_frame
    if frame and ScreenBase.inside(ScreenBase.expand(frame.dimen, slop), pos) then
        local cur = self.plugin.trend_mode
        local nxt = MODE_CYCLE[1]
        for i, name in ipairs(MODE_CYCLE) do
            if name == cur then nxt = MODE_CYCLE[i % #MODE_CYCLE + 1]; break end
        end
        self.plugin.trend_mode = nxt
        self:rebuild()
        return true
    end
end

-- What the darkest cell is worth. Shading is relative to the busiest block of
-- THIS week, so without this line the same darkness would silently mean a
-- different amount from one week to the next.
function TrendScreen:heatLegend()
    local max = self._heat and self._heat.max or 0
    if max <= 0 then return T("no consumption measured yet") end
    return string.format(T("darkest = %d%% of the week"), math.floor(max * 100 + 0.5))
end

-- How much of the grid is a measurement rather than a blank. Below a quarter
-- covered, say so plainly instead of letting four shaded cells pass for a week.
function TrendScreen:heatCoverage()
    local h = self._heat
    if not h or not h.total or h.total == 0 then return "" end
    if h.measured * 4 < h.total then
        return T("not enough data - the app only samples while open")
    end
    return string.format(T("%d/%d blocks measured - only while the app is open"),
                         h.measured, h.total)
end

-- Row labels in a left gutter and weekday labels underneath. Both are laid out
-- from the SAME integer cell size the grid uses, otherwise a label drifts a
-- pixel per row/column and by the far edge it points at the wrong block.
function TrendScreen:buildHeatmap(chart_w, chart_h, pct)
    local rows = Heatmap.BLOCKS
    local cols = Heatmap.DAYS

    local row_labels = {}
    local gutter = 0
    for r = 1, rows do
        local from = (r - 1) * (24 / rows)
        local txt = string.format("%02d-%02d", from, from + 24 / rows)
        local w = TextWidget:new{ text = txt, face = face(10), bold = true, fgcolor = C.muted }
        row_labels[r] = txt
        gutter = math.max(gutter, w:getSize().w)
        w:free()
    end
    gutter = gutter + sb(4)

    local cell_h = math.max(1, math.floor(chart_h / rows))
    local cell_w = math.max(1, math.floor((chart_w - gutter) / cols))
    local grid_w, grid_h = cell_w * cols, cell_h * rows

    local gutter_group = VerticalGroup:new{ align = "left" }
    for r = 1, rows do
        table.insert(gutter_group, CenterContainer:new{
            dimen = Geom:new{ w = gutter, h = cell_h },
            TextWidget:new{ text = row_labels[r], face = face(10), bold = true, fgcolor = C.muted },
        })
    end

    local frame = FrameContainer:new{
        bordersize = sb(1), radius = sb(8), padding = sb(6), margin = 0,
        background = C.white, bordercolor = C.rule,
        HorizontalGroup:new{
            align = "top",
            gutter_group,
            self:mkChart(grid_w, grid_h, pct, self._reset),
        },
    }

    -- Column labels: one weekday per day, read off the grid's own start epoch so
    -- they cannot disagree with the columns the bucketing produced.
    local start = (self._heat and self._heat.start) or os.time()
    local days = require("i18n").weekdays()
    local axis = HorizontalGroup:new{ align = "center",
                                      HorizontalSpan:new{ width = gutter } }
    for c = 1, cols do
        local wd = os.date("*t", start + (c - 1) * 86400).wday
        table.insert(axis, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = sb(16) },
            TextWidget:new{ text = days[wd] or "--", face = face(10), bold = true, fgcolor = C.muted },
        })
    end

    return frame, axis
end

function TrendScreen:rebuild()
    if self.closed then return end
    local landscape, base, lw = self:beginRebuild()

    local mode = self:mode()
    local h = self.data
    local pct = Fmt.num(h, mode.pct_key)
    self._reset = Fmt.num(h, mode.reset_key)

    local top = self:buildTop(self:updatedLabel(h ~= nil), lw)
    local bottom = self:makeBottomBar(self.page_idx)

    local chart_w = lw - sb(14)   -- minus the frame's padding and border
    local chart_h = math.floor(base * (landscape and 0.34 or 0.30))

    local chart_frame, axis
    if mode.heatmap then
        chart_frame, axis = self:buildHeatmap(chart_w, chart_h, pct)
    else
        chart_frame = FrameContainer:new{
            bordersize = sb(1), radius = sb(8), padding = sb(6), margin = 0,
            background = C.white, bordercolor = C.rule,
            self:mkChart(chart_w, chart_h, pct, self._reset),
        }
        -- Measured rather than a fixed span: "DOM 09:00" (7d) is nearly twice the
        -- width of "09:00" (5h), and the weekday names change with the language.
        local ax_l = TextWidget:new{ text = mode.axis(self._win_start), face = face(12), bold = true, fgcolor = C.muted }
        local ax_r = TextWidget:new{ text = mode.axis(self._win_end), face = face(12), bold = true, fgcolor = C.muted }
        axis = HorizontalGroup:new{
            align = "center",
            ax_l,
            HorizontalSpan:new{
                width = math.max(sb(8), chart_w - ax_l:getSize().w - ax_r:getSize().w),
            },
            ax_r,
        }
    end
    -- Kept so onExtraTap can hit-test the painted rect (.dimen is set by paintTo).
    self._chart_frame = chart_frame

    local subtitle = mode.heatmap and T("consumption per 6h block")
                     or T("real use + projection")

    -- A mostly-blank grid reads as "I barely worked", when it usually means the
    -- app was closed. Say which one it is, right under the grid, or the picture
    -- misinforms. See the provenance notes at the top of heatmap.lua.
    local legend = mode.heatmap and VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = self:heatLegend(), face = face(11), bold = true, fgcolor = C.muted },
        VerticalSpan:new{ width = sb(2) },
        TextWidget:new{ text = self:heatCoverage(), face = face(11), bold = true, fgcolor = C.muted },
    } or VerticalSpan:new{ width = 0 }

    local body = VerticalGroup:new{
        align = "center",
        VerticalGroup:new{
            align = "center",
            TextWidget:new{ text = T(mode.title), face = face(18), bold = true },
            VerticalSpan:new{ width = sb(2) },
            TextWidget:new{ text = subtitle .. T(" - tap to switch"),
                            face = face(12), bold = true, fgcolor = C.muted },
        },
        VerticalSpan:new{ width = sb(10) },
        chart_frame,
        VerticalSpan:new{ width = sb(4) },
        axis,
        legend,
        VerticalSpan:new{ width = mode.heatmap and sb(6) or sb(16) },
        VerticalGroup:new{
            align = "center",
            TextWidget:new{ text = Fmt.pct(pct), face = face(52), bold = true },
            VerticalSpan:new{ width = sb(4) },
            TextWidget:new{ text = T("RESETS IN - ") .. Fmt.resetDate(self._reset)
                            .. "  (" .. Fmt.resetIn(self._reset) .. ")",
                            face = face(13), bold = true, fgcolor = C.muted },
            VerticalSpan:new{ width = sb(6) },
            TextWidget:new{ text = self:statusText(self._proj), face = face(15), bold = true },
        },
    }


    self[1] = self:_screenFrame(top, body, bottom)
    self:markDirty()
end

return TrendScreen
