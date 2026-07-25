--[[
ModelScreen - page 2, per-model health.

A 2x2 grid (portrait) or a single row (landscape) of the four Claude models.
Each cell shows a Clawd mascot whose mood reflects that model's health, plus a
status chip with the latency. Health comes from two sources: a real probe
(POST /v1/messages, max_tokens:1 - HTTP code plus round trip), rotated one model
per refresh cycle, and the unresolved incidents from status.claude.com.

All the fetching lives on the controller; this screen renders and drives the loop.
Everything shared with the other pages lives in screenbase.lua.
]]--

local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget = require("ui/widget/textwidget")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Clawd = require("clawd")
local ScreenBase = require("screenbase")
local Theme = require("theme")

local sb, face, C = Theme.sb, Theme.face, Theme.color

local ModelScreen = ScreenBase:extend{
    page_idx = 2,
}

-- Probe result -> status chip. Grayscale severity: light for fine, dark fill for
-- something the user has to act on.
local function modelChip(res)
    local code = res and res.code
    local dark_fill = Blitbuffer.Color8(0x44)
    local mid_fill = Blitbuffer.Color8(0xAA)
    local pale = Blitbuffer.Color8(0xBB)
    local pale_border = Blitbuffer.Color8(0xCC)

    if not code or code == 0 then
        return ScreenBase.pill("--", C.fill, pale, pale_border)
    elseif code == 200 then
        return ScreenBase.pill(string.format("OK %.1fs", (res.ms or 0) / 1000),
                               C.fill, C.fg, C.border)
    elseif code == 429 then
        return ScreenBase.pill("LIMITADO", mid_fill, C.fg, C.border)
    elseif code == 404 then
        return ScreenBase.pill("N/D", C.fill, C.border, pale_border)
    elseif code == 401 or code == 403 then
        return ScreenBase.pill("AUTH", dark_fill, C.fill, C.fg)
    elseif code < 0 then
        return ScreenBase.pill("REDE", dark_fill, C.fill, C.fg)
    end
    return ScreenBase.pill("ERRO " .. tostring(code), dark_fill, C.fill, C.fg)
end

-- data ----------------------------------------------------------------------
function ModelScreen:doFetch()
    if self.closed then return end
    -- Eager (all four) only while some model was never probed; then one per cycle.
    local auth, err = self.plugin:refreshModels()
    self.err = err
    if not err then self.last_ok = os.time() end
    self:rebuild()
    if auth then self.plugin:webLogin() end   -- token expired -> QR login modal
    self:rescheduleRefresh()
end

-- layout --------------------------------------------------------------------
function ModelScreen:makeModelCard(i, card_w)
    local model = self.plugin.MODELS[i]
    local res = self.plugin._model_results[i]
    local inc = self.plugin._incidents
    -- No incident data means "unknown", not "down".
    local is_up = (inc and inc.has_data) and inc.up[model.name] or nil
    local emotion = Clawd.moodForProbe(res and res.code, is_up)

    local group = VerticalGroup:new{
        align = "center",
        self:mkClawd(emotion, self.mascot_scale),
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = model.name, face = face(16), bold = true },
        VerticalSpan:new{ width = sb(4) },
        modelChip(res),
    }
    -- Diagnostic: the API's own message for any non-OK probe, which is how you
    -- tell "rate limited" from "this model is not on your plan".
    if res and res.reason and res.code ~= 200 then
        table.insert(group, VerticalSpan:new{ width = sb(4) })
        table.insert(group, TextWidget:new{
            text = res.reason, face = face(10), max_width = card_w - sb(20),
            fgcolor = C.border })
    end
    return FrameContainer:new{
        width = card_w,
        bordersize = sb(Theme.card.bordersize),
        radius = sb(Theme.card.radius),
        padding = sb(Theme.card.padding),
        margin = 0,
        background = C.fill,
        bordercolor = C.rule,
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
        incident_line = "status.claude.com: sem dados"
    else
        local any_down = false
        for _, m in ipairs(self.plugin.MODELS) do
            if inc.up[m.name] == false then any_down = true end
        end
        incident_line = any_down and "Incidente ativo - veja status.claude.com"
                                  or "status.claude.com: OK - sem incidentes"
    end
    return VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = "Sonda real na API: 4 na abertura, 1 por ciclo",
                        face = face(13), fgcolor = C.muted },
        VerticalSpan:new{ width = sb(6) },
        TextWidget:new{ text = incident_line, face = face(13), fgcolor = C.muted },
    }
end

function ModelScreen:rebuild()
    if self.closed then return end
    local landscape, base, lw = self:beginRebuild()

    local top = self:buildTop(self:updatedLabel(self.last_ok ~= nil), lw)
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
