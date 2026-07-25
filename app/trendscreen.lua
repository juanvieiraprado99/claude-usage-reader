--[[
TrendScreen - page 3, the 5-hour window over time.

A graph of the 5h-window utilization: a solid line for the real history kept in
the local ring buffer, plus a dashed burn-rate projection and a one-line verdict
("esgota às X" / "uso estável" / "coletando dados"). The graph is redrawn only on
fetch. Everything shared with the other pages lives in screenbase.lua.
]]--

local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Chart = require("chart")
local History = require("history")
local ScreenBase = require("screenbase")
local Theme = require("theme")
local Fmt = require("fmt")

local sb, face, C = Theme.sb, Theme.face, Theme.color
local H5_PCT = "anthropic-ratelimit-unified-5h-utilization"
local H5_RESET = "anthropic-ratelimit-unified-5h-reset"

local RATE_WINDOW = 2700   -- 45 min of history used to estimate the burn rate

local TrendScreen = ScreenBase:extend{
    page_idx = 3,
    data = nil,
    err = nil,
}

-- Burn-rate projection from the last ~45 min of history.
local function computeProjection(samples, cur_pct, cur_epoch, reset_epoch)
    if not cur_pct or not cur_epoch then return { status = "insufficient" } end
    local ref
    for i = #samples, 1, -1 do
        if samples[i].t <= cur_epoch - RATE_WINDOW then ref = samples[i]; break end
    end
    if not ref or (cur_epoch - ref.t) < 300 then return { status = "insufficient" } end
    if cur_pct >= 0.995 then return { status = "exhausted" } end

    local dt_min = (cur_epoch - ref.t) / 60
    local rate = (cur_pct - ref.v) / dt_min      -- fraction per minute
    if rate <= 0.02 / 60 then return { status = "stable" } end

    local mins_left = (1.0 - cur_pct) / rate
    local eta = cur_epoch + mins_left * 60
    if reset_epoch and eta <= reset_epoch then
        return { status = "will_exhaust", eta = eta, mins = math.floor(mins_left) }
    end
    local end_pct = cur_pct
    if reset_epoch then end_pct = cur_pct + rate * ((reset_epoch - cur_epoch) / 60) end
    return { status = "safe", eta = reset_epoch, end_pct = math.min(1, end_pct) }
end

-- data ----------------------------------------------------------------------
function TrendScreen:doFetch()
    if self.closed then return end
    local h, err, auth = self.plugin:fetch()
    if h then
        self.data, self.err = h, nil
        self.last_ok = os.time()
        self.plugin:recordSample(Fmt.num(h, H5_PCT))
    else
        self.err = err
    end
    self:rebuild()
    if auth then self.plugin:webLogin() end
    self:rescheduleRefresh()
end

-- layout --------------------------------------------------------------------
function TrendScreen:statusText(proj)
    local s = proj and proj.status
    if s == "exhausted" then return "Esgotado - reseta em " .. Fmt.resetIn(self._reset) end
    if s == "stable" then return "Uso estável neste ritmo" end
    if s == "will_exhaust" then
        return string.format("Neste ritmo, esgota %s (em %dm)",
                             Fmt.resetDate(proj.eta), proj.mins or 0)
    end
    if s == "safe" then
        return string.format("Seguro - ~%d%% no reset",
                             math.floor((proj.end_pct or 0) * 100 + 0.5))
    end
    return "Coletando dados..."
end

function TrendScreen:mkChart(w, h, p5, reset_epoch)
    local now = os.time()
    local win_end = reset_epoch or now
    local win_start = win_end - History.WINDOW
    local samples = self.plugin.history:windowSamples(win_start)
    local proj = computeProjection(samples, p5, now, reset_epoch)
    self._proj = proj
    self._win_start, self._win_end = win_start, win_end

    local widget = Chart.makeWidget{
        w = w, h = h,
        samples = samples,
        win_start = win_start, win_end = win_end,
        cur_pct = p5, cur_epoch = now,
        projection = (proj.eta and proj.end_pct) and proj or nil,
    }
    table.insert(self._disposables, widget)
    return widget
end

function TrendScreen:rebuild()
    if self.closed then return end
    local landscape, base, lw = self:beginRebuild()

    local h = self.data
    local p5 = Fmt.num(h, H5_PCT)
    self._reset = Fmt.num(h, H5_RESET)

    local top = self:buildTop(self:updatedLabel(h ~= nil), lw)
    local bottom = self:makeBottomBar(self.page_idx)

    local chart_w = lw - sb(14)   -- minus the frame's padding and border
    local chart_h = math.floor(base * (landscape and 0.34 or 0.30))
    local chart_frame = FrameContainer:new{
        bordersize = sb(1), radius = sb(8), padding = sb(6), margin = 0,
        background = C.white, bordercolor = C.rule,
        self:mkChart(chart_w, chart_h, p5, self._reset),
    }

    local axis = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = Fmt.hm(self._win_start), face = face(12), fgcolor = C.muted },
        HorizontalSpan:new{ width = chart_w - sb(70) },
        TextWidget:new{ text = Fmt.hm(self._win_end), face = face(12), fgcolor = C.muted },
    }

    local body = VerticalGroup:new{
        align = "center",
        VerticalGroup:new{
            align = "center",
            TextWidget:new{ text = "JANELA DE 5H", face = face(18), bold = true },
            VerticalSpan:new{ width = sb(2) },
            TextWidget:new{ text = "uso real + projecao", face = face(12), fgcolor = C.muted },
        },
        VerticalSpan:new{ width = sb(10) },
        chart_frame,
        VerticalSpan:new{ width = sb(4) },
        axis,
        VerticalSpan:new{ width = sb(16) },
        VerticalGroup:new{
            align = "center",
            TextWidget:new{ text = Fmt.pct(p5), face = face(52), bold = true },
            VerticalSpan:new{ width = sb(4) },
            TextWidget:new{ text = "RESETA EM - " .. Fmt.resetDate(self._reset)
                            .. "  (" .. Fmt.resetIn(self._reset) .. ")",
                            face = face(13), fgcolor = C.muted },
            VerticalSpan:new{ width = sb(6) },
            TextWidget:new{ text = self:statusText(self._proj), face = face(15), bold = true },
        },
    }

    self[1] = self:_screenFrame(top, body, bottom)
    UIManager:setDirty(self, "ui")
end

return TrendScreen
