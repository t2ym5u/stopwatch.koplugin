-- alert.lua -- how a timer gets noticed on a reader with no speaker.
--
-- The screen flashes: a full-screen black page with the message in white,
-- then white with black text, a few times (e-ink "fast" refreshes, which are
-- the quickest the panel does). On a reader with a frontlight the light
-- blinks in step, and is put back exactly as it was afterwards. A message
-- then stays on screen until it is tapped away.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InfoMessage     = require("ui/widget/infomessage")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")

local Screen = Device.screen

local Alert = {}

-- ---------------------------------------------------------------------------
-- Frontlight blink
-- ---------------------------------------------------------------------------

-- Returns a light(on) function and a restore() function, or nil when there
-- is no frontlight. Goes through setIntensityHW so KOReader's own idea of
-- the light level (fl_intensity, saved in its settings) is never touched.
local function frontlight()
    if not (Device.hasFrontlight and Device:hasFrontlight()) then return nil end
    local ok, powerd = pcall(Device.getPowerDevice, Device)
    if not ok or not powerd or type(powerd.setIntensityHW) ~= "function" then return nil end
    local was_on   = powerd.isFrontlightOn and powerd:isFrontlightOn()
    local original = was_on and (powerd.fl_intensity or powerd.fl_max) or (powerd.fl_min or 0)
    local hi, lo   = powerd.fl_max or 100, powerd.fl_min or 0
    local function light(on)
        pcall(powerd.setIntensityHW, powerd, on and hi or lo)
    end
    local function restore()
        pcall(powerd.setIntensityHW, powerd, original)
    end
    return light, restore
end

-- ---------------------------------------------------------------------------
-- Flash page
-- ---------------------------------------------------------------------------

local FlashPage = InputContainer:extend{
    text     = "",
    inverted = true,
}

function FlashPage:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function FlashPage:paintTo(bb, x, y)
    local fg = self.inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bg = self.inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, bg)
    local box = TextBoxWidget:new{
        text      = self.text,
        face      = Font:getFace("cfont", 48),
        width     = math.floor(self.dimen.w * 0.85),
        alignment = "center",
        bold      = true,
        fgcolor   = fg,
        bgcolor   = bg,
    }
    local sz = box:getSize()
    box:paintTo(bb, x + math.floor((self.dimen.w - sz.w) / 2), y + math.floor((self.dimen.h - sz.h) / 2))
    box:free()
end

-- A tap during the flashes skips straight to the message.
function FlashPage:onTap()
    if self.on_tap then self.on_tap() end
    return true
end

-- ---------------------------------------------------------------------------
-- Alert.run
-- ---------------------------------------------------------------------------

local running -- the alert in progress, if any

-- opts: text (flash + message), flashes (number of black pages, 0 = none),
-- blink (frontlight), message (show the tap-to-dismiss message after),
-- on_done.
function Alert.run(opts)
    if running then running.finish() end
    local flashes = opts.flashes or 3
    local light, restore
    if opts.blink ~= false then light, restore = frontlight() end

    local page = FlashPage:new{ text = opts.text or "", inverted = true }
    local step, steps = 0, flashes * 2
    local state = {}
    running = state
    local tick

    function state.finish()
        if state.finished then return end
        state.finished = true
        if running == state then running = nil end
        UIManager:unschedule(tick)
        if restore then restore() end
        if state.shown then UIManager:close(page, "full") end
        if opts.message ~= false and opts.text and opts.text ~= "" then
            UIManager:show(InfoMessage:new{ text = opts.text, timeout = opts.timeout })
        end
        if opts.on_done then opts.on_done() end
    end
    page.on_tap = state.finish

    tick = function()
        if state.finished then return end
        step = step + 1
        if step > steps then return state.finish() end
        page.inverted = (step % 2 == 1)
        if light then light(page.inverted) end
        if not state.shown then
            state.shown = true
            UIManager:show(page, "fast")
        else
            UIManager:setDirty(page, "fast")
        end
        UIManager:scheduleIn(0.6, tick)
    end

    if steps <= 0 then return state.finish() end
    tick()
end

return Alert
