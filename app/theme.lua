--[[
Shared look: the grayscale palette and the handful of measurements that used to
appear as bare literals in six or more places across the three screens.

The device is grayscale e-ink, so every "color" here is a luminance byte:
0x22 is near-black text, 0xF4 a very light fill, 0xFF white.

Sizes are unscaled - pass them through sb(), which applies the screen's DPI
scaling. Font sizes are the exception: face() already accounts for it.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Screen = require("device").screen

local Theme = {}

function Theme.sb(n) return Screen:scaleBySize(n) end
function Theme.face(sz) return Font:getFace("cfont", sz) end

Theme.color = {
    fg     = Blitbuffer.Color8(0x22),   -- body text
    bar    = Blitbuffer.Color8(0x33),   -- progress bar fill
    active = Blitbuffer.Color8(0x66),   -- selected nav, card titles
    muted   = Blitbuffer.Color8(0x77),  -- secondary text
    border = Blitbuffer.Color8(0x88),   -- pill borders
    faint  = Blitbuffer.Color8(0x99),   -- version label
    rule   = Blitbuffer.Color8(0xB4),   -- dividers, card borders
    fill   = Blitbuffer.Color8(0xF4),   -- pill / card background
    white  = Blitbuffer.COLOR_WHITE,
}

Theme.MARGIN = 16     -- side margin of every screen
Theme.TAP_SLOP = 12   -- how far outside a button a tap still counts
Theme.GAP = 8         -- minimum breathing room between elements

-- Rounded button shell, shared by the status pills, the nav buttons and the
-- rotate button.
Theme.pill = { bordersize = 1, radius = 12, padding = 6 }
-- The bigger rounded frame used by the dashboard and model cards.
Theme.card = { bordersize = 1, radius = 10, padding = 10 }

return Theme
