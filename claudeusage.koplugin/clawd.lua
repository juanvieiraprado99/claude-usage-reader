--[[
Clawd — the Claude Code mascot, recreated as pixel-art in Lua.

Shape follows the idle reference sticker: a wide, solid rounded-square body with
a flat top, small 1px side "ear" nubs in the upper third, two big square eyes,
and two legs flanking a central notch. The body is built procedurally (so the
geometry/width is exact); features are stamped on top. Grayscale only
(KindleBasic2 is 16-level gray): terracotta -> mid gray, and the white sticker
outline -> a dark 1px outline (a white outline would vanish on the white page).

Resting faces (emotion, basis = max(5h,7d) + status):
    love/neutral  square eyes    strain  ">" "<"    dizzy  spiral
Animations (opts.anim, opts.phase) overlay on the resting face:
    blink   eyes -> line
    shy     ">" "<" + blush cheeks
    heart   a heart rises above the head
    sparkle an arm + a twinkling burst off the right side
]]--

local Blitbuffer = require("ffi/blitbuffer")
local ImageWidget = require("ui/widget/imagewidget")

local Clawd = {}

-- Grayscale palette (Color8: 0x00 = black, 0xFF = white). nil = transparent.
local PALETTE = {
    ["."] = nil,
    ["o"] = Blitbuffer.Color8(0x22),      -- outline, near-black
    ["b"] = Blitbuffer.Color8(0x8A),      -- body, mid gray
    ["l"] = Blitbuffer.Color8(0xB4),      -- highlight / blush / sparkle light
    ["E"] = Blitbuffer.Color8(0x00),      -- eye / face feature
    ["h"] = Blitbuffer.Color8(0x18),      -- heart
    ["n"] = Blitbuffer.Color8(0x00),      -- sparkle dark
}

local W, H = 26, 18
-- Body geometry (0-based). Rows 0..1 = heart zone; right cols 24..25 = sparkle.
local TOP, BOTTOM = 2, 13
local BL, BR = 2, 21          -- body left/right columns
local L, R = 7, 16            -- left/right eye centre columns
local EAR_ROWS = { 5, 6 }
local LEGS = { {5, 8}, {15, 18} }   -- {c1,c2} column spans

-- Build the base body as a fresh 0-indexed grid[r][c] of palette chars.
local function makeBase()
    local g = {}
    for r = 0, H - 1 do
        g[r] = {}
        for c = 0, W - 1 do g[r][c] = "." end
    end
    local function set(r, c, ch)
        if r >= 0 and r < H and c >= 0 and c < W then g[r][c] = ch end
    end
    local function fill(r, c1, c2, ch) for c = c1, c2 do set(r, c, ch) end end

    fill(TOP, BL, BR, "o")                                   -- head top
    set(TOP + 1, BL, "o"); fill(TOP + 1, BL + 1, BR - 1, "l"); set(TOP + 1, BR, "o")
    for r = TOP + 2, BOTTOM do                               -- body rows
        set(r, BL, "o"); fill(r, BL + 1, BR - 1, "b"); set(r, BR, "o")
    end
    for _i, r in ipairs(EAR_ROWS) do                         -- side ear nubs
        set(r, BL - 1, "o"); set(r, BR + 1, "o")
        set(r, BL, "b"); set(r, BR, "b")
    end
    set(BOTTOM, 11, "."); set(BOTTOM, 12, ".")               -- central notch
    for _i, lg in ipairs(LEGS) do                            -- legs
        for r = BOTTOM + 1, H - 1 do
            fill(r, lg[1], lg[2], "b")
            set(r, lg[1], "o"); set(r, lg[2], "o")
        end
        fill(H - 1, lg[1], lg[2], "o")                       -- foot bottom
    end
    return g
end

-- Face pixel lists (0-based) --------------------------------------------------
local function squareEye(cc)
    return { {5,cc-1},{5,cc},{5,cc+1}, {6,cc-1},{6,cc},{6,cc+1}, {7,cc-1},{7,cc},{7,cc+1} }
end
local function chevron(cc, dir)   -- ">" if dir>0, "<" if dir<0
    if dir > 0 then return { {5,cc-1},{6,cc+1},{7,cc-1} }
    else return { {5,cc+1},{6,cc-1},{7,cc+1} } end
end
local function spiralEye(cc)
    return { {5,cc-1},{5,cc},{5,cc+1}, {6,cc-1},{6,cc+1}, {7,cc-1},{7,cc},{7,cc+1}, {6,cc} }
end
local function lineEye(cc) return { {6,cc-1},{6,cc},{6,cc+1} } end

local function concat(a, b) for _i, p in ipairs(b) do a[#a+1] = p end return a end

local function faceFor(emotion)
    if emotion == "strain" then return concat(chevron(L, 1), chevron(R, -1))
    elseif emotion == "dizzy" then return concat(spiralEye(L), spiralEye(R))
    else return concat(squareEye(L), squareEye(R)) end
end

-- Decoration overlays ({r,c,char}) -------------------------------------------
local function heartOverlay(phase)
    local top = 3 - math.min(phase or 0, 3)     -- rises as phase grows
    local c = 4
    local rel = { {0,1},{0,3}, {1,0},{1,1},{1,2},{1,3},{1,4}, {2,1},{2,2},{2,3}, {3,2} }
    local out = {}
    for _i, p in ipairs(rel) do out[#out+1] = { top + p[1], c + p[2], "h" } end
    return out
end
local function sparkleOverlay(phase)
    local out = { {9,21,"o"},{9,22,"o"},{9,23,"o"} }
    local setA = { {6,23,"n"},{5,24,"l"},{8,24,"n"},{10,23,"l"},{7,25,"n"},{9,25,"l"} }
    local setB = { {5,23,"l"},{6,25,"n"},{7,24,"l"},{9,24,"n"},{11,23,"n"},{8,25,"l"} }
    local set = ((phase or 0) % 2 == 1) and setA or setB
    for _i, p in ipairs(set) do out[#out+1] = p end
    return out
end
local function blushOverlay()
    return { {8,L-1,"l"},{8,L,"l"}, {8,R,"l"},{8,R+1,"l"} }
end

Clawd.ANIMS = {
    blink   = { frames = 2, step = 0.12 },
    shy     = { frames = 4, step = 0.18 },
    heart   = { frames = 4, step = 0.30 },
    sparkle = { frames = 4, step = 0.16 },
}

local function buildGrid(emotion, anim, phase)
    local g = makeBase()
    local function stamp(r, c, ch)
        if r >= 0 and r < H and c >= 0 and c < W then g[r][c] = ch end
    end

    local face
    if anim == "shy" then face = concat(chevron(L, 1), chevron(R, -1))
    elseif anim == "blink" then face = concat(lineEye(L), lineEye(R))
    else face = faceFor(emotion) end
    for _i, p in ipairs(face) do stamp(p[1], p[2], "E") end

    local deco
    if anim == "shy" then deco = blushOverlay()
    elseif anim == "heart" then deco = heartOverlay(phase)
    elseif anim == "sparkle" then deco = sparkleOverlay(phase) end
    if deco then for _i, p in ipairs(deco) do stamp(p[1], p[2], p[3]) end end

    return g
end

local function render(g, scale, bg)
    local bb = Blitbuffer.new(W * scale, H * scale, Blitbuffer.TYPE_BB8)
    bb:fill(bg or Blitbuffer.COLOR_WHITE)
    for r = 0, H - 1 do
        for c = 0, W - 1 do
            local color = PALETTE[g[r][c]]
            if color then bb:paintRect(c * scale, r * scale, scale, scale, color) end
        end
    end
    return bb
end

-- Public: opts = { anim = "blink"|"shy"|"heart"|"sparkle"|nil, phase = n }
function Clawd.makeWidget(emotion, scale, opts, bg)
    scale = scale or 10
    opts = opts or {}
    local bb = render(buildGrid(emotion, opts.anim, opts.phase), scale, bg)
    return ImageWidget:new{
        image = bb,
        image_disposable = true,
        width = W * scale,
        height = H * scale,
    }
end

function Clawd.emotionFor(max_pct, status)
    if status == "rejected" then return "dizzy" end
    max_pct = max_pct or 0
    if max_pct >= 90 then return "dizzy" end
    if max_pct >= 75 then return "strain" end
    if max_pct >= 50 then return "neutral" end
    return "love"
end

Clawd.W, Clawd.H = W, H

return Clawd
