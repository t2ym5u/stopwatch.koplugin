-- timers.lua -- the stopwatch, countdown timers and interval timer, as pure
-- data plus arithmetic. No KOReader dependency: every function that needs
-- the time takes `now` (wall-clock seconds, may be fractional) as an
-- argument, so the specs drive the clock by hand.
--
-- Nothing here counts ticks. A running clock is stored as the wall-clock
-- instant it started (or will end) at, and every reading is computed from
-- `now`: a repaint that comes late, or a reader that slept for an hour, still
-- reads the right time the moment it looks again.

local M = {}

M.MAX_TIMERS = 8
M.MAX_LAPS   = 999

-- ---------------------------------------------------------------------------
-- Stopwatch
-- ---------------------------------------------------------------------------

local Stopwatch = {}
Stopwatch.__index = Stopwatch

function M.newStopwatch()
    return setmetatable({ acc = 0, started_at = nil, laps = {} }, Stopwatch)
end

function Stopwatch:isRunning() return self.started_at ~= nil end

-- Elapsed seconds. A clock set backwards while running never makes the
-- reading go below what was already accumulated.
function Stopwatch:elapsed(now)
    if not self.started_at then return self.acc end
    return self.acc + math.max(0, now - self.started_at)
end

function Stopwatch:start(now)
    if not self.started_at then self.started_at = now end
end

function Stopwatch:pause(now)
    if self.started_at then
        self.acc = self:elapsed(now)
        self.started_at = nil
    end
end

function Stopwatch:reset()
    self.acc, self.started_at, self.laps = 0, nil, {}
end

function Stopwatch:isZero() return not self.started_at and self.acc == 0 end

-- Records a lap: { n, total, split }. split is the time since the previous
-- lap (or since the start for the first one).
function Stopwatch:lap(now)
    if #self.laps >= M.MAX_LAPS then return nil end
    local total = self:elapsed(now)
    local prev  = self.laps[#self.laps]
    local lap = { n = #self.laps + 1, total = total, split = total - (prev and prev.total or 0) }
    self.laps[#self.laps + 1] = lap
    return lap
end

-- Index of the fastest and slowest lap, or nil with fewer than two laps.
function Stopwatch:lapExtremes()
    if #self.laps < 2 then return nil, nil end
    local best, worst = 1, 1
    for i, l in ipairs(self.laps) do
        if l.split < self.laps[best].split then best = i end
        if l.split > self.laps[worst].split then worst = i end
    end
    return best, worst
end

-- ---------------------------------------------------------------------------
-- Countdown timer
--
-- state: "idle" (never started or reset), "running" (end_at set), "paused"
-- (remaining frozen), "done" (rang at done_at, not yet reset).
-- ---------------------------------------------------------------------------

local Countdown = {}
Countdown.__index = Countdown

function M.newCountdown(id, name, duration)
    return setmetatable({
        id = id, name = name, duration = duration,
        state = "idle", remaining = duration, end_at = nil, done_at = nil,
    }, Countdown)
end

function Countdown:isRunning() return self.state == "running" end

function Countdown:remainingAt(now)
    if self.state == "running" then return math.max(0, self.end_at - now) end
    if self.state == "done" then return 0 end
    return self.remaining
end

function Countdown:start(now)
    if self.state == "running" then return end
    if self.state == "done" or self.state == "idle" then self.remaining = self.duration end
    self.end_at  = now + self.remaining
    self.done_at = nil
    self.state   = "running"
end

function Countdown:pause(now)
    if self.state ~= "running" then return end
    self.remaining = math.max(0, self.end_at - now)
    self.end_at    = nil
    self.state     = "paused"
end

function Countdown:reset()
    self.state, self.remaining, self.end_at, self.done_at = "idle", self.duration, nil, nil
end

-- Moves a running timer whose end has passed to "done". Returns the event
-- ({ kind = "timer", name, at }) once, or nil.
function Countdown:check(now)
    if self.state == "running" and now >= self.end_at then
        self.state, self.remaining, self.done_at = "done", 0, self.end_at
        self.end_at = nil
        return { kind = "timer", id = self.id, name = self.name, at = self.done_at }
    end
    return nil
end

function Countdown:nextDeadline()
    return self.state == "running" and self.end_at or nil
end

-- ---------------------------------------------------------------------------
-- Interval timer: optional preparation, then work/rest alternating for N
-- rounds. The last round has no rest after it.
-- ---------------------------------------------------------------------------

local Interval = {}
Interval.__index = Interval

function M.newInterval(work, rest, rounds, prep)
    return setmetatable({
        work = work or 30, rest = rest or 15, rounds = rounds or 8, prep = prep or 5,
        acc = 0, started_at = nil, state = "idle", done_at = nil, phase_idx = 1,
    }, Interval)
end

-- { { kind = "prep"|"work"|"rest", round, dur, from, to }, ... }, from/to
-- in elapsed seconds.
function Interval:phases()
    local list, t = {}, 0
    local function add(kind, round, dur)
        if dur > 0 then
            list[#list + 1] = { kind = kind, round = round, dur = dur, from = t, to = t + dur }
            t = t + dur
        end
    end
    add("prep", 0, self.prep)
    for r = 1, self.rounds do
        add("work", r, self.work)
        if r < self.rounds then add("rest", r, self.rest) end
    end
    return list, t
end

function Interval:total()
    local _l, t = self:phases()
    return t
end

function Interval:isRunning() return self.state == "running" end

function Interval:elapsed(now)
    if self.state == "done" then return self:total() end
    if not self.started_at then return self.acc end
    return math.min(self:total(), self.acc + math.max(0, now - self.started_at))
end

-- The phase at `elapsed`: index, phase, seconds left in it. Past the end:
-- nil index (the whole thing is over).
function Interval:phaseAt(elapsed)
    local list, total = self:phases()
    if elapsed >= total then return nil, nil, 0 end
    for i, p in ipairs(list) do
        if elapsed < p.to then return i, p, p.to - elapsed end
    end
    return nil, nil, 0
end

function Interval:start(now)
    if self.state == "running" then return end
    if self.state == "done" then self:reset() end
    if self:total() <= 0 then return end
    self.started_at = now
    self.state = "running"
    self.phase_idx = self:phaseAt(self.acc) or 1
end

function Interval:pause(now)
    if self.state ~= "running" then return end
    self.acc = self:elapsed(now)
    self.started_at = nil
    self.state = "paused"
end

function Interval:reset()
    self.acc, self.started_at, self.state, self.done_at, self.phase_idx = 0, nil, "idle", nil, 1
end

-- Changing work/rest/rounds/prep only while it is not running; resets it.
function Interval:configure(work, rest, rounds, prep)
    self.work, self.rest, self.rounds, self.prep = work, rest, rounds, prep
    self:reset()
end

-- Events for every phase boundary crossed since the last check, each with
-- the wall-clock instant it happened at; the last one is { kind = "interval" }.
function Interval:check(now)
    if self.state ~= "running" then return {} end
    local events = {}
    local base = self.started_at - self.acc   -- wall-clock instant of elapsed 0
    local list, total = self:phases()
    local idx = self:phaseAt(self:elapsed(now))
    local last = idx and (idx - 1) or #list
    for i = self.phase_idx, last do
        local nxt = list[i + 1]
        if nxt then
            events[#events + 1] = { kind = "phase", phase = nxt, at = base + list[i].to }
        end
    end
    if not idx then
        self.done_at = base + total
        self.acc, self.started_at, self.state = total, nil, "done"
        events[#events + 1] = { kind = "interval", at = self.done_at }
        self.phase_idx = #list
    else
        self.phase_idx = idx
    end
    return events
end

function Interval:nextDeadline()
    if self.state ~= "running" then return nil end
    local list = self:phases()
    local p = list[self.phase_idx]
    return p and (self.started_at - self.acc + p.to) or nil
end

-- ---------------------------------------------------------------------------
-- Model: everything the plugin keeps, saved as one table.
-- ---------------------------------------------------------------------------

local Model = {}
Model.__index = Model

function M.newModel()
    return setmetatable({
        stopwatch = M.newStopwatch(),
        timers    = {},
        interval  = M.newInterval(),
        next_id   = 1,
    }, Model)
end

function Model:addTimer(name, duration)
    if #self.timers >= M.MAX_TIMERS then return nil end
    local t = M.newCountdown(self.next_id, name, duration)
    self.next_id = self.next_id + 1
    self.timers[#self.timers + 1] = t
    return t
end

function Model:findTimer(id)
    for i, t in ipairs(self.timers) do
        if t.id == id then return t, i end
    end
end

function Model:removeTimer(id)
    local _t, i = self:findTimer(id)
    if i then table.remove(self.timers, i) end
end

-- Something that will ring is running (a countdown or the interval timer).
function Model:alarmRunning()
    if self.interval:isRunning() then return true end
    for _i, t in ipairs(self.timers) do
        if t:isRunning() then return true end
    end
    return false
end

function Model:anyRunning()
    return self.stopwatch:isRunning() or self:alarmRunning()
end

-- All events due by `now`, oldest first.
function Model:check(now)
    local events = {}
    for _i, t in ipairs(self.timers) do
        local ev = t:check(now)
        if ev then events[#events + 1] = ev end
    end
    for _i, ev in ipairs(self.interval:check(now)) do events[#events + 1] = ev end
    table.sort(events, function(a, b) return a.at < b.at end)
    return events
end

-- Earliest wall-clock instant something will ring, or nil.
function Model:nextDeadline()
    local best = self.interval:nextDeadline()
    for _i, t in ipairs(self.timers) do
        local d = t:nextDeadline()
        if d and (not best or d < best) then best = d end
    end
    return best
end

-- Splits events noticed at `now` into those that rang on time and those that
-- happened while nobody could see them (the reader was asleep, or KOReader
-- was not running): older than `grace` seconds.
function M.splitLate(events, now, grace)
    local late, fresh = {}, {}
    for _i, ev in ipairs(events) do
        if now - ev.at > (grace or 5) then late[#late + 1] = ev else fresh[#fresh + 1] = ev end
    end
    return late, fresh
end

-- ---------------------------------------------------------------------------
-- Persistence: plain tables only (LuaSettings writes them as Lua source).
-- ---------------------------------------------------------------------------

local function copyFields(src, fields)
    local out = {}
    for _i, f in ipairs(fields) do out[f] = src[f] end
    return out
end

local SW_FIELDS = { "acc", "started_at" }
local CD_FIELDS = { "id", "name", "duration", "state", "remaining", "end_at", "done_at" }
local IV_FIELDS = { "work", "rest", "rounds", "prep", "acc", "started_at", "state", "done_at", "phase_idx" }

function Model:serialize()
    local sw = copyFields(self.stopwatch, SW_FIELDS)
    sw.laps = {}
    for i, l in ipairs(self.stopwatch.laps) do sw.laps[i] = { n = l.n, total = l.total, split = l.split } end
    local timers = {}
    for i, t in ipairs(self.timers) do timers[i] = copyFields(t, CD_FIELDS) end
    return {
        version   = 1,
        stopwatch = sw,
        timers    = timers,
        interval  = copyFields(self.interval, IV_FIELDS),
        next_id   = self.next_id,
    }
end

local function num(v, default)
    v = tonumber(v)
    return v or default
end

local VALID_CD = { idle = true, running = true, paused = true, done = true }

function M.load(data)
    local m = M.newModel()
    if type(data) ~= "table" then return m end
    local sw = data.stopwatch
    if type(sw) == "table" then
        m.stopwatch.acc = num(sw.acc, 0)
        m.stopwatch.started_at = tonumber(sw.started_at)
        if type(sw.laps) == "table" then
            for i, l in ipairs(sw.laps) do
                if type(l) == "table" and tonumber(l.total) then
                    m.stopwatch.laps[#m.stopwatch.laps + 1] = {
                        n = i, total = num(l.total, 0), split = num(l.split, 0) }
                end
            end
        end
    end
    if type(data.timers) == "table" then
        for _i, t in ipairs(data.timers) do
            if type(t) == "table" and tonumber(t.duration) and #m.timers < M.MAX_TIMERS then
                local c = M.newCountdown(num(t.id, #m.timers + 1), tostring(t.name or ""), num(t.duration, 60))
                c.state     = VALID_CD[t.state] and t.state or "idle"
                c.remaining = num(t.remaining, c.duration)
                c.end_at    = tonumber(t.end_at)
                c.done_at   = tonumber(t.done_at)
                if c.state == "running" and not c.end_at then c.state = "paused" end
                m.timers[#m.timers + 1] = c
            end
        end
    end
    local iv = data.interval
    if type(iv) == "table" then
        local i = m.interval
        i.work, i.rest = num(iv.work, i.work), num(iv.rest, i.rest)
        i.rounds, i.prep = num(iv.rounds, i.rounds), num(iv.prep, i.prep)
        i.acc = num(iv.acc, 0)
        i.started_at = tonumber(iv.started_at)
        i.state = ({ idle = true, running = true, paused = true, done = true })[iv.state] and iv.state or "idle"
        i.done_at = tonumber(iv.done_at)
        i.phase_idx = num(iv.phase_idx, 1)
        if i.state == "running" and not i.started_at then i.state = "paused" end
    end
    local max_id = 0
    for _i, t in ipairs(m.timers) do max_id = math.max(max_id, t.id) end
    m.next_id = math.max(num(data.next_id, 1), max_id + 1)
    return m
end

return M
