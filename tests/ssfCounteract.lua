-- Run with: lua tests/ssfCounteract.lua
dofile('src/actions/edit/ssfCounteract.lua')

local function position(points, time, initial)
    local previous, total, velocity = 0, 0, initial
    for _, point in ipairs(points) do
        if point.StartTime > time then break end
        total = total + (point.StartTime - previous) * velocity
        previous, velocity = point.StartTime, point.Multiplier
    end
    return total + (time - previous) * velocity
end

local function check(startTime, hitTime, original, factors, tolerance, factorAtTime)
    local correction, err = buildSSFCounteractSVs(startTime, hitTime, original, factors, 1, tolerance)
    assert(correction, err)
    assert(#correction <= 5000)
    for index = 0, 1000 do
        local time = startTime + (hitTime - startTime) * index / 1000
        local originalDistance = position(original, hitTime, 1) - position(original, time, 1)
        local correctedDistance = position(correction, hitTime, 1) - position(correction, time, 1)
        assert(math.abs(factorAtTime(time) * correctedDistance - originalDistance) <= tolerance + 1e-7)
    end
    return correction
end

local constant = check(0, 100, {}, { { StartTime = 0, Multiplier = 2 } }, 0.01, function() return 2 end)
assert(#constant == 1 and constant[1].Multiplier == 0.5)

local ramp = { { StartTime = 0, Multiplier = 1 }, { StartTime = 200, Multiplier = 2 } }
local first = check(0, 100, {}, ramp, 0.05, function(time) return 1 + time / 200 end)
local second = check(0, 200, {}, ramp, 0.05, function(time) return 1 + time / 200 end)
assert(#first > 1 and #second > 1)

check(0, 200, { { StartTime = 80, Multiplier = 2 } }, ramp, 0.05, function(time) return 1 + time / 200 end)

check(
    1000,
    1500,
    { { StartTime = 900, Multiplier = 1.5 }, { StartTime = 1200, Multiplier = 0.75 } },
    { { StartTime = 0, Multiplier = 1 }, { StartTime = 2000, Multiplier = 2 } },
    0.05,
    function(time) return 1 + time / 2000 end
)

local impossible = buildSSFCounteractSVs(0, 100, {}, { { StartTime = 50, Multiplier = 0 } }, 1, 0.05)
assert(impossible == nil)

local global = { ScrollVelocities = {}, ScrollSpeedFactors = {} }
local source = {
    InitialScrollVelocity = 1,
    ScrollVelocities = {},
    ScrollSpeedFactors = { { StartTime = 0, Multiplier = 2 } },
}
map = { LegacyLNRendering = true, GlobalScrollGroup = global, TimingGroups = { ['$Default'] = source } }
state = {
    SelectedHitObjects = {
        { StartTime = 0, TimingGroup = '$Default' },
        { StartTime = 100, TimingGroup = '$Default' },
    },
}
utils = { GenerateTimingGroupIds = function() return { 'new_1', 'new_2' } end }
action_type = { CreateTimingGroup = 1, AddScrollSpeedFactorBatch = 2 }
createSV = function(time, multiplier) return { StartTime = time, Multiplier = multiplier } end
createSSF = createSV
createSG = function(svs, initial, color)
    return { ScrollVelocities = svs, InitialScrollVelocity = initial, ColorRgb = color }
end
createEA = function(kind, ...) return { kind = kind, args = { ... } } end
sortAscendingStartTime = function(a, b) return a.StartTime < b.StartTime end
pluralize = function(word) return word end
toggleablePrint = function() end
local batch
actions = { PerformBatch = function(items) batch = items end }
ssfCounteract({ tolerance = 0.05 })
assert(#batch == 4)
for _, item in ipairs(batch) do
    if item.kind == action_type.CreateTimingGroup then
        local group, notes = item.args[2], item.args[3]
        assert(#notes == 1)
        assert(group.ScrollVelocities[#group.ScrollVelocities].StartTime == notes[1].StartTime)
    end
end

print('SSF Counteract math checks passed')
