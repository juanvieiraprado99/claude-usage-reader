--[[
Rotate icon: a clockwise circular arrow, drawn pixel by pixel into a Blitbuffer.

Why not IconWidget? KOReader's icons are SVG, and rendering one pulls in
ImageWidget:_loadfile -> document/documentregistry, which registers the whole
document engine (crengine, mupdf, djvu). Those are exactly what the packaged
runtime prunes. Drawing it ourselves keeps the icon free of that dependency,
the same way clawd.lua and chart.lua build their own buffers.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local ImageWidget = require("ui/widget/imagewidget")

local RotIcon = {}

-- A thick ring with a slice missing in the upper right, and a solid arrowhead
-- pointing out of that gap. Grayscale only - the device has no color.
function RotIcon.makeWidget(size, fg, bg)
    size = math.max(8, math.floor(size or 18))
    fg = fg or Blitbuffer.COLOR_BLACK
    bg = bg or Blitbuffer.COLOR_WHITE

    local bb = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
    bb:fill(bg)

    local cx, cy = (size - 1) / 2, (size - 1) / 2
    local r_out = size * 0.40   -- leaves room for the arrow tip to stick out
    local thick = math.max(2, size * 0.16)
    local r_in = r_out - thick
    -- Screen coordinates: y grows downward, so negative angles are "up".
    -- This slice is where the arrowhead goes.
    local gap_from, gap_to = math.rad(-85), math.rad(-8)

    for y = 0, size - 1 do
        for x = 0, size - 1 do
            local dx, dy = x - cx, y - cy
            local d = math.sqrt(dx * dx + dy * dy)
            if d <= r_out and d >= r_in then
                local a = math.atan2(dy, dx)
                if a < gap_from or a > gap_to then
                    bb:paintRect(x, y, 1, 1, fg)
                end
            end
        end
    end

    -- Arrowhead: vertical base near the centre, tip pointing right, sitting
    -- inside the gap. Keep it below the top of the ring, or the two merge into
    -- one blob and the arrow stops reading as an arrow.
    local base_x = cx + r_in * 0.45
    local tip_x = cx + r_out * 1.20
    local head_y = cy - r_out * 0.62
    local half = thick * 1.15
    local span = math.max(1, tip_x - base_x)
    for i = 0, math.floor(span) do
        local h = half * (1 - i / span)
        for dy = -math.floor(h), math.floor(h) do
            local px, py = math.floor(base_x + i), math.floor(head_y + dy)
            if px >= 0 and px < size and py >= 0 and py < size then
                bb:paintRect(px, py, 1, 1, fg)
            end
        end
    end

    return ImageWidget:new{
        image = bb,
        image_disposable = true,
        width = size,
        height = size,
    }
end

return RotIcon
