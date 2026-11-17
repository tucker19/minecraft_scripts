"""Offline simulation tests for chunk_dig.lua and turtle_wireless_dash.lua.

Requires the Python package `lupa`. Not used in-game.

The harness simulates a small world in the turtle's own frame
(x = forward, y = up, z = right), mock turtle/peripheral/rednet/gps APIs,
stationary output and fuel inventories next to home, and checks safety
rules on every single action, not only the final result.
"""
from pathlib import Path
try:
    from lupa.lua52 import LuaRuntime
except ImportError:
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
local shared, barrel = O.outputSide==O.fuelSide, {}
local barrelSize, wirePushes, blindSucks, wrongPushes = O.barrelSize or 27, 0,0,0
local BLOCK, BARREL = "minecraft:coal_block", "minecraft:barrel_0"
local barrelRemoved, pulledFrom, pushedInto = {}, {}, {}
local pendingResume = nil
local resumeChecks, resumeFails = 0, 0
local inTrip = false
local nestedTrips = 0
local gpsMovedSeen = false
local cuts, cutIndex, files, printed = O.cuts or {}, 1, {}, {}
local directories = {}
local saveDir = "/.chunk_dig"
local queuedMove, move
local function fault(name)
    local want = cuts[cutIndex]
    if want == name or (want and last and want == name .. ":" .. last.status) then
        cutIndex = cutIndex + 1
        coroutine.yield("POWER_CUT", name)
    end
end
local function encode(v)
    local kind=type(v)
    if kind == "string" then return string.format("%q", v) end
    if kind == "number" or kind == "boolean" then return tostring(v) end
    assert(kind == "table", kind)
    local parts={"{"}
    for k,x in pairs(v) do
        parts[#parts+1]="[" .. encode(k) .. "]=" .. encode(x) .. ","
    end
    parts[#parts+1]="}"
    return table.concat(parts)
end
textutils = {
    serialize=encode,
    unserialize=function(s)
        local f=load("return " .. s,"record","t",{})
        if f then local ok,t=pcall(f); if ok then return t end end
    end,
}
fs = {
    exists=function(path) return files[path] ~= nil or directories[path] ~= nil end,
    makeDir=function(path) directories[path]=true end,
    delete=function(path)
        if path == saveDir .. "/action" then fault("before_action_clear") end
        files[path]=nil
    end,
    move=function(a,b)
        local action=b==saveDir .. "/action"
        fault(action and "before_action_publish" or "before_state_publish")
        assert(files[a] and not files[b])
        files[b],files[a]=files[a],nil
        fault(action and "after_action_publish" or "after_state_publish")
    end,
    open=function(path,mode)
        if mode=="r" then
            if not files[path] then return nil,"missing" end
            return {readAll=function() return files[path] end,close=function() end}
        end
        assert(mode=="w")
        files[path]=""
        return {write=function(s)
            local action=path==saveDir .. "/action.tmp"
            fault(action and "before_action_write" or "before_state_write")
            -- Leave a truncated staged file when power is cut during write.
            files[path]=s:sub(1,math.floor(#s/2))
            fault(action and "during_action_write" or "during_state_write")
            files[path]=s
            fault(action and "after_action_write" or "after_state_write")
        end,close=function() end}
    end,
}
local function record(path)
    return files[path] and textutils.unserialize(files[path]:match("\n(.*)$"))
end
function latest_record()
    local a,b=record(saveDir .. "/0"),record(saveDir .. "/1")
    if a and b then return a.seq>b.seq and a or b end
    return a or b
end
function corrupt_latest()
    local r=latest_record()
    files[saveDir .. "/" .. r.seq%2]="QUARRY 1 state 0\n{broken"
end
function corrupt_action() files[saveDir .. "/action"]="QUARRY 1 action 0\ncorrupt" end
function delete_latest()
    local r=latest_record()
    files[saveDir .. "/" .. r.seq%2]=nil
end
function different_version()
    local r=latest_record()
    local p=saveDir .. "/" .. r.seq%2
    files[p]=files[p]:gsub("^QUARRY 1 ", "QUARRY 42 ")
end
function power_change(n) if type(fuel)=="number" then fuel=fuel+n end end
function manual_choice()
    local j=record(saveDir .. "/action")
    local function at(p) return p.x==px and p.y==py and p.z==pz and p.h==hd end
    if j and at(j.before) then return j.seq,"before" end
    if j and at(j.after) then return j.seq,"after" end
end
function launch(f,...)
    local co=coroutine.create(f)
    local ok,what,event=coroutine.resume(co,...)
    assert(ok,what)
    return what,event
end

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
local function barrelStock(count)
    for i=1,barrelSize do
        if not barrel[i] then barrel[i]={name=BLOCK,count=count}; return end
    end
end
if shared then
    if not O.noOutput then addStorage(O.outputSide,"shared") end
    addStorage(O.outputSide=="top" and "front" or "top","dock")
    for _,s in ipairs(O.barrelItems or {}) do barrel[s[1]]={name=s[2],count=s[3]} end
    if O.fuelStock>0 then barrelStock(O.fuelStock) end
else
    if not O.noOutput then addStorage(O.outputSide, "output") end
    if not O.noFuelInv then addStorage(O.fuelSide, "fuel") end
end
if not shared and O.fuelStock > 0 then
    fuelInv[1] = {name = "minecraft:coal_block", count = O.fuelStock}
end
function enable_shared()
    shared=true
    addStorage("back","shared")
    addStorage("top","dock")
    barrelStock(64)
end
function drain_barrel()
    for i,d in pairs(barrel) do
        if d.name~=BLOCK then
            barrelRemoved[d.name]=(barrelRemoved[d.name] or 0)+d.count
            barrel[i]=nil
        end
    end
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
        if shared then barrelStock(64)
        else fuelInv[1] = {name = "minecraft:coal_block", count = 64} end
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

move = function(dir)
    local want=cuts[cutIndex]
    if want=="queue_move" or (want and last and want=="queue_move:" .. last.status) then
        queuedMove=dir
        fault("queue_move")
    end
    fault("before_move")
    fault("before_move_" .. dir)
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
    fault("after_move_" .. dir)
    fault("after_move")
    return true
end

local function dig(dir)
    fault("before_dig")
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
    fault("after_dig")
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
    fault("before_drop")
    tick()
    local s = slots[selected]
    if not s then return false, "No items to drop" end
    local kind = invAt(dir)
    if shared then v("native drop used in shared mode"); return false end
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
    fault("after_drop")
    return true
end

local function suck(dir, count)
    fault("before_suck")
    tick()
    local kind = invAt(dir)
    if shared then blindSucks=blindSucks+1; v("native suck used in shared mode"); return false end
    if kind ~= "fuel" then return false, "No items to take" end
    for i, st in ipairs(fuelInv) do
        if st.count > 0 then
            local n = math.min(count or 64, st.count, 64)
            st.count = st.count - n
            if st.count == 0 then table.remove(fuelInv, i) end
            insert(st.name, n)
            fault("after_suck")
            return true
        end
    end
    return false, "No items to take"
end

local function kindOnSide(side)
    local turn = ({front=0,right=1,back=2,left=3})[side]
    if side=="top" then return invAt("up") end
    if side=="bottom" then return invAt("down") end
    if turn==nil then return end
    local save=hd; hd=(hd+turn)%4
    local kind=invAt("forward"); hd=save
    return kind
end

local function wireCall(name,method,id,from,amount,into)
    assert(name==BARREL)
    tick()
    if method=="list" then
        local out={}
        for i,d in pairs(barrel) do out[i]={name=d.name,count=d.count} end
        return out
    end
    if method=="getItemDetail" then
        local d=barrel[id]
        return d and {name=d.name,count=d.count}
    end
    assert(id=="turtle_4")
    requireSlot1("wired inventory transfer")
    if method=="pushItems" then
        fault("before_wire_push")
        assert(amount==1 and slots[into]==nil and barrel[from])
        local d=barrel[from]
        assert(d.name==BLOCK)
        if O.wirePushFails then return 0 end
        local item=d.name
        if O.wireRace then item="minecraft:gravel"; O.wireRace=false; wrongPushes=wrongPushes+1 end
        d.count=d.count-1
        if d.count==0 then barrel[from]=nil end
        slots[into]={name=item,count=1}
        wirePushes=wirePushes+1
        pulledFrom[wirePushes],pushedInto[wirePushes]=from,into
        fault("after_wire_push")
        return 1
    end
    assert(method=="pullItems" and into==nil)
    fault("before_wire_pull")
    if O.wirePullFails then error("wired output failed") end
    local d=slots[from]
    assert(d and amount==d.count)
    local moved=0
    for pass=1,2 do
        for i=1,barrelSize do
            local b=barrel[i]
            if (pass==1 and b and b.name==d.name) or (pass==2 and not b) then
                local n=math.min(amount-moved,64-(b and b.count or 0))
                if n>0 then barrel[i]={name=d.name,count=(b and b.count or 0)+n}; moved=moved+n end
            end
        end
    end
    if moved>0 then
        outputItems[d.name]=(outputItems[d.name] or 0)+moved
        d.count=d.count-moved
        if d.count==0 then slots[from]=nil end
        fault("after_wire_pull")
    end
    return moved
end

local function wrapSide(side)
    if kindOnSide(side)=="dock" then
        if O.noDock then return nil end
        return {
            isWireless=function() return false end,
            getNameLocal=function() return not O.dockOff and "turtle_4" or nil end,
            getNamesRemote=function()
                if O.noWiredBarrel then return {"speaker_0"} end
                if O.twoWiredBarrels then return {BARREL,"minecraft:barrel_1","speaker_0"} end
                return {BARREL,"speaker_0"}
            end,
            getMethodsRemote=function(name)
                assert(name==BARREL)
                return {"list","getItemDetail","pushItems","pullItems"}
            end,
            callRemote=wireCall,
        }
    end
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
    local kind=invAt(dir)
    if kind then
        return {list = function() return kind=="fuel" and fuelInv or outputItems end,
            size = function() return 27 end}
    end
    return nil
end

os.getComputerID = function() return 12 end
os.getComputerLabel = function() return "Test Turtle" end
os.clock = function() return T end
os.epoch = function() return 1700000000000+math.floor(T*1000) end
print = function(s) printed[#printed+1]=s end
sleep = function(n)
    tick(n)
    fault("sleep")
    if last and (last.status == "complete" or last.status == "error"
        or last.status == "stopped" or last.status == O.stopStatus)
    then
        coroutine.yield("TEST_END")
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
    getType = function(side)
        local k=kindOnSide(side)
        if k=="shared" or k=="fuel" or k=="output" then return "minecraft:barrel","inventory" end
    end,
    wrap = function(side) return wrapSide(side) end,
}
rednet = {
    isOpen = function() return true end,
    open = function() end,
    broadcast = function(p, protocol)
        if protocol ~= "turtle_quarry_v1" then v("wrong protocol") end
        if selected ~= 1 then v("broadcast with slot " .. selected) end
        local r = p.location.relative
        if p.location.uncertain and (r or p.location.heading) then v("unverified pose published") end
        if r and (r.x ~= px or r.y ~= py or r.z ~= pz or p.location.heading ~= hd) then
            v("position drift: script " .. r.x .. "," .. r.y .. "," .. r.z
                .. " h" .. p.location.heading .. " vs true " .. px .. "," .. py
                .. "," .. pz .. " h" .. hd)
        end
        if p.inventory.totalSlots ~= 16 then v("totalSlots ~= 16") end
        if p.location.gps and p.location.gps.moved then gpsMovedSeen = true end
        if not last or last.status ~= p.status then
            statuses[#statuses + 1] = p.status
            if p.status == "returning_to_unload" or p.status == "returning_to_refuel" then
                if not inTrip then
                    inTrip = true
                    pendingResume = {px, py, pz, hd}
                    if p.detail == "no empty cargo slot" then cargoDetail = true end
                elseif not last or (last.status~="resumed" and last.status~="blocked") then
                    nestedTrips = nestedTrips + 1
                end
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
        fault("phase")
    end,
}
gps = {locate = function()
    if O.gps then return 1000 + px + (O.gpsOffset or 0), 64 + py, 2000 + pz end
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
        fault("before_refuel")
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
        fault("after_refuel")
        return true
    end,
    inspect = function() return inspect("forward") end,
    inspectUp = function() return inspect("up") end,
    inspectDown = function()
        if queuedMove then
            local dir=queuedMove; queuedMove=nil
            assert(move(dir), "deferred API move did not execute")
        end
        return inspect("down")
    end,
    detect = function() return (inspect("forward")) end,
    detectUp = function() return (inspect("up")) end,
    detectDown = function() return (inspect("down")) end,
    dig = function() return dig("forward") end,
    digUp = function() return dig("up") end,
    digDown = function() return dig("down") end,
    forward = function() return move("forward") end,
    up = function() return move("up") end,
    down = function() return move("down") end,
    turnRight = function()
        fault("before_turn"); tick(); hd=(hd+1)%4; fault("after_turn"); return true
    end,
    turnLeft = function()
        fault("before_turn"); tick(); hd=(hd+3)%4; fault("after_turn"); return true
    end,
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
        cutCount = cutIndex-1, printed = printed,
        wirePushes=wirePushes, blindSucks=blindSucks, wrongPushes=wrongPushes,
        barrel=barrel, barrelRemoved=barrelRemoved, pulledFrom=pulledFrom, pushedInto=pushedInto,
    }
end
'''

DEFAULTS = dict(fuel=0, limit=20000, fuelStock=64, outputCap=10 ** 9,
                outputSide="back", fuelSide="top", modem=True,
                manyItems=False, coalOre=False, failEvery=None,
                stopStatus="", gps=False)


class Simulation:
    def __init__(self, **options):
        opts = dict(DEFAULTS)
        opts.update(options)
        self.opts = opts
        self.lua = lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("OPTIONS = {}")
        self.g = g = lua.globals()
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
        for constant, option, default in [("OUTPUT_SIDE", "outputSide", "back"),
                                          ("FUEL_SIDE", "fuelSide", "back")]:
            code = code.replace(f'local {constant} = "{default}"',
                                f'local {constant} = "{opts[option]}"')
        # A fresh Lua closure per invocation, rather than repeatedly calling
        # a saved execution stack. The mocked world/FS outlive each process.
        self.code = code
        g.quarry_source = code
        lua.execute('shell = {execute=function(path, ...) '
                    'assert(path=="/chunk_dig"); return assert(load(quarry_source))(...) end}')

    def command(self, *args, startup=False):
        code = (ROOT / "startup.lua").read_text() if startup else self.code
        return self.g.launch(self.lua.eval("function(...) " + code + " end"), *args)

    def start(self):
        args = [str(self.opts.get("chunks", 1)), "Test Quarry"]
        if self.opts.get("anchor"):
            args.append(self.opts["anchor"])
        return self.command(*args)

    def results(self):
        r = self.g.results()
        out = {k: r[k] for k in r.keys()}
        for k in ("violations", "statuses", "printed"):
            out[k] = [r[k][i] for i in range(1, len(r[k]) + 1)]
        return out


def run(**options):
    sim = Simulation(**options)
    sim.start()
    return sim.results()


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


def recover(sim, count):
    outcome = sim.start()
    manual = []
    for _ in range(count):
        assert outcome[0] == "POWER_CUT", (outcome, sim.results()["printed"][-6:])
        outcome = sim.command(startup=True)
        r = sim.results()
        if r["last"]["status"] == "recovery_required":
            assert not r["last"]["location"]["relative"]
            seq, choice = sim.g.manual_choice()
            manual.append(choice)
            outcome = sim.command("resolve", str(seq), choice)
    assert outcome[0] == "TEST_END", (outcome, sim.results()["printed"][-6:])
    return check_complete(sim.results(), "restarted quarry"), manual


@test
def restart_at_moves_digs_turns_and_checkpoint_boundaries():
    cuts = [
        "before_turn", "after_turn", "before_action_write", "during_action_write",
        "after_action_write", "before_action_publish", "after_action_publish",
        "before_dig:mining", "after_dig:mining", "before_move:mining", "after_move:mining",
        "before_move_down:mining", "after_move_down:mining",
        "before_state_write:mining", "during_state_write:mining",
        "after_state_write:mining", "before_state_publish:mining",
        "after_state_publish:mining", "before_action_clear:mining",
    ]
    sim = Simulation(cuts=cuts)
    r, choices = recover(sim, len(cuts))
    assert r["cutCount"] == len(cuts)
    # A published turn intent before the API runs can also require manual
    # inspection. Definitely cover both actual sides of the turn boundary.
    assert choices[:2] == ["before", "after"], choices
    assert "recovering" in r["statuses"] and "resumed" in r["statuses"]
    assert r["minedItems"] == r["outputMined"]


@test
def restart_during_partial_unload_refuel_and_all_travel_phases():
    cuts = [
        "before_suck:refueling", "after_suck:refueling",
        "before_refuel:refueling", "after_refuel:refueling",
        "before_move:returning_to_unload", "after_move:returning_to_unload",
        "before_drop:unloading", "after_drop:unloading",
        "before_move:resuming", "after_move:resuming",
        "phase:returning_home", "before_move:returning_home", "after_move:returning_home",
        "before_drop:unloading", "after_drop:unloading",
    ]
    sim = Simulation(cuts=cuts, manyItems=True, limit=1000, fuelStock=200,
                     atm=[(0, -2, 0), (1, -3, 0)])
    r, manual = recover(sim, len(cuts))
    assert not manual
    assert r["minedItems"] == r["outputMined"]
    assert r["baseBurnsWrongSlot"] == 0 and r["fuelBurnsFromBase"] > 0
    assert r["travelUpOffShaft"] > 0 and r["resumeChecks"] > 0


@test
def restart_waiting_for_storage_and_mid_job_fuel():
    cuts = ["sleep:waiting_fuel", "sleep:waiting_output", "sleep:waiting_output"]
    sim = Simulation(cuts=cuts, fuelStock=1, refillAt=3000,
                     limit=1000, outputCap=750, outputGrowAt=5000)
    r, manual = recover(sim, len(cuts))
    assert not manual
    assert r["statuses"].index("returning_to_refuel") < r["statuses"].index("waiting_fuel")
    assert r["minedItems"] == r["outputMined"]


@test
def restart_after_partial_stack_transfer():
    cuts = ["after_drop:unloading", "sleep:waiting_output"]
    sim = Simulation(cuts=cuts, startItems=[("test:startup_cargo", 64)],
                     outputCap=20, outputGrowAt=30)
    r, manual = recover(sim, len(cuts))
    assert not manual
    assert r["minedItems"] + 64 == r["outputMined"]


@test
def shared_slot_selective_transfers_survive_restarts():
    # Sparse mixed barrel: existing cargo and a larger coal stack both
    # precede the one-block stack. The first pull must select slot 17.
    cuts = ["before_wire_pull", "after_wire_pull", "before_wire_push",
            "after_wire_push", "before_refuel", "after_refuel"]
    sim = Simulation(fuelSide="back", cuts=cuts, fuelStock=0, manyItems=True,
                     startItems=[("test:startup_cargo", 64)],
                     barrelSize=80,  # isolate quarry coverage from 27-slot capacity
                     barrelItems=[(1, "test:untouched", 62), (12, "minecraft:coal_block", 63),
                                  (17, "minecraft:coal_block", 1)])
    r, manual = recover(sim, len(cuts))
    assert not manual and r["cutCount"] == len(cuts)
    assert r["pulledFrom"][1] == 17 and r["pushedInto"][1] == 1
    assert r["barrel"][1]["name"] == "test:untouched" and r["barrel"][1]["count"] == 62
    assert r["fuelBurnsFromBase"] == r["wirePushes"] and not r["blindSucks"]
    assert r["fuel"] + r["moves"] == 800 * r["wirePushes"]
    assert r["minedItems"] + 64 == r["outputMined"]
    assert r["maxUsed"] == 16 and r["resumeChecks"] > 0


@test
def shared_full_barrel_burns_carried_coal_and_uses_another_buffer_slot():
    coal = "minecraft:coal_block"
    sim = Simulation(fuelSide="back", fuel=159, limit=1760, fuelStock=0,
                     barrelItems=[(1, "test:keep", 64), (2, coal, 1)],
                     barrelSize=2, startItems=[("test:carried", 3), (coal, 1)],
                     cuts=["after_wire_push", "phase:mining"])
    assert sim.start()[0] == "POWER_CUT"
    before = sim.results()
    assert before["fuel"] == 959 and before["pushedInto"][1] == 2
    assert before["outputMined"] == 0 and before["barrel"][2] is None
    assert sim.command(startup=True)[0] == "POWER_CUT"
    r = sim.results()
    assert r["fuel"] + r["moves"] == 1759 and r["outputMined"] == 3
    assert r["fuelBurnsFromBase"] == 2 and r["wirePushes"] == 1
    assert r["barrel"][1]["count"] == 64 and r["selected"] == 1 and not r["violations"]


@test
def shared_full_barrel_frees_a_slot_by_burning_fuel():
    sim = Simulation(fuelSide="back", fuel=0, limit=1600, fuelStock=0,
                     barrelItems=[(1, "test:keep", 64), (2, "minecraft:coal_block", 1)],
                     barrelSize=2, startItems=[("test:carried", 3)],
                     cuts=["after_wire_push", "phase:mining"])
    assert sim.start()[0] == "POWER_CUT"
    assert sim.results()["pushedInto"][1] == 2
    assert sim.command(startup=True)[0] == "POWER_CUT"
    r = sim.results()
    assert r["outputMined"] == 3 and r["fuel"] + r["moves"] == 800 and r["wirePushes"] == 1
    assert r["barrel"][1]["count"] == 64 and r["barrel"][2]["name"] == "test:carried"
    assert r["selected"] == 1 and not r["violations"]


@test
def shared_full_turtle_can_burn_a_whole_stack_to_open_a_buffer():
    sim = Simulation(fuelSide="back", fuel=200, limit=1800, fuelStock=0,
                     barrelItems=[(1, "test:keep", 64), (2, "minecraft:coal_block", 64)],
                     barrelSize=2, cuts=["after_wire_push"],
                     startItems=[(f"test:carried_{i}", 1) for i in range(15)] +
                                [("minecraft:coal_block", 1)])
    assert sim.start()[0] == "POWER_CUT"
    r = sim.results()
    assert r["fuel"] == 1000 and r["pushedInto"][1] == 16
    assert r["barrel"][2]["count"] == 63 and r["invItems"] == 16
    assert r["outputMined"] == r["moves"] == 0 and not r["violations"]


@test
def shared_partial_unload_retries_only_the_remaining_cargo():
    sim = Simulation(fuelSide="back", fuel="unlimited", fuelStock=0, barrelSize=1,
                     barrelItems=[(1, "test:carried", 63)],
                     startItems=[("test:carried", 4)], stopStatus="waiting_output",
                     cuts=["after_wire_pull", "before_dig"])
    assert sim.start()[0] == "POWER_CUT"
    r = sim.results()
    assert r["outputMined"] == 1 and r["invItems"] == 3 and r["barrel"][1]["count"] == 64
    assert sim.command(startup=True)[0] == "TEST_END"
    assert sim.results()["last"]["status"] == "waiting_output"
    sim.g.drain_barrel()
    assert sim.command(startup=True)[0] == "POWER_CUT"
    r = sim.results()
    assert r["outputMined"] == 4 and r["invItems"] == 0
    assert r["barrel"][1]["count"] == 3 and r["barrelRemoved"]["test:carried"] == 64
    assert r["wirePushes"] == 0 and not r["violations"]


@test
def shared_waits_for_coal_and_failed_transfers_then_resumes():
    sim = Simulation(fuelSide="back", fuelStock=0, stopStatus="waiting_fuel",
                     barrelItems=[(1, "minecraft:coal", 12)],
                     startItems=[("test:carried", 1)], wirePullFails=True,
                     cuts=["sleep:waiting_output"])
    assert sim.start()[0] == "POWER_CUT"
    assert "wired output failed" in sim.results()["last"]["detail"]
    sim.g.OPTIONS.wirePullFails = False
    assert sim.command(startup=True)[0] == "TEST_END"
    r = sim.results()
    assert "no coal blocks" in r["last"]["detail"] and r["wirePushes"] == 0
    assert r["outputMined"] == 1 and r["moves"] == 0
    sim.g.OPTIONS.refillAt = 1
    sim.g.OPTIONS.wirePushFails = True
    assert sim.command(startup=True)[0] == "TEST_END"
    assert "did not reach slot" in sim.results()["last"]["detail"]
    sim.g.OPTIONS.wirePushFails = False
    assert sim.command(startup=True)[0] == "TEST_END"
    r = check_complete(sim.results(), "shared refill")
    assert r["barrel"][1]["name"] == "minecraft:coal" and r["barrel"][1]["count"] == 12
    assert r["minedItems"] + 1 == r["outputMined"] and r["wirePushes"] > 0


@test
def shared_waits_safely_for_output_space_or_dock():
    for opts, detail in [
        (dict(noDock=True), "wired dock modem"),
        (dict(twoWiredBarrels=True), "more than one barrel"),
        (dict(fuel="unlimited"), "fuel tank has no room"),
        (dict(startItems=[(f"test:carried_{i}", 1) for i in range(16)]), "all 16 turtle slots occupied"),
    ]:
        opts.setdefault("startItems", [("test:carried", 1)])
        r = run(fuelSide="back", fuelStock=1, stopStatus="waiting_output", barrelSize=1, **opts)
        assert detail in r["last"]["detail"] and r["last"]["status"] == "waiting_output"
        assert r["moves"] == r["wirePushes"] == r["outputMined"] == 0
        assert r["invItems"] == len(opts["startItems"]) and r["selected"] == 1
        assert not r["blindSucks"] and not r["violations"]
    sim = Simulation(fuelSide="back", fuelStock=0, fuel="unlimited",
                     barrelItems=[(i, "test:full", 64) for i in range(1, 28)],
                     startItems=[("test:carried", 1)], stopStatus="waiting_output")
    assert sim.start()[0] == "TEST_END"
    assert sim.results()["last"]["status"] == "waiting_output"
    sim.g.drain_barrel()
    assert sim.command(startup=True)[0] == "TEST_END"
    r = check_complete(sim.results(), "shared output cleared")
    assert r["minedItems"] + 1 == r["outputMined"]


@test
def shared_changed_source_fails_closed_without_redepositing():
    sim = Simulation(fuelSide="back", fuelStock=1, wireRace=True, cuts=["after_wire_push"])
    assert sim.start()[0] == "POWER_CUT"
    for _ in range(2):
        sim.command(startup=True)
        r = sim.results()
        assert r["last"]["status"] == "recovery_required"
        assert "Unexpected item in shared fuel buffer" in r["last"]["detail"]
        assert r["wirePushes"] == r["wrongPushes"] == r["invItems"] == 1
        assert r["outputMined"] == r["moves"] == r["blindSucks"] == 0
        assert r["selected"] == 1 and not r["violations"]


@test
def shared_migration_is_explicit_home_only_and_restart_safe():
    sim = Simulation(fuelStock=0, stopStatus="waiting_fuel", cuts=[])
    # Wait on an ordinary published legacy checkpoint first, then arm
    # interruptions specifically for the migration.
    assert sim.start()[0] == "TEST_END"
    sim.code = sim.code.replace('local FUEL_SIDE = "top"', 'local FUEL_SIDE = "back"')
    sim.g.quarry_source = sim.code
    assert sim.command(startup=True)[0] == "TEST_END"
    assert sim.g.latest_record()["job"]["fuel"] == "top"
    sim.command("migrate-shared")
    assert sim.g.latest_record()["job"]["fuel"] == "top"
    sim.g.enable_shared()
    # Error telemetry changed the last status; unqualified hooks here only
    # fire when the explicitly invoked migration actually writes.
    sim.lua.execute('OPTIONS.cuts[1]="before_state_publish"; OPTIONS.cuts[2]="after_state_publish"')
    assert sim.command("migrate-shared")[0] == "POWER_CUT"
    assert sim.g.latest_record()["job"]["fuel"] == "top"
    assert sim.command("migrate-shared")[0] == "POWER_CUT"
    job = sim.g.latest_record()["job"]
    assert job["fuel"] == "back" and job["barrel"] == "minecraft:barrel_0"
    assert sim.results()["moves"] == 0
    assert sim.command(startup=True)[0] == "TEST_END"
    check_complete(sim.results(), "migrated legacy checkpoint")

    for cut, detail in [("before_turn", "Resolve the pending action"),
                        ("after_state_publish:mining", "original home")]:
        away = Simulation(cuts=[cut])
        assert away.start()[0] == "POWER_CUT"
        before = away.results()["moves"]
        away.command("migrate-shared")
        assert detail in away.results()["last"]["detail"], away.results()["last"]["detail"]
        assert away.g.latest_record()["job"]["fuel"] == "top" and away.results()["moves"] == before


@test
def resume_drains_a_previously_queued_move_before_reconciling():
    sim = Simulation(cuts=["queue_move:mining"])
    r, manual = recover(sim, 1)
    assert not manual and r["minedItems"] == r["outputMined"]


@test
def gps_anchors_unlimited_moves_but_not_turns():
    cuts = ["before_move:starting", "after_move:starting",
            "before_move:mining", "after_move:mining", "after_turn:mining"]
    sim = Simulation(cuts=cuts, fuel="unlimited", gps=True, anchor="east")
    r, manual = recover(sim, len(cuts))
    assert manual == ["after"], manual
    assert r["minedItems"] == r["outputMined"]


@test
def unresolved_actions_refuse_to_move_and_can_be_verified_manually():
    for options, alter in [({"fuel": "unlimited"}, None),
                           ({}, ("power_change", -5)),
                           ({"fuel": "unlimited", "gps": True, "anchor": "east"},
                            ("gpsOffset", 10))]:
        sim = Simulation(cuts=["after_move:mining"], **options)
        assert sim.start()[0] == "POWER_CUT"
        moves = sim.results()["moves"]
        if alter:
            name, value = alter
            if name == "power_change":
                sim.g.power_change(value)
            else:
                sim.g.OPTIONS[name] = value
        assert sim.command(startup=True)[0] is None
        r = sim.results()
        assert r["last"]["status"] == "recovery_required" and r["moves"] == moves
        assert r["last"]["location"]["uncertain"]
        sim.command("status")
        assert any("Before:" in line and "After:" in line for line in sim.results()["printed"])
        if alter and alter[0] == "gpsOffset":
            sim.g.OPTIONS.gpsOffset = 0
        seq, which = sim.g.manual_choice()
        assert sim.command("resolve", str(seq + 1), which)[0] is None
        assert sim.results()["moves"] == moves
        assert sim.command("resolve", str(seq), which)[0] == "TEST_END"
        check_complete(sim.results(), "operator-verified resume")


@test
def absent_corrupt_torn_and_completed_checkpoints():
    sim = Simulation()
    sim.g.turtle.select(5)
    assert sim.command(startup=True)[0] is None
    assert sim.results()["selected"] == 5
    sim.command("resume")
    assert "No active quarry checkpoint" in sim.results()["printed"]
    assert sim.results()["moves"] == 0 and sim.g.latest_record() is None

    sim = Simulation(cuts=["during_state_write"])
    assert sim.start()[0] == "POWER_CUT"
    sim.command(startup=True)
    assert sim.results()["last"]["status"] == "recovery_required"
    assert sim.results()["moves"] == 0

    for damage in ("corrupt_latest", "corrupt_action", "delete_latest", "different_version"):
        sim = Simulation(cuts=["after_move:mining"])
        assert sim.start()[0] == "POWER_CUT"
        assert sim.g.latest_record() is not None
        sim.g[damage]()
        before = sim.results()["moves"]
        sim.command(startup=True)
        r = sim.results()
        assert r["last"]["status"] == "recovery_required"
        assert r["moves"] == before

    sim = Simulation(cuts=["phase:complete"])
    assert sim.start()[0] == "POWER_CUT"
    before = check_complete(sim.results(), "completion committed")
    assert sim.g.latest_record()["job"]["done"]
    assert sim.command(startup=True)[0] is None
    sim.command("resume")
    sim.start()  # An explicit new job must also refuse to overwrite it.
    r = sim.results()
    assert r["moves"] == before["moves"] and r["outputMined"] == before["outputMined"]
    assert "Saved job is completed" in r["printed"]


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
            elseif event == 5 then
                assert(writes == SAVED_WRITES, "unchanged frame was redrawn")
                local p=pkt(1,"recovery_required")
                p.location={uncertain=true}
                return "rednet_message",1,p,"turtle_quarry_v1"
            elseif event == 6 then
                local all=table.concat(lines,"\n")
                assert(all:find("RECOVERY REQUIRED",1,true),all)
                assert(all:find("Position / heading not verified",1,true),all)
                return "rednet_message",1,pkt(1,"recovering"),"turtle_quarry_v1"
            elseif event == 7 then
                assert(table.concat(lines,"\n"):find("RECOVERING"))
                return "rednet_message",1,pkt(1,"resumed"),"turtle_quarry_v1"
            end
            assert(table.concat(lines,"\n"):find("RESUMED"))
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
