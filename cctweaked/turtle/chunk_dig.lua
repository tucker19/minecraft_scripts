-- chunk_dig <chunks> [job name]
-- Square extends forward and right. Slot 15: portable fuel storage.
-- Slot 16: portable output chest. Storage directly ABOVE is also a fuel source.
-- New run only: no reboot/crash resume. Do not auto-start in a partial quarry.
local args = {...}
local chunks = tonumber(args[1])
if not turtle then error("Run on a mining turtle", 0) end
if not chunks or chunks < 1 or chunks % 1 ~= 0 or chunks == math.huge then
    print('Usage: chunk_dig <chunks> [job name]')
    return
end
local side = chunks * 16
local protocol = "turtle_quarry_v1"
local jobName = args[2] or os.getComputerLabel() or ("Quarry " .. os.getComputerID())
local pos, heading = {x = 0, y = 0, z = 0}, 0
local status, detail, lastFuel = "starting", "", "none consumed yet"
local cells, layer, lastSend = 0, 0, -math.huge
local modem, world, lastGPS = nil, nil, -math.huge
local fuelChestOut, outputChestOut = false, false
local function fuelLevel()
    local n = turtle.getFuelLevel()
    return n == "unlimited" and math.huge or n
end
local function inventory()
    local used, items, capacity = 0, 0, 0
    for i = 1, 14 do
        local count = turtle.getItemCount(i)
        if count > 0 then used = used + 1 end
        items = items + count
        capacity = capacity + count + turtle.getItemSpace(i)
    end
    return {usedSlots = used, totalSlots = 14, items = items,
        capacity = capacity, percent = 100 * used / 14}
end
local function telemetry(force)
    if not force and os.clock() - lastSend < 2 then return end
    lastSend = os.clock()
    modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
    if not modem then return end
    local name = peripheral.getName(modem)
    if not rednet.isOpen(name) then rednet.open(name) end
    if os.clock() - lastGPS >= 15 then
        lastGPS = os.clock()
        local x, y, z = gps.locate(0.3, false)
        world = x and {x = x, y = y, z = z} or nil
    end
    -- GPS is a sampled fix, NOT a fabricated absolute position.
    pcall(rednet.broadcast, {
        type = "quarry", version = 1, id = os.getComputerID(), name = jobName,
        status = status, detail = detail, fuelType = lastFuel,
        fuel = turtle.getFuelLevel(), fuelLimit = turtle.getFuelLimit(),
        job = {chunks = chunks, side = side, area = side * side,
            layer = layer, cells = cells},
        inventory = inventory(),
        location = {relative = {x = pos.x, y = pos.y, z = pos.z},
            heading = heading, gps = world, gpsAge = os.clock() - lastGPS},
    }, protocol)
end
local function announce(s, d)
    status, detail = s, d or ""
    print(s .. (detail ~= "" and (": " .. detail) or ""))
    telemetry(true)
end
local function storageAbove()
    local p = peripheral.wrap("top")
    return p and type(p.list) == "function"
end
local function storageItem(slot)
    local item = turtle.getItemDetail(slot)
    return item and (item.name:find("chest") or item.name:find("barrel"))
end
local function recover(slot)
    turtle.select(slot)
    if not turtle.digUp() or turtle.getItemCount(slot) == 0 then
        error("Cannot recover portable storage above; collect it manually", 0)
    end
end
local function consume(target)
    for i = 1, 14 do
        turtle.select(i)
        while fuelLevel() < target and turtle.refuel(0) do
            local item = turtle.getItemDetail(i)
            local before = fuelLevel()
            if not turtle.refuel(1) then break end
            if fuelLevel() <= before then break end
            lastFuel = item.name
        end
    end
    turtle.select(1)
end
local function pullFuel(target)
    local placed = false
    if not storageAbove() and not turtle.detectUp() and storageItem(15) then
        turtle.select(15)
        placed = turtle.placeUp()
        fuelChestOut = placed
    end
    if storageAbove() then
        -- Fuel-only storage recommended. Return non-fuel/container leftovers
        -- to the source rather than allowing them to fill the turtle.
        for _ = 1, 32 do
            if fuelLevel() >= target then break end
            local empty
            for i = 1, 14 do
                if turtle.getItemCount(i) == 0 then empty = i; break end
            end
            if not empty then break end
            turtle.select(empty)
            if not turtle.suckUp(64) then break end
            consume(target)
            turtle.select(empty)
            if turtle.getItemCount(empty) > 0 and not turtle.dropUp() then
                break
            end
        end
    end
    if placed then recover(15); fuelChestOut = false end
    turtle.select(1)
end
local function ensureFuel()
    if fuelLevel() > 100 then return end
    local limit = turtle.getFuelLimit()
    local target = limit == "unlimited" and 1000 or math.min(4000, limit)
    consume(target)
    pullFuel(target)
    while fuelLevel() <= 100 do
        announce("waiting_fuel", "Add fuel to inventory or fuel storage above")
        sleep(3)
        consume(target)
        pullFuel(target)
    end
    status, detail = "mining", ""
end
local function unload()
    if inventory().usedSlots < 14 then return end
    local previous = status
    while inventory().usedSlots >= 14 do
        local placed = false
        if not turtle.detectUp() and storageItem(16) then
            turtle.select(16)
            placed = turtle.placeUp()
            outputChestOut = placed
        end
        if placed then
            for i = 1, 14 do
                turtle.select(i)
                -- Keep fuel items; only unload mined cargo.
                if not turtle.refuel(0) then turtle.dropUp() end
            end
            recover(16)
            outputChestOut = false
        end
        if inventory().usedSlots >= 14 then
            announce("waiting_inventory", "Free a cargo slot or empty output chest (slot 16)")
            sleep(3)
        end
    end
    status, detail = previous, ""
    turtle.select(1)
end
local function right()
    assert(turtle.turnRight(), "Cannot turn")
    heading = (heading + 1) % 4
end
local function face(h)
    while heading ~= h do right() end
end
local dx, dz = {[0] = 1, 0, -1, 0}, {[0] = 0, 1, 0, -1}
local function step(kind)
    ensureFuel()
    local inspect = kind == "up" and turtle.inspectUp
        or kind == "down" and turtle.inspectDown or turtle.inspect
    local dig = kind == "up" and turtle.digUp
        or kind == "down" and turtle.digDown or turtle.dig
    local move = kind == "up" and turtle.up
        or kind == "down" and turtle.down or turtle.forward
    local attack = kind == "up" and turtle.attackUp
        or kind == "down" and turtle.attackDown or turtle.attack
    for _ = 1, 30 do
        local blocked, block = inspect()
        if blocked then
            -- Never intentionally mine ATM ores with a fake player.
            if block.name:match("^allthemodium:.*ore") then
                return false, block.name
            end
            if storageAbove() and kind == "up" then
                return false, "storage above"
            end
            unload()
            turtle.select(1)
            if not dig() then return false, block.name end
        end
        if move() then
            if kind == "up" then pos.y = pos.y + 1
            elseif kind == "down" then pos.y = pos.y - 1
            else pos.x = pos.x + dx[heading]; pos.z = pos.z + dz[heading] end
            telemetry()
            return true
        end
        attack()
        sleep(0.1)
    end
    return false, "movement blocked"
end
local function mustStep(kind)
    local ok, reason = step(kind)
    if not ok then error("Blocked " .. kind .. ": " .. tostring(reason), 0) end
end
local function forward()
    local ok, reason = step("forward")
    if not ok then
        -- Travel ABOVE the obstacle, not down into the same blocked cell.
        announce("bypassing", tostring(reason))
        mustStep("up")
        mustStep("forward")
    end
    while pos.y > -layer do
        local lowered, block = step("down")
        if not lowered then
            if block == "minecraft:bedrock"
                or tostring(block):match("^allthemodium:.*ore") then
                -- Remain above this protected cell. The next horizontal
                -- step attempts to return to the working layer again.
                break
            end
            error("Cannot return to working layer: " .. tostring(block), 0)
        end
    end
    status, detail = "mining", ""
end
local function main()
    announce("starting", side .. "x" .. side .. "; fuel source above / portable slot 15")
    -- Load from an adjacent chest even if already carrying plenty of fuel.
    consume(4000)
    pullFuel(4000)
    while true do
        announce("mining", "Layer " .. layer)
        for row = 1, side do
            for col = 1, side do
                cells = cells + 1
                unload()
                telemetry()
                if col < side then forward() end
            end
            if row < side then
                face(1); forward()
                face(row % 2 == 1 and 2 or 0)
            end
        end
        -- SIDE is always even: finish at x=0, z=SIDE-1, facing backwards.
        face(3)
        for _ = 1, side - 1 do forward() end
        face(0)
        if pos.y ~= -layer then error("Origin column blocked at working layer", 0) end
        local ok, reason = step("down")
        if not ok then
            if reason ~= "minecraft:bedrock" then
                error("Descent blocked: " .. tostring(reason), 0)
            end
            announce("returning", "First bedrock at origin column; returning home")
            while pos.y < 0 do mustStep("up") end
            announce("complete", "Returned to starting corner")
            return
        end
        layer = layer + 1
    end
end
local ok, err = pcall(main)
if not ok then
    -- Do not move blindly or dig a deployed chest after an error/termination.
    announce("stopped", tostring(err) .. ((fuelChestOut or outputChestOut)
        and " (check portable storage above)" or ""))
end
while true do telemetry(true); sleep(3) end
