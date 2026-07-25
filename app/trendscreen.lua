--[[
TrendScreen — Page 3 "Janela de 5h" for the Claude Usage KOReader plugin.

A trend graph of the 5-hour-window utilization over time (solid line = real
history from the local ring buffer) plus a dashed burn-rate projection and a
text status ("esgota às X" / "uso estável" / "coletando dados"). Mirrors the
ESP32 firmware's build_tile_trend(). Light theme, e-ink grayscale; the graph is
redrawn only on fetch. Swipe east returns to Page 2 (models).
]]--

local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local LineWidget = require("ui/widget/linewidget")
local RotIcon = require("roticon")
local Version = require("appversion")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Chart = require("chart")
local T = require("i18n").t

local WINDOW = 5 * 3600
local RATE_WINDOW = 2700     -- 45 min reference for burn rate
local NAV_LABELS = { T("Uso"), T("Modelos"), T("5h") }

local TrendScreen = InputContainer:extend{
    plugin = nil,
    page_idx = 3,
    data = nil,
    err = nil,
}

local WEEKDAYS_PT = { "DOM", "SEG", "TER", "QUA", "QUI", "SEX", "SÁB" }
local function sb(n) return Screen:scaleBySize(n) end
local function face(sz) return Font:getFace("cfont", sz) end
local function inside(geom, pos)
    return geom and pos and pos.x >= geom.x and pos.x < geom.x + geom.w
        and pos.y >= geom.y and pos.y < geom.y + geom.h
end
local function expand(geom, m)
    if not geom then return nil end
    return Geom:new{ x = geom.x - m, y = geom.y - m,
                     w = geom.w + 2 * m, h = geom.h + 2 * m }
end
local function num(h, key)
    local v = h and h[key]
    return v and tonumber(v) or nil
end
local function pct_str(frac)
    if not frac then return "--%" end
    return string.format("%d%%", math.floor(frac * 100 + 0.5))
end
local function hm(epoch)
    if not epoch then return "--" end
    return os.date("%H:%M", epoch)
end
local function reset_date(epoch)
    if not epoch then return "--" end
    local t = os.date("*t", epoch)
    return string.format("%s %02d:%02d", WEEKDAYS_PT[t.wday] or "--", t.hour, t.min)
end
local function reset_in(epoch)
    if not epoch then return "--" end
    local secs = epoch - os.time()
    if secs < 0 then return T("agora") end
    local hrs = math.floor(secs / 3600)
    local mins = math.floor((secs % 3600) / 60)
    if hrs > 24 then return string.format("%dD %dH", math.floor(hrs / 24), hrs % 24) end
    return string.format("%dH %dM", hrs, mins)
end

local function pill(text, bg)
    return FrameContainer:new{
        bordersize = sb(1), radius = sb(12), padding = sb(6), margin = 0,
        bordercolor = Blitbuffer.Color8(0x88),
        background = bg or Blitbuffer.Color8(0xF4),
        TextWidget:new{ text = " " .. text .. " ", face = face(14), bold = true },
    }
end

-- Same shell as pill(), with the circular-arrow icon instead of a label: one
-- tap = a quarter turn.
local function rotPill()
    local bg = Blitbuffer.Color8(0xF4)
    return FrameContainer:new{
        bordersize = sb(1), radius = sb(12), padding = sb(6), margin = 0,
        bordercolor = Blitbuffer.Color8(0x88),
        background = bg,
        RotIcon.makeWidget(sb(18), Blitbuffer.Color8(0x22), bg),
    }
end

-- Burn-rate projection from the last ~45 min of history.
local function computeProjection(samples, cur_pct, cur_epoch, reset_epoch)
    if not cur_pct or not cur_epoch then return { status = "insufficient" } end
    local ref
    for i = #samples, 1, -1 do
        if samples[i].t <= cur_epoch - RATE_WINDOW then ref = samples[i]; break end
    end
    if not ref or (cur_epoch - ref.t) < 300 then return { status = "insufficient" } end
    if cur_pct >= 0.995 then
        return { status = "exhausted" }
    end
    local dt_min = (cur_epoch - ref.t) / 60
    local rate = (cur_pct - ref.v) / dt_min      -- fraction per minute
    if rate <= 0.02 / 60 then return { status = "stable" } end
    local mins_left = (1.0 - cur_pct) / rate
    local eta = cur_epoch + mins_left * 60
    if reset_epoch and eta <= reset_epoch then
        return { status = "will_exhaust", eta = eta, mins = math.floor(mins_left) }
    else
        local end_pct = cur_pct
        if reset_epoch then end_pct = cur_pct + rate * ((reset_epoch - cur_epoch) / 60) end
        return { status = "safe", eta = reset_epoch, end_pct = math.min(1, end_pct) }
    end
end

function TrendScreen:init()
    self.modal = true
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self._disposables = {}
    self.settings_btn = nil

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.refresh_task = function() self:doFetch() end

    self:rebuild()
    UIManager:nextTick(function() self:doFetch() end)
end

-- data / scheduling ---------------------------------------------------------
function TrendScreen:doFetch()
    if self.closed then return end
    local h, err, auth = self.plugin:fetch()
    if h then
        self.data, self.err = h, nil
        self.plugin:recordSample(num(h, "anthropic-ratelimit-unified-5h-utilization"))
    else
        self.err = err
    end
    self.last_ok = os.time()
    self:rebuild()
    if auth then self.plugin:webLogin() end
    self:rescheduleRefresh()
end

function TrendScreen:rescheduleRefresh()
    UIManager:unschedule(self.refresh_task)
    if self.plugin.refresh_interval > 0 then
        UIManager:scheduleIn(self.plugin.refresh_interval, self.refresh_task)
    end
end

-- gestures ------------------------------------------------------------------
function TrendScreen:onTap(a, b)
    local ges = b or a
    local pos = ges and ges.pos
    local m = sb(12)
    if self.close_btn and inside(expand(self.close_btn.dimen, m), pos) then
        self:onClose(); return true
    end
    if self.refresh_btn and inside(expand(self.refresh_btn.dimen, m), pos) then
        self.plugin:cycleInterval(); return true
    end
    if self.rot_btn and inside(expand(self.rot_btn.dimen, m), pos) then
        self.plugin:cycleRotation(); return true
    end
    for i, btn in ipairs(self.nav_btns or {}) do
        if i ~= self.page_idx and inside(expand(btn.dimen, m), pos) then
            UIManager:close(self); self.plugin:openPage(i); return true
        end
    end
    return true
end

function TrendScreen:onSwipe(a, b)
    local ges = b or a
    local dir = ges and ges.direction
    local t = (dir == "west") and self.page_idx + 1
           or (dir == "east") and self.page_idx - 1 or nil
    if t and t >= 1 and t <= self.plugin.PAGES_IMPL and t ~= self.page_idx then
        UIManager:close(self)
        self.plugin:openPage(t)
    end
    return true
end

function TrendScreen:onClose()
    self.plugin:closeUI()
    return true
end

function TrendScreen:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self.refresh_task)
end

-- widgets -------------------------------------------------------------------
function TrendScreen:buildHeader(updated)
    local lw = self.width - 2 * sb(16)
    local left = TextWidget:new{ text = updated, face = face(14),
                                 fgcolor = Blitbuffer.Color8(0x77) }
    local secs = self.plugin.refresh_interval
    local itxt = (secs == 0) and T("AUTO OFF") or string.format(T("AUTO %ds"), secs)
    self.refresh_btn = pill(itxt, Blitbuffer.COLOR_WHITE)
    self.close_btn = pill(T("FECHAR"), Blitbuffer.Color8(0xF4))
    local right = HorizontalGroup:new{
        align = "center",
        self.refresh_btn,
        HorizontalSpan:new{ width = sb(8) },
        self.close_btn,
    }
    local gap = math.max(sb(8), lw - left:getSize().w - right:getSize().w)
    return HorizontalGroup:new{
        align = "center", left, HorizontalSpan:new{ width = gap }, right }
end

-- Bottom navigation: one text button per page, current highlighted.
function TrendScreen:makeNav(active)
    self.nav_btns = {}
    local grp = HorizontalGroup:new{ align = "center" }
    for i, label in ipairs(NAV_LABELS) do
        local active_i = (i == active)
        local btn = FrameContainer:new{
            bordersize = sb(1), radius = sb(12), padding = sb(6), margin = 0,
            bordercolor = Blitbuffer.Color8(0x88),
            background = active_i and Blitbuffer.Color8(0x66) or Blitbuffer.COLOR_WHITE,
            TextWidget:new{ text = " " .. label .. " ", face = face(14), bold = true,
                fgcolor = active_i and Blitbuffer.COLOR_WHITE or Blitbuffer.Color8(0x22) },
        }
        self.nav_btns[i] = btn
        table.insert(grp, btn)
        if i < #NAV_LABELS then table.insert(grp, HorizontalSpan:new{ width = sb(12) }) end
    end
    return grp
end

-- Bottom bar: rotate button on the left, version on the right, page navigation
-- centered. The two spans are computed separately so the nav sits in the middle
-- of the bar regardless of how wide the version label happens to be.
function TrendScreen:makeBottomBar(active)
    local nav = self:makeNav(active)
    self.rot_btn = rotPill()
    local ver = TextWidget:new{ text = "v" .. Version, face = face(12),
                                fgcolor = Blitbuffer.Color8(0x99) }
    local lw = self.width - 2 * sb(16)
    local half = (lw - nav:getSize().w) / 2
    local sp_l = math.max(sb(8), math.floor(half - self.rot_btn:getSize().w))
    local sp_r = math.max(sb(8), math.floor(half - ver:getSize().w))
    return HorizontalGroup:new{
        align = "center",
        self.rot_btn,
        HorizontalSpan:new{ width = sp_l },
        nav,
        HorizontalSpan:new{ width = sp_r },
        ver,
    }
end

function TrendScreen:statusText(proj)
    local s = proj and proj.status
    if s == "exhausted" then return T("Esgotado - reseta em ") .. reset_in(self._reset) end
    if s == "stable" then return T("Uso estável neste ritmo") end
    if s == "will_exhaust" then
        return string.format(T("Neste ritmo, esgota %s (em %dm)"),
                             reset_date(proj.eta), proj.mins or 0)
    end
    if s == "safe" then
        return string.format(T("Seguro - ~%d%% no reset"),
                             math.floor((proj.end_pct or 0) * 100 + 0.5))
    end
    return T("Coletando dados...")
end

function TrendScreen:mkChart(w, h, p5, reset_epoch)
    local win_end = reset_epoch or os.time()
    local win_start = win_end - WINDOW
    local samples = self.plugin.history:windowSamples(win_start)
    local proj = computeProjection(samples, p5, os.time(), reset_epoch)
    self._proj = proj
    local widget = Chart.makeWidget{
        w = w, h = h,
        samples = samples,
        win_start = win_start, win_end = win_end,
        cur_pct = p5, cur_epoch = os.time(),
        projection = (proj.eta and proj.end_pct) and proj or nil,
    }
    table.insert(self._disposables, widget)
    self._win_start, self._win_end = win_start, win_end
    return widget
end

-- Full-screen white frame in three blocks: top anchored, bottom bar pinned,
-- body centered in the leftover space (40/60) for an even fill.
function TrendScreen:_screenFrame(top, body, bottom)
    local pad = sb(14)
    local leftover = math.max(sb(16), self.height - top:getSize().h
                     - body:getSize().h - bottom:getSize().h - pad)
    local s1 = math.max(sb(8), math.floor(leftover * 0.4))
    local s2 = math.max(sb(8), leftover - s1)
    local content = VerticalGroup:new{
        align = "center",
        top,
        VerticalSpan:new{ width = s1 },
        body,
        VerticalSpan:new{ width = s2 },
        bottom,
        VerticalSpan:new{ width = pad },
    }
    return FrameContainer:new{
        width = self.width, height = self.height,
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
end

function TrendScreen:rebuild()
    if self.closed then return end
    for _i, w in ipairs(self._disposables or {}) do
        if w.free then w:free() end
    end
    self._disposables = {}

    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen.w, self.dimen.h = self.width, self.height
    local landscape = self.width > self.height
    local base = math.min(self.width, self.height)
    local lw = self.width - 2 * sb(16)          -- inner width (side margins)

    local h = self.data
    local p5 = num(h, "anthropic-ratelimit-unified-5h-utilization")
    self._reset = num(h, "anthropic-ratelimit-unified-5h-reset")

    local updated = self.err and T("falhou")
        or (h and (T("atualizado ") .. os.date("%H:%M", self.last_ok)) or T("carregando..."))
    local header = self:buildHeader(updated)
    local divider = LineWidget:new{ background = Blitbuffer.Color8(0xB4),
        dimen = Geom:new{ w = lw, h = sb(2) } }
    local bottom = self:makeBottomBar(self.page_idx)

    local chart_w = lw - sb(14)   -- minus chart_frame padding/border ≈ framed to lw
    local chart_h = math.floor(base * (landscape and 0.34 or 0.30))
    local chart = self:mkChart(chart_w, chart_h, p5, self._reset)
    local chart_frame = FrameContainer:new{
        bordersize = sb(1), radius = sb(8), padding = sb(6), margin = 0,
        background = Blitbuffer.COLOR_WHITE, bordercolor = Blitbuffer.Color8(0xB4),
        chart,
    }

    -- time axis labels (window start / end)
    local axis = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = hm(self._win_start), face = face(12),
                        fgcolor = Blitbuffer.Color8(0x77) },
        HorizontalSpan:new{ width = chart_w - sb(70) },
        TextWidget:new{ text = hm(self._win_end), face = face(12),
                        fgcolor = Blitbuffer.Color8(0x77) },
    }

    local title = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = T("JANELA DE 5H"), face = face(18), bold = true },
        VerticalSpan:new{ width = sb(2) },
        TextWidget:new{ text = T("uso real + projecao"), face = face(12),
                        fgcolor = Blitbuffer.Color8(0x77) },
    }

    local summary = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = pct_str(p5), face = face(52), bold = true },
        VerticalSpan:new{ width = sb(4) },
        TextWidget:new{ text = T("RESETA EM - ") .. reset_date(self._reset)
                        .. "  (" .. reset_in(self._reset) .. ")",
                        face = face(13), fgcolor = Blitbuffer.Color8(0x77) },
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = self:statusText(self._proj), face = face(15), bold = true },
    }

    local top = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = sb(10) },
        header,
        VerticalSpan:new{ width = sb(6) },
        divider,
    }
    local body = VerticalGroup:new{
        align = "center",
        title,
        VerticalSpan:new{ width = sb(10) },
        chart_frame,
        VerticalSpan:new{ width = sb(4) },
        axis,
        VerticalSpan:new{ width = sb(16) },
        summary,
    }

    self[1] = self:_screenFrame(top, body, bottom)
    UIManager:setDirty(self, "ui")
end

return TrendScreen
