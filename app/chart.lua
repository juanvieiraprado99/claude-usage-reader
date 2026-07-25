--[[
Chart — renders the 5h-window trend graph into a Blitbuffer and wraps it in an
ImageWidget. Grayscale, e-ink friendly (no anti-aliasing, updates only on fetch).

Chart.makeWidget(opts) where opts = {
    w, h,                  -- pixel size of the chart area
    samples,               -- { {t=epoch, v=0..1}, ... } chronological
    win_start, win_end,    -- x-domain (epoch): window start .. reset time
    cur_pct, cur_epoch,    -- latest point
    projection,            -- optional { eta, end_pct } for the dashed line
}
Solid line = real history; dashed line = burn-rate projection; small filled
circle = current point; three faint horizontal grid lines at 25/50/75%.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local ImageWidget = require("ui/widget/imagewidget")

local Chart = {}

local C_GRID = Blitbuffer.Color8(0xBB)
local C_LINE = Blitbuffer.Color8(0x33)
local C_PROJ = Blitbuffer.Color8(0x66)
local C_DOT  = Blitbuffer.Color8(0x22)

local function drawLine(bb, x0, y0, x1, y1, color)
    x0, y0, x1, y1 = math.floor(x0), math.floor(y0), math.floor(x1), math.floor(y1)
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx - dy
    while true do
        bb:paintRect(x0, y0, 1, 1, color)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x0 = x0 + sx end
        if e2 < dx then err = err + dx; y0 = y0 + sy end
    end
end

-- 2px-thick line (draw the segment plus a 1px vertical offset copy).
local function drawThickLine(bb, x0, y0, x1, y1, color)
    drawLine(bb, x0, y0, x1, y1, color)
    drawLine(bb, x0, y0 + 1, x1, y1 + 1, color)
end

local function drawDashedLine(bb, x0, y0, x1, y1, color, dash, gap)
    local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
    if len == 0 then return end
    local ux, uy = (x1 - x0) / len, (y1 - y0) / len
    local pos = 0
    while pos < len do
        local seg = math.min(dash, len - pos)
        drawLine(bb, x0 + ux * pos, y0 + uy * pos,
                     x0 + ux * (pos + seg), y0 + uy * (pos + seg), color)
        pos = pos + dash + gap
    end
end

local function drawDot(bb, cx, cy, r, color)
    for dy = -r, r do
        for dx = -r, r do
            if dx * dx + dy * dy <= r * r then
                bb:paintRect(math.floor(cx + dx), math.floor(cy + dy), 1, 1, color)
            end
        end
    end
end

function Chart.makeWidget(opts)
    local w, h = math.max(2, opts.w or 2), math.max(2, opts.h or 2)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)

    local span = (opts.win_end or 0) - (opts.win_start or 0)
    if span <= 0 then span = 1 end
    local win_start = opts.win_start or 0
    local function px(t) return (t - win_start) / span * (w - 1) end
    local function py(v) return (1 - math.max(0, math.min(1, v))) * (h - 1) end

    -- Grid lines at 25 / 50 / 75%
    for _, frac in ipairs({ 0.25, 0.5, 0.75 }) do
        local gy = math.floor(py(frac))
        bb:paintRect(0, gy, w, 1, C_GRID)
    end

    -- History polyline
    local s = opts.samples or {}
    for i = 2, #s do
        drawThickLine(bb, px(s[i - 1].t), py(s[i - 1].v),
                          px(s[i].t), py(s[i].v), C_LINE)
    end

    -- Current point + projection
    if opts.cur_pct and opts.cur_epoch then
        local cx, cy = px(opts.cur_epoch), py(opts.cur_pct)
        -- connect last sample to the current point if they differ
        if #s > 0 then
            drawThickLine(bb, px(s[#s].t), py(s[#s].v), cx, cy, C_LINE)
        end
        local proj = opts.projection
        if proj and proj.eta and proj.end_pct then
            drawDashedLine(bb, cx, cy, px(proj.eta), py(proj.end_pct), C_PROJ, 6, 4)
        end
        drawDot(bb, cx, cy, 3, C_DOT)
    end

    return ImageWidget:new{
        image = bb,
        image_disposable = true,
        width = w,
        height = h,
    }
end

return Chart
