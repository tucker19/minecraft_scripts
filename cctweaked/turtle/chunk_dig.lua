-- chunk_dig: dig a chunk-sized square area straight down to bedrock.
--
-- Usage:
--   chunk_dig <chunks>
--
--   1 = 16x16 blocks (one chunk)
--   2 = 32x32 blocks (2x2 chunks)
--   3 = 48x48 blocks (3x3 chunks)
--
-- The turtle digs a square with its starting corner where it sits,
-- clears 3 layers per pass, and stops at bedrock. When finished (or
-- out of fuel) it climbs back up to its starting position.
--
-- Put an ender chest in slot 16 and the turtle drops its inventory
-- into it automatically when it fills up.

local args = {...}
local chunks = tonumber(args[1])

if not chunks or chunks < 1 or chunks % 1 ~= 0 then
    print("Usage: chunk_dig <chunks>")
    print("  1 = 16x16, 2 = 2x2 chunks, 3 = 3x3 chunks")
    print("Digs from the turtle's level down to bedrock,")
    print("then climbs back to the start.")
    return
end

local SIDE = chunks * 16

-- heading: 0 = initial facing, 1 = right of it, 2 = behind, 3 = left of it
local heading = 0
local depth = 0

local function turnRight()
    turtle.turnRight()
    heading = (heading + 1) % 4
end

local function turnLeft()
    turtle.turnLeft()
    heading = (heading + 3) % 4
end

local function turnTo(target)
    while heading ~= target do turnRight() end
end

local function safeDig()
    while turtle.detect() do
        if not turtle.dig() then return false end
    end
    return true
end

local function safeDigUp()
    while turtle.detectUp() do
        if not turtle.digUp() then return false end
    end
    return true
end

local function safeDigDown()
    while turtle.detectDown() do
        if not turtle.digDown() then return false end
    end
    return true
end

local function forward()
    for attempt = 1, 50 do
        if safeDig() then
            if turtle.forward() then return true end
        elseif turtle.getFuelLevel() > 0 then
            -- Undiggable block ahead (bedrock-adjacent mods, ATM10's
            -- Allthemodium ore, obsidian with a weak pick, ...).
            -- Climb over it and drop in behind it, leaving the block
            -- in the wall to collect by hand later.
            if not up() then break end

            if turtle.forward() then
                if down() then return true end

                error("Climbed over an undiggable block but cannot"
                    .. " descend behind it.", 0)
            end

            turtle.down()
        else
            break -- out of fuel, digging fails
        end

        turtle.attack()
        sleep(0.1)
    end
    return false
end

local function up()
    safeDigUp()
    return turtle.up()
end

local function down()
    safeDigDown()
    return turtle.down()
end

local function bedrockBelow()
    local ok, data = turtle.inspectDown()
    return ok and data.name == "minecraft:bedrock"
end

local function refuel()
    for slot = 1, 16 do
        turtle.select(slot)
        turtle.refuel()
    end
end

-- One pass: a serpentine sweep over the whole square.
-- At each cell the turtle clears above and below, so each pass
-- removes 3 layers: the one it sits on, one above, one below.
local function digPass()
    for row = 1, SIDE do
        safeDigUp()
        safeDigDown()

        for col = 1, SIDE - 1 do
            if not forward() then
                error("Stuck while digging row " .. row, 0)
            end
            safeDigUp()
            safeDigDown()
        end

        if row < SIDE then
            if row % 2 == 1 then
                turnRight()
                forward()
                turnRight()
            else
                turnLeft()
                forward()
                turnLeft()
            end
        end
    end
end

-- After a pass the turtle sits at a far corner:
--   SIDE odd  -> (SIDE-1, SIDE-1), heading 0
--   SIDE even -> (0, SIDE-1), heading 2
-- Walk back to the starting corner.
local function returnToStart()
    if heading == 0 then
        turnRight()
        turnRight()
        for i = 1, SIDE - 1 do forward() end
        turnRight()
        for i = 1, SIDE - 1 do forward() end
    else
        turnRight()
        for i = 1, SIDE - 1 do forward() end
    end
end

local function usedSlots()
    local used = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then used = used + 1 end
    end
    return used
end

local function dropoff()
    local chest = turtle.getItemDetail(16)

    if not chest or not chest.name:lower():find("chest") then
        return false
    end

    safeDigUp()
    turtle.select(16)

    if not turtle.placeUp() then return false end

    for slot = 1, 15 do
        turtle.select(slot)
        turtle.dropUp()
    end

    turtle.select(16)
    turtle.digUp() -- chest item falls onto the turtle and is collected
    return true
end

-- Fuel needed: one more pass, the walk home, the descent,
-- and a reserve for the final climb back up.
local function fuelNeeded()
    return SIDE * SIDE + 4 * SIDE + 40 + depth + 3
end

local function fuelCheck()
    if turtle.getFuelLevel() >= fuelNeeded() then return true end

    refuel()

    if turtle.getFuelLevel() >= fuelNeeded() then return true end

    print("Fuel low: have " .. turtle.getFuelLevel()
        .. ", need about " .. fuelNeeded())
    return false
end

-- Descend one layer. Returns "ok", "bedrock", or "stuck".
local function descendOne()
    if down() then
        depth = depth + 1
        return "ok"
    end

    if bedrockBelow() then
        return "bedrock"
    end

    return "stuck"
end

print("Digging " .. SIDE .. "x" .. SIDE .. " blocks ("
    .. chunks .. "x" .. chunks .. " chunks) down to bedrock.")
print("Tip: ender chest in slot 16 = automatic inventory drop-off.")

local estPasses = math.ceil(130 / 3)
local estFuel = estPasses * (SIDE * SIDE + 4 * SIDE + 40)
print("Rough fuel estimate: about " .. estFuel
    .. " (" .. math.ceil(estFuel / 800) .. " coal blocks).")

if not fuelCheck() then
    print("Add fuel (coal, etc.) and run again.")
    return
end

local pass = 0
local stopped = false

while not stopped do
    if not fuelCheck() then
        print("Out of fuel. Refuel and run chunk_dig "
            .. chunks .. " again to continue.")
        stopped = true
    else
        turnTo(0)
        digPass()
        pass = pass + 1
        print("Pass " .. pass .. " done. Depth: " .. depth)

        returnToStart()

        if usedSlots() >= 15 then
            if dropoff() then
                print("Inventory dropped into the ender chest.")
            else
                print("WARNING: inventory nearly full and no chest in")
                print("slot 16 - new drops will be lost.")
            end
        end

        for i = 1, 3 do
            local result = descendOne()

            if result == "bedrock" then
                print("Bedrock reached.")
                stopped = true
                break
            elseif result ~= "ok" then
                print("Cannot dig down - something undiggable is below.")
                stopped = true
                break
            end
        end
    end
end

print("Climbing back up " .. depth .. " layers...")

for i = 1, depth do
    if not up() then
        print("Blocked while climbing at layer " .. i .. ".")
        print("Come collect me - I'm " .. (depth - i) .. " layers down.")
        return
    end
end

turnTo(0)
print("Done. " .. pass .. " passes, depth " .. depth
    .. ". Back at the starting corner.")
