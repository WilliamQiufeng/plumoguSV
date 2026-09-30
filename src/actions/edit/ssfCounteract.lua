local MAX_COUNTERACT_SVS = 5000

local function isFinite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

-- Quaver inserts global points after group points, so global points win equal-time ties.
local function effectivePoints(group, field)
    local points = {}
    local function append(source, priority)
        for index, point in ipairs(source[field] or {}) do
            table.insert(points, {
                StartTime = point.StartTime,
                Multiplier = point.Multiplier,
                priority = priority,
                index = index,
            })
        end
    end
    append(group, 1)
    if group ~= map.GlobalScrollGroup then append(map.GlobalScrollGroup, 2) end
    table.sort(points, function(a, b)
        if a.StartTime ~= b.StartTime then return a.StartTime < b.StartTime end
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.index < b.index
    end)
    return points
end

local function multiplierAt(points, time, initial)
    local low, high = 1, #points
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if points[mid].StartTime <= time then
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return high == 0 and initial or points[high].Multiplier
end

local function positionFunction(svs, initial)
    local positions = {}
    local lastTime, lastPosition, lastSV = 0, 0, initial
    for index, sv in ipairs(svs) do
        lastPosition = lastPosition + (sv.StartTime - lastTime) * lastSV
        positions[index] = lastPosition
        lastTime, lastSV = sv.StartTime, sv.Multiplier
    end
    return function(time)
        local low, high = 1, #svs
        while low <= high do
            local mid = math.floor((low + high) / 2)
            if svs[mid].StartTime <= time then
                low = mid + 1
            else
                high = mid - 1
            end
        end
        if high == 0 then return time * initial end
        return positions[high] + (time - svs[high].StartTime) * svs[high].Multiplier
    end
end

local function factorAt(ssfs, time)
    local low, high = 1, #ssfs
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if ssfs[mid].StartTime <= time then
            low = mid + 1
        else
            high = mid - 1
        end
    end
    if high == 0 then return 1 end
    if high == #ssfs then return ssfs[high].Multiplier end
    local left, right = ssfs[high], ssfs[high + 1]
    return left.Multiplier
        + (right.Multiplier - left.Multiplier) * (time - left.StartTime) / (right.StartTime - left.StartTime)
end

-- Returns SV points for one note start. Each segment has constant original SV and linear SSF,
-- so its exact maximum visible error is at the midpoint of the segment.
function buildSSFCounteractSVs(startTime, hitTime, svs, ssfs, initialSV, tolerance)
    local position = positionFunction(svs, initialSV)
    local hitPosition = position(hitTime)
    local times = { startTime, hitTime }
    for _, points in ipairs({ svs, ssfs }) do
        for _, point in ipairs(points) do
            if point.StartTime > startTime and point.StartTime < hitTime then times[#times + 1] = point.StartTime end
        end
    end
    table.sort(times)
    local unique = { times[1] }
    for index = 2, #times do
        if times[index] ~= unique[#unique] then unique[#unique + 1] = times[index] end
    end

    -- Before the first SSF Quaver uses 1x, then jumps to the first point's value.
    if #ssfs > 0 and ssfs[1].StartTime > startTime and ssfs[1].StartTime < hitTime and ssfs[1].Multiplier ~= 1 then
        return nil, 'An SSF jump inside the approach cannot be counteracted with finite SV points.'
    end
    for index = 2, #ssfs do
        if
            ssfs[index].StartTime == ssfs[index - 1].StartTime
            and ssfs[index].StartTime >= startTime
            and ssfs[index].StartTime <= hitTime
        then
            return nil, 'Overlapping SSF points inside the approach are unsupported.'
        end
    end

    local function desiredDistance(time)
        local factor = factorAt(ssfs, time)
        if not isFinite(factor) or factor == 0 then return nil end
        return (hitPosition - position(time)) / factor
    end

    local result = {}
    local function addSegment(left, right, leftDistance, rightDistance)
        if #result >= MAX_COUNTERACT_SVS then return false end
        local mid = (left + right) / 2
        local slope = (leftDistance - rightDistance) / (right - left)
        local error = math.abs(factorAt(ssfs, mid) * (leftDistance + rightDistance) / 2 - (hitPosition - position(mid)))
        if not isFinite(slope) or not isFinite(error) then return false end
        if error > tolerance then
            -- Quaver stores SV timestamps as float32; avoid points that collapse when converted.
            local minimumStep = math.max(0.000001, math.abs(mid) * 2 ^ -22)
            if mid - left <= minimumStep or right - mid <= minimumStep then return false end
            local midDistance = desiredDistance(mid)
            if not midDistance then return false end
            return addSegment(left, mid, leftDistance, midDistance)
                and addSegment(mid, right, midDistance, rightDistance)
        end
        result[#result + 1] = { StartTime = left, Multiplier = slope }
        return true
    end

    for index = 1, #unique - 1 do
        local left, right = unique[index], unique[index + 1]
        local leftFactor, rightFactor = factorAt(ssfs, left), factorAt(ssfs, right)
        if
            not isFinite(leftFactor)
            or not isFinite(rightFactor)
            or leftFactor == 0
            or rightFactor == 0
            or leftFactor * rightFactor < 0
        then
            return nil, 'SSF reaches zero inside the approach.'
        end
        local leftDistance, rightDistance = desiredDistance(left), desiredDistance(right)
        if not leftDistance or not rightDistance or not addSegment(left, right, leftDistance, rightDistance) then
            return nil, 'The tolerance needs more than 5,000 SV points or exceeds timestamp precision.'
        end
    end
    return result
end

function ssfCounteract(menuVars)
    local tolerance = menuVars.tolerance
    if not isFinite(tolerance) or tolerance <= 0 then
        toggleablePrint('e!', 'Tolerance must be a positive finite number of msx.')
        return
    end
    if not map.LegacyLNRendering then
        toggleablePrint('e!', 'SSF Counteract requires Legacy LN Rendering to be enabled.')
        return
    end

    local selected = state.SelectedHitObjects
    local startTime, endTime = math.huge, -math.huge
    local grouped = {}
    for _, note in ipairs(selected) do
        startTime = math.min(startTime, note.StartTime)
        endTime = math.max(endTime, note.StartTime)
        local sourceId = note.TimingGroup
        if not sourceId or sourceId == '' then sourceId = '$Default' end
        grouped[sourceId] = grouped[sourceId] or {}
        grouped[sourceId][note.StartTime] = grouped[sourceId][note.StartTime] or {}
        table.insert(grouped[sourceId][note.StartTime], note)
    end
    if startTime >= endTime then
        toggleablePrint('e!', 'Select notes with at least two distinct start times.')
        return
    end

    local planned = {}
    for sourceId, byTime in pairs(grouped) do
        local source = map.TimingGroups[sourceId]
        if not source then
            toggleablePrint('e!', 'Selected note has an unknown timing group: ' .. sourceId)
            return
        end
        local svs = effectivePoints(source, 'ScrollVelocities')
        local ssfs = effectivePoints(source, 'ScrollSpeedFactors')
        for hitTime, notes in pairs(byTime) do
            for _, globalSV in ipairs(map.GlobalScrollGroup.ScrollVelocities) do
                if globalSV.StartTime >= startTime and globalSV.StartTime <= hitTime then
                    toggleablePrint('e!', 'An inherited global SV lies inside the counteracted approach.')
                    return
                end
            end
            local correction, err =
                buildSSFCounteractSVs(startTime, hitTime, svs, ssfs, source.InitialScrollVelocity, tolerance)
            if not correction then
                toggleablePrint('e!', err)
                return
            end
            local newSVs = {}
            local sourceSVs = source == map.GlobalScrollGroup and {} or source.ScrollVelocities
            for _, sv in ipairs(sourceSVs) do
                if sv.StartTime < startTime or sv.StartTime > hitTime then
                    newSVs[#newSVs + 1] = createSV(sv.StartTime, sv.Multiplier)
                end
            end
            for _, sv in ipairs(correction) do
                newSVs[#newSVs + 1] = createSV(sv.StartTime, sv.Multiplier)
            end
            newSVs[#newSVs + 1] = createSV(hitTime, multiplierAt(svs, hitTime, source.InitialScrollVelocity))
            if #newSVs > MAX_COUNTERACT_SVS then
                toggleablePrint('e!', 'The timing group needs more than 5,000 SV points.')
                return
            end
            table.sort(newSVs, sortAscendingStartTime)
            planned[#planned + 1] = { source = source, notes = notes, svs = newSVs }
        end
    end

    local ids = utils.GenerateTimingGroupIds(#planned, 'ssf_counteract_')
    local editorActions = {}
    for index, item in ipairs(planned) do
        local newGroup = createSG(item.svs, item.source.InitialScrollVelocity, item.source.ColorRgb)
        editorActions[#editorActions + 1] = createEA(action_type.CreateTimingGroup, ids[index], newGroup, item.notes)
        if item.source ~= map.GlobalScrollGroup and #item.source.ScrollSpeedFactors > 0 then
            local clonedSSFs = {}
            for _, ssf in ipairs(item.source.ScrollSpeedFactors) do
                clonedSSFs[#clonedSSFs + 1] = createSSF(ssf.StartTime, ssf.Multiplier)
            end
            editorActions[#editorActions + 1] = createEA(action_type.AddScrollSpeedFactorBatch, clonedSSFs, newGroup)
        end
    end
    actions.PerformBatch(editorActions)
    toggleablePrint('s!', 'Counteracted SSF for ' .. #selected .. pluralize(' selected note.', #selected, -2))
end
