--[[
Clawd — the Claude Code mascot, recreated as pixel-art in Lua.

Shape follows the front-facing reference: a single flat-topped rectangular
head+body block, two small square eyes set high and widely spaced, two short
ARMS protruding from the sides at mid-upper height (ending above the body's
bottom), and FOUR short legs on the base separated by three white gaps.
In the "heart" animation the heart floats above-left of the head.

Grayscale only (Kindle e-ink): terracotta -> mid gray; the sticker's white
outline becomes a dark 1px outline (white would vanish on the white page).
The outline is computed automatically: any filled cell with an empty 4-neighbor
becomes outline, which handles the stepped silhouette for free.

Rendering paints horizontal RUNS of same-colored cells (one paintRect per run,
not per cell) — much cheaper on the Kindle, especially during animations.

Resting faces (emotion, basis = max(5h,7d) + status):
    love/neutral  square eyes    strain  ">" "<"    dizzy  spiral
Animations (opts.anim, opts.phase) overlay on the resting face:
    blink   eyes -> line
    shy     ">" "<" + blush cheeks  (also triggered by tapping the mascot)
    heart   a heart rises above-left of the head
    sparkle a twinkling burst above the right arm
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

local W, H = 30, 24
-- Rows 0..3 are headroom for overlays (rising heart). Body geometry (0-based):
local L, R = 9, 20            -- left/right eye centre columns (set high, wide apart)

-- Silhouette rectangles: { c1, c2, r1, r2 } (inclusive). Symmetric front view.
local SHAPE = {
    { 6, 23,  4, 17 },   -- head+body (single flat-topped block)
    { 1,  5, 10, 13 },   -- left arm (ends above the body bottom)
    { 24, 28, 10, 13 },  -- right arm
    { 6,  8, 18, 23 },   -- leg 1 (four short legs, three gaps)
    { 11, 13, 18, 23 },  -- leg 2
    { 16, 18, 18, 23 },  -- leg 3
    { 21, 23, 18, 23 },  -- leg 4
}

-- Build the base grid: fill the silhouette mask, then derive outline/highlight.
local function makeBase()
    -- Boolean mask
    local m = {}
    for r = 0, H - 1 do m[r] = {} end
    for _, s in ipairs(SHAPE) do
        for r = s[3], s[4] do
            for c = s[1], s[2] do m[r][c] = true end
        end
    end
    -- Char grid: outline where a filled cell touches an empty 4-neighbor/edge.
    local g = {}
    for r = 0, H - 1 do
        g[r] = {}
        for c = 0, W - 1 do
            if not m[r][c] then
                g[r][c] = "."
            else
                local up    = r > 0     and m[r - 1][c]
                local down  = r < H - 1 and m[r + 1][c]
                local left  = c > 0     and m[r][c - 1]
                local right = c < W - 1 and m[r][c + 1]
                if not (up and down and left and right) then
                    g[r][c] = "o"
                elseif r == 5 then
                    g[r][c] = "l"          -- highlight line under the head top
                else
                    g[r][c] = "b"
                end
            end
        end
    end
    return g
end

-- Face pixel lists (0-based) --------------------------------------------------
local function squareEye(cc)
    return { {6,cc-1},{6,cc},{6,cc+1}, {7,cc-1},{7,cc},{7,cc+1}, {8,cc-1},{8,cc},{8,cc+1} }
end
local function chevron(cc, dir)   -- ">" if dir>0, "<" if dir<0
    if dir > 0 then return { {6,cc-1},{7,cc+1},{8,cc-1} }
    else return { {6,cc+1},{7,cc-1},{8,cc+1} } end
end
local function spiralEye(cc)
    -- 5x5 box outline + center dot (dizzy)
    return {
        {5,cc-2},{5,cc-1},{5,cc},{5,cc+1},{5,cc+2},
        {6,cc-2},{6,cc+2},
        {7,cc-2},{7,cc},{7,cc+2},
        {8,cc-2},{8,cc+2},
        {9,cc-2},{9,cc-1},{9,cc},{9,cc+1},{9,cc+2},
    }
end
local function lineEye(cc) return { {7,cc-1},{7,cc},{7,cc+1} } end

local function concat(a, b) for _, p in ipairs(b) do a[#a+1] = p end return a end

local function faceFor(emotion)
    if emotion == "strain" then return concat(chevron(L, 1), chevron(R, -1))
    elseif emotion == "dizzy" then return concat(spiralEye(L), spiralEye(R))
    else return concat(squareEye(L), squareEye(R)) end
end

-- Decoration overlays ({r,c,char}) -------------------------------------------
local function blushOverlay()
    return { {10,L-2,"l"},{10,L-1,"l"}, {10,R+1,"l"},{10,R+2,"l"} }
end
local function heartOverlay(phase)
    -- Floats above-LEFT of the head (as on the sticker); rises with phase.
    local top = 2 - math.min(phase or 0, 3)
    local c = 2
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
    -- Twinkle above the right arm (upper right, clear of the body).
    local setA = { {5,27,"n"},{6,29,"l"},{7,28,"n"},{8,29,"n"},{6,26,"l"} }
    local setB = { {5,28,"l"},{6,27,"n"},{7,29,"l"},{8,27,"n"},{5,26,"n"} }
    return ((phase or 0) % 2 == 1) and setA or setB
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

-- Paint horizontal runs of same-colored cells (one paintRect per run).
local function render(g, scale, bg)
    local bb = Blitbuffer.new(W * scale, H * scale, Blitbuffer.TYPE_BB8)
    bb:fill(bg or Blitbuffer.COLOR_WHITE)
    for r = 0, H - 1 do
        local row = g[r]
        local c = 0
        while c < W do
            local ch = row[c]
            local color = PALETTE[ch]
            if color then
                local c2 = c + 1
                while c2 < W and row[c2] == ch do c2 = c2 + 1 end
                bb:paintRect(c * scale, r * scale, (c2 - c) * scale, scale, color)
                c = c2
            else
                c = c + 1
            end
        end
    end
    return bb
end

-- Rasters are cached: the mascot only has a handful of distinct appearances, but
-- an animation frame used to redraw one from scratch every 120-300ms, and at the
-- dashboard's scale that is ~160k pixels each time.
--
-- The cache owns the buffers, so the widgets it hands out are NOT disposable -
-- freeing one would leave the cache holding a dangling buffer.
local cache = {}
local cache_order = {}
local CACHE_MAX = 12   -- ~2MB at the largest scale we ever ask for

Clawd.raster_count = 0   -- rasterisations actually performed (the smoke test reads it)

local function cached(key, build)
    local bb = cache[key]
    if bb then return bb end
    bb = build()
    Clawd.raster_count = Clawd.raster_count + 1
    if #cache_order >= CACHE_MAX then
        local oldest = table.remove(cache_order, 1)
        if cache[oldest] then cache[oldest]:free() end
        cache[oldest] = nil
    end
    cache[key] = bb
    cache_order[#cache_order + 1] = key
    return bb
end

-- Public: opts = { anim = "blink"|"shy"|"heart"|"sparkle"|nil, phase = n }
function Clawd.makeWidget(emotion, scale, opts, bg)
    scale = scale or 10
    opts = opts or {}
    local key = table.concat({ emotion or "-", opts.anim or "-",
                               opts.phase or 0, scale,
                               bg and bg.a or "w" }, "|")
    local bb = cached(key, function()
        return render(buildGrid(emotion, opts.anim, opts.phase), scale, bg)
    end)
    return ImageWidget:new{
        image = bb,
        image_disposable = false,
        width = W * scale,
        height = H * scale,
    }
end

-- Drop every cached raster. Called when the scale changes (rotation), where the
-- old buffers are all dead weight.
function Clawd.clearCache()
    for _, key in ipairs(cache_order) do
        if cache[key] then cache[key]:free() end
    end
    cache, cache_order = {}, {}
end

function Clawd.emotionFor(max_pct, status)
    if status == "rejected" then return "dizzy" end
    max_pct = max_pct or 0
    if max_pct >= 90 then return "dizzy" end
    if max_pct >= 75 then return "strain" end
    if max_pct >= 50 then return "neutral" end
    return "love"
end

-- Mood from a per-model probe result (Models screen). is_up = no active
-- incident for that model on status.claude.com.
function Clawd.moodForProbe(code, is_up)
    if is_up == false then return "dizzy" end      -- incident on Anthropic's side
    if not code or code == 0 then return "neutral" end   -- not probed yet
    if code == 200 then return "love" end
    if code == 429 then return "strain" end
    if code == 404 then return "dizzy" end
    return "strain"                                -- 401/403 / 5xx / network
end

Clawd.W, Clawd.H = W, H

return Clawd
