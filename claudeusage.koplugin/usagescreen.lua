--[[
UsageScreen — fullscreen Claude usage dashboard for KOReader (e-ink, grayscale).

Layout mirrors the wireframe (PT labels, light theme): header shows
"atualizado HH:MM" + a FECHAR pill; two cards (session 5h / weekly 7d) with big
%, progress bar, "RESETA EM - <DIA HH:MM>" and a big countdown; a lower band with
the Clawd mascot (left) and a real-data column (right): STATUS, biggest usage,
an ATUALIZA pill that cycles the fetch interval, and a GIRAR pill that flips
portrait<->landscape (the device has no rotation sensor). Page dots at the bottom
are a static placeholder for a future page 2. The wireframe's "tokens janela
entrada/saída" are omitted — subscription accounts expose only percentages, never
raw token counts. Clawd's resting face is usage-driven with random occasional
animations (blink / shy / heart / sparkle). Auto-refresh + animations run only
while this screen is open.
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
local IconWidget = require("ui/widget/iconwidget")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Clawd = require("clawd")
local T = require("i18n").t

local ANIM_MIN, ANIM_MAX = 5, 20          -- random seconds between animations
local NAV_LABELS = { T("Uso"), T("Modelos"), T("5h") }

local UsageScreen = InputContainer:extend{
    plugin = nil,
    page_idx = 1,
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
local WEEKDAYS_PT = { "DOM", "SEG", "TER", "QUA", "QUI", "SEX", "SÁB" }
local function reset_date(epoch)
    if not epoch then return "--" end
    local t = os.date("*t", epoch)
    return string.format("%s %02d:%02d", WEEKDAYS_PT[t.wday] or "--", t.hour, t.min)
end
local function reset_in(epoch)
    if not epoch then return "--" end
    local secs = epoch - os.time()
    if secs < 0 then return T("now") end
    local hrs = math.floor(secs / 3600)
    local mins = math.floor((secs % 3600) / 60)
    if hrs > 24 then return string.format("%dD %dH", math.floor(hrs / 24), hrs % 24) end
    return string.format("%dH %dM", hrs, mins)
end

function UsageScreen:init()
    self.modal = true
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.orig_rotation = Screen:getRotationMode()
    self.rotated = false
    self._disposables = {}
    math.randomseed(os.time())

    self.settings_btn = nil
    self.nav_btns = nil
    self._mascot_ref = nil
    self._mascot_bbox = nil

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }

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
    if h then
        self.data, self.err = h, nil
        self.plugin:recordSample(num(h, "anthropic-ratelimit-unified-5h-utilization"))
    else
        self.err = err
    end
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
            self:rebuild(true)
            self:scheduleNextAnim()
            return
        end
        self.cur_anim, self.cur_phase = name, i
        self.cur_bob = (i % 2 == 0) and sb(3) or 0
        self:rebuild(true)
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
            self:rebuild(true)
            self:scheduleNextAnim()
            return
        end
        self.cur_phase = i
        self.cur_bob = (i % 2 == 0) and sb(3) or 0
        self:rebuild(true)
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
    if self.refresh_btn and inside(expand(self.refresh_btn.dimen, m), pos) then
        self.plugin:cycleInterval(); return true
    end
    if self.rot_p and inside(expand(self.rot_p.dimen, m), pos) then
        self.plugin:setRotationLandscape(false); return true
    end
    if self.rot_l and inside(expand(self.rot_l.dimen, m), pos) then
        self.plugin:setRotationLandscape(true); return true
    end
    for i, btn in ipairs(self.nav_btns or {}) do
        if i ~= self.page_idx and inside(expand(btn.dimen, m), pos) then
            UIManager:close(self); self.plugin:openPage(i); return true
        end
    end
    -- Tap on the mascot -> shy animation
    local bbox = self:mascotBBox()
    if bbox and inside(expand(bbox, m), pos) then
        self:triggerShy(); return true
    end
    return true
end

-- Swipe left/right to move between pages (dashboard <-> models).
-- KOReader swipe directions are compass points: west = finger moved left.
function UsageScreen:onSwipe(a, b)
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

-- Back key / hardware close -> full exit (restores rotation via the plugin).
function UsageScreen:onClose()
    self.plugin:closeUI()
    return true
end

function UsageScreen:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self.refresh_task)
    UIManager:unschedule(self.anim_task)
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
        TextWidget:new{ text = T("RESETA EM - ") .. reset_date(epoch),
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
    if self.err then return T("erro de rede") end
    if status == "rejected" then return T("LIMITADO") end
    if status == "allowed_warning" then return T("AVISO") end
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
        align = "center",
        left,
        HorizontalSpan:new{ width = gap },
        right,
    }
end

-- Bottom navigation: one text button per page, current highlighted. Refs kept
-- in self.nav_btns for tap hit-testing (onTap -> plugin:openPage).
function UsageScreen:makeNav(active)
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

-- Bottom bar: rotate buttons in each corner (left=portrait, right=landscape)
-- with the page navigation centered between them.
function UsageScreen:makeBottomBar(active)
    local nav = self:makeNav(active)
    self.rot_p = pill(T("RETRATO"), Blitbuffer.Color8(0xF4))
    self.rot_l = pill(T("PAISAGEM"), Blitbuffer.Color8(0xF4))
    local lw = self.width - 2 * sb(16)
    local sp = math.max(sb(8), math.floor(
        (lw - self.rot_p:getSize().w - self.rot_l:getSize().w - nav:getSize().w) / 2))
    return HorizontalGroup:new{
        align = "center",
        self.rot_p,
        HorizontalSpan:new{ width = sp },
        nav,
        HorizontalSpan:new{ width = sp },
        self.rot_l,
    }
end

-- Right-hand data column: real obtainable data (interval/rotate now live in the
-- settings dialog behind the gear icon).
function UsageScreen:buildDataColumn()
    return VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = T("STATUS: ") .. self:statusText(),
                        face = face(15), bold = true },
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = string.format(T("MAIOR USO: %d%%"), self:maxPct()),
                        face = face(13), fgcolor = Blitbuffer.Color8(0x77) },
    }
end

-- Full-screen white frame in three blocks: top (header) anchored, bottom bar
-- pinned, and the body centered in the leftover space (40% above / 60% below)
-- so the screen fills evenly instead of leaving one big gap.
function UsageScreen:_screenFrame(top, body, bottom)
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

function UsageScreen:rebuild(anim_only)
    if self.closed then return end
    -- Animation frames repaint only the mascot area (less e-ink flashing).
    -- Capture the previous mascot bbox BEFORE tearing the tree down; its
    -- position is stable across frames (bob is covered by the margin).
    local dirty_region
    if anim_only then
        local bbox = self:mascotBBox()
        if bbox then dirty_region = expand(bbox, sb(10)) end
    end
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
    local lw = self.width - 2 * sb(16)          -- inner width (side margins)
    self.mascot_scale = math.max(4, math.floor((base * 0.42) / Clawd.W))

    local h = self.data
    local p5 = num(h, "anthropic-ratelimit-unified-5h-utilization")
    local p7 = num(h, "anthropic-ratelimit-unified-7d-utilization")
    local e5 = num(h, "anthropic-ratelimit-unified-5h-reset")
    local e7 = num(h, "anthropic-ratelimit-unified-7d-reset")

    local updated = self.err and T("falhou")
        or (h and (T("atualizado ") .. os.date("%H:%M", self.last_ok)) or T("carregando..."))

    local header = self:buildHeader(updated)
    local bottom = self:makeBottomBar(self.page_idx)
    local divider = LineWidget:new{ background = Blitbuffer.Color8(0xB4),
        dimen = Geom:new{ w = lw, h = sb(2) } }

    -- Mascot (left) + real-data column (right) — the wireframe's lower band.
    local lower = HorizontalGroup:new{
        align = "center",
        self:mascotHolder(),
        HorizontalSpan:new{ width = sb(28) },
        self:buildDataColumn(),
    }

    local body
    if landscape then
        local card_w = math.floor(lw * 0.44)
        local cards_col = VerticalGroup:new{
            align = "center",
            self:makeCard(T("5 HORAS"), p5, e5, card_w),
            VerticalSpan:new{ width = sb(12) },
            self:makeCard(T("SEMANAL"), p7, e7, card_w),
        }
        body = HorizontalGroup:new{
            align = "center",
            cards_col,
            HorizontalSpan:new{ width = sb(28) },
            lower,
        }
    else
        local card_w = math.floor((lw - sb(12)) / 2)
        local cards = HorizontalGroup:new{
            align = "top",
            self:makeCard(T("5 HORAS"), p5, e5, card_w),
            HorizontalSpan:new{ width = sb(12) },
            self:makeCard(T("SEMANAL"), p7, e7, card_w),
        }
        body = VerticalGroup:new{
            align = "center",
            cards,
            VerticalSpan:new{ width = sb(20) },
            lower,
        }
    end

    local top = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = sb(10) },
        header,
        VerticalSpan:new{ width = sb(6) },
        divider,
    }

    self[1] = self:_screenFrame(top, body, bottom)
    UIManager:setDirty(self, "ui", dirty_region)
end

return UsageScreen
