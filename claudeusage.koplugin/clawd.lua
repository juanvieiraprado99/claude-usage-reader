--[[
Clawd — the Claude Code mascot, recreated as pixel-art in Lua.

Shape follows the reference sticker: a wide, solid rounded-square body with
a flat top, small side "ear" nubs in the upper third, two big square eyes,
and FOUR legs (2 pairs with gaps between them). The body is built
procedurally; features are stamped on top. Grayscale only (Kindle e-ink is
16-level gray): terracotta -> mid gray, and the white sticker outline -> a
dark 1px outline (white outline vanishes on the white page).

Resting faces (emotion, basis = max(5h,7d) + status):
    love/neutral  square eyes    strain  ">" "<"    dizzy  spiral
Animations (opts.anim, opts.phase) overlay on the resting face:
    blink   eyes -> line
    shy     ">" "<" + blush cheeks  (also triggered by tapping the mascot)
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

local W, H = 28, 24
-- Body geometry (0-based). Rows 3..16 = body; ears on rows 6..9.
local TOP, BOTTOM = 3, 16
local BL, BR = 3, 24          -- body left/right outline columns
local L, R = 9, 18            -- left/right eye centre columns

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

    -- Head top (outline)
    fill(TOP, BL, BR, "o")
    -- Head highlight row
    set(TOP + 1, BL, "o"); fill(TOP + 1, BL + 1, BR - 1, "l"); set(TOP + 1, BR, "o")
    -- Body fill rows
    for r = TOP + 2, BOTTOM do
        set(r, BL, "o"); fill(r, BL + 1, BR - 1, "b"); set(r, BR, "o")
    end
    -- Side ear nubs (protrude 2px on each side)
    for r = 6, 9 do
        set(r, BL - 2, "o"); set(r, BL - 1, "o")
        set(r, BL, "b")
        set(r, BR, "b")
        set(r, BR + 1, "o"); set(r, BR + 2, "o")
    end
    -- Central notch at body bottom (gap between inner legs)
    set(BOTTOM, 12, "."); set(BOTTOM, 13, ".")
    -- FOUR legs: outer-left, inner-left, inner-right, outer-right
    local legs = { {5, 7}, {9, 11}, {16, 18}, {20, 22} }
    for _, lg in ipairs(legs) do
        for r = BOTTOM + 1, H - 2 do
            fill(r, lg[1], lg[2], "b")
            set(r, lg[1], "o"); set(r, lg[2], "o")
        end
        fill(H - 1, lg[1], lg[2], "o")   -- foot bottom
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
    -- 5x5 box outline + center dot (matches original dizzy reference)
    return {
        {5,cc-2},{5,cc-1},{5,cc},{5,cc+1},{5,cc+2},
        {6,cc-2},{6,cc+2},
        {7,cc-2},{7,cc},{7,cc+2},
        {8,cc-2},{8,cc+2},
        {9,cc-2},{9,cc-1},{9,cc},{9,cc+1},{9,cc+2},
        {7,cc},
    }
end
local function lineEye(cc) return { {6,cc-1},{6,cc},{6,cc+1} } end

local function concat(a, b) for _, p in ipairs(b) do a[#a+1] = p end return a end

local function faceFor(emotion)
    if emotion == "strain" then return concat(chevron(L, 1), chevron(R, -1))
    elseif emotion == "dizzy" then return concat(spiralEye(L), spiralEye(R))
    else return concat(squareEye(L), squareEye(R)) end
end

-- Decoration overlays ({r,c,char}) -------------------------------------------
local function blushOverlay()
    return { {9,L-2,"l"},{9,L-1,"l"}, {9,R+1,"l"},{9,R+2,"l"} }
end
local function heartOverlay(phase)
    local top = 1 - math.min(phase or 0, 3)     -- rises as phase grows
    local c = 4
    local rel = {
        {0,1},{0,2},{0,4},{0,5},
        {1,0},{1,1},{1,2},{1,3},{1,4},{1,5},{1,6},
        {2,0},{2,1},{2,2},{2,3},{2,4},{2,5},{2,6},
        {3,1},{3,2},{3,3},{3,4},{3,5},
        {4,2},{4,3},{4,4},
        {5,3},
    }
    local out = {}
    for _, p in ipairs(rel) do out[#out+1] = { top + p[1], c + p[2], "h" } end
    return out
end
local function sparkleOverlay(phase)
    local out = { {10,24,"o"},{10,25,"o"},{10,26,"o"} }
    local setA = { {7,26,"n"},{6,27,"l"},{9,27,"n"},{11,26,"l"},{8,27,"n"},{10,27,"l"} }
    local setB = { {6,26,"l"},{7,27,"n"},{8,27,"l"},{10,27,"n"},{12,26,"n"},{9,27,"l"} }
    local set = ((phase or 0) % 2 == 1) and setA or setB
    for _, p in ipairs(set) do out[#out+1] = p end
    return out
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
    for _, p in ipairs(face) do stamp(p[1], p[2], "E") end

    local deco
    if anim == "shy" then deco = blushOverlay()
    elseif anim == "heart" then deco = heartOverlay(phase)
    elseif anim == "sparkle" then deco = sparkleOverlay(phase) end
    if deco then for _, p in ipairs(deco) do stamp(p[1], p[2], p[3]) end end

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
