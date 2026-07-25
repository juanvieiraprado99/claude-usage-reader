--[[
LoginModal — fullscreen modal that shows a QR code + URL + PIN for the LAN token
receiver. Scan the QR on a phone (same WiFi) to open the paste form with the PIN
pre-filled. The URL/PIN/QR rotate every 5 minutes so a stale QR stops working.
Owns the TokenServer while open; on token receipt it calls on_token and closes.

    UIManager:show(LoginModal:new{
        ip = "192.168.0.5", port = 8099,
        on_token = function(tok) ... end,
    })
]]--

local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local QRWidget = require("ui/widget/qrwidget")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local TokenServer = require("tokenserver")
local T = require("i18n").t

local ROTATE_EVERY = 300     -- seconds; PIN/URL/QR lifetime

local LoginModal = InputContainer:extend{
    ip = nil,
    port = 8099,
    on_token = nil,
    on_close = nil,     -- called when the modal is torn down
}

local function sb(n) return Screen:scaleBySize(n) end
local function face(sz) return Font:getFace("cfont", sz) end

function LoginModal:init()
    self.modal = true
    self.closed = false
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }

    math.randomseed(os.time())
    self.pin = string.format("%04d", math.random(0, 9999))

    self.server = TokenServer:new{
        port = self.port,
        pin = self.pin,
        on_token = function(tok)
            if self.on_token then self.on_token(tok) end
            self:onClose()
        end,
        on_error = function() end,
    }
    self.server:start()

    self.rotate_task = function() self:rotate() end
    UIManager:scheduleIn(ROTATE_EVERY, self.rotate_task)

    self:build()
end

function LoginModal:rotate()
    if self.closed then return end
    self.pin = string.format("%04d", math.random(0, 9999))
    if self.server then self.server.pin = self.pin end
    self:build()
    UIManager:scheduleIn(ROTATE_EVERY, self.rotate_task)
end

function LoginModal:build()
    if self.closed then return end
    if self.qr and self.qr.free then self.qr:free() end
    local url = string.format("http://%s:%d/?k=%s", self.ip, self.port, self.pin)
    self.qr = QRWidget:new{ text = url, width = sb(220) }

    local card = FrameContainer:new{
        bordersize = sb(1),
        radius = sb(12),
        padding = sb(20),
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        bordercolor = Blitbuffer.Color8(0x88),
        VerticalGroup:new{
            align = "center",
            TextWidget:new{ text = T("Login — scan on your phone"), face = face(18), bold = true },
            VerticalSpan:new{ width = sb(14) },
            self.qr,
            VerticalSpan:new{ width = sb(14) },
            TextWidget:new{ text = url, face = face(13),
                            fgcolor = Blitbuffer.Color8(0x55) },
            VerticalSpan:new{ width = sb(8) },
            TextWidget:new{ text = "PIN: " .. self.pin, face = face(30), bold = true },
            VerticalSpan:new{ width = sb(6) },
            TextWidget:new{ text = T("paste the 'claude setup-token' value"),
                            face = face(12), fgcolor = Blitbuffer.Color8(0x77) },
            VerticalSpan:new{ width = sb(4) },
            TextWidget:new{ text = T("expires in 5 min • tap to cancel"),
                            face = face(12), fgcolor = Blitbuffer.Color8(0x77) },
        },
    }

    self[1] = FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
            card,
        },
    }
    UIManager:setDirty(self, "ui")
end

function LoginModal:onTap()
    self:onClose()
    return true
end

function LoginModal:onClose()
    UIManager:close(self)
    return true
end

function LoginModal:onCloseWidget()
    self.closed = true
    if self.rotate_task then UIManager:unschedule(self.rotate_task) end
    if self.server then self.server:stop(); self.server = nil end
    if self.qr and self.qr.free then self.qr:free() end
    if self.on_close then self.on_close() end
end

return LoginModal
