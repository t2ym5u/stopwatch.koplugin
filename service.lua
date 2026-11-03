-- service.lua -- the timers' life outside the screen.
--
-- One per KOReader process (lrequire caches this module), not one per plugin
-- instance: KOReader builds a fresh plugin instance for every file browser
-- and every opened book, and an alarm scheduled by each of them would ring
-- several times. The service owns the model, its settings file, the alarm,
-- the keep-awake hold and the alerts; the plugin instances and the screen
-- only talk to it. So a kitchen timer keeps running, and rings, while you
-- read: closing the screen does not stop it.

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager   = require("ui/uimanager")
local _           = require("i18n")
local T           = require("ffi/util").template

local Timers = lrequire("timers")
local Format = lrequire("format")
local Clock  = lrequire("clock")
local Awake  = lrequire("awake")
local Alert  = lrequire("alert")

local Service = {
    model    = nil,
    settings = nil,
    screen   = nil,   -- the open screen, told about every change
}

-- An event this much older than the moment it is noticed happened while the
-- reader was asleep (the alarm itself fires within a fraction of a second).
Service.LATE = 5

function Service:open(plugin_id)
    if self.settings then return end
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. plugin_id .. ".lua")
    self.model = Timers.load(self.settings:readSetting("state"))
    self._alarm = function() self:onAlarm(false) end
    -- Something may have finished while KOReader was not running at all.
    UIManager:nextTick(function() self:onAlarm(false) end)
end

function Service:getSetting(key, default)
    local v = self.settings:readSetting(key)
    if v == nil then return default end
    return v
end

function Service:saveSetting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
    self:refreshAwake()
end

function Service:save()
    self.settings:saveSetting("state", self.model:serialize())
    self.settings:flush()
end

-- Call after any change to the model: saves, re-arms the alarm, re-decides
-- the keep-awake hold.
function Service:changed()
    self:save()
    self:reschedule()
    self:refreshAwake()
end

function Service:reschedule()
    UIManager:unschedule(self._alarm)
    local at = self.model:nextDeadline()
    if at then
        -- A hair late rather than early: the check must see the end passed.
        UIManager:scheduleIn(math.max(0.02, at - Clock.now() + 0.02), self._alarm)
    end
end

-- Awake while something will ring, and while the stopwatch runs with its
-- screen open (no point keeping a reader awake for a clock nobody watches;
-- it reads right again on resume anyway).
function Service:refreshAwake()
    local want = self:getSetting("keep_awake", true) and (
        self.model:alarmRunning()
        or (self.screen ~= nil and self.model.stopwatch:isRunning()))
    Awake.set(want and true or false)
end

function Service:setScreen(screen)
    self.screen = screen
    self:refreshAwake()
end

-- ---------------------------------------------------------------------------
-- Ringing
-- ---------------------------------------------------------------------------

local function describe(ev)
    if ev.kind == "timer" then
        return ev.name ~= "" and T(_("%1: time is up!"), ev.name) or _("Time is up!")
    elseif ev.kind == "interval" then
        return _("Interval workout complete!")
    elseif ev.phase.kind == "work" then
        return T(_("Work — round %1"), ev.phase.round)
    elseif ev.phase.kind == "rest" then
        return _("Rest")
    end
    return ""
end

function Service:onAlarm(resumed)
    if not self.model then return end
    local now = Clock.now()
    local events = self.model:check(now)
    if #events > 0 then
        self:save()
        self:ring(events, now, resumed)
    end
    self:reschedule()
    self:refreshAwake()
    if self.screen and self.screen.onModelChanged then self.screen:onModelChanged(#events > 0) end
end

-- After a sleep: called by the plugin's onResume.
function Service:onResume()
    if not self.model then return end
    self:onAlarm(true)
end

function Service:ring(events, now, resumed)
    local late, fresh = Timers.splitLate(events, now, self.LATE)
    local flashes = self:getSetting("flashes", 3)
    local blink   = self:getSetting("blink", true)

    if #late > 0 then
        -- Only the timers' final rings matter after a sleep; missed interval
        -- phase changes are noise.
        local lines = {}
        for _i, ev in ipairs(late) do
            if ev.kind ~= "phase" then
                lines[#lines + 1] = T(_("%1 (at %2)"), describe(ev), Format.clock(ev.at))
            end
        end
        if #lines > 0 then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("While the reader was asleep:") .. "\n\n" .. table.concat(lines, "\n"),
            })
        end
    end
    if #fresh == 0 then return end

    local final, lines = false, {}
    for _i, ev in ipairs(fresh) do
        if ev.kind ~= "phase" then final = true end
        lines[#lines + 1] = describe(ev)
    end
    local text = table.concat(lines, "\n")
    if final then
        Alert.run{ text = text, flashes = flashes, blink = blink, message = true }
    else
        -- An interval phase change: one short flash, no message to dismiss
        -- (the screen itself shows the new phase).
        Alert.run{ text = text, flashes = 1, blink = blink, message = false }
    end
end

return Service
