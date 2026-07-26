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

-- TEXT vs STRUCTURE. The greys below the divider are for lines and fills only.
-- Reading them as a text colour is what made the small labels wash out: e-ink
-- has no backlight and much less effective contrast than the emulator suggests,
-- so a 0x88 caption that looks merely soft on a monitor is close to unreadable
-- on the device. Secondary text bottoms out at `muted`; anything lighter is a
-- border. Small captions also carry bold = true, which on e-ink buys more
-- legibility than another shade of grey.
Theme.color = {
    fg     = Blitbuffer.Color8(0x22),   -- body text
    bar    = Blitbuffer.Color8(0x33),   -- progress bar fill
    active = Blitbuffer.Color8(0x55),   -- selected nav, card titles
    muted  = Blitbuffer.Color8(0x44),   -- secondary text (captions, axes)
    faint  = Blitbuffer.Color8(0x55),   -- version label - the lightest TEXT
    -- structure only, never a text colour:
    border = Blitbuffer.Color8(0x88),   -- pill borders
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
