-- format.lua -- durations as text, and typed durations back to seconds.
-- Pure: no KOReader dependency.

local F = {}

-- Whole seconds shown by a clock that counts up: 59.9 s still reads 00:59.
function F.up(secs)
    secs = math.max(0, math.floor(secs + 1e-6))
    local h, m, s = math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

-- Whole seconds shown by a clock that counts down: 0.2 s left still reads
-- 00:01, and 00:00 only appears once the time is really up.
function F.down(secs)
    return F.up(math.ceil(math.max(0, secs) - 1e-6))
end

-- With tenths, for a stopped stopwatch and for laps: "01:23.4".
function F.tenths(secs)
    local t = math.floor(math.max(0, secs) * 10 + 1e-6)
    return F.up(math.floor(t / 10)) .. "." .. tostring(t % 10)
end

-- A short label for a preset or a duration setting: "5 min", "1 h 30 min",
-- "45 s", "1 min 30 s".
function F.short(secs, units)
    units = units or { h = "h", min = "min", s = "s" }
    secs = math.floor(secs + 0.5)
    local h, m, s = math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60
    local parts = {}
    if h > 0 then parts[#parts + 1] = h .. " " .. units.h end
    if m > 0 then parts[#parts + 1] = m .. " " .. units.min end
    if s > 0 or #parts == 0 then parts[#parts + 1] = s .. " " .. units.s end
    return table.concat(parts, " ")
end

-- Parses what a user types for a custom timer:
--   "5"        -> 5 minutes
--   "1:30"     -> 1 min 30 s
--   "1:00:00"  -> 1 hour
--   "90s", "2m", "1h30", "1h 30m", "1 h 30 min", "45 sec"
-- Returns seconds (> 0) or nil.
function F.parse(text)
    if type(text) ~= "string" then return nil end
    local s = text:lower():gsub("^%s+", ""):gsub("%s+$", ""):gsub(",", ".")
    if s == "" then return nil end
    local total
    if s:match("^%d+%.?%d*$") then
        total = tonumber(s) * 60
    elseif s:match("^%d+:%d%d?$") then
        local m, sec = s:match("^(%d+):(%d+)$")
        if tonumber(sec) >= 60 then return nil end
        total = tonumber(m) * 60 + tonumber(sec)
    elseif s:match("^%d+:%d%d?:%d%d?$") then
        local h, m, sec = s:match("^(%d+):(%d+):(%d+)$")
        if tonumber(m) >= 60 or tonumber(sec) >= 60 then return nil end
        total = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)
    else
        total = 0
        local rest = s
        local unit_secs = { h = 3600, hr = 3600, hrs = 3600, hour = 3600, hours = 3600, heure = 3600, heures = 3600,
                            m = 60, mn = 60, min = 60, mins = 60, minute = 60, minutes = 60,
                            s = 1, sec = 1, secs = 1, second = 1, seconds = 1, seconde = 1, secondes = 1 }
        local last_unit
        while rest ~= "" do
            local n, u, tail = rest:match("^(%d+%.?%d*)%s*(%a*)%s*(.*)$")
            if not n then return nil end
            if u == "" then
                -- "1h30": a bare number after hours means minutes, after
                -- minutes means seconds.
                if last_unit == 3600 then u = "m" elseif last_unit == 60 then u = "s" else return nil end
            end
            local f = unit_secs[u]
            if not f then return nil end
            total = total + tonumber(n) * f
            last_unit = f
            rest = tail
        end
    end
    total = math.floor(total + 0.5)
    if total <= 0 or total > 99 * 3600 then return nil end
    return total
end

-- "14:32" for a wall-clock instant (os.date, local time).
function F.clock(at)
    return os.date("%H:%M", math.floor(at))
end

return F
