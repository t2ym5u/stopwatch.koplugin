-- awake.lua -- keeps the reader from going to sleep while a timer runs.
--
-- Same two switches as Plugin Manager 1.7.0 uses during a bulk install,
-- both what KOReader's own background jobs use:
--   * PluginShare.pause_auto_suspend, read by the autosuspend plugin each
--     time its countdown fires (keepalive.koplugin uses the same flag);
--   * UIManager:preventStandby() / allowStandby(), counted.
-- Each one is a no-op where it does not exist (emulator, older builds).
--
-- One hold at a time: set(true) twice is the same as once, set(false)
-- gives back exactly what set(true) took and restores the flag as it was.
-- The power button still suspends the reader: nothing here can stop that,
-- which is why the plugin also checks its timers on resume.

local UIManager = require("ui/uimanager")

local Awake = { held = false, saved = nil, standby = false }

local function pluginshare()
    local ok, PluginShare = pcall(require, "pluginshare")
    return ok and type(PluginShare) == "table" and PluginShare or nil
end

function Awake.set(on)
    if on == Awake.held then return end
    local share = pluginshare()
    if on then
        Awake.held = true
        if share then
            Awake.saved = share.pause_auto_suspend
            share.pause_auto_suspend = true
        end
        Awake.standby = false
        if type(UIManager.preventStandby) == "function" and type(UIManager.allowStandby) == "function" then
            Awake.standby = pcall(UIManager.preventStandby, UIManager)
        end
    else
        Awake.held = false
        if share then share.pause_auto_suspend = Awake.saved end
        Awake.saved = nil
        if Awake.standby then pcall(UIManager.allowStandby, UIManager) end
        Awake.standby = false
        -- Count the end of the hold as activity, so the autosuspend countdown
        -- starts from now instead of putting the reader to sleep at once.
        if type(UIManager.event_hook) == "table" and UIManager.event_hook.execute then
            pcall(UIManager.event_hook.execute, UIManager.event_hook, "InputEvent")
        end
    end
end

return Awake
