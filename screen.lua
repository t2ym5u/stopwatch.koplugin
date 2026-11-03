local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonDialog    = require("ui/widget/buttondialog")
local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local Font            = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputDialog     = require("ui/widget/inputdialog")
local Size            = require("ui/size")
local SpinWidget      = require("ui/widget/spinwidget")
local TextViewer      = require("ui/widget/textviewer")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase = require("screen_base")

local Clock   = lrequire("clock")
local Format  = lrequire("format")
local Timers  = lrequire("timers")
local W       = lrequire("widgets")

local DScreen = Device.screen

local MODES   = { "stopwatch", "timers", "interval" }
local PRESETS = { 1, 3, 5, 10, 15, 30 }   -- minutes

-- Choices for the interval durations (seconds).
local DURATIONS = { 5, 10, 15, 20, 25, 30, 40, 45, 50, 60, 75, 90, 120, 150, 180,
                    240, 300, 360, 420, 480, 540, 600, 900, 1200, 1800, 2700, 3600 }

local HELP_EN = [[
Stopwatch
Start, pause, take laps, reset. Laps show the lap time and the total; the fastest and slowest laps are marked. Tenths of a second appear once the stopwatch is paused. "All laps" in the ☰ menu lists every lap.

Timers
Tap a duration to start a timer at once, or "Custom…" to type one (5 = 5 min, 1:30, 1h30, 90s) and give it a name. Up to 8 timers run at the same time. Tap a timer to pause or resume it; hold it to restart, rename or delete it.

Interval
Set the work time, the rest time, the number of rounds and a short "get ready" countdown, then Start. The screen flashes once at every change between work and rest, and longer at the end.

When time is up
A reader has no speaker, so the screen flashes black and white a few times (and the frontlight blinks, if the reader has one), then a message stays until you tap it.

Timers keep running when you close this screen, even while you read, and ring wherever you are in KOReader. While a timer runs, the reader is kept from going to sleep on its own. If it was put to sleep anyway (power button), it tells you on waking what finished, and when.

Times come from the reader's clock, not from counting seconds, so they stay right however long the screen was not looked at.]]

local HELP_FR = [[
Chronomètre
Démarrer, mettre en pause, prendre des tours, remettre à zéro. Chaque tour affiche son temps et le total ; le tour le plus rapide et le plus lent sont signalés. Les dixièmes de seconde s'affichent une fois le chronomètre en pause. « Tous les tours », dans le menu ☰, les liste tous.

Minuteurs
Touchez une durée pour lancer aussitôt un minuteur, ou « Personnalisé… » pour en saisir une (5 = 5 min, 1:30, 1h30, 90s) et lui donner un nom. Jusqu'à 8 minuteurs tournent en même temps. Touchez un minuteur pour le mettre en pause ou le relancer ; appui long pour le redémarrer, le renommer ou le supprimer.

Fractionné
Réglez le temps d'effort, le temps de repos, le nombre de tours et un court compte à rebours de préparation, puis Démarrer. L'écran clignote une fois à chaque passage effort/repos, et plus longuement à la fin.

Quand le temps est écoulé
La liseuse n'a pas de haut-parleur : l'écran clignote plusieurs fois en noir et blanc (et l'éclairage aussi, si la liseuse en a un), puis un message reste affiché jusqu'à ce que vous le touchiez.

Les minuteurs continuent quand vous fermez cet écran, même pendant la lecture, et sonnent où que vous soyez dans KOReader. Tant qu'un minuteur tourne, la liseuse ne se met pas en veille d'elle-même. Si elle a été mise en veille quand même (bouton marche), elle indique au réveil ce qui s'est terminé, et à quelle heure.

Les temps viennent de l'horloge de la liseuse, pas d'un décompte des secondes : ils restent justes même si l'écran n'a pas été regardé depuis longtemps.]]

local StopwatchScreen = ScreenBase:extend{
    vertical_align = "top",
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function StopwatchScreen:init()
    self.model = self.service.model
    self.mode  = self.plugin:getSetting("mode", "stopwatch")
    if not ({ stopwatch = true, timers = true, interval = true })[self.mode] then self.mode = "stopwatch" end
    self._tick = function() self:onTick() end
    ScreenBase.init(self)
    self.service:setScreen(self)
    self:scheduleTick()
end

function StopwatchScreen:serializeState()
    return self.model:serialize()
end

function StopwatchScreen:closeScreen()
    UIManager:unschedule(self._tick)
    self.service:setScreen(nil)
    ScreenBase.closeScreen(self)
end

-- Saves, re-arms the alarm and redraws after a button press.
function StopwatchScreen:commit()
    self.service:changed()
    self:redraw()
end

function StopwatchScreen:redraw()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    self:scheduleTick()
end

-- The service rang something (or caught up after a sleep).
function StopwatchScreen:onModelChanged()
    self:redraw()
end

-- ---------------------------------------------------------------------------
-- Once-a-second update: only the clock faces, "fast" refresh, at most once a
-- second, aligned on the second the visible clock is about to change.
-- ---------------------------------------------------------------------------

function StopwatchScreen:nextTickDelay(now)
    local m = self.model
    if self.mode == "stopwatch" then
        if not m.stopwatch:isRunning() then return nil end
        return 1 - (m.stopwatch:elapsed(now) % 1)
    elseif self.mode == "timers" then
        local best
        for _i, t in ipairs(m.timers) do
            if t:isRunning() then
                local d = t:remainingAt(now) % 1
                if d < 0.02 then d = 1 end
                if not best or d < best then best = d end
            end
        end
        return best
    else
        local iv = m.interval
        if not iv:isRunning() then return nil end
        local _i, _p, left = iv:phaseAt(iv:elapsed(now))
        local d = (left or 0) % 1
        if d < 0.02 then d = 1 end
        return d
    end
end

function StopwatchScreen:scheduleTick()
    UIManager:unschedule(self._tick)
    local d = self:nextTickDelay(Clock.now())
    if d then UIManager:scheduleIn(d + 0.01, self._tick) end
end

-- Repaints one widget in place and refreshes only its rectangle -- unless
-- something (a menu, a dialog) is on top of the screen: then the new text is
-- just kept for the next full repaint.
function StopwatchScreen:repaintPart(widget, rect)
    if UIManager:getTopmostVisibleWidget() ~= self then return end
    if not (widget.dimen and widget.dimen.w and widget.dimen.x) then return end
    UIManager:widgetRepaint(widget, widget.dimen.x, widget.dimen.y)
    UIManager:setDirty(nil, "fast", rect or widget.dimen)
end

function StopwatchScreen:onTick()
    local now = Clock.now()
    self:updateClocks(now)
    self:scheduleTick()
end

function StopwatchScreen:updateClocks(now, no_paint)
    local m = self.model
    if self.mode == "stopwatch" and self.sw_label then
        if self.sw_label:setText(self:stopwatchText(now)) and not no_paint then
            self:repaintPart(self.sw_label)
        end
    elseif self.mode == "timers" and self.timer_rows then
        local changed = false
        for i, t in ipairs(m.timers) do
            local txt = Format.down(t:remainingAt(now))
            if self.timer_texts[i] ~= txt then self.timer_texts[i] = txt; changed = true end
        end
        if changed and not no_paint then
            local r = self.timer_rows.dimen
            self:repaintPart(self.timer_rows, r and r.x and { x = r.x + self.time_col_x, y = r.y,
                w = r.w - self.time_col_x, h = r.h } or nil)
        end
    elseif self.mode == "interval" and self.iv_label then
        local a = self.iv_label:setText(self:intervalTime(now))
        local b = self.iv_total:setText(self:intervalTotal(now))
        if not no_paint then
            if a then self:repaintPart(self.iv_label) end
            if b then self:repaintPart(self.iv_total) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function StopwatchScreen:scale(px) return DScreen:scaleBySize(px) end

function StopwatchScreen:buttonRow(buttons, width)
    local h = self:scale(64)
    for _i, b in ipairs(buttons) do
        b.height = b.height or h
        b.font_size = b.font_size or 24
        b.font_bold = true
    end
    return ButtonTable:new{ width = width, buttons = { buttons } }
end

function StopwatchScreen:buildLayout()
    local sw, sh = self.dimen.w, self.dimen.h
    local g = self:getGutter()
    local landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Stopwatch & timer"), function() return self:menuItems() end)
    local cw = sw - 2 * g
    local tabs = W.TabBar:new{
        width = cw, height = self:scale(52),
        tabs = { _("Stopwatch"), _("Timers"), _("Interval") },
        selected = ({ stopwatch = 1, timers = 2, interval = 3 })[self.mode],
        on_select = function(i) self:setMode(MODES[i]) end,
    }
    local avail_h = sh - title_bar:getSize().h - tabs:getSize().h - 3 * g

    self.sw_label, self.timer_rows, self.iv_label, self.iv_total = nil, nil, nil, nil
    local content
    if self.mode == "stopwatch" then
        content = self:buildStopwatch(cw, avail_h, landscape)
    elseif self.mode == "timers" then
        content = self:buildTimers(cw, avail_h, landscape)
    else
        content = self:buildInterval(cw, avail_h, landscape)
    end

    self.layout = VerticalGroup:new{
        align = "center",
        title_bar,
        VerticalSpan:new{ width = g },
        tabs,
        VerticalSpan:new{ width = g },
        content,
    }
    self[1] = self.layout
end

function StopwatchScreen:setMode(mode)
    self.mode = mode
    self.plugin:saveSetting("mode", mode)
    self:redraw()
end

-- Two columns in landscape, stacked in portrait.
function StopwatchScreen:arrange(landscape, cw, left, right)
    if landscape then
        return HorizontalGroup:new{
            align = "top",
            left,
            HorizontalSpan:new{ width = self:getGutter() },
            right,
        }
    end
    return VerticalGroup:new{
        align = "center",
        left,
        VerticalSpan:new{ width = self:getGutter() },
        right,
    }
end

-- ---------------------------------------------------------------------------
-- Stopwatch
-- ---------------------------------------------------------------------------

function StopwatchScreen:stopwatchText(now)
    local sw = self.model.stopwatch
    local e = sw:elapsed(now)
    local hours = e >= 3600
    local face = hours and self.sw_face_long or self.sw_face
    if self.sw_label then self.sw_label.face = face end
    if sw:isRunning() then return Format.up(e) end
    return Format.tenths(e)
end

function StopwatchScreen:buildStopwatch(cw, avail_h, landscape)
    local g = self:getGutter()
    local sw = self.model.stopwatch
    local col_w = landscape and math.floor((cw - g) * 0.5) or cw
    local label_h = landscape and math.floor(avail_h * 0.45) or self:scale(170)
    self.sw_face = W.fitFace("cfont", "00:00.0", col_w - 2 * g, label_h, 200, true)
    self.sw_face_long = W.fitFace("cfont", "0:00:00.0", col_w - 2 * g, label_h, 200, true)
    self.sw_label = W.Label:new{ width = col_w, height = label_h, face = self.sw_face, bold = true }
    self.sw_label:setText(self:stopwatchText(Clock.now()))

    local running = sw:isRunning()
    local buttons = self:buttonRow({
        { text = running and _("Pause") or (sw:isZero() and _("Start") or _("Resume")),
          callback = function() self:onStartPause() end },
        { text = running and _("Lap") or _("Reset"),
          enabled = running or not sw:isZero(),
          callback = function() if sw:isRunning() then self:onLap() else self:onResetStopwatch() end end },
    }, col_w)

    local left = VerticalGroup:new{ align = "center", self.sw_label, VerticalSpan:new{ width = g }, buttons }
    local lap_h = landscape and avail_h or (avail_h - left:getSize().h - g)
    local laps = self:buildLaps(landscape and (cw - col_w - g) or cw, lap_h)
    return self:arrange(landscape, cw, left, laps)
end

function StopwatchScreen:buildLaps(w, h)
    local sw = self.model.stopwatch
    local laps = sw.laps
    local best, worst = sw:lapExtremes()
    local row_h = self:scale(40)
    local face = Font:getFace("cfont", 21)
    local small = Font:getFace("cfont", 16)
    local cols = { 0.14, 0.33, 0.33, 0.20 }
    local function colx(i)
        local x = 0
        for k = 1, i - 1 do x = x + cols[k] end
        return x
    end
    local n = #laps
    local rows = W.Rows:new{
        width = w, height = h, row_h = row_h, header_h = row_h, count = n,
        header = function(bb, x, y, ww, hh)
            if n == 0 then
                W.drawText(bb, face, _("No laps yet."), x, y, ww, hh * 2, Blitbuffer.COLOR_DARK_GRAY)
                return
            end
            local heads = { "#", _("Lap time"), _("Total"), "" }
            for i, t in ipairs(heads) do
                W.drawText(bb, small, t, x + math.floor(colx(i) * ww), y, math.floor(cols[i] * ww), hh,
                    Blitbuffer.COLOR_DARK_GRAY, true)
            end
            bb:paintRect(x, y + hh - 2, ww, 2, Blitbuffer.COLOR_BLACK)
        end,
        paint_row = function(bb, i, x, y, ww, hh)
            -- newest first
            local idx = n - i + 1
            local lap = laps[idx]
            local tag = ""
            if idx == best then
                tag = _("fastest")
                bb:paintRect(x, y, ww, hh, Blitbuffer.COLOR_LIGHT_GRAY)
            elseif idx == worst then
                tag = _("slowest")
            end
            local vals = { tostring(lap.n), Format.tenths(lap.split), Format.tenths(lap.total) }
            for c, t in ipairs(vals) do
                W.drawText(bb, face, t, x + math.floor(colx(c) * ww), y, math.floor(cols[c] * ww), hh,
                    Blitbuffer.COLOR_BLACK, c == 2)
            end
            if tag ~= "" then
                W.drawText(bb, small, tag, x + math.floor(colx(4) * ww), y, math.floor(cols[4] * ww), hh,
                    Blitbuffer.COLOR_BLACK)
            end
            bb:paintRect(x, y + hh - 1, ww, 1, Blitbuffer.COLOR_GRAY)
        end,
    }
    -- More laps than fit: the last visible row says how many are hidden.
    local vis = rows:visibleRows()
    if n > vis and vis > 1 then
        rows.count = vis - 1
        local paint = rows.paintTo
        rows.paintTo = function(this, bb, x, y)
            paint(this, bb, x, y)
            W.drawText(bb, small, T(_("+ %1 earlier laps (☰ → All laps)"), n - vis + 1),
                x, y + this.header_h + (vis - 1) * row_h, w, row_h, Blitbuffer.COLOR_DARK_GRAY)
        end
    end
    return rows
end

function StopwatchScreen:onStartPause()
    local sw, now = self.model.stopwatch, Clock.now()
    if sw:isRunning() then sw:pause(now) else sw:start(now) end
    self:commit()
end

function StopwatchScreen:onLap()
    if not self.model.stopwatch:lap(Clock.now()) then
        self:showMessage(_("Lap limit reached."))
    end
    self:commit()
end

function StopwatchScreen:onResetStopwatch()
    self.model.stopwatch:reset()
    self:commit()
end

function StopwatchScreen:showAllLaps()
    local laps = self.model.stopwatch.laps
    local lines = {}
    for _i, l in ipairs(laps) do
        lines[#lines + 1] = string.format("%3d   %s   %s", l.n, Format.tenths(l.split), Format.tenths(l.total))
    end
    UIManager:show(TextViewer:new{
        title = _("All laps"),
        text  = #lines > 0 and table.concat(lines, "\n") or _("No laps yet."),
        monospace_font = true,
        width  = math.floor(DScreen:getWidth() * 0.9),
        height = math.floor(DScreen:getHeight() * 0.9),
    })
end

-- ---------------------------------------------------------------------------
-- Timers
-- ---------------------------------------------------------------------------

function StopwatchScreen:presetLabel(minutes)
    return minutes .. " min"
end

function StopwatchScreen:buildTimers(cw, avail_h, landscape)
    local g = self:getGutter()
    local col_w = landscape and math.floor((cw - g) * 0.36) or cw
    local per_row = landscape and 2 or 4
    local specs = {}
    for _i, m in ipairs(PRESETS) do
        specs[#specs + 1] = { text = self:presetLabel(m), callback = function() self:addTimer(m * 60) end }
    end
    specs[#specs + 1] = { text = _("Custom…"), callback = function() self:askCustomTimer() end }
    local rows, row = {}, {}
    for i, s in ipairs(specs) do
        s.height, s.font_size, s.font_bold = self:scale(60), 22, true
        s.enabled = #self.model.timers < Timers.MAX_TIMERS
        row[#row + 1] = s
        if #row == per_row or i == #specs then rows[#rows + 1] = row; row = {} end
    end
    local presets = ButtonTable:new{ width = col_w, buttons = rows }
    local list_w = landscape and (cw - col_w - g) or cw
    local list_h = landscape and avail_h or (avail_h - presets:getSize().h - g)
    return self:arrange(landscape, cw, presets, self:buildTimerList(list_w, list_h))
end

function StopwatchScreen:buildTimerList(w, h)
    local m = self.model
    local now = Clock.now()
    local row_h = math.min(self:scale(96), math.floor(h / math.max(4, #m.timers)))
    local name_face = Font:getFace("cfont", 22)
    local small = Font:getFace("cfont", 16)
    local time_w = math.floor(w * 0.5)
    local time_face = W.fitFace("cfont", "00:00:00", time_w - 2 * self:getGutter(), math.floor(row_h * 0.62), 72, true)
    self.time_col_x = w - time_w
    self.timer_texts = {}
    for i, t in ipairs(m.timers) do self.timer_texts[i] = Format.down(t:remainingAt(now)) end

    local rows = W.Rows:new{
        width = w, height = h, row_h = row_h, count = #m.timers,
        header = #m.timers == 0 and function(bb, x, y, ww)
            local box = require("ui/widget/textboxwidget"):new{
                text = _("Tap a duration to start a timer. Tap a running timer to pause it, hold it for more options."),
                face = name_face, width = ww - 4 * self:getGutter(), alignment = "center",
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            box:paintTo(bb, x + 2 * self:getGutter(), y + self:getGutter() * 3)
            box:free()
        end or nil,
        paint_row = function(bb, i, x, y, ww, hh)
            local t = m.timers[i]
            local done = t.state == "done"
            local fg = done and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
            local pad = self:getGutter()
            if done then bb:paintRect(x, y + 2, ww, hh - 4, Blitbuffer.COLOR_BLACK) end
            local status
            if t.state == "running" then status = T(_("Ends at %1"), Format.clock(t.end_at))
            elseif t.state == "paused" then status = _("Paused")
            elseif done then status = T(_("Done at %1"), Format.clock(t.done_at or now))
            else status = T(_("Ready · %1"), Format.short(t.duration)) end
            local half = math.floor(hh / 2)
            W.drawText(bb, name_face, t.name, x + pad, y + math.floor(hh * 0.08), ww - time_w - pad, half, fg, true, "left")
            W.drawText(bb, small, status, x + pad, y + half, ww - time_w - pad, half - math.floor(hh * 0.08), fg, false, "left")
            W.drawText(bb, time_face, self.timer_texts[i] or "", x + ww - time_w, y, time_w - pad, hh, fg,
                t.state == "running", "right", true)
            if t.state == "paused" then
                -- paused: a grey bar under the digits
                bb:paintRect(x + ww - time_w + pad, y + hh - math.floor(hh * 0.14), time_w - 2 * pad, 3, Blitbuffer.COLOR_GRAY)
            end
            bb:paintRect(x, y + hh - 1, ww, 1, Blitbuffer.COLOR_DARK_GRAY)
        end,
        on_tap  = function(i) self:onTimerTap(i) end,
        on_hold = function(i) self:onTimerOptions(i) end,
    }
    if #m.timers == 0 then rows.header_h = 0 end
    self.timer_rows = rows
    return rows
end

function StopwatchScreen:nextTimerName(duration)
    return Format.short(duration)
end

function StopwatchScreen:addTimer(duration, name)
    local t = self.model:addTimer(name or self:nextTimerName(duration), duration)
    if not t then
        self:showMessage(T(_("At most %1 timers."), Timers.MAX_TIMERS))
        return
    end
    t:start(Clock.now())
    self:commit()
end

function StopwatchScreen:askCustomTimer()
    local dlg
    dlg = require("ui/widget/multiinputdialog"):new{
        title = _("New timer"),
        fields = {
            { description = _("Duration (5 = 5 min, 1:30, 1h30, 90s)"), text = "", hint = "10", input_type = "string" },
            { description = _("Name (optional)"), text = "", hint = _("Kitchen") },
        },
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Start"), is_enter_default = true, callback = function()
                local f = dlg:getFields()
                local secs = Format.parse(f[1])
                if not secs then
                    self:showMessage(_("Could not read that duration."))
                    return
                end
                UIManager:close(dlg)
                local name = f[2] and f[2]:gsub("^%s+", ""):gsub("%s+$", "") or ""
                self:addTimer(secs, name ~= "" and name or nil)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function StopwatchScreen:onTimerTap(i)
    local t = self.model.timers[i]
    if not t then return end
    local now = Clock.now()
    if t.state == "running" then t:pause(now)
    elseif t.state == "done" then t:reset()
    else t:start(now) end
    self:commit()
end

function StopwatchScreen:onTimerOptions(i)
    local t = self.model.timers[i]
    if not t then return end
    local dlg
    local function act(fn) return function() UIManager:close(dlg); fn(); self:commit() end end
    dlg = ButtonDialog:new{
        title = t.name,
        buttons = {
            { { text = t.state == "running" and _("Pause") or _("Start"), callback = act(function()
                if t.state == "running" then t:pause(Clock.now()) else t:start(Clock.now()) end end) } },
            { { text = _("Restart"), callback = act(function() t:reset(); t:start(Clock.now()) end) } },
            { { text = _("Rename"), callback = function() UIManager:close(dlg); self:renameTimer(t) end } },
            { { text = _("Delete"), callback = act(function() self.model:removeTimer(t.id) end) } },
        },
    }
    UIManager:show(dlg)
end

function StopwatchScreen:renameTimer(t)
    local dlg
    dlg = InputDialog:new{
        title = _("Rename"),
        input = t.name,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("OK"), is_enter_default = true, callback = function()
                local name = dlg:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dlg)
                if name ~= "" then t.name = name end
                self:commit()
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- Interval
-- ---------------------------------------------------------------------------

local function mmss(secs) return Format.up(secs) end

function StopwatchScreen:intervalPhase(now)
    local iv = self.model.interval
    if iv.state == "done" then return _("Finished!"), false end
    if iv.state == "idle" then return T(_("%1 rounds"), iv.rounds), false end
    local _i, p = iv:phaseAt(iv:elapsed(now))
    if not p then return _("Finished!"), false end
    local paused = iv.state == "paused" and (" · " .. _("Paused")) or ""
    if p.kind == "prep" then return _("Get ready") .. paused, false end
    if p.kind == "work" then return T(_("WORK · %1/%2"), p.round, iv.rounds) .. paused, true end
    return T(_("Rest · %1/%2"), p.round, iv.rounds) .. paused, false
end

function StopwatchScreen:intervalTime(now)
    local iv = self.model.interval
    if iv.state == "idle" then return mmss(iv.prep > 0 and iv.prep or iv.work) end
    local _i, _p, left = iv:phaseAt(iv:elapsed(now))
    return Format.down(left or 0)
end

function StopwatchScreen:intervalTotal(now)
    local iv = self.model.interval
    local total = iv:total()
    if iv.state == "idle" then return T(_("Total %1"), Format.up(total)) end
    return T(_("Left %1 of %2"), Format.down(total - iv:elapsed(now)), Format.up(total))
end

function StopwatchScreen:buildInterval(cw, avail_h, landscape)
    local g = self:getGutter()
    local iv = self.model.interval
    local now = Clock.now()
    local col_w = landscape and math.floor((cw - g) * 0.46) or cw
    local editable = iv.state ~= "running"
    local function cfg(label, key)
        return {
            text = T(label, key == "rounds" and tostring(iv.rounds) or mmss(iv[key])),
            enabled = editable,
            height = self:scale(56), font_size = landscape and 18 or 20, font_bold = false,
            callback = function() self:editInterval(key) end,
        }
    end
    local config = ButtonTable:new{
        width = col_w,
        buttons = {
            { cfg(_("Work %1"), "work"), cfg(_("Rest %1"), "rest") },
            { cfg(_("Rounds %1"), "rounds"), cfg(_("Get ready %1"), "prep") },
        },
    }
    local running = iv:isRunning()
    local buttons = self:buttonRow({
        { text = running and _("Pause") or (iv.state == "paused" and _("Resume") or _("Start")),
          callback = function() self:onIntervalStartPause() end },
        { text = _("Reset"), enabled = iv.state ~= "idle", callback = function()
            iv:reset(); self:commit() end },
    }, col_w)

    local right_w = landscape and (cw - col_w - g) or cw
    local phase_h = self:scale(64)
    local total_h = self:scale(44)
    local left_h = config:getSize().h + buttons:getSize().h + g
    local time_h = landscape and math.min(self:scale(260), math.floor(avail_h - phase_h - total_h - 2 * g))
        or math.max(self:scale(120), math.min(self:scale(220), avail_h - left_h - phase_h - total_h - 4 * g))
    local phase_text, inverted = self:intervalPhase(now)
    local phase = W.Label:new{ width = right_w, height = phase_h, bold = true, inverted = inverted, ink = false,
        face = W.fitFace("cfont", phase_text, right_w - 2 * g, phase_h - 2 * Size.padding.default, 34, true) }
    phase:setText(phase_text)
    self.iv_label = W.Label:new{ width = right_w, height = time_h, bold = true,
        face = W.fitFace("cfont", "00:00", right_w - 2 * g, time_h, 220, true) }
    self.iv_total = W.Label:new{ width = right_w, height = total_h, face = Font:getFace("cfont", 22), ink = false }
    self:updateClocks(now, true)

    local display = VerticalGroup:new{
        align = "center",
        phase, VerticalSpan:new{ width = g }, self.iv_label, VerticalSpan:new{ width = g }, self.iv_total,
    }
    local controls = VerticalGroup:new{ align = "center", config, VerticalSpan:new{ width = g }, buttons }
    if landscape then
        return self:arrange(true, cw, controls, display)
    end
    return VerticalGroup:new{ align = "center", display, VerticalSpan:new{ width = 2 * g }, controls }
end

function StopwatchScreen:onIntervalStartPause()
    local iv, now = self.model.interval, Clock.now()
    if iv:isRunning() then iv:pause(now) else iv:start(now) end
    self:commit()
end

function StopwatchScreen:editInterval(key)
    local iv = self.model.interval
    local titles = { work = _("Work time"), rest = _("Rest time"), rounds = _("Number of rounds"), prep = _("Get ready time") }
    local spin
    if key == "rounds" then
        spin = SpinWidget:new{
            title_text = titles[key], value = iv.rounds, value_min = 1, value_max = 99,
            value_step = 1, value_hold_step = 5, default_value = 8,
            callback = function(s)
                iv:configure(iv.work, iv.rest, s.value, iv.prep)
                self:commit()
            end,
        }
    else
        local list, labels, index = {}, {}, 1
        if key ~= "work" then list[1] = 0 end
        for _i, d in ipairs(DURATIONS) do
            if key ~= "prep" or d <= 60 then list[#list + 1] = d end
        end
        for i, d in ipairs(list) do
            labels[i] = mmss(d)
            if d <= iv[key] then index = i end
        end
        spin = SpinWidget:new{
            title_text = titles[key], value_table = labels, value_index = index,
            callback = function(s)
                local v = list[s.value_index] or iv[key]
                local cfgv = { work = iv.work, rest = iv.rest, prep = iv.prep }
                cfgv[key] = v
                iv:configure(cfgv.work, cfgv.rest, iv.rounds, cfgv.prep)
                self:commit()
            end,
        }
    end
    UIManager:show(spin)
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

function StopwatchScreen:menuItems()
    local svc = self.service
    local items = {}
    if self.mode == "stopwatch" then
        items[#items + 1] = { text = _("All laps"), callback = function() self:showAllLaps() end }
    elseif self.mode == "timers" and #self.model.timers > 0 then
        items[#items + 1] = { text = _("Delete finished timers"), callback = function()
            for i = #self.model.timers, 1, -1 do
                local t = self.model.timers[i]
                if t.state == "done" or t.state == "idle" then table.remove(self.model.timers, i) end
            end
            self:commit()
        end }
    end
    local flashes = svc:getSetting("flashes", 3)
    items[#items + 1] = { text = T(_("Screen flashes: %1"), flashes), callback = function()
        local nxt = ({ [1] = 3, [3] = 5, [5] = 10, [10] = 1 })[flashes] or 3
        svc:saveSetting("flashes", nxt)
    end }
    if Device:hasFrontlight() then
        items[#items + 1] = {
            text = svc:getSetting("blink", true) and _("Frontlight blink: on") or _("Frontlight blink: off"),
            callback = function() svc:saveSetting("blink", not svc:getSetting("blink", true)) end }
    end
    items[#items + 1] = {
        text = svc:getSetting("keep_awake", true) and _("Keep reader awake: on") or _("Keep reader awake: off"),
        callback = function() svc:saveSetting("keep_awake", not svc:getSetting("keep_awake", true)) end }
    items[#items + 1] = { text = _("Test the alert"), callback = function()
        lrequire("alert").run{ text = _("Time is up!"), flashes = svc:getSetting("flashes", 3),
            blink = svc:getSetting("blink", true) }
    end }
    items[#items + 1] = { text = _("Help"), callback = function()
        self:showRules((_.lang() == "fr" and HELP_FR) or HELP_EN, { title = _("Help") })
    end }
    return items
end

-- The reader was rotated: rebuild for the new width and height.
function StopwatchScreen:onSetDimensions(dimen)
    self.dimen.w, self.dimen.h = dimen.w, dimen.h
    self:redraw()
end

function StopwatchScreen:updateStatus() end

return StopwatchScreen
