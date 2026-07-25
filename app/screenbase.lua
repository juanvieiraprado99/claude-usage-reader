--[[
Everything the three pages (dashboard, models, 5h trend) do identically: the
fullscreen frame, the header, the bottom bar with navigation, the tap and swipe
handling, and the refresh scheduling.

Before this existed the three screens carried ~570 lines of byte-identical copy
between them, so every fix had to be written three times. A page now only
implements what makes it different: `rebuild()` and `doFetch()`.

Subclasses:
  * extend this instead of InputContainer
  * may define `setup()`   - extra state, run before the first build
  * may define `onExtraTap(pos, slop)` - page-specific tap targets
  * must define `rebuild()` and `doFetch()`
]]--

local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local LineWidget = require("ui/widget/linewidget")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local RotIcon = require("roticon")
local Clawd = require("clawd")
local Version = require("appversion")
local Theme = require("theme")

local sb, face, C = Theme.sb, Theme.face, Theme.color

local NAV_LABELS = { "Uso", "Modelos", "5h" }

local ScreenBase = InputContainer:extend{
    plugin = nil,
    page_idx = 1,
}

-- geometry helpers ----------------------------------------------------------
local function inside(geom, pos)
    return geom and pos and pos.x >= geom.x and pos.x < geom.x + geom.w
        and pos.y >= geom.y and pos.y < geom.y + geom.h
end

local function expand(geom, m)
    if not geom then return nil end
    return Geom:new{ x = geom.x - m, y = geom.y - m,
                     w = geom.w + 2 * m, h = geom.h + 2 * m }
end

ScreenBase.inside = inside
ScreenBase.expand = expand

-- A tap counts if it lands within TAP_SLOP of the widget's painted rect.
local function hit(widget, pos, slop)
    return widget and inside(expand(widget.dimen, slop), pos)
end

-- lifecycle -----------------------------------------------------------------
function ScreenBase:init()
    -- modal: the framework then routes every gesture here instead of consulting
    -- the touch zones underneath, which would otherwise swallow our taps.
    self.modal = true
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self._disposables = {}

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.refresh_task = function() self:doFetch() end

    if self.setup then self:setup() end
    self:rebuild()
    UIManager:nextTick(function() self:doFetch() end)
end

function ScreenBase:rescheduleRefresh()
    UIManager:unschedule(self.refresh_task)
    local secs = self.plugin:nextRefreshDelay()
    if secs > 0 then UIManager:scheduleIn(secs, self.refresh_task) end
end

-- Free last frame's buffers and re-read the screen, which may have rotated.
-- Returns the values every rebuild() needs: orientation, short side, inner width.
function ScreenBase:beginRebuild()
    for _i, w in ipairs(self._disposables or {}) do
        if w.free then w:free() end
    end
    self._disposables = {}

    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen.w, self.dimen.h = self.width, self.height
    return self.width > self.height,
           math.min(self.width, self.height),
           self.width - 2 * sb(Theme.MARGIN)
end

-- Not registered as a disposable: Clawd caches its rasters and owns them.
-- Changing scale (a rotation) invalidates the whole cache.
function ScreenBase:mkClawd(emotion, scale, opts)
    if self._clawd_scale and self._clawd_scale ~= scale then
        Clawd.clearCache()
    end
    self._clawd_scale = scale
    return Clawd.makeWidget(emotion, scale, opts, C.white)
end

-- gestures ------------------------------------------------------------------
function ScreenBase:onTap(a, b)
    local ges = b or a
    local pos = ges and ges.pos
    local slop = sb(Theme.TAP_SLOP)

    if hit(self.close_btn, pos, slop) then self:onClose(); return true end
    if hit(self.refresh_btn, pos, slop) then self.plugin:cycleInterval(); return true end
    if hit(self.rot_btn, pos, slop) then self.plugin:cycleRotation(); return true end
    -- The version label doubles as the way into the settings dialog, which is
    -- where login/logout live.
    if hit(self.ver_btn, pos, slop) then self.plugin:showSettings(); return true end

    for i, btn in ipairs(self.nav_btns or {}) do
        if i ~= self.page_idx and hit(btn, pos, slop) then
            UIManager:close(self)
            self.plugin:openPage(i)
            return true
        end
    end

    if self.onExtraTap and self:onExtraTap(pos, slop) then return true end
    return true
end

-- KOReader reports swipes as compass points: west means the finger moved left,
-- which should advance to the next page.
function ScreenBase:onSwipe(a, b)
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

-- Back key or the FECHAR pill: quit the app, not just this screen.
function ScreenBase:onClose()
    self.plugin:closeUI()
    return true
end

function ScreenBase:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self.refresh_task)
end

-- widgets -------------------------------------------------------------------
-- Rounded label button. Callable as a plain function (ScreenBase.pill) too.
function ScreenBase.pill(text, bg, fg, border)
    return FrameContainer:new{
        bordersize = sb(Theme.pill.bordersize),
        radius = sb(Theme.pill.radius),
        padding = sb(Theme.pill.padding),
        margin = 0,
        bordercolor = border or C.border,
        background = bg or C.fill,
        TextWidget:new{ text = " " .. text .. " ", face = face(14), bold = true,
                        fgcolor = fg or C.fg },
    }
end

-- Same shell as pill(), carrying the circular-arrow icon: one tap = a quarter turn.
function ScreenBase.rotPill()
    return FrameContainer:new{
        bordersize = sb(Theme.pill.bordersize),
        radius = sb(Theme.pill.radius),
        padding = sb(Theme.pill.padding),
        margin = 0,
        bordercolor = C.border,
        background = C.fill,
        RotIcon.makeWidget(sb(18), C.fg, C.fill),
    }
end

-- "atualizado 14:03" on the left, the auto-refresh and close pills on the right.
function ScreenBase:buildHeader(updated)
    local lw = self.width - 2 * sb(Theme.MARGIN)
    local left = TextWidget:new{ text = updated, face = face(14), fgcolor = C.muted }
    local secs = self.plugin.refresh_interval
    local itxt = (secs == 0) and "AUTO OFF" or string.format("AUTO %ds", secs)
    self.refresh_btn = ScreenBase.pill(itxt, C.white)
    self.close_btn = ScreenBase.pill("FECHAR", C.fill)
    local right = HorizontalGroup:new{
        align = "center",
        self.refresh_btn,
        HorizontalSpan:new{ width = sb(Theme.GAP) },
        self.close_btn,
    }
    local gap = math.max(sb(Theme.GAP), lw - left:getSize().w - right:getSize().w)
    return HorizontalGroup:new{
        align = "center",
        left,
        HorizontalSpan:new{ width = gap },
        right,
    }
end

-- One button per page, the current one inverted. Refs kept for hit-testing.
function ScreenBase:makeNav(active)
    self.nav_btns = {}
    local grp = HorizontalGroup:new{ align = "center" }
    for i, label in ipairs(NAV_LABELS) do
        local is_active = (i == active)
        local btn = FrameContainer:new{
            bordersize = sb(Theme.pill.bordersize),
            radius = sb(Theme.pill.radius),
            padding = sb(Theme.pill.padding),
            margin = 0,
            bordercolor = C.border,
            background = is_active and C.active or C.white,
            TextWidget:new{ text = " " .. label .. " ", face = face(14), bold = true,
                            fgcolor = is_active and C.white or C.fg },
        }
        self.nav_btns[i] = btn
        table.insert(grp, btn)
        if i < #NAV_LABELS then
            table.insert(grp, HorizontalSpan:new{ width = sb(12) })
        end
    end
    return grp
end

-- Rotate button left, version right, navigation centered. The two spans are
-- computed separately so the nav sits in the middle of the bar whatever the
-- version label happens to measure.
function ScreenBase:makeBottomBar(active)
    local nav = self:makeNav(active)
    self.rot_btn = ScreenBase.rotPill()
    self.ver_btn = TextWidget:new{ text = "v" .. Version, face = face(12),
                                   fgcolor = C.faint }
    local lw = self.width - 2 * sb(Theme.MARGIN)
    local half = (lw - nav:getSize().w) / 2
    local sp_l = math.max(sb(Theme.GAP), math.floor(half - self.rot_btn:getSize().w))
    local sp_r = math.max(sb(Theme.GAP), math.floor(half - self.ver_btn:getSize().w))
    return HorizontalGroup:new{
        align = "center",
        self.rot_btn,
        HorizontalSpan:new{ width = sp_l },
        nav,
        HorizontalSpan:new{ width = sp_r },
        self.ver_btn,
    }
end

-- Fullscreen white frame in three blocks: header anchored at the top, bottom bar
-- pinned, body centered in the leftover space (40% above / 60% below) so the
-- page fills evenly instead of leaving one big gap.
function ScreenBase:_screenFrame(top, body, bottom)
    local pad = sb(14)
    local leftover = math.max(sb(Theme.MARGIN), self.height - top:getSize().h
                     - body:getSize().h - bottom:getSize().h - pad)
    local s1 = math.max(sb(Theme.GAP), math.floor(leftover * 0.4))
    local s2 = math.max(sb(Theme.GAP), leftover - s1)
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
        background = C.white,
        content,
    }
end

-- The header block every page puts above its body.
function ScreenBase:buildTop(updated, lw)
    return VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = sb(10) },
        self:buildHeader(updated),
        VerticalSpan:new{ width = sb(6) },
        LineWidget:new{ background = C.rule, dimen = Geom:new{ w = lw, h = sb(2) } },
    }
end

-- "atualizado HH:MM" / "carregando..." / "falhou"
function ScreenBase:updatedLabel(has_data)
    if self.err then return "falhou" end
    if has_data then return "atualizado " .. os.date("%H:%M", self.last_ok) end
    return "carregando..."
end

return ScreenBase
