--[[
Heatmap — the week as a 7 x 4 grid (one column per day, one row per 6h block),
cell darkness = how much quota was consumed in that block. Grayscale, e-ink
friendly: flat rectangles, no anti-aliasing, one repaint per fetch.

WHERE THE NUMBERS COME FROM - read this before trusting a cell.

  1. Source is the `weekly` series in history.lua, i.e. the
     `anthropic-ratelimit-unified-7d-utilization` response header. It is sampled
     ONLY WHILE THE APP IS OPEN, and throttled to at most one sample an hour
     (MIN_GAP_7D). There is no background collection; adding one would mean
     shipping a daemon, which this project deliberately does not do.

  2. That header is CUMULATIVE utilization of the weekly window, not
     consumption. A cell is therefore a DERIVED DELTA between two consecutive
     samples, spread across the interval they span - not an observation. Two
     samples 12 hours apart produce two plausible-looking cells out of a single
     measured number. The spreading is proportional because we genuinely do not
     know when inside the gap the work happened; dumping the delta on one cell
     would invent a spike that was never measured.

  3. Blocks that no interval covers are `nil`, NOT zero. "Idle" and "not
     measured" must render differently or the grid lies about the user's week.
     Since consecutive samples define contiguous intervals, the unknown region
     is a prefix/suffix around the sampled range, not scattered holes.

  4. Shading is RELATIVE to the week's own busiest block, because an absolute
     0-100% scale would render a light user's entire week as blank paper. The
     same darkness therefore means different absolute usage from one week to the
     next, which is why the screen prints what the darkest cell equals.

  5. The API returns percentages only for subscription accounts, so none of this
     can be converted to token counts on-device. That needs `ccusage` over
     ~/.claude/projects/**/*.jsonl on a PC.

Bucketing is kept separate from rendering so it can be tested without pixels.

    Heatmap.bucket(samples, now, days, blocks) -> cells, max, measured, total
    Heatmap.makeWidget{ w, h, cells, max }     -> ImageWidget
]]--

local Blitbuffer = require("ffi/blitbuffer")
local ImageWidget = require("ui/widget/imagewidget")
local Theme = require("theme")

local Heatmap = {}

Heatmap.DAYS = 7      -- columns: the last 7 local days, today rightmost
Heatmap.BLOCKS = 4    -- rows: 00-06, 06-12, 12-18, 18-24

local C = Theme.color
-- The "not measured" dot. It has a job - telling an idle block from an
-- unobserved one - so it has to be visible on e-ink, while still reading as
-- lighter than the lightest ramp step (0xEE would be invisible, and darker than
-- the ramp would make blanks look busy).
local C_EMPTY = Blitbuffer.Color8(0xAA)

-- Darkness ramp, lightest -> darkest. Five steps: e-ink cannot show a smooth
-- gradient, and clean banding reads better than dithering.
local RAMP = {
    Blitbuffer.Color8(0xEE),
    Blitbuffer.Color8(0xC0),
    Blitbuffer.Color8(0x90),
    Blitbuffer.Color8(0x58),
    Blitbuffer.Color8(0x22),
}

-- Local midnight of the day `epoch` falls in. os.date/os.time round-trip so the
-- device's timezone (and DST) is respected rather than assuming UTC.
local function midnight(epoch)
    local d = os.date("*t", epoch)
    return os.time{ year = d.year, month = d.month, day = d.day,
                    hour = 0, min = 0, sec = 0, isdst = d.isdst }
end

--[[
Reduce the weekly series to a grid of consumption.

Returns:
  cells     [row][col] = fraction consumed in that block, or nil if unmeasured
  max       largest cell value (0 if nothing measured) - the shading reference
  measured  how many cells are non-nil
  total     how many cells there are (days * blocks)
  start     epoch of the grid's first column, 00:00 local
]]--
function Heatmap.bucket(samples, now, days, blocks)
    days = days or Heatmap.DAYS
    blocks = blocks or Heatmap.BLOCKS
    now = now or os.time()

    local block_secs = 86400 / blocks
    -- The grid ends at the end of today, so today is the rightmost column.
    local grid_start = midnight(now) - (days - 1) * 86400
    local grid_end = grid_start + days * 86400

    local cells = {}
    for r = 1, blocks do cells[r] = {} end

    -- Add `amount` to whichever cell covers [from, to), splitting proportionally
    -- across every cell the interval overlaps.
    local function spread(from, to, amount)
        if to <= from then return end
        local span = to - from
        local i = math.floor((from - grid_start) / block_secs)
        local last = math.floor((to - grid_start - 1) / block_secs)
        while i <= last do
            local cell_from = grid_start + i * block_secs
            local cell_to = cell_from + block_secs
            local lo = math.max(from, cell_from)
            local hi = math.min(to, cell_to)
            if hi > lo then
                local slot = math.floor(i / blocks)   -- which day column
                local row = i - slot * blocks + 1
                local col = slot + 1
                if cells[row] and col >= 1 and col <= days then
                    local share = amount * (hi - lo) / span
                    cells[row][col] = (cells[row][col] or 0) + share
                end
            end
            i = i + 1
        end
    end

    for i = 2, #samples do
        local a, b = samples[i - 1], samples[i]
        -- A drop means the weekly window reset between the two samples: what we
        -- can attribute is everything accumulated since that reset, i.e. b.v.
        -- Never a negative delta.
        local amount = b.v - a.v
        if amount < 0 then amount = b.v end
        local from = math.max(a.t, grid_start)
        local to = math.min(b.t, grid_end)
        spread(from, to, amount)
    end

    local max, measured = 0, 0
    for r = 1, blocks do
        for c = 1, days do
            local v = cells[r][c]
            if v then
                measured = measured + 1
                if v > max then max = v end
            end
        end
    end

    return cells, max, measured, days * blocks, grid_start
end

-- opts = { w, h, cells, max, days, blocks }
function Heatmap.makeWidget(opts)
    local w, h = math.max(2, opts.w or 2), math.max(2, opts.h or 2)
    local days = opts.days or Heatmap.DAYS
    local blocks = opts.blocks or Heatmap.BLOCKS
    local cells = opts.cells or {}
    local max = opts.max or 0

    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)

    -- Integer cell size, with the rounding slack left as an unused right/bottom
    -- edge rather than letting cells drift a pixel apart across the grid.
    local cw = math.max(1, math.floor(w / days))
    local ch = math.max(1, math.floor(h / blocks))

    for r = 1, blocks do
        for c = 1, days do
            local x, y = (c - 1) * cw, (r - 1) * ch
            local v = cells[r] and cells[r][c]
            if v == nil then
                -- Unmeasured: white with a small centre dot. Deliberately not
                -- the lightest ramp step, which means "measured, near zero".
                bb:paintRect(x, y, cw, ch, C.white)
                bb:paintRect(x + math.floor(cw / 2) - 1, y + math.floor(ch / 2) - 1,
                             2, 2, C_EMPTY)
            else
                local step = 1
                if max > 0 then
                    step = math.floor((v / max) * (#RAMP - 1) + 0.5) + 1
                    if step < 1 then step = 1 end
                    if step > #RAMP then step = #RAMP end
                end
                bb:paintRect(x, y, cw, ch, RAMP[step])
            end
            -- 1px separators, so two equally-shaded neighbours stay distinct.
            bb:paintRect(x, y, cw, 1, C.rule)
            bb:paintRect(x, y, 1, ch, C.rule)
        end
    end
    -- Close the grid on the right and bottom edges.
    bb:paintRect(0, blocks * ch - 1, days * cw, 1, C.rule)
    bb:paintRect(days * cw - 1, 0, 1, blocks * ch, C.rule)

    return ImageWidget:new{
        image = bb,
        image_disposable = true,   -- pixels change with the data, like chart.lua
        width = w,
        height = h,
    }
end

return Heatmap
