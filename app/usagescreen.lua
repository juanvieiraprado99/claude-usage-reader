--[[
UsageScreen - page 1, the dashboard.

Two cards (5h session / 7d weekly) with the big percentage, a progress bar and
the countdown to the reset, plus a lower band with the Clawd mascot and a small
data column. The wireframe's "tokens in/out" is deliberately absent: subscription
accounts expose percentages only, never raw token counts.

Clawd's resting face follows usage, with occasional random animations. Both the
auto-refresh and the animations run only while this screen is open.

Everything shared with the other pages lives in screenbase.lua.
]]--

local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextWidget = require("ui/widget/textwidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Clawd = require("clawd")
local ScreenBase = require("screenbase")
local Theme = require("theme")
local Fmt = require("fmt")
local T = require("i18n").t

local sb, face, C = Theme.sb, Theme.face, Theme.color
local H5_PCT = "anthropic-ratelimit-unified-5h-utilization"
local H7_PCT = "anthropic-ratelimit-unified-7d-utilization"
local H5_RESET = "anthropic-ratelimit-unified-5h-reset"
local H7_RESET = "anthropic-ratelimit-unified-7d-reset"
local H_STATUS = "anthropic-ratelimit-unified-status"

local ANIM_MIN, ANIM_MAX = 5, 20   -- random seconds between animations

local UsageScreen = ScreenBase:extend{
    page_idx = 1,
    data = nil,
    err = nil,
    cur_anim = nil,     -- animation name (nil = resting)
    cur_phase = 0,
    cur_bob = 0,        -- mascot vertical bob in px
}

function UsageScreen:setup()
    math.randomseed(os.time())
    self._mascot_ref = nil
    self._mascot_bbox = nil
    self.anim_task = function() self:playRandomAnim() end
    if self.plugin.animations then
        UIManager:nextTick(function() self:scheduleNextAnim() end)
    end
end

function UsageScreen:onCloseWidget()
    ScreenBase.onCloseWidget(self)
    UIManager:unschedule(self.anim_task)
end

-- data ----------------------------------------------------------------------
-- Everything a repaint would actually show, as one string: comparing this
-- against the last fetch's value lets doFetch skip the full-screen e-ink
-- flash when a tick brought back exactly the same numbers.
function UsageScreen:displaySig()
    local h = self.data
    local e5, e7 = Fmt.num(h, H5_RESET), Fmt.num(h, H7_RESET)
    return table.concat({
        tostring(self.err),
        -- The whole header line, not just the clock: it also carries the
        -- account and the battery level, and anything drawn but missing from
        -- this signature would sit frozen until some other number moved.
        self:headerText(self:updatedLabel(h ~= nil)),
        h and h[H_STATUS] or "",
        Fmt.pct(Fmt.num(h, H5_PCT)), Fmt.pct(Fmt.num(h, H7_PCT)),
        Fmt.resetIn(e5), Fmt.resetIn(e7),
        Fmt.resetDate(e5), Fmt.resetDate(e7),
    }, "|")
end

function UsageScreen:doFetch()
    if self.closed then return end
    local h, err, auth = self.plugin:fetch()
    if h then
        self.data, self.err = h, nil
        self.last_ok = os.time()
        self.plugin:recordSample(Fmt.num(h, H5_PCT), Fmt.num(h, H7_PCT))
    else
        self.err = err
    end
    local sig = self:displaySig()
    if sig ~= self._last_sig then
        self._last_sig = sig
        self:rebuild()
    end
    if auth then self.plugin:reauth() end   -- token expired -> QR login modal
    self:rescheduleRefresh()
end

function UsageScreen:maxPct()
    local p5 = Fmt.num(self.data, H5_PCT)
    local p7 = Fmt.num(self.data, H7_PCT)
    return math.max((p5 or 0), (p7 or 0)) * 100
end

-- animation -----------------------------------------------------------------
function UsageScreen:scheduleNextAnim()
    if self.closed then return end
    UIManager:unschedule(self.anim_task)
    if not self.plugin.animations or self.plugin:isIdle() then return end
    UIManager:scheduleIn(math.random(ANIM_MIN, ANIM_MAX), self.anim_task)
end

-- Called by the controller when the animations setting is flipped from the
-- settings dialog while this screen is on screen.
function UsageScreen:onAnimSettingChanged()
    if self.plugin.animations then
        self:scheduleNextAnim()
    else
        UIManager:unschedule(self.anim_task)
    end
end

-- Pick an animation, biased by usage: cheerful when there is room, flustered
-- when the window is nearly spent.
function UsageScreen:pickAnim()
    local maxp = self:maxPct()
    if maxp >= 75 then return ({ "shy", "shy", "blink", "sparkle" })[math.random(4)] end
    if maxp < 50 then return ({ "heart", "heart", "blink", "sparkle" })[math.random(4)] end
    return ({ "sparkle", "blink", "heart", "shy" })[math.random(4)]
end

-- Drive one animation frame by frame; each frame only repaints the mascot area.
function UsageScreen:runAnim(name, on_done)
    local spec = Clawd.ANIMS[name] or { frames = 2, step = 0.15 }
    local i = 0
    local function step()
        if self.closed then return end
        -- The setting can flip mid-animation; the in-flight frame closure has
        -- no task ref for onAnimSettingChanged to unschedule, so it checks
        -- itself and settles back to resting instead of playing out.
        if not self.plugin.animations then
            self.cur_anim, self.cur_phase, self.cur_bob = nil, 0, 0
            self:rebuild(true)
            return
        end
        i = i + 1
        if i > spec.frames then
            self.cur_anim, self.cur_phase, self.cur_bob = nil, 0, 0
            self:rebuild(true)
            if on_done then on_done() end
            return
        end
        self.cur_anim, self.cur_phase = name, i
        self.cur_bob = (i % 2 == 0) and sb(3) or 0
        self:rebuild(true)
        UIManager:scheduleIn(spec.step, step)
    end
    step()
end

function UsageScreen:playRandomAnim()
    if self.closed then return end
    -- The setting or idle state may have changed since this was scheduled.
    if not self.plugin.animations or self.plugin:isIdle() then return end
    self:runAnim(self:pickAnim(), function() self:scheduleNextAnim() end)
end

function UsageScreen:triggerShy()
    if not self.plugin.animations then return end   -- setting says no animations, full stop
    if self.cur_anim then return end   -- don't interrupt a running animation
    self:runAnim("shy", function() self:scheduleNextAnim() end)
end

-- gestures ------------------------------------------------------------------
-- Absolute screen rect of the mascot, walking up the parent chain. Only valid
-- after a paint, which is why the result is cached until the next rebuild.
function UsageScreen:mascotBBox()
    if self._mascot_bbox then return self._mascot_bbox end
    local w = self._mascot_ref
    if not w or not w.dimen then return nil end
    local x, y = w.dimen.x, w.dimen.y
    local p = w.parent
    while p do
        if p.dimen then
            x = x + (p.dimen.x or 0)
            y = y + (p.dimen.y or 0)
        end
        p = p.parent
    end
    self._mascot_bbox = Geom:new{ x = x, y = y, w = w.dimen.w, h = w.dimen.h }
    return self._mascot_bbox
end

function UsageScreen:onExtraTap(pos, slop)
    local bbox = self:mascotBBox()
    if bbox and ScreenBase.inside(ScreenBase.expand(bbox, slop), pos) then
        self:triggerShy()
        return true
    end
end

-- layout --------------------------------------------------------------------
function UsageScreen:makeCard(title, frac, epoch, card_w)
    local pad = sb(Theme.card.padding)
    local group = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = title, face = face(15), bold = true, fgcolor = C.active },
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = Fmt.pct(frac), face = face(48), bold = true },
        VerticalSpan:new{ width = sb(8) },
        ProgressWidget:new{
            width = card_w - 2 * pad,
            height = sb(16),
            percentage = frac or 0,
            bordersize = sb(1),
            bordercolor = C.active,
            bgcolor = C.white,
            fillcolor = C.bar,
        },
        VerticalSpan:new{ width = sb(12) },
        TextWidget:new{ text = T("RESETS IN - ") .. Fmt.resetDate(epoch),
                        face = face(12), bold = true, fgcolor = C.muted },
        VerticalSpan:new{ width = sb(2) },
        TextWidget:new{ text = Fmt.resetIn(epoch), face = face(28), bold = true },
    }
    return FrameContainer:new{
        width = card_w,
        bordersize = sb(Theme.card.bordersize),
        radius = sb(Theme.card.radius),
        padding = pad,
        margin = 0,
        background = C.fill,
        bordercolor = C.rule,
        group,
    }
end

function UsageScreen:mascotHolder()
    local status = self.data and self.data[H_STATUS]
    local emotion = Clawd.emotionFor(self:maxPct(), status)
    local mascot = self:mkClawd(emotion, self.mascot_scale,
                                { anim = self.cur_anim, phase = self.cur_phase })
    self._mascot_ref = mascot
    return VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = self.cur_bob or 0 },
        mascot,
    }
end

function UsageScreen:statusText()
    if self.err then return T("network error") end
    local status = self.data and self.data[H_STATUS]
    if status == "rejected" then return T("LIMITED") end
    if status == "allowed_warning" then return T("WARNING") end
    if status == "allowed" then return "OK" end
    return "..."
end

function UsageScreen:buildDataColumn()
    return VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = T("STATUS: ") .. self:statusText(),
                        face = face(15), bold = true },
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = string.format(T("PEAK USE: %d%%"), math.floor(self:maxPct())),
                        face = face(13), bold = true, fgcolor = C.muted },
    }
end

-- `anim_only` narrows the repaint to the mascot, so an animation frame does not
-- flash the whole page.
function UsageScreen:rebuild(anim_only)
    if self.closed then return end
    -- A rebuild triggered by anything other than doFetch (rotation, language,
    -- interval change) already repaints on its own; invalidate the cached sig
    -- so the next tick's doFetch does not mistake stale state for a match.
    if not anim_only then self._last_sig = nil end

    -- Capture the mascot rect BEFORE tearing the tree down; its position is
    -- stable across frames (the bob fits inside the margin).
    local dirty_region
    if anim_only then
        local bbox = self:mascotBBox()
        if bbox then dirty_region = ScreenBase.expand(bbox, sb(10)) end
    end

    local landscape, base, lw = self:beginRebuild()
    self._mascot_bbox = nil   -- the mascot widget is rebuilt below
    self.mascot_scale = math.max(4, math.floor((base * 0.42) / Clawd.W))

    local h = self.data
    local p5, p7 = Fmt.num(h, H5_PCT), Fmt.num(h, H7_PCT)
    local e5, e7 = Fmt.num(h, H5_RESET), Fmt.num(h, H7_RESET)

    local top = self:buildTop(self:updatedLabel(h ~= nil), lw)
    local bottom = self:makeBottomBar(self.page_idx)

    local lower = HorizontalGroup:new{
        align = "center",
        self:mascotHolder(),
        HorizontalSpan:new{ width = sb(28) },
        self:buildDataColumn(),
    }

    local body
    if landscape then
        local card_w = math.floor(lw * 0.44)
        body = HorizontalGroup:new{
            align = "center",
            VerticalGroup:new{
                align = "center",
                self:makeCard(T("5 HOURS"), p5, e5, card_w),
                VerticalSpan:new{ width = sb(12) },
                self:makeCard(T("WEEKLY"), p7, e7, card_w),
            },
            HorizontalSpan:new{ width = sb(28) },
            lower,
        }
    else
        local card_w = math.floor((lw - sb(12)) / 2)
        body = VerticalGroup:new{
            align = "center",
            HorizontalGroup:new{
                align = "top",
                self:makeCard(T("5 HOURS"), p5, e5, card_w),
                HorizontalSpan:new{ width = sb(12) },
                self:makeCard(T("WEEKLY"), p7, e7, card_w),
            },
            VerticalSpan:new{ width = sb(20) },
            lower,
        }
    end

    self[1] = self:_screenFrame(top, body, bottom)
    self:markDirty(dirty_region)
end

return UsageScreen
