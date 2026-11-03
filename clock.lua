-- clock.lua -- the one place the plugin reads the time.
--
-- Wall-clock (CLOCK_REALTIME) with sub-second precision through KOReader's
-- ui/time, falling back to os.time(). Wall-clock rather than monotonic on
-- purpose: Linux's CLOCK_MONOTONIC stops while a Kobo is suspended, so a
-- 10-minute timer started before a sleep would ring late by the length of
-- the sleep; and the timers are saved with absolute end times so they
-- survive a restart of KOReader, which a boot-relative clock would not.
-- The cost: changing the reader's clock while a timer runs shifts it.

local ok, time = pcall(require, "ui/time")

local Clock = {}

if ok and type(time) == "table" and time.realtime and time.to_number then
    function Clock.now() return time.to_number(time.realtime()) end
else
    function Clock.now() return os.time() end
end

return Clock
