-- chunk_dig <chunks> [job name]
--
-- Quarries a square (chunks x 16 blocks per side) from the layer BELOW the
-- turtle down to bedrock. The square extends FORWARD and to the RIGHT of
-- the turtle's starting position. That starting position and facing is
-- "home": the turtle returns there to unload into a stationary output
-- inventory and to refuel from a stationary fuel inventory, then goes
-- back to the exact cell and heading it left and continues.
--
-- No persistent state: a reboot or Ctrl+T ends the job where it stands.
-- Do not put this program in startup.lua.

----------------------------------------------------------------------
-- Configuration (sides are relative to the turtle's STARTING facing)
----------------------------------------------------------------------

-- Where the cargo inventory (barrel/chest) sits next to home.
-- One of: "front", "back", "left", "right", "top".
local OUTPUT_SIDE = "back"

-- Where the fuel inventory (coal blocks) sits next to home.
-- One of: "front", "back", "left", "right", "top". Must differ from
-- OUTPUT_SIDE. "bottom" is not allowed for either: it is the quarry shaft.
local FUEL_SIDE = "top"

-- Extra fuel kept on top of the exact cost of the route home.
local SAFETY_MARGIN = 32

-- A refuel trip only leaves home with enough fuel to reach the work
-- position, do at least this many more moves, and still get home.
local MIN_PROGRESS = 64

-- Seconds between retries while waiting for output space, fuel, or a
-- blocked route.
local RETRY_SECONDS = 5

local PROTOCOL = "turtle_quarry_v1"

----------------------------------------------------------------------
-- Arguments and validation
----------------------------------------------------------------------

local args = {...}
if not turtle then error("Run chunk_dig on a mining turtle", 0) end

local chunks = tonumber(args[1])
if not chunks or chunks < 1 or chunks % 1 ~= 0 or chunks == math.huge then
    print("Usage: chunk_dig <chunks> [job name]")
    print("  1 = 16x16, 2 = 32x32, 3 = 48x48 blocks")
    print("Output: " .. OUTPUT_SIDE .. ", fuel: " .. FUEL_SIDE
        .. " (edit the top of this file)")
    return
end

local SIDE = chunks * 16
local JOB_NAME = args[2] or os.getComputerLabel()
    or ("Quarry " .. os.getComputerID())

local SIDE_HEADING = {front = 0, right = 1, back = 2, left = 3}
local VALID_SIDE = {front = true, right = true, back = true, left = true,
    top = true}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

-- Coordinates relative to home: x = forward, y = up, z = right.
-- Heading 0 = original facing, 1 = right, 2 = back, 3 = left.
local DX = {[0] = 1, 0, -1, 0}
local DZ = {[0] = 0, 1, 0, -1}
local KM = 100000

local pos = {x = 0, y = 0, z = 0}
local heading = 0

local status, detail = "starting", ""
local lastFuel = "none consumed yet"
local fuelValues = {
    ["minecraft:coal_block"] = 800,
    ["minecraft:coal"] = 80,
    ["minecraft:charcoal"] = 80,
    ["minecraft:lava_bucket"] = 1000,
    ["minecraft:blaze_rod"] = 120,
}

local layer = 0              -- 0 = at home level, 1 = first dug layer
local totalCleared = 0
local trips = 0
local inService = false
local reserve = 0            -- fuel needed to reach home + margin

-- Layer bookkeeping. Keys are K(x, z). Only the current layer and the
-- one above it are kept. A layer can be split into several connected
-- "regions" when undiggable blocks (bedrock, protected ore) wall parts of
-- it off; each region is entered from a cleared cell directly above it.
-- region = {entry = {x, z}, up = list of cleared points from the cell
--           above the entry to home, upCost = #up}
local function newLayer(y)
    return {y = y, cleared = {}, dist = {}, blocked = {}, regionOf = {},
        regions = {}, candidates = {}}
end
local cur = nil              -- current layer
local par = nil              -- layer above the current one (nil on layer 1)
local layerCleared, layerBlocked, layerSkipped = 0, 0, 0
local unreached = {}         -- cells proven unreachable from this region

local function K(x, z) return x * KM + z end

local function unlimited()
    return turtle.getFuelLevel() == "unlimited"
end

local function fuelLevel()
    local n = turtle.getFuelLevel()
    return n == "unlimited" and math.huge or n
end

local function fuelLimit()
    local n = turtle.getFuelLimit()
    return n == "unlimited" and math.huge or n
end

local function fail(message) error(message, 0) end

----------------------------------------------------------------------
-- Inventory helpers (slot 1 is always re-selected afterwards)
----------------------------------------------------------------------

local function inventoryInfo()
    local used, items = 0, 0
    for i = 1, 16 do
        local c = turtle.getItemCount(i)
        if c > 0 then used = used + 1 end
        items = items + c
    end
    return {usedSlots = used, totalSlots = 16, emptySlots = 16 - used,
        items = items, percent = 100 * used / 16}
end

local function hasEmptySlot()
    for i = 1, 16 do
        if turtle.getItemCount(i) == 0 then return true end
    end
    return false
end

-- Merge partial stacks of the same item toward lower slots.
local function compact()
    for j = 16, 2, -1 do
        local dj = turtle.getItemDetail(j)
        if dj then
            for i = 1, j - 1 do
                if turtle.getItemCount(j) == 0 then break end
                local di = turtle.getItemDetail(i)
                if di and di.name == dj.name and turtle.getItemSpace(i) > 0 then
                    turtle.select(j)
                    turtle.transferTo(i)
                end
            end
        end
    end
    turtle.select(1)
end

----------------------------------------------------------------------
-- Telemetry
----------------------------------------------------------------------

local lastSend, lastGpsTry = -math.huge, -math.huge
local gpsFix, gpsTime, gpsAt = nil, nil, nil

local function telemetry(force)
    local now = os.clock()
    if not force and now - lastSend < 2 then return end
    lastSend = now

    local modem = peripheral.find("modem", function(_, m)
        return type(m.isWireless) == "function" and m.isWireless()
    end)
    if not modem then return end

    local name = peripheral.getName(modem)
    if not rednet.isOpen(name) then rednet.open(name) end

    if now - lastGpsTry >= 15 then
        lastGpsTry = now
        local x, y, z = gps.locate(0.5)
        if x then
            gpsFix = {x = x, y = y, z = z}
            gpsTime = now
            gpsAt = {x = pos.x, y = pos.y, z = pos.z}
        end
    end

    local gpsInfo = nil
    if gpsFix then
        gpsInfo = {
            x = gpsFix.x, y = gpsFix.y, z = gpsFix.z,
            age = now - gpsTime,
            -- True once the turtle has moved since the fix was taken:
            -- the dashboard must not present it as the current position.
            moved = gpsAt.x ~= pos.x or gpsAt.y ~= pos.y or gpsAt.z ~= pos.z,
        }
    end

    pcall(rednet.broadcast, {
        type = "quarry", version = 1,
        id = os.getComputerID(), name = JOB_NAME,
        status = status, detail = detail,
        fuelType = lastFuel,
        fuel = turtle.getFuelLevel(), fuelLimit = turtle.getFuelLimit(),
        reserve = unlimited() and 0 or reserve,
        job = {
            chunks = chunks, side = SIDE, area = SIDE * SIDE,
            layer = layer, layerCleared = layerCleared,
            layerBlocked = layerBlocked, layerSkipped = layerSkipped,
            regions = cur and #cur.regions or 0, cells = totalCleared,
            trips = trips,
        },
        inventory = inventoryInfo(),
        location = {
            relative = {x = pos.x, y = pos.y, z = pos.z},
            heading = heading,
            gps = gpsInfo,
            -- Kept for older dashboards.
            gpsAge = gpsInfo and gpsInfo.age or nil,
        },
    }, PROTOCOL)
end

local function announce(s, d)
    status, detail = s, d or ""
    print(s .. (detail ~= "" and (": " .. detail) or ""))
    telemetry(true)
end

----------------------------------------------------------------------
-- Turning and raw movement (position changes only after success)
----------------------------------------------------------------------

local function turnRight()
    if not turtle.turnRight() then fail("turnRight failed") end
    heading = (heading + 1) % 4
end

local function turnLeft()
    if not turtle.turnLeft() then fail("turnLeft failed") end
    heading = (heading + 3) % 4
end

local function turnTo(h)
    local diff = (h - heading) % 4
    if diff == 1 then turnRight()
    elseif diff == 2 then turnRight(); turnRight()
    elseif diff == 3 then turnLeft() end
end

local function targetOf(dir)
    if dir == "up" then return pos.x, pos.y + 1, pos.z end
    if dir == "down" then return pos.x, pos.y - 1, pos.z end
    return pos.x + DX[heading], pos.y, pos.z + DZ[heading]
end

local function rawMove(dir)
    local ok, why
    if dir == "up" then ok, why = turtle.up()
    elseif dir == "down" then ok, why = turtle.down()
    else ok, why = turtle.forward() end
    if ok then
        if dir == "up" then pos.y = pos.y + 1
        elseif dir == "down" then pos.y = pos.y - 1
        else
            pos.x = pos.x + DX[heading]
            pos.z = pos.z + DZ[heading]
        end
    end
    return ok, why
end

local function inspectDir(dir)
    if dir == "up" then return turtle.inspectUp() end
    if dir == "down" then return turtle.inspectDown() end
    return turtle.inspect()
end

local function digDir(dir)
    if dir == "up" then return turtle.digUp() end
    if dir == "down" then return turtle.digDown() end
    return turtle.dig()
end

local function attackDir(dir)
    if dir == "up" then return turtle.attackUp() end
    if dir == "down" then return turtle.attackDown() end
    return turtle.attack()
end

----------------------------------------------------------------------
-- Dig protection
----------------------------------------------------------------------

local function isProtectedOre(name)
    -- Allthemodium, Vibranium and Unobtainium ores (all in the
    -- allthemodium namespace). Fake players cannot harvest them, and a
    -- break can delete the ore, so the turtle leaves them in place.
    return name:match("^allthemodium:") and name:find("ore") ~= nil
end

local function looksLikeStorage(name)
    return name:find("chest") or name:find("barrel")
        or name:find("shulker") or name:find("drawer")
end

local function isGravityBlock(name)
    return name:find("sand") or name:find("gravel")
        or name:find("concrete_powder")
end

-- The turtle may only dig inside the quarry footprint below home level.
-- The single exception is a falling block that dropped into the home cell.
local function canDigAt(x, y, z, name)
    if name == "minecraft:bedrock" or isProtectedOre(name) then
        return false
    end
    if y >= 0 then
        return x == 0 and y == 0 and z == 0
            and isGravityBlock(name) and not looksLikeStorage(name)
    end
    return x >= 0 and x < SIDE and z >= 0 and z < SIDE
end

----------------------------------------------------------------------
-- Layer path finding
----------------------------------------------------------------------

-- Breadth-first search inside layer L. When allowUnknown is false only
-- cleared cells are used, so the route is known to be open. Returns the
-- path, or nil plus the set of explored cells.
local function bfs(L, fx, fz, tx, tz, allowUnknown)
    local start, goal = K(fx, fz), K(tx, tz)
    if start == goal then return {{x = fx, z = fz}} end

    local prev = {[start] = start}
    local qx, qz, head = {fx}, {fz}, 1

    while head <= #qx do
        local x, z = qx[head], qz[head]
        head = head + 1
        for h = 0, 3 do
            local nx, nz = x + DX[h], z + DZ[h]
            if nx >= 0 and nx < SIDE and nz >= 0 and nz < SIDE then
                local nk = K(nx, nz)
                if prev[nk] == nil and not L.blocked[nk]
                    and (L.cleared[nk] or allowUnknown)
                then
                    prev[nk] = K(x, z)
                    if nk == goal then
                        local rev, c = {}, nk
                        while c ~= start do
                            rev[#rev + 1] = c
                            c = prev[c]
                        end
                        rev[#rev + 1] = start
                        local out = {}
                        for i = #rev, 1, -1 do
                            out[#out + 1] = {
                                x = math.floor(rev[i] / KM),
                                z = rev[i] % KM,
                            }
                        end
                        return out
                    end
                    qx[#qx + 1] = nx
                    qz[#qz + 1] = nz
                end
            end
        end
    end
    return nil, prev
end

-- Upper bound on moves from the current mining cell to home.
local function homeCost()
    if layer == 0 or not cur then return 0 end
    local k = K(pos.x, pos.z)
    local r = cur.regions[cur.regionOf[k]]
    return (cur.dist[k] or 0) + r.upCost
end

-- Cleared points from cell (x, z) of layer L to home: inside its region
-- to the region entry, then the region's recorded route up.
local function routeFrom(L, x, z)
    local r = L.regions[L.regionOf[K(x, z)]]
    if not r then fail("cell is not in a cleared region (internal)") end
    local p = bfs(L, x, z, r.entry.x, r.entry.z, false)
    if not p then fail("No cleared route to region entry (internal)") end
    local points = {}
    for i = 1, #p do points[#points + 1] = {x = p[i].x, y = L.y, z = p[i].z} end
    for _, c in ipairs(r.up) do points[#points + 1] = c end
    return points
end

local function routeHome()
    if layer == 0 then return {{x = pos.x, y = pos.y, z = pos.z}} end
    if pos.y ~= cur.y then fail("routeHome outside current layer (internal)") end
    return routeFrom(cur, pos.x, pos.z)
end

-- Cleared route from the current cell, up through the layer above, to the
-- cell directly above (tx, tz), then down into (tx, tz). Used to move
-- between separated regions of the current layer.
local function crossRoute(tx, tz)
    if not par then return nil end
    local r = cur.regions[cur.regionOf[K(pos.x, pos.z)]]
    local a = bfs(cur, pos.x, pos.z, r.entry.x, r.entry.z, false)
    local b = bfs(par, r.entry.x, r.entry.z, tx, tz, false)
    if not a or not b then return nil end
    local points = {}
    for i = 1, #a do points[#points + 1] = {x = a[i].x, y = cur.y, z = a[i].z} end
    for i = 1, #b do points[#points + 1] = {x = b[i].x, y = par.y, z = b[i].z} end
    points[#points + 1] = {x = tx, y = cur.y, z = tz}
    return points
end

----------------------------------------------------------------------
-- Waiting while blocked
----------------------------------------------------------------------

local function waitBlocked(message)
    local s, d = status, detail
    announce("blocked", message)
    sleep(RETRY_SECONDS)
    status, detail = s, d
    telemetry(true)
end

----------------------------------------------------------------------
-- Travel (service trips): never digs new ground, never starts a trip
----------------------------------------------------------------------

local function travelStep(n)
    local dir
    if n.y == pos.y + 1 and n.x == pos.x and n.z == pos.z then
        dir = "up"
    elseif n.y == pos.y - 1 and n.x == pos.x and n.z == pos.z then
        dir = "down"
    else
        for h = 0, 3 do
            if pos.x + DX[h] == n.x and pos.z + DZ[h] == n.z
                and n.y == pos.y
            then
                turnTo(h)
                dir = "forward"
            end
        end
        if not dir then fail("Route step is not adjacent (internal)") end
    end

    local tries = 0
    while true do
        local ok, why = rawMove(dir)
        if ok then
            telemetry()
            return
        end
        if why == "Out of fuel" then fail("Out of fuel while travelling") end

        local present, block = inspectDir(dir)
        if present then
            -- Something filled a cleared cell (falling gravel, a placed
            -- block). Dig it only if it is quarry ground and it can be
            -- stored; never dig protected or storage blocks.
            if not hasEmptySlot() then compact() end
            if canDigAt(n.x, n.y, n.z, block.name) and hasEmptySlot()
                and digDir(dir)
            then
                tries = 0
            else
                tries = tries + 1
                if tries >= 3 then
                    waitBlocked("route blocked by " .. block.name
                        .. " at " .. n.x .. "," .. n.y .. "," .. n.z)
                    tries = 0
                end
            end
        else
            attackDir(dir)
            tries = tries + 1
            if tries >= 10 then
                waitBlocked("route blocked at " .. n.x .. "," .. n.y
                    .. "," .. n.z .. " (" .. tostring(why) .. ")")
                tries = 0
            else
                sleep(0.2)
            end
        end
    end
end

local function travelPath(points)
    for i = 2, #points do
        if not unlimited() then
            reserve = (#points - i + 1) + SAFETY_MARGIN
        end
        travelStep(points[i])
    end
end

----------------------------------------------------------------------
-- Base storage at home
----------------------------------------------------------------------

local function faceSide(side)
    if SIDE_HEADING[side] then turnTo(SIDE_HEADING[side]) end
end

local function peripheralSide(side)
    if side == "top" then return "top" end
    return "front"
end

local function inventoryAt(side)
    faceSide(side)
    local p = peripheral.wrap(peripheralSide(side))
    return p ~= nil and type(p.list) == "function"
end

local function dropFn(side)
    if side == "top" then return turtle.dropUp end
    return turtle.drop
end

local function suckFn(side)
    if side == "top" then return turtle.suckUp end
    return turtle.suck
end

-- Move one slot into the output inventory. Never drops into the world:
-- the inventory is checked first.
local function dropToOutput(slot)
    if not inventoryAt(OUTPUT_SIDE) then
        return false, "output inventory missing (" .. OUTPUT_SIDE .. ")"
    end
    turtle.select(slot)
    local before = turtle.getItemCount(slot)
    local ok, why = dropFn(OUTPUT_SIDE)()
    local after = turtle.getItemCount(slot)
    turtle.select(1)
    if after == 0 then return true end
    if after < before then return false, "output inventory full" end
    if why and tostring(why):lower():find("space") then
        return false, "output inventory full"
    end
    return false, "transfer to output failed: " .. tostring(why)
end

local function unloadAll()
    for s = 1, 16 do
        if turtle.getItemCount(s) > 0 then
            local ok, why = dropToOutput(s)
            if not ok then
                turtle.select(1)
                return false, why
            end
        end
    end
    turtle.select(1)
    return true
end

-- Burn carried fuel items, one at a time, until fuel reaches target.
local function consumeCarried(target)
    if unlimited() then return end
    target = math.min(target, fuelLimit())
    for s = 1, 16 do
        if fuelLevel() >= target then break end
        if turtle.getItemCount(s) > 0 then
            turtle.select(s)
            if turtle.refuel(0) then
                local d = turtle.getItemDetail(s)
                while fuelLevel() < target and turtle.getItemCount(s) > 0 do
                    local before = fuelLevel()
                    if not turtle.refuel(1) then break end
                    local gain = fuelLevel() - before
                    if gain <= 0 then break end
                    if d then
                        fuelValues[d.name] = gain
                        lastFuel = d.name
                    end
                end
            end
        end
    end
    turtle.select(1)
end

-- Pull fuel one item at a time into slot 1 and burn it. Tops up as far
-- as possible without overflowing the tank; must reach `need`.
local function topUp(need)
    local limit = fuelLimit()
    local nonFuel = 0
    while true do
        local fuel = fuelLevel()
        if fuel >= limit then return true, "tank full" end
        local nextValue = fuelValues[lastFuel] or 800
        if fuel >= need and limit - fuel < nextValue then
            return true, "topped up"
        end

        if turtle.getItemCount(1) > 0 then
            local ok, why = dropToOutput(1)
            if not ok then return false, why end
        end

        if not inventoryAt(FUEL_SIDE) then
            return false, "fuel inventory missing (" .. FUEL_SIDE .. ")"
        end
        turtle.select(1)
        if not suckFn(FUEL_SIDE)(1) then
            turtle.select(1)
            return false, "fuel inventory empty"
        end

        if turtle.refuel(0) then
            local d = turtle.getItemDetail(1)
            local before = fuelLevel()
            local ok = turtle.refuel(1)
            local gain = fuelLevel() - before
            turtle.select(1)
            if not ok or gain <= 0 then
                return false, "could not burn " .. (d and d.name or "fuel")
            end
            if d then
                fuelValues[d.name] = gain
                lastFuel = d.name
            end
        else
            nonFuel = nonFuel + 1
            local ok, why = dropToOutput(1)
            if not ok then
                faceSide(FUEL_SIDE)
                turtle.select(1)
                dropFn(FUEL_SIDE)()
                turtle.select(1)
                return false, "non-fuel item in fuel inventory; " .. why
            end
            if nonFuel >= 4 then
                return false, "fuel inventory holds non-fuel items"
            end
        end

        -- Empty containers (e.g. buckets) go to the output.
        if turtle.getItemCount(1) > 0 then
            local ok, why = dropToOutput(1)
            if not ok then return false, why end
        end
        turtle.select(1)
    end
end

-- Unload everything, then refuel to at least `need`. Waits at home,
-- keeping all cargo, until both succeed. Ends facing home heading.
local function baseService(need)
    while true do
        if not unlimited() and fuelLevel() < need then
            consumeCarried(need)
        end

        announce("unloading")
        local ok, why = unloadAll()
        if not ok then
            announce("waiting_output", why)
            turnTo(0)
            sleep(RETRY_SECONDS)
        elseif unlimited() then
            break
        else
            if need > fuelLimit() then
                turnTo(0)
                fail("round trip needs " .. need .. " fuel but the fuel"
                    .. " limit is " .. fuelLimit())
            end
            announce("refueling", "need " .. need .. ", have " .. fuelLevel())
            local _, fwhy = topUp(need)
            if fuelLevel() >= need then break end
            announce("waiting_fuel", tostring(fwhy) .. " (have "
                .. fuelLevel() .. ", need " .. need .. ")")
            turnTo(0)
            sleep(RETRY_SECONDS)
        end
    end
    turnTo(0)
    turtle.select(1)
end

----------------------------------------------------------------------
-- Service trip: home and back to the exact cell and heading
----------------------------------------------------------------------

local function service(kind, why, extraNeed)
    if inService then fail("internal error: recursive service trip") end
    inService = true

    local saved = {x = pos.x, y = pos.y, z = pos.z, h = heading}
    local savedCost = homeCost()
    local path = routeHome()
    local routeMoves = #path - 1
    local h = math.max(routeMoves, savedCost)

    announce(kind == "cargo" and "returning_to_unload"
        or "returning_to_refuel", why)
    travelPath(path)

    -- Enough to come back (h), make useful progress (or cover a known
    -- extra trip such as crossing to another region), and get home again.
    baseService(math.max(2 * h + 2 * MIN_PROGRESS + SAFETY_MARGIN,
        h + (extraNeed or 0)))

    announce("resuming", "back to " .. saved.x .. "," .. saved.y .. ","
        .. saved.z)
    local back = {}
    for i = #path, 1, -1 do back[#back + 1] = path[i] end
    travelPath(back)
    turnTo(saved.h)

    if pos.x ~= saved.x or pos.y ~= saved.y or pos.z ~= saved.z
        or heading ~= saved.h
    then
        fail("did not return to saved work position (internal)")
    end

    trips = trips + 1
    inService = false
    reserve = homeCost() + SAFETY_MARGIN
    announce("mining", "layer " .. layer)
end

----------------------------------------------------------------------
-- Mining checks (only called while mining, never during travel)
----------------------------------------------------------------------

local function ensureBudget()
    if unlimited() then reserve = 0 return end
    local need = homeCost() + 2 + SAFETY_MARGIN
    reserve = need
    if fuelLevel() >= need then return end
    consumeCarried(need + MIN_PROGRESS)
    if fuelLevel() >= need then return end
    service("fuel", "fuel " .. fuelLevel() .. " below home reserve " .. need)
end

local function ensureSlot()
    if hasEmptySlot() then return end
    compact()
    if hasEmptySlot() then return end
    service("cargo", "no empty cargo slot")
end

-- Move one cell in `dir`, digging if needed. Returns "moved", or
-- "blocked" plus the block name when the cell cannot be dug.
local function mineStep(dir)
    local tx, ty, tz = targetOf(dir)
    local tries = 0
    while true do
        ensureBudget()
        local present, block = inspectDir(dir)
        if present then
            if not canDigAt(tx, ty, tz, block.name) then
                return "blocked", block.name
            end
            ensureSlot()
            local p2, b2 = inspectDir(dir)
            if p2 then
                if not canDigAt(tx, ty, tz, b2.name) then
                    return "blocked", b2.name
                end
                local ok, why = digDir(dir)
                if not ok then return "blocked", tostring(why) end
            end
        else
            local ok, why = rawMove(dir)
            if ok then return "moved" end
            if why == "Out of fuel" then fail("Out of fuel while mining") end
            attackDir(dir)
            tries = tries + 1
            if tries >= 10 then
                waitBlocked("cannot move " .. dir .. " (" .. tostring(why)
                    .. ")")
                tries = 0
            else
                sleep(0.2)
            end
        end
    end
end

-- Fuel for a precomputed trip that runs without service checks.
local function ensureTrip(need, why)
    if unlimited() then return end
    reserve = need
    if fuelLevel() >= need then return end
    consumeCarried(need + MIN_PROGRESS)
    if fuelLevel() >= need then return end
    service("fuel", why, need)
    if fuelLevel() < need then fail("fuel still below " .. need .. " (internal)") end
end

local function checkBelow()
    local present, b = turtle.inspectDown()
    if not present or canDigAt(pos.x, pos.y - 1, pos.z, b.name) then
        cur.candidates[K(pos.x, pos.z)] = true
    end
end

local function markCleared(key, d, region)
    cur.cleared[key] = true
    cur.dist[key] = d
    cur.regionOf[key] = region
    layerCleared = layerCleared + 1
    totalCleared = totalCleared + 1
    checkBelow()
end

local function onArrive()
    local key = K(pos.x, pos.z)
    if not cur.cleared[key] then
        local best, region
        for h = 0, 3 do
            local nk = K(pos.x + DX[h], pos.z + DZ[h])
            local d = cur.dist[nk]
            if d and cur.cleared[nk] and (not best or d < best) then
                best, region = d, cur.regionOf[nk]
            end
        end
        if not best then fail("arrived in a cell with no cleared neighbour (internal)") end
        markCleared(key, best + 1, region)
    end
    telemetry()
end

local function faceToward(x, z)
    for h = 0, 3 do
        if pos.x + DX[h] == x and pos.z + DZ[h] == z then
            turnTo(h)
            return
        end
    end
    fail("faceToward: not adjacent (internal)")
end

local function markBlocked(key)
    if not cur.blocked[key] then
        cur.blocked[key] = true
        layerBlocked = layerBlocked + 1
    end
end

-- Get the target cell cleared, proven undiggable, or proven unreachable
-- from the current region (it may still be reachable from above).
local function reach(tx, tz)
    local key = K(tx, tz)
    while not cur.cleared[key] and not cur.blocked[key]
        and not unreached[key]
    do
        local path, seen
        if math.abs(pos.x - tx) + math.abs(pos.z - tz) == 1 then
            path = {{x = pos.x, z = pos.z}, {x = tx, z = tz}}
        else
            path, seen = bfs(cur, pos.x, pos.z, tx, tz, true)
        end
        if not path then
            -- Unknown cells count as open in the search, so anything it
            -- could not reach is walled off from this region for good.
            for zz = 0, SIDE - 1 do
                for xx = 0, SIDE - 1 do
                    local k = K(xx, zz)
                    if not seen[k] and not cur.cleared[k]
                        and not cur.blocked[k]
                    then
                        unreached[k] = true
                    end
                end
            end
            return
        end
        local n = path[2]
        faceToward(n.x, n.z)
        if mineStep("forward") == "moved" then
            onArrive()
        else
            markBlocked(K(n.x, n.z))
        end
    end
end

local function startLayer(up)
    layer = layer + 1
    par = cur
    cur = newLayer(-layer)
    layerCleared, layerBlocked, layerSkipped = 0, 0, 0
    cur.regions[1] = {entry = {x = pos.x, z = pos.z}, up = up, upCost = #up}
    markCleared(K(pos.x, pos.z), 0, 1)
    announce("mining", "layer " .. layer)
end

-- Serpentine order: rows run forward (x), shifting right (z).
local function cellAt(i)
    local row = math.floor((i - 1) / SIDE)
    local col = (i - 1) % SIDE
    local x = (row % 2 == 0) and col or (SIDE - 1 - col)
    return x, row
end

local function travelPoints(points, first, last)
    for i = first, last do travelStep(points[i]) end
end

-- Walk to a separated part of the current layer through the cleared
-- layer above and dig down into it. Returns true when a new region was
-- entered; false when the cell below turned out undiggable.
local function enterIsolated(tx, tz)
    local key = K(tx, tz)
    while true do
        ensureSlot()
        local pts = crossRoute(tx, tz)
        if not pts then return false end
        local up = routeFrom(par, tx, tz)
        ensureTrip((#pts - 1) + #up + 2 + SAFETY_MARGIN,
            "fuel for crossing to " .. tx .. "," .. tz)
        -- A service trip may have run; the route is still valid because
        -- it returned to the same cell.
        pts = crossRoute(tx, tz)

        announce("mining", "crossing to walled-off cells at " .. tx .. ","
            .. cur.y .. "," .. tz)
        travelPoints(pts, 2, #pts - 1)

        local result = "ok"
        local present, b = turtle.inspectDown()
        if present then
            if not canDigAt(tx, cur.y, tz, b.name) then
                result = "blocked"
            else
                if not hasEmptySlot() then compact() end
                if not hasEmptySlot() then
                    result = "noslot"
                elseif not digDir("down") then
                    result = "blocked"
                end
            end
        end
        if result == "ok" then
            local tries = 0
            while true do
                local ok, why = rawMove("down")
                if ok then break end
                if why == "Out of fuel" then fail("Out of fuel while mining") end
                attackDir("down")
                tries = tries + 1
                if tries >= 10 then result = "blocked" break end
                sleep(0.2)
            end
        end

        if result == "ok" then
            local idx = #cur.regions + 1
            cur.regions[idx] = {entry = {x = tx, z = tz}, up = up,
                upCost = #up}
            markCleared(key, 0, idx)
            announce("mining", "layer " .. layer)
            return true
        end

        -- Go back the way we came, to the original cell.
        local back = {}
        for i = #pts - 1, 1, -1 do back[#back + 1] = pts[i] end
        travelPoints(back, 2, #back)
        if result == "blocked" then
            markBlocked(key)
            announce("mining", "layer " .. layer)
            return false
        end
        -- "noslot": loop; ensureSlot will run a cargo trip first.
    end
end

local function sweep()
    for i = 1, SIDE * SIDE do
        local x, z = cellAt(i)
        reach(x, z)
    end
end

local function processLayer()
    unreached = {}
    sweep()
    local tried = {}
    while par do
        local fx, fz
        for i = 1, SIDE * SIDE do
            local x, z = cellAt(i)
            local k = K(x, z)
            if not cur.cleared[k] and not cur.blocked[k] and not tried[k]
                and par.cleared[k]
            then
                fx, fz = x, z
                break
            end
        end
        if not fx then break end
        tried[K(fx, fz)] = true
        if enterIsolated(fx, fz) then
            unreached = {}
            sweep()
        end
    end
    layerSkipped = 0
    for i = 1, SIDE * SIDE do
        local x, z = cellAt(i)
        local k = K(x, z)
        if not cur.cleared[k] and not cur.blocked[k] then
            layerSkipped = layerSkipped + 1
        end
    end
    if layerSkipped > 0 then
        print("Layer " .. layer .. ": " .. layerSkipped
            .. " cells walled off and unreachable; skipped")
    end
end

-- Move to cleared cell (cx, cz) of the current layer, crossing through
-- the layer above if it lies in a different region.
local function goToCleared(cx, cz)
    local ri = cur.regionOf[K(cx, cz)]
    if ri ~= cur.regionOf[K(pos.x, pos.z)] then
        local t = cur.regions[ri]
        local pts = crossRoute(t.entry.x, t.entry.z)
        if not pts then fail("no cleared route between regions (internal)") end
        ensureTrip((#pts - 1) + t.upCost + 2 + SAFETY_MARGIN,
            "fuel for crossing between regions")
        pts = crossRoute(t.entry.x, t.entry.z)
        announce("mining", "crossing to another part of layer " .. layer)
        travelPoints(pts, 2, #pts)
        announce("mining", "layer " .. layer)
    end

    local path = bfs(cur, pos.x, pos.z, cx, cz, false)
    for i = 2, #path do
        faceToward(path[i].x, path[i].z)
        if mineStep("forward") ~= "moved" then
            fail("cleared route inside the layer is blocked")
        end
        telemetry()
    end
end

-- Cells of the layer above that were walled off on every side (and from
-- above) are dug upward from the cleared cell beneath them. The turtle
-- does not enter them.
local function clearFromBelow()
    if not par then return end
    par.fromBelow = par.fromBelow or {}
    for i = 1, SIDE * SIDE do
        local x, z = cellAt(i)
        local k = K(x, z)
        if not par.cleared[k] and not par.blocked[k] and not par.fromBelow[k]
            and cur.cleared[k]
        then
            par.fromBelow[k] = true
            goToCleared(x, z)
            local dug = false
            for _ = 1, 32 do
                ensureBudget()
                local present, b = turtle.inspectUp()
                if not present then break end
                if not canDigAt(x, par.y, z, b.name) then break end
                ensureSlot()
                if not digDir("up") then break end
                dug = true
            end
            if dug then
                totalCleared = totalCleared + 1
                print("Dug walled-off cell " .. x .. "," .. par.y .. "," .. z
                    .. " from below")
            end
        end
    end
end

-- Pick the cleared cell closest to home (by route) that can go down.
-- Returns true after descending into a new layer.
local function descend()
    while true do
        local best, bestCost
        for key in pairs(cur.candidates) do
            local r = cur.regions[cur.regionOf[key]]
            local c = cur.dist[key] + r.upCost
            if not bestCost or c < bestCost then best, bestCost = key, c end
        end
        if not best then return false end

        local cx, cz = math.floor(best / KM), best % KM
        goToCleared(cx, cz)
        local up = routeFrom(cur, cx, cz)
        if mineStep("down") == "moved" then
            startLayer(up)
            return true
        end
        cur.candidates[best] = nil
    end
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------

local function validateBase()
    if not VALID_SIDE[OUTPUT_SIDE] then
        fail("OUTPUT_SIDE must be front, back, left, right or top")
    end
    if not VALID_SIDE[FUEL_SIDE] then
        fail("FUEL_SIDE must be front, back, left, right or top")
    end
    if OUTPUT_SIDE == FUEL_SIDE then
        fail("OUTPUT_SIDE and FUEL_SIDE must be different inventories")
    end
    local outOk = inventoryAt(OUTPUT_SIDE)
    local fuelOk = inventoryAt(FUEL_SIDE)
    turnTo(0)
    if not outOk then
        fail("no output inventory on " .. OUTPUT_SIDE .. " side of home")
    end
    if not fuelOk then
        fail("no fuel inventory on " .. FUEL_SIDE .. " side of home")
    end
end

local function main()
    turtle.select(1)
    announce("starting", SIDE .. "x" .. SIDE .. ", output " .. OUTPUT_SIDE
        .. ", fuel " .. FUEL_SIDE)
    validateBase()

    baseService(2 * MIN_PROGRESS + SAFETY_MARGIN)

    if mineStep("down") ~= "moved" then
        fail("cannot dig below home")
    end
    startLayer({{x = 0, y = 0, z = 0}})

    while true do
        processLayer()
        clearFromBelow()
        if not descend() then break end
    end

    inService = true
    announce("returning_home", "finished at layer " .. layer)
    travelPath(routeHome())
    while true do
        local ok, why = unloadAll()
        if ok then break end
        announce("waiting_output", why)
        turnTo(0)
        sleep(RETRY_SECONDS)
    end
    turnTo(0)
    turtle.select(1)
    inService = false
    reserve = 0
    announce("complete", totalCleared .. " cells, " .. layer .. " layers, "
        .. trips .. " service trips")
end

local ok, err = pcall(main)
turtle.select(1)
if not ok then
    if tostring(err) == "Terminated" then
        announce("stopped", "terminated by user")
    else
        announce("error", tostring(err))
    end
end

-- Keep reporting the final state until Ctrl+T.
while true do
    telemetry(true)
    sleep(3)
end
