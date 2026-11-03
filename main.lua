local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local PluginBase = require("plugin_base")
local _          = require("i18n")

require("i18n").extend(lrequire("i18n_fr"))
local Service         = lrequire("service")
local StopwatchScreen = lrequire("screen")

local Stopwatch = PluginBase:extend{
    name      = "stopwatch",
    menu_text = _("Stopwatch & timer"),
    menu_hint = "tools",
}

-- The timers live in the service (one per KOReader process), and so does
-- the settings file: two LuaSettings objects on one file would each write
-- back their own copy and lose the other's changes.
function Stopwatch:ensureSettings()
    Service:open(self:getPluginId())
    self.settings_file = Service.settings.file
    self.settings = Service.settings
end

function Stopwatch:createScreen()
    return StopwatchScreen:new{ plugin = self, service = Service }
end

-- The reader woke up: anything that should have rung while it slept is
-- reported now, with the time it finished at.
function Stopwatch:onResume()
    Service:onResume()
end

function Stopwatch:stopPlugin()
    PluginBase.stopPlugin(self)
    Service:setScreen(nil)
    require("ui/uimanager"):unschedule(Service._alarm)
    lrequire("awake").set(false)
end

-- A utility, not a game: its own entry in the Tools menu, as Dashboard,
-- Plugin Manager and Book Drop have, rather than a place under Tools →
-- Games (PluginBase's default).
function Stopwatch:addToMainMenu(menu_items)
    menu_items.stopwatch = {
        text         = self.menu_text,
        sorting_hint = "tools",
        callback     = function() self:showGame() end,
    }
end

return Stopwatch
