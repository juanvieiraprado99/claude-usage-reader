--[[
UsageScreen — fullscreen Claude usage dashboard for KOReader (e-ink, grayscale).

Two cards (session 5h / weekly 7d): big %, progress bar, reset date + countdown.
Clawd mascot with usage-driven resting face + random occasional animations
(blink / shy / heart / sparkle). A tappable label cycles the fetch interval; a
"Girar" button flips portrait<->landscape (the device has no rotation sensor);
"X Fechar" closes. Auto-refresh + animations run only while this screen is open.
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
local ProgressWidget = require("ui/widget/progresswidget")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Clawd = require("clawd")
local T = require("i18n").t

local INTERVAL_CYCLE = { 0, 5, 10, 15, 30 }
local ANIM_MIN, ANIM_MAX = 5, 20          -- random seconds between animations
local ROTA_PORTRAIT  = Screen.DEVICE_ROTATED_UPRIGHT or 0
local ROTA_LANDSCAPE = Screen.DEVICE_ROTATED_CLOCKWISE or 1

local UsageScreen = InputContainer:extend{
    plugin = nil,
    data = nil,
    err = nil,
    cur_anim = nil,     -- animation name (nil = resting)
    cur_phase = 0,
    cur_bob = 0,        -- mascot vertical bob in px
}

local function sb(n) return Screen:scaleBySize(n) end
local function face(sz) return Font:getFace("cfont", sz) end
local function inside(geom, pos)
    return geom and pos and pos.x >= geom.x and pos.x < geom.x + geom.w
        and pos.y >= geom.y and pos.y < geom.y + geom.h
end
local function num(h, key)
    local v = h and h[key]
    return v and tonumber(v) or nil
end
local function pct_str(frac)
    if not frac then return "--%" end
    return string.format("%d%%", math.floor(frac * 100 + 0.5))
end
local function reset_date(epoch)
    if not epoch then return "--" end
    return os.date("%a %H:%M", epoch)
end
local function reset_in(epoch)
    if not epoch then return "--" end
    local secs = epoch - os.time()
    if secs < 0 then return T("now") end
    local hrs = math.floor(secs / 3600)
    local mins = math.floor((secs % 3600) / 60)
    if hrs > 24 then return string.format("%dd %dh", math.floor(hrs / 24), hrs % 24) end
    return string.format("%dh %dm", hrs, mins)
end

function UsageScreen:init()
    self.modal = true
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.orig_rotation = Screen:getRotationMode()
    self.rotated = false
    self._disposables = {}
    math.randomseed(os.time())

    self.close_btn = nil
    self.interval_btn = nil
    self.rotate_btn = nil
    self._mascot_ref = nil
    self._mascot_bbox = nil

    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }

    self.refresh_task = function() self:doFetch() end
    self.anim_task = function() self:playRandomAnim() end

    self:rebuild()
    self:scheduleNextAnim()
    UIManager:nextTick(function() self:doFetch() end)
end

-- data / scheduling ---------------------------------------------------------
function UsageScreen:doFetch()
    if self.closed then return end
    local h, err, auth = self.plugin:fetch()
    if h then self.data, self.err = h, nil else self.err = err end
    self.last_ok = os.time()
    self:rebuild()
    if auth then self.plugin:webLogin() end   -- token expired -> QR login modal
    self:rescheduleRefresh()
end

function UsageScreen:rescheduleRefresh()
    UIManager:unschedule(self.refresh_task)
    if self.plugin.refresh_interval > 0 then
        UIManager:scheduleIn(self.plugin.refresh_interval, self.refresh_task)
    end
end

-- animation -----------------------------------------------------------------
function UsageScreen:maxPct()
    local p5 = num(self.data, "anthropic-ratelimit-unified-5h-utilization")
    local p7 = num(self.data, "anthropic-ratelimit-unified-7d-utilization")
    return math.max((p5 or 0), (p7 or 0)) * 100
end

function UsageScreen:scheduleNextAnim()
    if self.closed then return end
    UIManager:unschedule(self.anim_task)
    UIManager:scheduleIn(math.random(ANIM_MIN, ANIM_MAX), self.anim_task)
end

-- Pick an animation, biased by usage.
function UsageScreen:pickAnim()
    local maxp = self:maxPct()
    local pool
    if maxp >= 75 then pool = { "shy", "shy", "blink", "sparkle" }
    elseif maxp < 50 then pool = { "heart", "heart", "blink", "sparkle" }
    else pool = { "sparkle", "blink", "heart", "shy" } end
    return pool[math.random(#pool)]
end

function UsageScreen:playRandomAnim()
    if self.closed then return end
    local name = self:pickAnim()
    local spec = Clawd.ANIMS[name] or { frames = 2, step = 0.15 }
    local i = 0
    local function step()
        if self.closed then return end
        i = i + 1
        if i > spec.frames then
            self.cur_anim, self.cur_phase, self.cur_bob = nil, 0, 0
            self:rebuild()
            self:scheduleNextAnim()
            return
        end
        self.cur_anim, self.cur_phase = name, i
        self.cur_bob = (i % 2 == 0) and sb(3) or 0
        self:rebuild()
        UIManager:scheduleIn(spec.step, step)
    end
    step()
end

-- Build a Clawd widget and register its Blitbuffer for freeing next rebuild.
function UsageScreen:mkClawd(emotion, scale, opts)
    local w = Clawd.makeWidget(emotion, scale, opts, Blitbuffer.COLOR_WHITE)
    table.insert(self._disposables, w)
    return w
end

-- gestures ------------------------------------------------------------------
local function expand(geom, m)
    if not geom then return nil end
    return Geom:new{ x = geom.x - m, y = geom.y - m,
                     w = geom.w + 2 * m, h = geom.h + 2 * m }
end

function UsageScreen:mascotBBox()
    if self._mascot_bbox then return self._mascot_bbox end
    local w = self._mascot_ref
    if not w or not w.dimen then return nil end
    -- Walk up the parent chain to get absolute screen coordinates.
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

function UsageScreen:triggerShy()
    if self.cur_anim then return end   -- don't interrupt a running animation
    self.cur_anim = "shy"
    self.cur_phase = 0
    local spec = Clawd.ANIMS.shy
    local i = 0
    local function step()
        if self.closed then return end
        i = i + 1
        if i > spec.frames then
            self.cur_anim, self.cur_phase, self.cur_bob = nil, 0, 0
            self:rebuild()
            self:scheduleNextAnim()
            return
        end
        self.cur_phase = i
        self.cur_bob = (i % 2 == 0) and sb(3) or 0
        self:rebuild()
        UIManager:scheduleIn(spec.step, step)
    end
    step()
end

function UsageScreen:onTap(a, b)
    local ges = b or a
    local pos = ges and ges.pos
    local m = sb(12)
    if self.close_btn and inside(expand(self.close_btn.dimen, m), pos) then
        self:onClose(); return true
    end
    if self.rotate_btn and inside(expand(self.rotate_btn.dimen, m), pos) then
        self:toggleRotation(); return true
    end
    if self.interval_btn and inside(expand(self.interval_btn.dimen, m), pos) then
        self:cycleInterval(); return true
    end
    -- Tap on the mascot -> shy animation
    local bbox = self:mascotBBox()
    if bbox and inside(expand(bbox, m), pos) then
        self:triggerShy(); return true
    end
    return true
end

function UsageScreen:cycleInterval()
    local cur = self.plugin.refresh_interval
    local nxt = INTERVAL_CYCLE[1]
    for i, v in ipairs(INTERVAL_CYCLE) do
        if v == cur then nxt = INTERVAL_CYCLE[(i % #INTERVAL_CYCLE) + 1]; break end
    end
    if self.plugin:setRefreshInterval(nxt) then
        self:rescheduleRefresh()
        self:rebuild()
    end
end

function UsageScreen:toggleRotation()
    local target = (Screen:getWidth() > Screen:getHeight()) and ROTA_PORTRAIT or ROTA_LANDSCAPE
    UIManager:broadcastEvent(Event:new("SetRotationMode", target))
    self.rotated = (target ~= self.orig_rotation)
    self:rebuild()
end

function UsageScreen:onClose()
    UIManager:close(self)
    return true
end

function UsageScreen:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self.refresh_task)
    UIManager:unschedule(self.anim_task)
    if self.rotated then
        UIManager:broadcastEvent(Event:new("SetRotationMode", self.orig_rotation))
    end
end

-- layout --------------------------------------------------------------------
function UsageScreen:makeCard(title, frac, epoch, card_w)
    local pad = sb(10)
    local inner_w = card_w - 2 * pad
    local bar = ProgressWidget:new{
        width = inner_w,
        height = sb(16),
        percentage = frac or 0,
        bordersize = sb(1),
        bordercolor = Blitbuffer.Color8(0x66),
        bgcolor = Blitbuffer.COLOR_WHITE,
        fillcolor = Blitbuffer.Color8(0x33),
    }
    local group = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = title, face = face(15), bold = true,
                        fgcolor = Blitbuffer.Color8(0x66) },
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = pct_str(frac), face = face(48), bold = true },
        VerticalSpan:new{ width = sb(8) },
        bar,
        VerticalSpan:new{ width = sb(12) },
        TextWidget:new{ text = T("RESETS AT ") .. reset_date(epoch),
                        face = face(12), fgcolor = Blitbuffer.Color8(0x77) },
        VerticalSpan:new{ width = sb(2) },
        TextWidget:new{ text = reset_in(epoch), face = face(28), bold = true },
    }
    return FrameContainer:new{
        width = card_w,
        bordersize = sb(1),
        radius = sb(10),
        padding = pad,
        margin = 0,
        background = Blitbuffer.Color8(0xF4),
        bordercolor = Blitbuffer.Color8(0xB4),
        group,
    }
end

function UsageScreen:mascotHolder()
    local status = self.data and self.data["anthropic-ratelimit-unified-status"]
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
    local status = self.data and self.data["anthropic-ratelimit-unified-status"]
    if self.err then return T("network error") end
    if status == "rejected" then return T("LIMITED") end
    if status == "allowed_warning" then return T("WARNING") end
    if status == "allowed" then return "OK" end
    return "..."
end

local function pill(text, bg)
    return FrameContainer:new{
        bordersize = sb(1), radius = sb(12), padding = sb(6), margin = 0,
        bordercolor = Blitbuffer.Color8(0x88),
        background = bg or Blitbuffer.Color8(0xF4),
        TextWidget:new{ text = " " .. text .. " ", face = face(14), bold = true },
    }
end

function UsageScreen:buildHeader(updated)
    local head_scale = math.max(2, math.floor(self.mascot_scale / 4))
    local left = HorizontalGroup:new{
        align = "center",
        self:mkClawd("neutral", head_scale, nil),
        HorizontalSpan:new{ width = sb(8) },
        TextWidget:new{ text = "CLAUDE CODE", face = face(18), bold = true },
    }
    self.close_btn = pill(T("X Close"), Blitbuffer.Color8(0xF4))
    local right = HorizontalGroup:new{
        align = "center",
        TextWidget:new{ text = updated, face = face(12), fgcolor = Blitbuffer.Color8(0x77) },
        HorizontalSpan:new{ width = sb(12) },
        self.close_btn,
    }
    local gap = math.max(sb(8), self.width - left:getSize().w - right:getSize().w - sb(20))
    return HorizontalGroup:new{ align = "center", left, HorizontalSpan:new{ width = gap }, right }
end

function UsageScreen:buildFooter(interval_txt)
    self.interval_btn = pill(interval_txt .. T(" (tap)"), Blitbuffer.COLOR_WHITE)
    self.rotate_btn = pill(T("Rotate"), Blitbuffer.Color8(0xF4))
    return HorizontalGroup:new{
        align = "center",
        pill(self:statusText()),
        HorizontalSpan:new{ width = sb(18) },
        self.rotate_btn,
        HorizontalSpan:new{ width = sb(18) },
        self.interval_btn,
    }
end

function UsageScreen:rebuild()
    if self.closed then return end
    for _i, w in ipairs(self._disposables or {}) do
        if w.free then w:free() end
    end
    self._disposables = {}
    self._mascot_bbox = nil   -- mascot widget changes each rebuild

    -- Live dimensions (orientation may have changed).
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen.w, self.dimen.h = self.width, self.height
    local landscape = self.width > self.height
    local base = math.min(self.width, self.height)
    self.mascot_scale = math.max(4, math.floor((base * 0.34) / Clawd.W))

    local h = self.data
    local p5 = num(h, "anthropic-ratelimit-unified-5h-utilization")
    local p7 = num(h, "anthropic-ratelimit-unified-7d-utilization")
    local e5 = num(h, "anthropic-ratelimit-unified-5h-reset")
    local e7 = num(h, "anthropic-ratelimit-unified-7d-reset")

    local secs = self.plugin.refresh_interval
    local interval_txt = (secs == 0) and T("auto: off") or string.format(T("auto: %ds"), secs)
    local updated = self.err and T("failed") or (h and T("updated now") or T("loading..."))

    local header = self:buildHeader(updated)
    local footer = self:buildFooter(interval_txt)
    local divider = LineWidget:new{ background = Blitbuffer.Color8(0xB4),
        dimen = Geom:new{ w = self.width - sb(40), h = sb(2) } }

    local body
    if landscape then
        local card_w = math.floor(self.width * 0.38)
        local cards_col = VerticalGroup:new{
            align = "center",
            self:makeCard(T("5 HOURS"), p5, e5, card_w),
            VerticalSpan:new{ width = sb(12) },
            self:makeCard(T("WEEK"), p7, e7, card_w),
        }
        body = HorizontalGroup:new{
            align = "center",
            cards_col,
            HorizontalSpan:new{ width = sb(28) },
            self:mascotHolder(),
        }
    else
        local card_w = math.floor((self.width - sb(36)) / 2)
        local cards = HorizontalGroup:new{
            align = "top",
            self:makeCard(T("5 HOURS"), p5, e5, card_w),
            HorizontalSpan:new{ width = sb(12) },
            self:makeCard(T("WEEK"), p7, e7, card_w),
        }
        body = VerticalGroup:new{
            align = "center",
            cards,
            VerticalSpan:new{ width = sb(20) },
            self:mascotHolder(),
        }
    end

    local content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = sb(10) },
        header,
        VerticalSpan:new{ width = sb(6) },
        divider,
        VerticalSpan:new{ width = sb(16) },
        body,
        VerticalSpan:new{ width = sb(16) },
        footer,
    }

    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            content,
        },
    }
    UIManager:setDirty(self, "ui")
end

return UsageScreen
