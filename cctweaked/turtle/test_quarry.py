"""Offline simulation tests for chunk_dig.lua and turtle_wireless_dash.lua.

Requires the Python package `lupa`. Not used in-game.

The harness simulates a small world in the turtle's own frame
(x = forward, y = up, z = right), mock turtle/peripheral/rednet/gps APIs,
stationary output and fuel inventories next to home, and checks safety
rules on every single action, not only the final result.
"""
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).parent

HARNESS = r'''
local O = OPTIONS
local SIDE = 16 * (O.chunks or 1)
local px, py, pz, hd = 0, 0, 0, 0
local T, actions = 0, 0
local fuel = O.fuel
local limit = O.limit
local slots = {}
for i = 1, 16 do slots[i] = nil end
local selected = 1
local removed, visited = {}, {}
local violations = {}
local packets, statuses = {}, {}
local last = nil
local lost, minedItems, atmDug = 0, 0, 0
local minedCoalBurned = 0
local moveCount, failCounter = 0, 0
local maxUsed, minY = 0, 0
local travelUpOffShaft = 0
local fuelBurnsFromBase, baseBurnsWrongSlot = 0, 0
local cargoDetail, wastedFuel = false, 0
local outputCap = O.outputCap
local outputItems, outputTotal = {}, 0
local fuelInv = {}
local pendingResume = nil
local resumeChecks, resumeFails = 0, 0
local inTrip = false
local nestedTrips = 0
local gpsMovedSeen = false

local FUEL_VALUE = {["minecraft:coal_block"] = 800, ["minecraft:coal"] = 80}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function v(msg) violations[#violations + 1] = msg end

local SIDE_OFF = {front = {1, 0, 0}, right = {0, 0, 1}, back = {-1, 0, 0},
    left = {0, 0, -1}, top = {0, 1, 0}}
local storage = {}
local function addStorage(side, kind)
    local o = SIDE_OFF[side]
    storage[key(o[1], o[2], o[3])] = kind
end
if not O.noOutput then addStorage(O.outputSide, "output") end
if not O.noFuelInv then addStorage(O.fuelSide, "fuel") end
if O.fuelStock > 0 then
    fuelInv[1] = {name = "minecraft:coal_block", count = O.fuelStock}
end

local function bedrockY(x, z)
    -- Uneven floor: most cells bedrock at y=-6, some pockets at y=-5.
    if (x * 3 + z * 5) % 4 == 0 then return -5 end
    return -6
end

local atm = {}
for _, c in ipairs(O.atm or {}) do atm[key(c[1], c[2], c[3])] = true end

local function blockAt(x, y, z)
    local k = key(x, y, z)
    if storage[k] then return "minecraft:barrel" end
    if removed[k] then return nil end
    if y >= 0 then return nil end
    if y <= bedrockY(x, z) then return "minecraft:bedrock" end
    if atm[k] then return "allthemodium:allthemodium_ore" end
    local h = (x * 7 + z * 13 + y * 5) % 9
    if O.coalOre and h == 0 then return "minecraft:coal_ore" end
    if O.manyItems and h <= 4 then
        return "test:ore_" .. ((x * 3 + z * 7 + y * 11) % 24)
    end
    return "minecraft:stone"
end

local function dropOf(name)
    if name == "minecraft:stone" then return "minecraft:cobblestone" end
    if name == "minecraft:coal_ore" then return "minecraft:coal" end
    return name .. "_drop"
end

local VEC = {[0] = {1, 0}, {0, 1}, {-1, 0}, {0, -1}}
local function coord(dir)
    if dir == "up" then return px, py + 1, pz end
    if dir == "down" then return px, py - 1, pz end
    local d = VEC[hd]
    return px + d[1], py, pz + d[2]
end

local function tick(n)
    T = T + (n or 0.05)
    actions = actions + 1
    if actions > 3000000 then error("TIMEOUT: too many actions") end
    if O.outputGrowAt and T >= O.outputGrowAt then outputCap = 10 ^ 9 end
    if O.refillAt and T >= O.refillAt and not O.refilled then
        O.refilled = true
        fuelInv[1] = {name = "minecraft:coal_block", count = 64}
    end
end

local function used()
    local n = 0
    for i = 1, 16 do if slots[i] then n = n + 1 end end
    return n
end

-- CC inserts starting at the selected slot, wrapping, into the first
-- slot that is empty or holds the same item with room.
local function insert(name, count)
    for o = 0, 15 do
        local i = (selected - 1 + o) % 16 + 1
        local s = slots[i]
        if not s then
            local n = math.min(64, count)
            slots[i] = {name = name, count = n}
            count = count - n
        elseif s.name == name and s.count < 64 then
            local n = math.min(64 - s.count, count)
            s.count = s.count + n
            count = count - n
        end
        if count == 0 then break end
    end
    if count > 0 then lost = lost + count end
    if used() > maxUsed then maxUsed = used() end
end

local TRAVEL = {returning_to_unload = true, returning_to_refuel = true,
    resuming = true, returning_home = true}

local function requireSlot1(what)
    if selected ~= 1 then v(what .. " with slot " .. selected .. " selected") end
end

local function move(dir)
    tick(0.4)
    requireSlot1("move " .. dir)
    if fuel ~= "unlimited" and fuel <= 0 then return false, "Out of fuel" end
    local x, y, z = coord(dir)
    if blockAt(x, y, z) then return false, "Movement obstructed" end
    if O.failEvery then
        failCounter = failCounter + 1
        if failCounter % O.failEvery == 0 then
            return false, "Movement obstructed"
        end
    end
    if y >= 0 and not (x == 0 and y == 0 and z == 0) then
        v("entered home level outside home: " .. key(x, y, z))
    end
    if last and TRAVEL[last.status] and not visited[key(x, y, z)]
        and not (x == 0 and y == 0 and z == 0)
    then
        v("travel into never-visited cell " .. key(x, y, z))
    end
    if last and TRAVEL[last.status] and dir == "up"
        and not (px == 0 and pz == 0)
    then
        travelUpOffShaft = travelUpOffShaft + 1
    end
    if x < 0 or x >= SIDE or z < 0 or z >= SIDE then
        if not (x == 0 and z == 0) then v("left footprint " .. key(x, y, z)) end
    end
    px, py, pz = x, y, z
    visited[key(x, y, z)] = true
    if y < minY then minY = y end
    if fuel ~= "unlimited" then fuel = fuel - 1 end
    moveCount = moveCount + 1
    return true
end

local function dig(dir)
    tick()
    requireSlot1("dig " .. dir)
    local x, y, z = coord(dir)
    local name = blockAt(x, y, z)
    if not name then return false, "Nothing to dig here" end
    if storage[key(x, y, z)] then
        v("dug storage at " .. key(x, y, z))
        return false, "Cannot break protected block"
    end
    if name == "minecraft:bedrock" then return false, "Cannot break unbreakable block" end
    if y >= 0 then v("dug at home level " .. key(x, y, z)) end
    if x < 0 or x >= SIDE or z < 0 or z >= SIDE then
        v("dug outside footprint " .. key(x, y, z))
    end
    removed[key(x, y, z)] = true
    if name == "allthemodium:allthemodium_ore" then
        atmDug = atmDug + 1
        return true -- fake player break deletes the ore
    end
    minedItems = minedItems + 1
    insert(dropOf(name), 1)
    return true
end

local function inspect(dir)
    tick(0.01)
    local name = blockAt(coord(dir))
    if name then return true, {name = name} end
    return false, "No block to inspect"
end

local function invAt(dir)
    local x, y, z = coord(dir)
    return storage[key(x, y, z)]
end

local function drop(dir, count)
    tick()
    local s = slots[selected]
    if not s then return false, "No items to drop" end
    local kind = invAt(dir)
    if not kind then
        lost = lost + s.count
        v("dropped items into the world")
        slots[selected] = nil
        return true
    end
    local n = math.min(count or s.count, s.count)
    if kind == "output" then
        n = math.min(n, outputCap - outputTotal)
        if n <= 0 then return false, "No space for items" end
        outputItems[s.name] = (outputItems[s.name] or 0) + n
        outputTotal = outputTotal + n
    else
        local placed = false
        for _, st in ipairs(fuelInv) do
            if st.name == s.name then st.count = st.count + n; placed = true end
        end
        if not placed then fuelInv[#fuelInv + 1] = {name = s.name, count = n} end
    end
    s.count = s.count - n
    if s.count == 0 then slots[selected] = nil end
    return true
end

local function suck(dir, count)
    tick()
    local kind = invAt(dir)
    if kind ~= "fuel" then return false, "No items to take" end
    for i, st in ipairs(fuelInv) do
        if st.count > 0 then
            local n = math.min(count or 64, st.count, 64)
            st.count = st.count - n
            if st.count == 0 then table.remove(fuelInv, i) end
            insert(st.name, n)
            return true
        end
    end
    return false, "No items to take"
end

local function sideToDir(side)
    if side == "top" then return "up" end
    if side == "bottom" then return "down" end
    return side
end

local function wrapSide(side)
    local dir
    if side == "front" then dir = "forward"
    elseif side == "top" then dir = "up"
    elseif side == "bottom" then dir = "down"
    else
        local turn = ({right = 1, back = 2, left = 3})[side]
        if side == "right" and O.modem then
            return {isWireless = function() return true end}
        end
        local save = hd
        hd = (hd + turn) % 4
        local kind = invAt("forward")
        hd = save
        if kind then return {list = function() return {} end, size = function() return 27 end} end
        return nil
    end
    if invAt(dir) then
        return {list = function() return {} end, size = function() return 27 end}
    end
    return nil
end

os.getComputerID = function() return 12 end
os.getComputerLabel = function() return "Test Turtle" end
os.clock = function() return T end
print = function() end
sleep = function(n)
    tick(n)
    if last and (last.status == "complete" or last.status == "error"
        or last.status == "stopped" or last.status == O.stopStatus)
    then
        error("TEST_END")
    end
end

local modemObj = {isWireless = function() return true end}
peripheral = {
    find = function(kind, filter)
        if kind == "modem" and O.modem then
            if not filter or filter("right", modemObj) then return modemObj end
        end
        return nil
    end,
    getName = function() return "right" end,
    wrap = function(side) return wrapSide(side) end,
}
rednet = {
    isOpen = function() return true end,
    open = function() end,
    broadcast = function(p, protocol)
        if protocol ~= "turtle_quarry_v1" then v("wrong protocol") end
        if selected ~= 1 then v("broadcast with slot " .. selected) end
        local r = p.location.relative
        if r.x ~= px or r.y ~= py or r.z ~= pz or p.location.heading ~= hd then
            v("position drift: script " .. r.x .. "," .. r.y .. "," .. r.z
                .. " h" .. p.location.heading .. " vs true " .. px .. "," .. py
                .. "," .. pz .. " h" .. hd)
        end
        if p.inventory.totalSlots ~= 16 then v("totalSlots ~= 16") end
        if p.location.gps and p.location.gps.moved then gpsMovedSeen = true end
        if not last or last.status ~= p.status then
            statuses[#statuses + 1] = p.status
            if p.status == "returning_to_unload" or p.status == "returning_to_refuel" then
                if inTrip then nestedTrips = nestedTrips + 1 end
                inTrip = true
                pendingResume = {px, py, pz, hd}
                if p.detail == "no empty cargo slot" then cargoDetail = true end
            elseif p.status == "mining" and pendingResume then
                resumeChecks = resumeChecks + 1
                local s = pendingResume
                if s[1] ~= px or s[2] ~= py or s[3] ~= pz or s[4] ~= hd then
                    resumeFails = resumeFails + 1
                end
                pendingResume = nil
                inTrip = false
            end
        end
        last = p
        packets[#packets + 1] = p
    end,
}
gps = {locate = function()
    if O.gps then return 1000 + px, 64 + py, 2000 + pz end
    return nil
end}

turtle = {
    select = function(i)
        if i < 1 or i > 16 then error("bad slot") end
        selected = i
        return true
    end,
    getSelectedSlot = function() return selected end,
    getFuelLevel = function() return fuel end,
    getFuelLimit = function() return fuel == "unlimited" and "unlimited" or limit end,
    getItemCount = function(i) return slots[i or selected] and slots[i or selected].count or 0 end,
    getItemSpace = function(i) local s = slots[i or selected]; return s and 64 - s.count or 64 end,
    getItemDetail = function(i)
        local s = slots[i or selected]
        if s then return {name = s.name, count = s.count} end
    end,
    transferTo = function(to, count)
        tick()
        local s, d = slots[selected], slots[to]
        if not s then return false end
        if d and d.name ~= s.name then return false end
        local n = math.min(count or s.count, s.count, d and 64 - d.count or 64)
        if n <= 0 then return false end
        if d then d.count = d.count + n else slots[to] = {name = s.name, count = n} end
        s.count = s.count - n
        if s.count == 0 then slots[selected] = nil end
        return true
    end,
    refuel = function(n)
        tick()
        local s = slots[selected]
        if not s or not FUEL_VALUE[s.name] then return false, "Items not combustible" end
        if n == 0 then return true end
        if fuel == "unlimited" then return true end
        local k = math.min(n or s.count, s.count)
        for _ = 1, k do
            local before = fuel
            fuel = math.min(limit, fuel + FUEL_VALUE[s.name])
            wastedFuel = wastedFuel + (before + FUEL_VALUE[s.name] - fuel)
            if s.name == "minecraft:coal" then minedCoalBurned = minedCoalBurned + 1 end
            if s.name == "minecraft:coal_block" then
                fuelBurnsFromBase = fuelBurnsFromBase + 1
                if selected ~= 1 then baseBurnsWrongSlot = baseBurnsWrongSlot + 1 end
            end
        end
        s.count = s.count - k
        if s.count == 0 then slots[selected] = nil end
        return true
    end,
    inspect = function() return inspect("forward") end,
    inspectUp = function() return inspect("up") end,
    inspectDown = function() return inspect("down") end,
    detect = function() return (inspect("forward")) end,
    detectUp = function() return (inspect("up")) end,
    detectDown = function() return (inspect("down")) end,
    dig = function() return dig("forward") end,
    digUp = function() return dig("up") end,
    digDown = function() return dig("down") end,
    forward = function() return move("forward") end,
    up = function() return move("up") end,
    down = function() return move("down") end,
    turnRight = function() tick(); hd = (hd + 1) % 4; return true end,
    turnLeft = function() tick(); hd = (hd + 3) % 4; return true end,
    attack = function() return false end,
    attackUp = function() return false end,
    attackDown = function() return false end,
    drop = function(c) return drop("forward", c) end,
    dropUp = function(c) return drop("up", c) end,
    dropDown = function(c) return drop("down", c) end,
    suck = function(c) return suck("forward", c) end,
    suckUp = function(c) return suck("up", c) end,
    suckDown = function(c) return suck("down", c) end,
}

for i, s in ipairs(O.startItems or {}) do slots[i] = {name = s[1], count = s[2]} end

function results()
    -- Every diggable cell inside the footprint must be gone.
    local remaining = 0
    for x = 0, SIDE - 1 do
        for z = 0, SIDE - 1 do
            for y = -1, bedrockY(x, z) + 1, -1 do
                local n = blockAt(x, y, z)
                if n and n ~= "allthemodium:allthemodium_ore" then
                    remaining = remaining + 1
                end
            end
        end
    end
    local inv = 0
    for i = 1, 16 do if slots[i] then inv = inv + slots[i].count end end
    local outMined = 0
    for name, c in pairs(outputItems) do
        if name ~= "minecraft:coal_block" then outMined = outMined + c end
    end
    return {
        x = px, y = py, z = pz, heading = hd, selected = selected,
        last = last, violations = violations, statuses = statuses,
        lost = lost, minedItems = minedItems, invItems = inv,
        outputMined = outMined, atmDug = atmDug, remaining = remaining,
        maxUsed = maxUsed, minY = minY, nestedTrips = nestedTrips,
        resumeChecks = resumeChecks, resumeFails = resumeFails,
        cargoDetail = cargoDetail, travelUpOffShaft = travelUpOffShaft,
        fuelBurnsFromBase = fuelBurnsFromBase,
        baseBurnsWrongSlot = baseBurnsWrongSlot,
        fuel = fuel, wastedFuel = wastedFuel, gpsMovedSeen = gpsMovedSeen,
        moves = moveCount, minedCoalBurned = minedCoalBurned,
        outputCoal = outputItems["minecraft:coal"] or 0,
    }
end
'''

DEFAULTS = dict(fuel=0, limit=20000, fuelStock=64, outputCap=10 ** 9,
                outputSide="back", fuelSide="top", modem=True,
                manyItems=False, coalOre=False, failEvery=None,
                stopStatus="", gps=False)


def run(**options):
    opts = dict(DEFAULTS)
    opts.update(options)
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("OPTIONS = {}")
    g = lua.globals()
    for k, v in opts.items():
        if isinstance(v, list):
            t = lua.table()
            for i, item in enumerate(v, 1):
                t[i] = lua.table(*item) if isinstance(item, (list, tuple)) else item
            g.OPTIONS[k] = t
        elif v is not None:
            g.OPTIONS[k] = v
    lua.execute(HARNESS)
    code = (ROOT / "chunk_dig.lua").read_text()
    if opts["outputSide"] != "back":
        code = code.replace('local OUTPUT_SIDE = "back"',
                            'local OUTPUT_SIDE = "%s"' % opts["outputSide"])
    if opts["fuelSide"] != "top":
        code = code.replace('local FUEL_SIDE = "top"',
                            'local FUEL_SIDE = "%s"' % opts["fuelSide"])
    program = lua.eval("function(...) " + code + " end")
    try:
        program(str(opts.get("chunks", 1)), "Test Quarry")
    except Exception as error:
        if "TEST_END" not in str(error):
            raise
    r = lua.globals().results()
    out = {k: r[k] for k in r.keys()}
    out["violations"] = [r["violations"][i] for i in range(1, len(r["violations"]) + 1)]
    out["statuses"] = [r["statuses"][i] for i in range(1, len(r["statuses"]) + 1)]
    return out


def check_complete(r, name):
    assert not r["violations"], (name, r["violations"][:5])
    assert r["last"]["status"] == "complete", (name, r["last"]["status"], r["last"]["detail"])
    assert (r["x"], r["y"], r["z"], r["heading"]) == (0, 0, 0, 0), (name, r)
    assert r["selected"] == 1, name
    assert r["lost"] == 0, (name, "items lost", r["lost"])
    assert r["invItems"] == 0, (name, "final cargo not unloaded")
    assert r["remaining"] == 0, (name, "cells skipped", r["remaining"])
    assert r["atmDug"] == 0, (name, "protected ore dug")
    assert r["nestedTrips"] == 0, (name, "recursive service trip")
    assert r["resumeFails"] == 0, (name, "did not resume at saved cell/heading")
    assert r["minY"] == -5, (name, "descended to", r["minY"])
    assert r["last"]["job"]["layer"] == 5, (name, r["last"]["job"]["layer"])
    return r


TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


@test
def all_16_slots_and_no_empty_slot_return():
    r = check_complete(run(manyItems=True), "cargo")
    assert r["maxUsed"] == 16, ("not all 16 slots used", r["maxUsed"])
    assert r["cargoDetail"], "cargo trip did not report 'no empty cargo slot'"
    assert "returning_to_unload" in r["statuses"]
    assert r["resumeChecks"] > 0
    assert r["minedItems"] == r["outputMined"], "mined items not all in output"


@test
def fuel_through_slot_1_and_low_fuel_return():
    r = check_complete(run(limit=1000, fuelStock=200), "low fuel")
    assert "returning_to_refuel" in r["statuses"], r["statuses"]
    assert r["fuelBurnsFromBase"] > 0
    assert r["baseBurnsWrongSlot"] == 0, "base fuel not burned from slot 1"
    assert r["resumeChecks"] > 0


@test
def surplus_mined_coal_unloads_and_carried_fuel_is_used():
    r = check_complete(run(limit=1000, fuelStock=200, coalOre=True), "coal")
    assert r["minedCoalBurned"] > 0, "carried mined coal was never used as fuel"
    assert r["outputCoal"] > 0, "surplus mined coal was not unloaded"
    # Every mined item was either burned as needed fuel or unloaded.
    assert r["minedItems"] == r["outputMined"] + r["minedCoalBurned"], (
        r["minedItems"], r["outputMined"], r["minedCoalBurned"])


@test
def output_full_then_available():
    r = check_complete(run(manyItems=True, outputCap=300, outputGrowAt=4000), "output")
    assert "waiting_output" in r["statuses"], r["statuses"]


@test
def empty_fuel_then_replenished():
    r = check_complete(run(fuelStock=0, refillAt=200), "fuel start")
    assert r["statuses"][:4].count("waiting_fuel") >= 1, r["statuses"][:6]
    r = check_complete(run(limit=1000, fuelStock=1, refillAt=3000), "fuel mid")
    i = r["statuses"].index("waiting_fuel")
    assert "returning_to_refuel" in r["statuses"][:i], r["statuses"][:i + 1]


@test
def unlimited_fuel():
    r = check_complete(run(fuel="unlimited", fuelStock=0), "unlimited")
    assert "returning_to_refuel" not in r["statuses"]
    assert r["last"]["reserve"] == 0


@test
def fuel_capacity_too_small_stays_home():
    r = run(limit=150)
    assert not r["violations"], r["violations"][:5]
    assert r["last"]["status"] == "error", r["last"]["status"]
    assert "fuel limit" in r["last"]["detail"], r["last"]["detail"]
    assert (r["x"], r["y"], r["z"]) == (0, 0, 0)
    assert r["selected"] == 1


@test
def no_wasted_base_fuel():
    r = check_complete(run(limit=20000), "waste")
    assert r["wastedFuel"] == 0, r["wastedFuel"]


@test
def failed_movement_without_drift():
    check_complete(run(failEvery=7, limit=1000, fuelStock=200, manyItems=True), "fail moves")


@test
def undiggable_bypass_and_relocated_descent():
    # ATM ore in the first row and directly under the layer-1 and layer-2
    # descent cells, forcing detours and off-shaft descents.
    atm = [(3, -1, 0), (0, -2, 0), (0, -3, 1), (1, -3, 0), (5, -2, 5),
           (6, -2, 5), (5, -2, 6)]
    r = check_complete(run(atm=atm, limit=1000, fuelStock=200, manyItems=True), "bypass")
    assert r["travelUpOffShaft"] > 0, "service routes never changed elevation off the shaft"


@test
def two_chunk_quarry():
    r = check_complete(run(chunks=2, limit=1000, fuelStock=200, manyItems=True), "2 chunks")
    assert r["last"]["job"]["side"] == 32 and r["last"]["job"]["area"] == 1024


@test
def storage_sides_configurable():
    for out_side, fuel_side in (("left", "right"), ("front", "back"), ("top", "left")):
        check_complete(run(outputSide=out_side, fuelSide=fuel_side,
                           manyItems=True), "sides %s/%s" % (out_side, fuel_side))


@test
def missing_inventory_refuses_to_start():
    r = run(noOutput=True)
    assert r["last"]["status"] == "error" and "output" in r["last"]["detail"]
    assert r["moves"] == 0
    r = run(noFuelInv=True)
    assert r["last"]["status"] == "error" and "fuel" in r["last"]["detail"]
    assert r["moves"] == 0


@test
def gps_marked_stale_after_moving():
    r = check_complete(run(gps=True), "gps")
    assert r["gpsMovedSeen"]


def test_dashboard():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(r'''
        local clock, event, cursor, writes = 0, 0, 1, 0
        local lines = {}
        colors = {cyan=1, gray=2, white=3, yellow=4, lime=5, orange=6,
            lightBlue=7, black=8, red=9, magenta=10, green=11}
        keys = {right=1, left=2}
        local monitor = {
            getSize = function() return 90, 30 end,
            setTextScale = function() end, setCursorBlink = function() end,
            setBackgroundColor = function() end, setTextColor = function() end,
            setCursorPos = function(x, y) cursor = y end,
            write = function(t) lines[cursor] = t; writes = writes + 1 end,
        }
        peripheral = {find = function(kind)
            if kind == "modem" then return {} end
            return monitor
        end, getName = function() return "right" end}
        rednet = {open = function() end, host = function() end}
        os.getComputerLabel = function() return "Test Dash" end
        os.clock = function() return clock end
        os.startTimer = function() return 1 end
        local function pkt(id, st, gpsMoved)
            return {type="quarry", version=1, name="Turtle " .. id, status=st,
                detail="no empty cargo slot", fuel=1000, fuelLimit=20000,
                reserve=57, fuelType="minecraft:coal_block",
                job={chunks=1, side=16, area=256, layer=3, layerCleared=128,
                    layerBlocked=2, cells=640, trips=4},
                inventory={usedSlots=12, totalSlots=16, percent=75, items=400},
                location={relative={x=4, y=-3, z=7}, heading=1,
                    gps={x=100, y=60, z=-20, age=12, moved=gpsMoved}}}
        end
        os.pullEvent = function()
            event = event + 1
            if event == 1 then
                return "rednet_message", 1, pkt(1, "returning_to_unload", true), "turtle_quarry_v1"
            elseif event == 2 then
                return "rednet_message", 2, pkt(2, "waiting_fuel", false), "turtle_quarry_v1"
            elseif event == 3 then
                local all = table.concat(lines, "\n")
                assert(all:find("2 turtles"), all)
                assert(all:find("#1 Turtle 1") and all:find("#2 Turtle 2"))
                assert(all:find("RETURNING TO UNLOAD"), all)
                assert(all:find("WAITING FUEL"), all)
                assert(all:find("12/16"), all)
                assert(all:find("reserve 57"), all)
                assert(all:find("facing right"), all)
                assert(all:find("layer 3"), all)
                assert(all:find("STALE"), "moved GPS fix not marked stale")
                assert(all:find("no empty cargo slot"), all)
                clock = 20
                return "timer", 1
            elseif event == 4 then
                assert(table.concat(lines, "\n"):find("OFFLINE"))
                SAVED_WRITES = writes
                return "timer", 1
            end
            assert(writes == SAVED_WRITES, "unchanged frame was redrawn")
            error("TEST_END")
        end
    ''')
    try:
        lua.execute((ROOT / "turtle_wireless_dash.lua").read_text())
    except Exception as error:
        if "TEST_END" not in str(error):
            raise


def main():
    for path in sorted(ROOT.glob("*.lua")):
        LuaRuntime().execute("function syntax_check(...) " + path.read_text() + " end")
        print("PASS syntax", path.name)
    failed = 0
    for fn in TESTS:
        try:
            fn()
            print("PASS", fn.__name__)
        except AssertionError as e:
            failed += 1
            print("FAIL", fn.__name__, e)
    try:
        test_dashboard()
        print("PASS dashboard")
    except Exception as e:
        failed += 1
        print("FAIL dashboard", e)
    if failed:
        raise SystemExit("%d test(s) failed" % failed)


if __name__ == "__main__":
    main()
