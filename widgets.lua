-- widgets.lua -- the few painted widgets the screen is made of.
--
--   Label    -- fixed-size box with one line of centred text; the clock
--               faces. Fixed size so a changing time never moves anything
--               and can be repainted on its own.
--   TabBar   -- the mode switcher: the current tab painted black.
--   Rows     -- a tappable list of rows (laps, timers), painted in one go.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local Size           = require("ui/size")
local Widget         = require("ui/widget/widget")

local Screen = Device.screen

local W = {}

local function textWidth(face, text, bold)
    return RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, bold).x
end
W.textWidth = textWidth

-- Largest font size (<= max) at which `sample` fits w x h.
function W.fitFace(name, sample, w, h, max, bold)
    local lo, hi, best = 8, max or 200, 8
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local face = Font:getFace(name, mid)
        local m = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, sample, true, bold)
        if m.x <= w and (m.y_top + m.y_bottom) <= h then best = mid; lo = mid + 1 else hi = mid - 1 end
    end
    return Font:getFace(name, best), best
end

-- Vertical centring: by the text's own ink for clock digits (ink = true),
-- otherwise by the font's cap height, so that words with and without
-- descenders ("Stopwatch", "Timers") sit on one baseline.
local function drawText(bb, face, text, x, y, w, h, color, bold, align, ink)
    local m = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, bold)
    local tx
    if align == "left" then tx = x
    elseif align == "right" then tx = x + w - m.x
    else tx = x + math.floor((w - m.x) / 2) end
    local v = ink and m or RenderText:sizeUtf8Text(0, Screen:getWidth(), face, "H", true, bold)
    local baseline = y + math.floor((h - (v.y_top + v.y_bottom)) / 2) + v.y_top
    RenderText:renderUtf8Text(bb, tx, baseline, face, text, true, bold, color or Blitbuffer.COLOR_BLACK)
end
W.drawText = drawText

-- ---------------------------------------------------------------------------
-- Label
-- ---------------------------------------------------------------------------

local Label = Widget:extend{
    width = 100, height = 40, text = "", face = nil, bold = false,
    inverted = false, align = "center", ink = true,
}

function Label:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Label:getSize() return self.dimen end

function Label:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local bg = self.inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local fg = self.inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    bb:paintRect(x, y, self.width, self.height, bg)
    if self.text ~= "" then
        drawText(bb, self.face, self.text, x, y, self.width, self.height, fg, self.bold, self.align, self.ink)
    end
end

-- Returns true when the text changed (the caller then repaints it).
function Label:setText(text)
    if text == self.text then return false end
    self.text = text
    return true
end

W.Label = Label

-- ---------------------------------------------------------------------------
-- TabBar
-- ---------------------------------------------------------------------------

local TabBar = InputContainer:extend{
    width = 100, height = 50, tabs = nil, selected = 1, on_select = nil,
}

function TabBar:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local longest = ""
    for _i, t in ipairs(self.tabs) do if #t > #longest then longest = t end end
    local cell_w = math.floor(self.width / #self.tabs)
    self.face = W.fitFace("cfont", longest, cell_w - 2 * Size.padding.large,
        self.height - 2 * Size.padding.default, 24, true)
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } } }
end

function TabBar:getSize() return self.dimen end

function TabBar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local n = #self.tabs
    local b = Size.border.thick
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    for i, t in ipairs(self.tabs) do
        local cx = x + math.floor((i - 1) * self.width / n)
        local cw = math.floor(i * self.width / n) - math.floor((i - 1) * self.width / n)
        local sel = i == self.selected
        if sel then bb:paintRect(cx, y, cw, self.height, Blitbuffer.COLOR_BLACK) end
        drawText(bb, self.face, t, cx, y, cw, self.height,
            sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, true)
        if i > 1 then bb:paintRect(cx, y, b, self.height, Blitbuffer.COLOR_BLACK) end
    end
    bb:paintBorder(x, y, self.width, self.height, b, Blitbuffer.COLOR_BLACK)
end

function TabBar:onTap(_arg, ges)
    local i = math.floor((ges.pos.x - self.dimen.x) / (self.width / #self.tabs)) + 1
    i = math.max(1, math.min(#self.tabs, i))
    if i ~= self.selected and self.on_select then self.on_select(i) end
    return true
end

W.TabBar = TabBar

-- ---------------------------------------------------------------------------
-- Rows: a list of equal-height rows, each painted by paint_row(bb, i, x, y,
-- w, h), tapped through on_tap(i, ges) / on_hold(i, ges).
-- ---------------------------------------------------------------------------

local Rows = InputContainer:extend{
    width = 100, height = 100, row_h = 40, count = 0,
    paint_row = nil, on_tap = nil, on_hold = nil, header = nil, header_h = 0,
}

function Rows:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = function() return self.dimen end } },
        Hold = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Rows:getSize() return self.dimen end

function Rows:visibleRows()
    return math.max(0, math.floor((self.height - self.header_h) / self.row_h))
end

function Rows:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
    if self.header then self.header(bb, x, y, self.width, self.header_h) end
    for i = 1, math.min(self.count, self:visibleRows()) do
        self.paint_row(bb, i, x, y + self.header_h + (i - 1) * self.row_h, self.width, self.row_h)
    end
end

function Rows:rowAt(ges)
    local i = math.floor((ges.pos.y - self.dimen.y - self.header_h) / self.row_h) + 1
    if ges.pos.y < self.dimen.y + self.header_h then return nil end
    if i >= 1 and i <= math.min(self.count, self:visibleRows()) then return i end
end

function Rows:onTap(_arg, ges)
    local i = self:rowAt(ges)
    if i and self.on_tap then self.on_tap(i, ges) end
    return i ~= nil
end

function Rows:onHold(_arg, ges)
    local i = self:rowAt(ges)
    if i and self.on_hold then self.on_hold(i, ges) end
    return i ~= nil
end

W.Rows = Rows

return W
