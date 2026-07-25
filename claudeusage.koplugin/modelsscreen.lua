--[[
ModelScreen — Page 2 "Models" for the Claude Usage KOReader plugin.

A 2x2 grid (portrait) / 1x4 row (landscape) of the four Claude models
(Haiku / Sonnet / Opus / Fable). Each cell shows a Clawd mascot whose mood
reflects the model's health plus a status pill with latency (OK 0.9s / LIMITADO
/ ERRO 500 / AUTH / REDE / N/D / --). Below the grid: a "Sonda real na API"
note and the status.claude.com incident line.

Health comes from two sources (mirrors the ESP32 firmware): a real per-model
probe (POST /v1/messages, max_tokens:1, HTTP code + latency) rotated ONE model
per refresh cycle, plus status.claude.com unresolved incidents. All the fetching
lives on the plugin (main.lua); this screen only renders and drives the loop.

Swipe right returns to Page 1 (dashboard). Light theme, e-ink grayscale.
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
local IconWidget = require("ui/widget/iconwidget")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Clawd = require("clawd")
local T = require("i18n").t

local NAV_LABELS = { T("Uso"), T("Modelos"), T("5h") }

local ModelScreen = InputContainer:extend{
    plugin = nil,
    page_idx = 2,
}

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

-- A status pill with explicit background / foreground / border colors.
local function pill(text, bg, fg, border)
    return FrameContainer:new{
        bordersize = sb(1), radius = sb(12), padding = sb(6), margin = 0,
        bordercolor = border or Blitbuffer.Color8(0x88),
        background = bg or Blitbuffer.Color8(0xF4),
        TextWidget:new{ text = " " .. text .. " ", face = face(14), bold = true,
                        fgcolor = fg or Blitbuffer.Color8(0x22) },
    }
end

-- Map a probe result -> pill widget (text + grayscale severity colors).
local function modelChip(res)
    local code = res and res.code
    local light, dark, mid, err = Blitbuffer.Color8(0xF4), Blitbuffer.Color8(0x22),
                                  Blitbuffer.Color8(0xAA), Blitbuffer.Color8(0x44)
    local muted, faint = Blitbuffer.Color8(0x88), Blitbuffer.Color8(0xBB)
    if not code or code == 0 then
        return pill("--", light, faint, Blitbuffer.Color8(0xCC))
    elseif code == 200 then
        return pill(string.format("OK %.1fs", (res.ms or 0) / 1000), light, dark, muted)
    elseif code == 429 then
        return pill("LIMITADO", mid, dark, muted)
    elseif code == 404 then
        return pill("N/D", light, muted, Blitbuffer.Color8(0xCC))
    elseif code == 401 or code == 403 then
        return pill("AUTH", err, light, dark)
    elseif code < 0 then
        return pill("REDE", err, light, dark)
    else
        return pill("ERRO " .. tostring(code), err, light, dark)
    end
end

function ModelScreen:init()
    self.modal = true
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.orig_rotation = Screen:getRotationMode()
    self.rotated = false
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
function ModelScreen:doFetch()
    if self.closed then return end
    -- Eager (all 4) only while some model was never probed; then 1 per cycle.
    local auth = self.plugin:refreshModels()
    self.last_ok = os.time()
    self:rebuild()
    if auth then self.plugin:webLogin() end   -- token expired -> QR login modal
    self:rescheduleRefresh()
end

function ModelScreen:rescheduleRefresh()
    UIManager:unschedule(self.refresh_task)
    if self.plugin.refresh_interval > 0 then
        UIManager:scheduleIn(self.plugin.refresh_interval, self.refresh_task)
    end
end

-- gestures ------------------------------------------------------------------
function ModelScreen:onTap(a, b)
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
    return true
end

-- Swipe east (finger moved right) -> back to the dashboard (page 1).
-- KOReader swipe directions are compass points, not left/right.
function ModelScreen:onSwipe(a, b)
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

function ModelScreen:onClose()
    self.plugin:closeUI()
    return true
end

function ModelScreen:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self.refresh_task)
end

-- widgets -------------------------------------------------------------------
function ModelScreen:mkClawd(emotion, scale)
    local w = Clawd.makeWidget(emotion, scale, nil, Blitbuffer.COLOR_WHITE)
    table.insert(self._disposables, w)
    return w
end

function ModelScreen:buildHeader(updated)
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

-- Bottom navigation: one text button per page, current highlighted.
function ModelScreen:makeNav(active)
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

-- Bottom bar: rotate buttons in each corner + centered navigation.
function ModelScreen:makeBottomBar(active)
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

-- One model cell: mascot + name + status pill inside a light rounded frame.
function ModelScreen:makeModelCard(i, card_w)
    local model = self.plugin.MODELS[i]
    local res = self.plugin._model_results[i]
    local inc = self.plugin._incidents
    local is_up = inc and inc.up and inc.up[model.name]
    if inc and not inc.has_data then is_up = nil end   -- unknown, not "down"
    local emotion = Clawd.moodForProbe(res and res.code, is_up)

    local group = VerticalGroup:new{
        align = "center",
        self:mkClawd(emotion, self.mascot_scale),
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = model.name, face = face(16), bold = true },
        VerticalSpan:new{ width = sb(4) },
        modelChip(res),
    }
    -- Diagnostic: show the API error message for any non-OK probe.
    if res and res.reason and res.code ~= 200 then
        table.insert(group, VerticalSpan:new{ width = sb(4) })
        table.insert(group, TextWidget:new{
            text = res.reason, face = face(10), max_width = card_w - sb(20),
            fgcolor = Blitbuffer.Color8(0x88) })
    end
    return FrameContainer:new{
        width = card_w,
        bordersize = sb(1),
        radius = sb(10),
        padding = sb(10),
        margin = 0,
        background = Blitbuffer.Color8(0xF4),
        bordercolor = Blitbuffer.Color8(0xB4),
        CenterContainer:new{
            dimen = Geom:new{ w = card_w - sb(20), h = group:getSize().h },
            group,
        },
    }
end

function ModelScreen:buildInfoLines()
    local inc = self.plugin._incidents
    local incident_line
    if not inc or not inc.has_data then
        incident_line = T("status.claude.com: sem dados")
    else
        local any_down = false
        for _, m in ipairs(self.plugin.MODELS) do
            if inc.up[m.name] == false then any_down = true end
        end
        incident_line = any_down and T("Incidente ativo - veja status.claude.com")
                                  or T("status.claude.com: OK - sem incidentes")
    end
    return VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = T("Sonda real na API: 4 na abertura, 1 por ciclo"),
                        face = face(13), fgcolor = Blitbuffer.Color8(0x77) },
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = incident_line,
                        face = face(13), fgcolor = Blitbuffer.Color8(0x77) },
    }
end

-- Full-screen white frame in three blocks: top anchored, bottom bar pinned,
-- body centered in the leftover space (40/60) for an even fill.
function ModelScreen:_screenFrame(top, body, bottom)
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

function ModelScreen:rebuild()
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

    local updated = self.last_ok
        and (T("atualizado ") .. os.date("%H:%M", self.last_ok))
        or T("carregando...")
    local header = self:buildHeader(updated)
    local divider = LineWidget:new{ background = Blitbuffer.Color8(0xB4),
        dimen = Geom:new{ w = lw, h = sb(2) } }
    local bottom = self:makeBottomBar(self.page_idx)

    local grid
    if landscape then
        self.mascot_scale = math.max(3, math.floor((base * 0.18) / Clawd.W))
        local card_w = math.floor((lw - sb(36)) / 4)
        grid = HorizontalGroup:new{ align = "top" }
        for i = 1, 4 do
            table.insert(grid, self:makeModelCard(i, card_w))
            if i < 4 then table.insert(grid, HorizontalSpan:new{ width = sb(12) }) end
        end
    else
        self.mascot_scale = math.max(3, math.floor((base * 0.24) / Clawd.W))
        local card_w = math.floor((lw - sb(12)) / 2)
        local function row(a, b)
            return HorizontalGroup:new{
                align = "top",
                self:makeModelCard(a, card_w),
                HorizontalSpan:new{ width = sb(12) },
                self:makeModelCard(b, card_w),
            }
        end
        grid = VerticalGroup:new{
            align = "center",
            row(1, 2),
            VerticalSpan:new{ width = sb(14) },
            row(3, 4),
        }
    end

    local top = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = sb(10) },
        header,
        VerticalSpan:new{ width = sb(6) },
        divider,
    }
    local body = VerticalGroup:new{
        align = "center",
        grid,
        VerticalSpan:new{ width = sb(18) },
        self:buildInfoLines(),
    }

    self[1] = self:_screenFrame(top, body, bottom)
    UIManager:setDirty(self, "ui")
end

return ModelScreen
