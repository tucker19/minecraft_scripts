-- chunk_dig <chunks> [job name] [north|east|south|west]
-- chunk_dig resume | auto | status | resolve <generation> <before|after>
-- chunk_dig migrate-shared  (existing back/top job, safely stopped at home)
-- Stand at the original base to start. The first mined layer is below home.
local OUTPUT_SIDE = "back"
local FUEL_SIDE = "back"
local SAFETY_MARGIN = 32
local MIN_PROGRESS = 64
local RETRY_SECONDS = 5

local args = {...}
if not turtle then error("Run chunk_dig on a mining turtle", 0) end
local DIR, VERSION = "/.chunk_dig", 1
local PROTOCOL = "turtle_quarry_v1"
local sides = {front=0, right=1, back=2, left=3, top=true}
local sideNames = {[0]="front","right","back","left"}
local cardinal = {north=0, east=1, south=2, west=3}
local DX, DZ = {[0]=1, 0, -1, 0}, {[0]=0, 1, 0, -1}
local WX, WZ = {[0]=0, 1, 0, -1}, {[0]=-1, 0, 1, 0}
local HOME = {x=0, y=0, z=0, h=0}
local KM = 100000
local S, generation, pending, side
local status, detail, reserve = "starting", "", 0
local verifiedPose = false
local lastSend, lastGpsTry, gpsFix, motionCount = -math.huge, -math.huge, nil, 0
local handlers = {}
local COAL_BLOCK = "minecraft:coal_block"
local fuelValues = {["minecraft:coal_block"]=800, ["minecraft:coal"]=80,
    ["minecraft:charcoal"]=80, ["minecraft:lava_bucket"]=1000, ["minecraft:blaze_rod"]=120}

local function fail(s) error(s, 0) end
local function recovery(s) fail("RECOVERY: " .. s) end
local function integer(n, lo, hi)
    return type(n) == "number" and n % 1 == 0 and n >= lo and n <= hi
end
local function K(x, z) return x * KM + z end
local function xz(k) return math.floor(k / KM), k % KM end
local function point(x, y, z) return {x=x, y=y, z=z} end
local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
local function pose(x, y, z, h) return {x=x, y=y, z=z, h=h} end
local function adjacent(a, b)
    return math.abs(a.x-b.x) + math.abs(a.y-b.y) + math.abs(a.z-b.z) == 1
end
local function fuel()
    local n = turtle.getFuelLevel()
    return n == "unlimited" and math.huge or n
end
local function limit()
    local n = turtle.getFuelLimit()
    return n == "unlimited" and math.huge or n
end
local function inBox(x, z) return x >= 0 and z >= 0 and x < side and z < side end
local function validPoint(p, heading)
    return type(p) == "table" and integer(p.x, 0, side-1) and integer(p.z, 0, side-1)
        and integer(p.y, -30000000, 0) and (p.y < 0 or same(p, HOME))
        and (not heading or integer(p.h, 0, 3))
end
local function validWorld(p)
    return type(p) == "table" and integer(p.x,-30000000,30000000)
        and integer(p.y,-30000000,30000000) and integer(p.z,-30000000,30000000)
end
local function world(p)
    local a = S.anchor
    local r = (a.h + 1) % 4
    return point(a.x + p.x*WX[a.h] + p.z*WX[r], a.y + p.y,
        a.z + p.x*WZ[a.h] + p.z*WZ[r])
end
local function locate(timeout)
    local x,y,z = gps.locate(timeout)
    local p = point(x,y,z)
    return validWorld(p) and p or nil
end

local function telemetry(force)
    local now = os.clock()
    if not force and now-lastSend < 2 then return end
    lastSend = now
    local modem = peripheral.find("modem", function(_,m)
        return type(m.isWireless) == "function" and m.isWireless()
    end)
    if not modem then return end
    local n = peripheral.getName(modem)
    if not rednet.isOpen(n) then rednet.open(n) end
    if verifiedPose and now-lastGpsTry >= 15 then
        lastGpsTry = now
        local p = locate(0.5)
        if p then gpsFix = {point=p, time=os.clock(), move=motionCount} end
    end
    local g
    if verifiedPose and gpsFix then
        g = point(gpsFix.point.x,gpsFix.point.y,gpsFix.point.z)
        g.age, g.moved = os.clock()-gpsFix.time, gpsFix.move ~= motionCount
    end
    local used, items = 0, 0
    for i=1,16 do
        local count = turtle.getItemCount(i)
        if count > 0 then used = used+1 end
        items = items+count
    end
    local s, c = S or {}, S and S.cur or {}
    rednet.broadcast({
        type="quarry", version=1, id=os.getComputerID(),
        name=s.name or os.getComputerLabel() or ("Quarry " .. os.getComputerID()),
        status=status, detail=detail, fuelType=s.lastFuel or "none consumed yet",
        fuel=turtle.getFuelLevel(), fuelLimit=turtle.getFuelLimit(),
        reserve=fuel() == math.huge and 0 or reserve,
        job={chunks=s.chunks, side=side, area=side and side*side, layer=s.layer,
            layerCleared=c.count, layerBlocked=c.nblocked, layerSkipped=c.skipped,
            regions=c.regions and #c.regions, cells=s.total, trips=s.trips},
        inventory={usedSlots=used,totalSlots=16,emptySlots=16-used,items=items,percent=100*used/16},
        location={relative=verifiedPose and s.pos or nil,
            heading=verifiedPose and s.pos.h or nil, uncertain=not verifiedPose,
            gps=g, gpsAge=g and g.age},
    }, PROTOCOL)
end
local function announce(st, msg)
    msg = msg or ""
    if st ~= status or msg ~= detail then
        status, detail = st, msg
        print(st .. (msg ~= "" and ": " .. msg or ""))
        telemetry(true)
    else telemetry() end
end

-- Checkpoints alternate between two committed files. A partially written .tmp
-- never becomes authoritative. A corrupt *committed* file is not silently
-- bypassed: the older copy might precede a physical move or completion.
local function checksum(s)
    local a,b = 1,0
    for i=1,#s do a=(a+s:byte(i))%65521; b=(b+a)%65521 end
    return a*65536+b
end
local function readRecord(path, kind)
    local f, why = fs.open(path, "r")
    if not f then recovery("Cannot read " .. path .. ": " .. tostring(why)) end
    local content = f.readAll() or ""; f.close()
    local ver,k,sum,payload = content:match("^QUARRY (%d+) (%a+) (%d+)\n(.*)$")
    if tonumber(ver) ~= VERSION or k ~= kind or tonumber(sum) ~= checksum(payload or "") then
        recovery("Corrupt or incompatible " .. path .. "; preserve " .. DIR .. " for inspection")
    end
    local data = textutils.unserialize(payload)
    if type(data) ~= "table" then recovery("Invalid record " .. path) end
    return data
end
local function publish(path, kind, data, pair)
    local payload = textutils.serialize(data, {compact=true, allow_repetitions=true})
    local tmp = path .. ".tmp"
    local f, why = fs.open(tmp, "w")
    if not f then recovery("Cannot stage " .. path .. ": " .. tostring(why)) end
    local content=("QUARRY %d %s %.0f\n"):format(VERSION,kind,checksum(payload)) .. payload
    f.write(content); f.close()
    local check, err=fs.open(tmp,"r")
    if not check then recovery("Cannot verify " .. tmp .. ": " .. tostring(err)) end
    local written=check.readAll(); check.close()
    if written~=content then recovery("Staged write did not verify: " .. tmp) end
    if pair and not fs.exists(DIR .. "/paired") then fs.makeDir(DIR .. "/paired") end
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
end

-- Pack the two layer maps in rows and store routes as a start point plus
-- unit directions. This keeps frequent snapshots under the turtle's
-- disk quota for ordinary footprints, including fragmented bedrock.
local alphabet="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local digits={}
for i=1,#alphabet do digits[alphabet:sub(i,i)]=i-1 end
local routeCache=setmetatable({},{__mode="k"})
local pathDX,pathDY,pathDZ={1,-1,0,0,0,0},{0,0,1,-1,0,0},{0,0,0,0,1,-1}
local function encodeRoute(path)
    if routeCache[path] then return routeCache[path] end
    local bytes={}
    for i=2,#path do
        local a,b=path[i-1],path[i]
        for d=1,6 do
            if b.x-a.x==pathDX[d] and b.y-a.y==pathDY[d] and b.z-a.z==pathDZ[d] then
                bytes[#bytes+1]=tostring(d); break
            end
        end
    end
    local packed={first=path[1],steps=table.concat(bytes)}
    if #packed.steps~=#path-1 then fail("Cannot encode a non-adjacent path") end
    routeCache[path]=packed
    return packed
end
local function decodeRoute(p)
    if type(p)~="table" or not validPoint(p.first) or type(p.steps)~="string" then
        recovery("Invalid encoded path")
    end
    local path={p.first}
    for i=1,#p.steps do
        local d=p.steps:byte(i)-48
        if not pathDX[d] then recovery("Invalid encoded path step") end
        local a=path[i]
        path[i+1]=point(a.x+pathDX[d],a.y+pathDY[d],a.z+pathDZ[d])
    end
    routeCache[path]=p
    return path
end
local function cellWidth()
    local max,width=2*side^4+2*side^2+3,1
    while max>=64 do width=width+1; max=math.floor(max/64) end
    return width
end
local function rowSize() return side*cellWidth() end
local function cellCode(v)
    local n,bytes=v+2,{}
    for i=cellWidth(),1,-1 do
        local idx=n%64+1
        bytes[i]=alphabet:sub(idx,idx); n=math.floor(n/64)
    end
    return table.concat(bytes)
end
local function setCell(c,x,z,v)
    c.cells[K(x,z)]=v
    local rows=c.rows
    if not rows then
        rows={}; c.rows=rows
        local blank=cellCode(0):rep(side)
        for i=1,side do rows[i]=blank end
    end
    local width=cellWidth()
    local row=rows[z+1]
    rows[z+1]=row:sub(1,x*width) .. cellCode(v) .. row:sub((x+1)*width+1)
end
local function copy(t)
    local out={}
    for k,v in pairs(t) do out[k]=v end
    return out
end
local function packLayer(c)
    if not c then return end
    local p=copy(c)
    p.cells,p.rows=table.concat(c.rows),nil
    p.regions={}
    for i,r in ipairs(c.regions) do p.regions[i]={entry=r.entry,up=encodeRoute(r.up)} end
    return p
end
local function unpackLayer(c)
    if not c then return end
    if type(c)~="table" or type(c.cells)~="string" or #c.cells~=side*rowSize()
        or type(c.regions)~="table" then recovery("Invalid encoded quarry layer") end
    local packed,width=c.cells,cellWidth()
    c.cells,c.rows={},{}
    local index=1
    for z=0,side-1 do
        c.rows[z+1]=packed:sub(index,index+side*width-1)
        for x=0,side-1 do
            local code=0
            for _=1,width do
                local d=digits[packed:sub(index,index)]
                if not d then recovery("Invalid encoded quarry cell") end
                code=code*64+d; index=index+1
            end
            if code~=2 then c.cells[K(x,z)]=code-2 end
        end
    end
    for _,r in ipairs(c.regions) do
        if type(r)~="table" then recovery("Invalid encoded region") end
        r.up=decodeRoute(r.up)
    end
end
local function packJob()
    local s=copy(S)
    s.cur,s.par,s.tasks=packLayer(S.cur),packLayer(S.par),{}
    for i,t in ipairs(S.tasks) do
        local p=copy(t)
        if t.path then p.path=encodeRoute(t.path) end
        if t.up then p.up=encodeRoute(t.up) end
        s.tasks[i]=p
    end
    return s
end
local function unpackJob(s)
    unpackLayer(s.cur); unpackLayer(s.par)
    for _,t in ipairs(s.tasks) do
        if type(t)~="table" then recovery("Invalid encoded task") end
        if t.path then t.path=decodeRoute(t.path) end
        if t.up then t.up=decodeRoute(t.up) end
    end
end
local function checkpoint()
    local nextGen = generation+1
    publish(DIR .. "/" .. nextGen%2, "state", {seq=nextGen, job=packJob()},nextGen==2)
    generation = nextGen
end
local function verifyRoute(path)
    if type(path) ~= "table" or #path < 1 then return false end
    for i,p in ipairs(path) do
        if not validPoint(p) or (i > 1 and not adjacent(path[i-1],p)) then return false end
    end
    return true
end
local function verifyLayer(c, depth)
    if type(c) ~= "table" or c.y ~= -depth or type(c.cells) ~= "table"
        or type(c.regions) ~= "table" or #c.regions == 0
        or not integer(c.count,1,side*side) or not integer(c.nblocked,0,side*side)
        or not integer(c.skipped,0,side*side) then return false end
    -- Positive values encode distance + region + candidate flag; -1 means
    -- blocked and -2 means dug from below (not part of a safe travel route).
    local seen, blocked = 0,0
    for k,v in pairs(c.cells) do
        if not integer(k,0,(side-1)*(KM+1)) or not inBox(xz(k))
            or not integer(v,-2,2*side^4+2*side^2+1) or v == 0 then return false end
        if v > 0 then
            local region = math.floor(v/2) % (side*side+1)
            if not c.regions[region] then return false end
            seen=seen+1
        elseif v == -1 then blocked=blocked+1 end
    end
    if seen ~= c.count or blocked ~= c.nblocked then return false end
    for _,r in ipairs(c.regions) do
        if type(r) ~= "table" or not validPoint(r.entry) or r.entry.y ~= c.y
            or (c.cells[K(r.entry.x,r.entry.z)] or 0) <= 0
            or not verifyRoute(r.up) or not adjacent(r.entry,r.up[1])
            or r.up[1].y ~= c.y+1 or not same(r.up[#r.up],HOME) then return false end
    end
    return true
end
local validTask
local function validateState(r)
    local s = r.job
    if not integer(r.seq,1,2^52) or type(s) ~= "table"
        or s.owner ~= os.getComputerID() or not integer(s.chunks,1,64)
        or not integer(s.created,1,2^52)
        or type(s.name) ~= "string" or #s.name > 200
        or not sides[s.output] or not sides[s.fuel]
        -- Retain the old dock name as opaque checkpoint metadata, not as routing.
        or (s.barrel~=nil and (s.output~=s.fuel or type(s.barrel)~="string"))
        or (s.sharedMigration~=nil and (s.output~="back" or s.fuel~="back"
            or not integer(s.sharedMigration,1,r.seq-1)))
        or not integer(s.margin,0,1000000) or not integer(s.progress,1,1000000)
        or not integer(s.retry,1,3600) or not integer(s.layer,0,30000000)
        or not integer(s.total,0,2^52) or not integer(s.trips,0,2^52)
        or type(s.lastFuel) ~= "string" or type(s.tasks) ~= "table"
        or (s.done ~= true and s.done ~= false)
        or (s.result ~= nil and type(s.result) ~= "boolean")
        or (s.anchor and (not validWorld(s.anchor) or not integer(s.anchor.h,0,3))) then
        recovery("Checkpoint metadata is invalid or belongs to another turtle")
    end
    side = s.chunks*16
    unpackJob(s)
    if not validPoint(s.home,true) or not same(s.home,HOME) or s.home.h~=0
        or not validPoint(s.pos,true)
        or (s.layer == 0 and (s.cur ~= nil or s.par ~= nil))
        or (s.layer > 0 and not verifyLayer(s.cur,s.layer))
        or (s.layer < 2 and s.par ~= nil)
        or (s.layer >= 2 and not verifyLayer(s.par,s.layer-1))
        or (s.done and (#s.tasks ~= 0 or not same(s.pos,HOME) or s.pos.h ~= 0))
        or (not s.done and (#s.tasks < 1 or #s.tasks > 16
            or type(s.tasks[1]) ~= "table" or s.tasks[1].kind ~= "job")) then
        recovery("Invalid checkpoint pose, layer, or execution stack")
    end
    for i,t in ipairs(s.tasks) do
        if not validTask(t,i) then recovery("Invalid checkpoint task at depth " .. i) end
        if t.sharedFuelSlot and s.output~=s.fuel then recovery("Invalid shared fuel buffer") end
    end
    local t=s.tasks[#s.tasks]
    if t then
        if t.kind=="walk" then
            local at=t.path[t.i-(t.moved and 0 or 1)]
            if not at or not same(at,s.pos) then recovery("Walk cursor disagrees with saved pose") end
        elseif t.kind=="mine" then
            if (t.moved and (t.mode=="below" or not same(t.p,s.pos)))
                or (not t.moved and not adjacent(t.p,s.pos)) then recovery("Mine target disagrees with saved pose") end
        elseif t.kind=="base" and not same(s.pos,HOME) then recovery("Base step has non-home pose") end
    end
end
local function readState()
    local latest, older
    for i=0,1 do
        local path = DIR .. "/" .. i
        if fs.exists(path) then
            local r = readRecord(path,"state")
            validateState(r)
            if r.seq%2 ~= i then recovery("Checkpoint in wrong generation slot") end
            if not latest or r.seq > latest.seq then older,latest=latest,r
            else older=r end
        end
    end
    if latest and older and latest.seq ~= older.seq+1 then recovery("Checkpoint generations disagree") end
    if latest and older then
        local new,old=latest.job,older.job
        local migrated=old.output=="back" and old.fuel=="top" and new.fuel=="back"
            and new.sharedMigration==older.seq and same(old.pos,HOME) and same(new.pos,HOME)
            and old.pos.h==new.pos.h and not old.done and not new.done
        if new.created~=old.created or new.chunks~=old.chunks or new.output~=old.output
            or (new.fuel~=old.fuel and not migrated)
            or (old.barrel and new.barrel~=old.barrel)
            or (new.sharedMigration~=old.sharedMigration and not migrated) then
            recovery("Checkpoint copies belong to different jobs or configurations")
        end
    end
    if latest and not older and (latest.seq>1 or fs.exists(DIR .. "/paired"))
        and not fs.exists(DIR .. "/" .. (latest.seq+1)%2 .. ".tmp") then
        recovery("A committed checkpoint is missing without an interrupted replacement; preserve " .. DIR)
    end
    if not latest and fs.exists(DIR) then recovery("No committed checkpoint in " .. DIR) end
    return latest
end

local function task() return S.tasks[#S.tasks] end
local function push(kind,t)
    t = t or {}; t.kind=kind; S.tasks[#S.tasks+1]=t
    return true
end
local function pop(result)
    S.tasks[#S.tasks]=nil; S.result=result
    return true
end
local function result()
    local r=S.result; S.result=nil; return r
end
local function target(dir,p)
    if dir == "up" then return point(p.x,p.y+1,p.z) end
    if dir == "down" then return point(p.x,p.y-1,p.z) end
    return point(p.x+DX[p.h],p.y,p.z+DZ[p.h])
end
local function dirAPI(prefix,dir)
    return turtle[prefix .. (dir == "up" and "Up" or dir == "down" and "Down" or "")]
end
local function afterPose(op,p)
    if op == "right" or op == "left" then
        return pose(p.x,p.y,p.z,(p.h+(op == "right" and 1 or 3))%4)
    end
    local a=target(op,p); a.h=p.h; return a
end
local function motion(op)
    local old = S.pos
    local after = afterPose(op,old)
    if not validPoint(after,true) then fail("Unsafe motion outside footprint") end
    local move = op ~= "right" and op ~= "left"
    pending = {seq=generation, job=S.created, op=op, before=old, after=after,
        fuel=turtle.getFuelLevel(), depth=#S.tasks, kind=task().kind}
    publish(DIR .. "/action","action",pending)
    local fn = move and turtle[op] or (op == "right" and turtle.turnRight or turtle.turnLeft)
    local ok,why = fn()
    if ok then
        S.pos=after
        if move then task().moved=true; motionCount=motionCount+1 end
    end
    -- Even a failed call is committed before removing the intent. This
    -- makes the same recovery rule apply before and after a failed call.
    checkpoint()
    fs.delete(DIR .. "/action"); pending=nil
    if not ok and not move then fail("Turn failed: " .. tostring(why)) end
    return ok,why
end
local function face(h)
    local d=(h-S.pos.h)%4
    if d == 0 then return true end
    motion(d == 3 and "left" or "right")
    return false -- one motion per dispatcher step
end
local function faceSide(which)
    return which=="top" or face(sides[which])
end
local function physicalSide(which)
    return which=="top" and "top" or sideNames[(sides[which]-S.pos.h)%4]
end
local function direction(p)
    local c=S.pos
    if not adjacent(c,p) then fail("Route step is not adjacent") end
    if p.y ~= c.y then return p.y > c.y and "up" or "down" end
    for h=0,3 do
        if c.x+DX[h] == p.x and c.z+DZ[h] == p.z then return "forward",h end
    end
end

local function describe(p)
    local s=("%d,%d,%d heading %d"):format(p.x,p.y,p.z,p.h)
    if S.anchor then
        local w=world(p)
        local names={[0]="north","east","south","west"}
        s=s .. (" (world %d,%d,%d facing %s)"):format(w.x,w.y,w.z,names[(S.anchor.h+p.h)%4])
    end
    return s
end
local function actionRecord()
    local path=DIR .. "/action"
    if not fs.exists(path) then return end
    local j=readRecord(path,"action")
    if j.job~=S.created or not integer(j.seq,1,generation) or j.seq < generation-1
        or not ({forward=true,up=true,down=true,left=true,right=true})[j.op]
        or not validPoint(j.before,true) or not validPoint(j.after,true)
        or not integer(j.depth,1,16) or type(j.kind) ~= "string"
        or (j.fuel ~= "unlimited" and not integer(j.fuel,0,2^52)) then
        recovery("Invalid action journal; preserve " .. DIR)
    end
    local a=afterPose(j.op,j.before)
    local move=j.op~="left" and j.op~="right"
    if not same(a,j.after) or a.h ~= j.after.h or #S.tasks ~= j.depth or task().kind ~= j.kind
        or (move and j.kind ~= "walk" and j.kind ~= "mine") then recovery("Action and checkpoint disagree") end
    if move then
        local t=task()
        local dest=t.kind=="walk" and t.path[t.i] or t.p
        if not dest or not same(dest,j.after) or t.mode=="below" then recovery("Journal has the wrong motion target") end
    end
    local before = same(S.pos,j.before) and S.pos.h == j.before.h
    local after = same(S.pos,j.after) and S.pos.h == j.after.h
    if (j.seq == generation and not before) or (j.seq < generation and not before and not after)
        or (move and (task().moved == true) ~= (j.seq < generation and after)) then
        recovery("Action pose and checkpoint disagree")
    end
    return j
end
local function reconcile(manualSeq, manualChoice)
    -- Drain any old turtle command still queued after a stop (notably
    -- Ctrl+T while an API call was waiting for its result). Inspect is a
    -- read-only command on the same queue as moves, turns and transfers.
    turtle.inspectDown()
    local j=actionRecord()
    if not j or j.seq < generation then
        if manualSeq then recovery("No matching unresolved action") end
        if S.anchor then
            local fix=locate(2)
            if not fix or not same(fix,world(S.pos)) then
                recovery("GPS cannot verify the saved position: " .. describe(S.pos))
            end
        end
        if j then fs.delete(DIR .. "/action") end
        return
    end
    local move=j.op ~= "left" and j.op ~= "right"
    local choice
    if S.anchor then
        local fix=locate(2)
        if fix then
            if not same(fix,world(j.before)) and not same(fix,world(j.after)) then
                recovery("GPS disagrees with both journal positions; do not move the turtle")
            end
            if move then choice=same(fix,world(j.before)) and "before" or "after" end
        elseif not manualSeq then
            recovery("No GPS fix for pending " .. j.op .. "; restore GPS or verify the pose manually."
                .. "\nBefore: " .. describe(j.before) .. "\nAfter: " .. describe(j.after)
                .. "\nAfter verifying: chunk_dig resolve " .. j.seq .. " before|after")
        end
    elseif move and type(j.fuel) == "number" and type(turtle.getFuelLevel()) == "number" then
        -- CC:Tweaked moves and deducts fuel in the same server tick.
        -- Applies to ordinary chunk unload, not independent disk/world rollback.
        local delta=j.fuel-turtle.getFuelLevel()
        if delta == 0 then choice="before" elseif delta == 1 then choice="after" end
    end
    if manualSeq then
        if manualSeq ~= j.seq then recovery("Action generation changed; run chunk_dig status") end
        if S.anchor and choice and manualChoice ~= choice then recovery("Manual choice disagrees with GPS") end
        choice=manualChoice -- operator explicitly verified actual pose
    end
    if not choice then
        recovery("Unresolved " .. j.op .. "; verify the turtle in place."
            .. "\nBefore: " .. describe(j.before) .. "\nAfter: " .. describe(j.after)
            .. "\nAfter verifying: chunk_dig resolve " .. j.seq .. " before|after")
    end
    if choice == "after" then
        S.pos=j.after
        if move then task().moved=true end
    end
    checkpoint()
    fs.delete(DIR .. "/action")
end

-- Inventory changes replay by observation, not by a saved slot index/count.
local function emptySlot()
    for i=1,16 do if turtle.getItemCount(i) == 0 then return true end end
    return false
end
local function cargoSpace()
    if emptySlot() then return true end
    for j=16,2,-1 do
        local d=turtle.getItemDetail(j)
        if d then
            for i=1,j-1 do
                local a=turtle.getItemDetail(i)
                if a and a.name == d.name and turtle.getItemSpace(i)>0 then
                    turtle.select(j)
                    local ok=turtle.transferTo(i)
                    turtle.select(1)
                    if ok and turtle.getItemCount(j)==0 then return true end
                end
            end
        end
    end
    return emptySlot()
end
local function burn(slot)
    turtle.select(slot)
    local d=turtle.getItemDetail(slot)
    local before=fuel()
    local ok=d and turtle.refuel(1)
    turtle.select(1)
    if ok and fuel()>before then
        S.lastFuel=d.name
        return true
    end
    return false
end
local function carried(need)
    if fuel() >= need then return end
    for i=1,16 do
        while fuel()<need and turtle.getItemCount(i)>0 and burn(i) do end
    end
end
local function carriedBlocks(need)
    for i=1,16 do
        while fuel()<need do
            local d=turtle.getItemDetail(i)
            if not d or d.name~=COAL_BLOCK or not burn(i) then break end
        end
    end
end
local function inventoryAt(which, generic)
    local side=physicalSide(which)
    if generic then return peripheral.hasType(side,"inventory") end
    local p=peripheral.wrap(side)
    return p and type(p.list)=="function" and p or nil
end
local function sideProbe(which)
    local side=physicalSide(which)
    local inspect=side=="front" and turtle.inspect or side=="top" and turtle.inspectUp
    local block="not inspected (requires front or top)"
    if inspect then
        local ok,detail=inspect()
        block=ok and detail.name or tostring(detail)
    end
    local types={peripheral.getType(side)}
    return ("home %s -> current %s at heading %d; block=%s; peripheral=%s; inventory=%s")
        :format(which,side,S.pos.h,block,#types>0 and table.concat(types,",") or "none",
            tostring(not not peripheral.hasType(side,"inventory")))
end
local function drop(which,i)
    local side=physicalSide(which)
    if side~="front" and side~="top" then fail("Output transfer attempted before facing storage") end
    turtle.select(i)
    local ok,why=(side=="top" and turtle.dropUp or turtle.drop)()
    turtle.select(1)
    if turtle.getItemCount(i)==0 then return true end
    if ok or tostring(why):lower():find("space") then return false,"output inventory full" end
    return false,"output transfer failed: " .. tostring(why)
end
local function canDig(p,name)
    if name == "minecraft:bedrock" or (name:match("^allthemodium:") and name:find("ore"))
        or name:find("chest") or name:find("barrel") or name:find("shulker") or name:find("drawer")
        then return false end
    if p.y == 0 then
        return same(p,HOME) and (name:find("sand") or name:find("gravel") or name:find("concrete_powder"))
    end
    return p.y < 0 and inBox(p.x,p.z)
end
local function waitFor(state,message)
    announce(state,message); sleep(S.retry)
end
local function baseWait(t,stage,message)
    if t.stage~=stage then t.stage=stage; checkpoint() end
    waitFor(stage,message)
end

local function wireCall(fn,...)
    local ok,value=pcall(fn,...)
    if ok then return value end
    if value=="Terminated" then fail(value) end
    return nil,tostring(value)
end
local function fuelDockSide(which) return which=="top" and "front" or "top" end
local function fuelDock(which)
    local dockHomeSide=fuelDockSide(which)
    local dockSide=physicalSide(dockHomeSide)
    local m=peripheral.wrap(dockSide)
    if not m or type(m.isWireless)~="function" or m.isWireless()
        or type(m.getNameLocal)~="function" or type(m.getNamesRemote)~="function"
        or type(m.getMethodsRemote)~="function" or type(m.callRemote)~="function" then
        return nil,"selective fuel requires a wired dock modem with remote inventory calls; " .. sideProbe(dockHomeSide)
    end
    local id=wireCall(m.getNameLocal)
    if type(id)~="string" or id=="" then
        return nil,"wired dock does not address this turtle (getNameLocal unavailable); enable peripheral mode and check keepalive"
    end
    local names=wireCall(m.getNamesRemote)
    local name,methods
    for _,n in pairs(names or {}) do
        if n~=id then
            local available={}
            for _,method in pairs(wireCall(m.getMethodsRemote,n) or {}) do available[method]=true end
            if available.list and available.pushItems then
                if name then return nil,"multiple wired inventories expose list/pushItems; use a dedicated network for the shared storage" end
                name,methods=n,available
            end
        end
    end
    if not name then return nil,"selective fuel requires list and slot-specific pushItems on the wired shared inventory" end
    return {id=id,detail=methods.getItemDetail,call=function(method,...)
        return wireCall(m.callRemote,name,method,...)
    end}
end

local function roomForFuel(t)
    local headroom=limit()-fuel()
    return headroom>=fuelValues[COAL_BLOCK] or (not t.final and fuel()<t.need and headroom>0)
end
local function bufferSlot()
    if not cargoSpace() then return end
    for i=1,16 do if turtle.getItemCount(i)==0 then return i end end
end

-- A full cargo inventory can still make room if the tank can take
-- an entire carried coal-block stack plus the block from the barrel.
local function burnCarriedForBuffer()
    local max=math.floor((limit()-fuel())/fuelValues[COAL_BLOCK])-1
    if max<1 then return end
    local best,slot
    for i=1,16 do
        local d=turtle.getItemDetail(i)
        if d and d.name==COAL_BLOCK and d.count<=max and (not best or d.count<best) then
            best,slot=d.count,i
        end
    end
    if slot then
        for _=1,best do if not burn(slot) then return end end
        return slot
    end
end

local function coalSlot(items,tried)
    local from,best,count=nil,nil,0
    for i,d in pairs(items) do
        if integer(i,1,2^31-1) and type(d)=="table" and d.name==COAL_BLOCK
            and type(d.count)=="number" and d.count>0 and not tried[i] then
            count=count+1
            if not best or d.count<best or (d.count==best and i<from) then from,best=i,d.count end
        end
    end
    return from,count
end
local function sharedPull(t)
    if not roomForFuel(t) or fuel()==math.huge then return false,"fuel tank has no room for a coal block" end
    local dock,missing=fuelDock(S.output)
    if not dock then return false,missing end
    local items,why=dock.call("list")
    if type(items)~="table" then return false,"cannot list wired shared inventory: " .. tostring(why) end
    local tried={}
    local _,attempts=coalSlot(items,tried)
    if attempts==0 then return false,"no coal blocks exposed by the wired inventory" end
    local into=bufferSlot() or burnCarriedForBuffer()
    if not into then return false,"all 16 turtle slots occupied; no slot for a coal block" end
    -- Persist the empty buffer slot before the transfer. A reboot can
    -- consume a delivered coal block or detect a changed source slot.
    t.sharedFuelSlot=into
    checkpoint()
    local problem="coal slots changed before transfer"
    -- Refresh after the checkpoint and every failed attempt. Do not chase
    -- moving virtual slots indefinitely or retry the same index in a pass.
    for _=1,attempts do
        items,why=dock.call("list")
        if type(items)~="table" then return false,"cannot refresh wired shared inventory: " .. tostring(why) end
        local from=coalSlot(items,tried)
        if not from then break end
        tried[from]=true
        local d=items[from]
        if dock.detail then
            local detail,err=dock.call("getItemDetail",from)
            -- An optional method that errors is not needed for a fresh list.
            if not err then d=detail end
        end
        if d and d.name==COAL_BLOCK then
            local moved,err=dock.call("pushItems",dock.id,from,1,into)
            local got=turtle.getItemDetail(into)
            if got and (got.name~=COAL_BLOCK or got.count~=1) then
                recovery("Unexpected item in shared fuel buffer slot " .. into .. "; stop other access to the inventory and remove that item before resuming")
            end
            if got then return true end
            if err then
                return false,"wired slot transfer to the turtle failed; verify the turtle exposes a writable inventory: " .. err
            end
            if moved~=0 then
                recovery("Wired transfer returned " .. tostring(moved) .. " but the fuel buffer did not receive it; inspect both inventories before resuming")
            end
            problem="coal was listed but no block was extracted into turtle slot " .. into
                .. "; check storage extraction/compaction or the wired turtle target"
        end
    end
    return false,problem
end

local function sharedBase(t)
    if t.sharedFuelSlot then
        local d=turtle.getItemDetail(t.sharedFuelSlot)
        if d then
            if d.name~=COAL_BLOCK or d.count~=1 then
                recovery("Unexpected item in shared fuel buffer slot " .. t.sharedFuelSlot
                    .. "; stop other access to the inventory and remove that item before resuming")
            end
            if fuel()<limit() and fuel()~=math.huge then
                if not burn(t.sharedFuelSlot) then
                    waitFor("waiting_fuel","could not burn coal block in slot " .. t.sharedFuelSlot)
                end
                return
            end
            -- If fuel settings changed while stopped, treat the block as
            -- ordinary cargo rather than discarding it or overfilling.
        end
        t.sharedFuelSlot=nil
        return true
    end
    if t.stage=="orient" then
        if face(0) then return pop() end
        return
    end
    if t.need>limit() then
        if face(0) then fail("round trip needs " .. t.need .. " fuel but the fuel limit is " .. limit()) end
        return
    end
    if not t.final then
        carriedBlocks(t.need)
        carried(t.need)
    end
    -- Check horizontally mounted storage through the front, not through
    -- an upgrade side that can mask an adjacent peripheral. With a top
    -- inventory, face home-front so its wired dock is not masked either.
    if not faceSide(S.output=="top" and fuelDockSide(S.output) or S.output) then return end
    -- A block on its own does not establish a usable adjacent inventory.
    if not inventoryAt(S.output,true) then
        waitFor("waiting_output","no adjacent item inventory capability: " .. sideProbe(S.output))
        return
    end
    if t.stage=="validate_output" or t.stage=="validate_fuel" or t.stage=="invalid_base" then
        t.stage,t.problem="unload",nil
        return true
    end
    local hasCargo,transferError
    for i=1,16 do
        local n=turtle.getItemCount(i)
        if n>0 then
            hasCargo=true
            if not inventoryAt(S.output,true) then
                baseWait(t,"waiting_output","adjacent inventory capability disappeared; cargo retained; " .. sideProbe(S.output))
                return
            end
            local _,err=drop(S.output,i)
            if turtle.getItemCount(i)<n then return end
            transferError=err or "no cargo accepted"
        end
    end
    if hasCargo then
        local ok,err=sharedPull(t)
        if ok then return end
        baseWait(t,"waiting_output",transferError .. "; " .. err)
        return
    end
    if t.final or fuel()==math.huge or not roomForFuel(t) then t.stage="orient"; return true end
    if t.stage~="refuel" and t.stage~="waiting_fuel" then t.stage="refuel"; return true end
    local ok,err=sharedPull(t)
    if ok then return end
    if fuel()>=t.need then t.stage="orient"; return true end
    baseWait(t,"waiting_fuel",err)
end

-- Cleared geometry is persisted as integer cell records, not Lua closures.
local function get(c,x,z) return c.cells[K(x,z)] or 0 end
local function cellInfo(c,x,z)
    local n=get(c,x,z)
    if n <= 0 then fail("Expected a cleared route cell") end
    local v=math.floor(n/2)
    return math.floor(v/(side*side+1)), v%(side*side+1), n%2 == 1
end
local function mark(c,d,r)
    local p=S.pos
    local present,b=turtle.inspectDown()
    local candidate=not present or canDig(target("down",p),b.name)
    setCell(c,p.x,p.z,2*(d*(side*side+1)+r)+(candidate and 1 or 0))
    c.count, S.total=c.count+1,S.total+1
end
local function block(c,x,z)
    if get(c,x,z)==0 then setCell(c,x,z,-1); c.nblocked=c.nblocked+1 end
end
local function bfs(c,fx,fz,tx,tz,unknown)
    local start,goal=K(fx,fz),K(tx,tz)
    local q,seen,i={start},{[start]=start},1
    while i<=#q do
        local k=q[i]; i=i+1
        if k==goal then
            local path={}
            while true do
                local x,z=xz(k)
                path[#path+1]=point(x,c.y,z)
                if k==start then break end
                k=seen[k]
            end
            for a=1,math.floor(#path/2) do
                local b=#path-a+1; path[a],path[b]=path[b],path[a]
            end
            return path
        end
        local x,z=xz(k)
        for h=0,3 do
            local nx,nz=x+DX[h],z+DZ[h]
            if inBox(nx,nz) then
                local nextK,v=K(nx,nz),get(c,nx,nz)
                if not seen[nextK] and (v>0 or (unknown and v==0)) then
                    seen[nextK]=k; q[#q+1]=nextK
                end
            end
        end
    end
    return nil,seen
end
local function append(out,more,first)
    for i=first or 1,#more do out[#out+1]=more[i] end
    return out
end
local function reversed(path)
    local out={}
    for i=#path,1,-1 do out[#out+1]=path[i] end
    return out
end
local function routeFrom(c,x,z)
    local _,r=cellInfo(c,x,z)
    local region=c.regions[r]
    local path=bfs(c,x,z,region.entry.x,region.entry.z)
    if not path then fail("No cleared route to region entry") end
    return append(path,region.up)
end
local function routeHome()
    local p=S.pos
    return p.y==0 and {HOME} or routeFrom(S.cur,p.x,p.z)
end
local function homeCost()
    local p=S.pos
    if p.y==0 then return 0 end
    local d,r=cellInfo(S.cur,p.x,p.z)
    return d+#S.cur.regions[r].up
end
local function crossRoute(x,z)
    local p,c=S.pos,S.cur
    local _,r=cellInfo(c,p.x,p.z)
    local entry=c.regions[r].entry
    local a=bfs(c,p.x,p.z,entry.x,entry.z)
    local b=bfs(S.par,entry.x,entry.z,x,z)
    return a and b and append(a,b)
end
local function onArrive()
    local c,p=S.cur,S.pos
    if get(c,p.x,p.z)>0 then return end
    local best,r
    for h=0,3 do
        local x,z=p.x+DX[h],p.z+DZ[h]
        if inBox(x,z) and get(c,x,z)>0 then
            local d,region=cellInfo(c,x,z)
            if not best or d<best then best,r=d,region end
        end
    end
    if not best then fail("No cleared neighbour") end
    mark(c,best+1,r)
end
local function addRegion(up)
    local c,p=S.cur,S.pos
    local r=#c.regions+1
    c.regions[r]={entry=point(p.x,p.y,p.z),up=up}
    mark(c,0,r)
end
local function newLayer(up)
    S.layer=S.layer+1
    S.par=S.cur
    S.cur={y=-S.layer,cells={},regions={},count=0,nblocked=0,skipped=0}
    addRegion(up)
end
local function cellAt(i)
    local z=math.floor((i-1)/side)
    local col=(i-1)%side
    return z%2==0 and col or side-1-col,z
end

-- Each dispatch is either a logical transition (checkpoint on return), a
-- single journaled motion (checkpoint inside motion), or a retryable world
-- operation. No Lua call stack, loop index or stale transfer count is saved.
local function service(kind,why,extra)
    for _,t in ipairs(S.tasks) do if t.kind=="service" then fail("Recursive service trip") end end
    local path=routeHome()
    local h=math.max(#path-1,homeCost())
    return push("service",{stage="out",path=path,saved=S.pos,reason=why,
        transit=kind=="cargo" and "returning_to_unload" or "returning_to_refuel",
        need=math.max(2*h+2*S.progress+S.margin,h+(extra or 0))})
end
local function budget(need)
    reserve=need
    if fuel()>=need then return false end
    carried(math.min(limit(),need+S.progress))
    if fuel()>=need then return false end
    return service("fuel","fuel " .. fuel() .. " below reserve " .. need,need)
end
local function room()
    if cargoSpace() then return false end
    return service("cargo","no empty cargo slot")
end
local function pushWalk(path)
    return push("walk",{path=path,i=2})
end
local function pushMine(p, mode)
    return push("mine",{p=p,mode=mode})
end

handlers.walk = function(t)
    if t.moved then t.i=t.i+1; t.moved=nil; return true end
    local p=t.path[t.i]
    if not p then return pop() end
    if fuel()<#t.path-t.i+1 then fail("Insufficient fuel for remaining recorded travel; refuel in place before resuming") end
    local dir,h=direction(p)
    if h and not face(h) then return end
    local present,b=dirAPI("inspect",dir)()
    if present then
        if canDig(p,b.name) and cargoSpace() then
            local ok,why=dirAPI("dig",dir)()
            if not ok then waitFor("blocked","Route dig failed: " .. tostring(why)) end
        else waitFor("blocked","Route obstructed by " .. b.name .. " at " .. p.x .. "," .. p.y .. "," .. p.z) end
        return
    end
    local ok,why=motion(dir)
    if not ok then
        dirAPI("attack",dir)()
        waitFor("blocked","Route move failed: " .. tostring(why))
    end
end
handlers.mine = function(t)
    if t.moved then return pop(true) end
    -- Crossings pre-budget both the excursion and the safe return.
    local isolated = t.mode=="isolated"
    if not isolated and budget(homeCost()+2+S.margin) then return true end
    local dir,h=direction(t.p)
    if h and not face(h) then return end
    local present,b=dirAPI("inspect",dir)()
    if present then
        if not canDig(t.p,b.name) then return pop(false) end
        if isolated then
            if not cargoSpace() then return pop(nil) end
        elseif room() then return true end
        local ok=dirAPI("dig",dir)()
        if not ok then
            if t.mode=="below" then return pop(false) end
            local still=dirAPI("inspect",dir)()
            if still then return pop(false) end
        end
        -- Reinspect on the next dispatch, including after a successful dig
        -- or reboot. This also handles another gravity block falling in.
        return
    end
    if t.mode=="below" then return pop(true) end
    local ok,why=motion(dir)
    if not ok then
        dirAPI("attack",dir)()
        waitFor("blocked","Mining move failed: " .. tostring(why))
    end
end

handlers.base = function(t)
    if not same(S.pos,HOME) then fail("Base operation outside home") end
    if S.output==S.fuel then return sharedBase(t) end
    if t.stage=="invalid_base" then
        if not face(0) then return end
        local why=t.problem
        t.stage,t.problem="validate_output",nil
        checkpoint()
        fail(why)
    end
    if t.stage=="validate_output" or t.stage=="validate_fuel" then
        local output=t.stage=="validate_output"
        local which=output and S.output or S.fuel
        if not faceSide(which) then return end
        if not inventoryAt(which) then
            t.stage="invalid_base"
            t.problem="no " .. (output and "output" or "fuel") .. " inventory on " .. which .. " side of home; " .. sideProbe(which)
            return true
        end
        t.stage=output and "validate_fuel" or "unload"
        return true
    end
    if t.stage=="orient" then
        if face(0) then return pop() end
        return
    end
    if t.stage=="unload" or t.stage=="waiting_output" then
        if not t.final then carried(t.need) end
        local slot
        for i=1,16 do if turtle.getItemCount(i)>0 then slot=i; break end end
        if slot then
            if not faceSide(S.output) then return end
            local ok,why
            if inventoryAt(S.output) then ok,why=drop(S.output,slot)
            else why="output inventory missing; " .. sideProbe(S.output) end
            if not ok then
                baseWait(t,"waiting_output",why)
            end
            return
        end
        t.stage=(t.final or fuel()==math.huge) and "orient" or "refuel"
        return true
    end
    if t.need>limit() then
        if face(0) then fail("round trip needs " .. t.need .. " fuel but the fuel limit is " .. limit()) end
        return
    end
    if turtle.getItemCount(1)>0 then
        local d=turtle.getItemDetail(1)
        if d.name=="minecraft:coal_block" and fuel()<limit() and burn(1) then return end
        -- Keep wrong/leftover items, even if the output fills during refuel.
        if not faceSide(S.output) then return end
        local ok,why
        if inventoryAt(S.output) then ok,why=drop(S.output,1)
        else why="output inventory missing; " .. sideProbe(S.output) end
        if not ok then waitFor("waiting_output",why)
        elseif d.name~="minecraft:coal_block" then
            baseWait(t,"waiting_fuel","Fuel inventory must contain only coal blocks")
        end
        return
    end
    if fuel()>=limit() or (fuel()>=t.need and limit()-fuel()<fuelValues["minecraft:coal_block"]) then
        t.stage="orient"; return true
    end
    if not faceSide(S.fuel) then return end
    local sourceInventory=inventoryAt(S.fuel)
    if not sourceInventory then
        if fuel()>=t.need then t.stage="orient"; return true end
        baseWait(t,"waiting_fuel","fuel inventory missing; " .. sideProbe(S.fuel))
        return
    end
    turtle.select(1)
    local list=sourceInventory.list()
    local source=next(list)
    local ok,why=(S.fuel=="top" and turtle.suckUp or turtle.suck)(1)
    turtle.select(1)
    if ok and turtle.getItemCount(1)>0 then
        if t.stage=="waiting_fuel" then t.stage="refuel"; return true end
        return
    end
    if fuel()>=t.need then t.stage="orient"; return true end
    baseWait(t,"waiting_fuel",source and ("fuel transfer failed: " .. tostring(why)) or "fuel inventory empty")
end

handlers.service = function(t)
    if t.stage=="out" then t.stage="at_base"; return pushWalk(t.path) end
    if t.stage=="at_base" then t.stage="back"; return push("base",{stage="unload",need=t.need}) end
    if t.stage=="back" then
        if fuel()<t.need then return push("base",{stage="unload",need=t.need}) end
        t.stage="restore"; return pushWalk(reversed(t.path))
    end
    if not same(S.pos,t.saved) then fail("Did not return to saved work cell") end
    if not face(t.saved.h) then return end
    S.trips=S.trips+1
    pop()
    return true
end

handlers.sweep = function(t)
    local c,p=S.cur,S.pos
    if t.target then
        if result() then onArrive() else block(c,t.target.x,t.target.z) end
        t.target=nil
        return true
    end
    local i=t.i
    -- Scan in memory. Publish the cursor independently before any physical
    -- operation, but do not write a checkpoint for each already-known cell.
    while i<=side*side do
        local x,z=cellAt(i)
        if get(c,x,z)==0 and not t.unreached[K(x,z)] then
            local path,seen
            if math.abs(p.x-x)+math.abs(p.z-z)==1 then path={p,point(x,p.y,z)}
            else path,seen=bfs(c,p.x,p.z,x,z,true) end
            if path then
                t.i=i; t.target=path[2]
                return pushMine(t.target,"normal")
            end
            for j=i,side*side do
                local a,b=cellAt(j); local k=K(a,b)
                if get(c,a,b)==0 and not seen[k] then t.unreached[k]=true end
            end
        end
        i=i+1
    end
    return pop()
end
handlers.isolated = function(t)
    if t.stage=="plan" then
        local path=crossRoute(t.x,t.z)
        if not path then return pop(false) end
        if room() then return true end
        local up=routeFrom(S.par,t.x,t.z)
        if budget(math.max(2*(#path-1)+homeCost(),#path+#up+2)+S.margin) then return true end
        t.stage,t.path,t.up="down",path,up
        return pushWalk(path)
    end
    if t.stage=="down" then
        t.stage="land"
        return pushMine(point(t.x,S.cur.y,t.z),"isolated")
    end
    if t.stage=="land" then
        local r=result()
        if r then addRegion(t.up); return pop(true) end
        t.stage=r==nil and "retry" or "blocked"
        return pushWalk(reversed(t.path))
    end
    if t.stage=="retry" then t.stage="plan"; return true end
    block(S.cur,t.x,t.z)
    return pop(false)
end
handlers.layer = function(t)
    if t.stage=="sweep" then
        t.stage="find"
        return push("sweep",{i=1,unreached={}})
    end
    if t.stage=="island" then
        if result() then t.stage,t.i="sweep",1 else t.stage="find" end
        return true
    end
    if S.par then
        for i=t.i,side*side do
            local x,z=cellAt(i)
            if get(S.cur,x,z)==0 and get(S.par,x,z)>0 then
                t.stage,t.i="island",i+1
                return push("isolated",{stage="plan",x=x,z=z})
            end
        end
    end
    local c=S.cur
    c.skipped=side*side-c.count-c.nblocked
    if c.skipped>0 then print("Layer " .. S.layer .. ": " .. c.skipped .. " cells not yet reachable") end
    return pop()
end
handlers.gotoCell = function(t)
    local p=S.pos
    if p.x==t.x and p.z==t.z then return pop() end
    local _,a=cellInfo(S.cur,p.x,p.z)
    local d,b=cellInfo(S.cur,t.x,t.z)
    local path
    if a~=b then
        local r=S.cur.regions[b]
        path=crossRoute(r.entry.x,r.entry.z)
        if not path then fail("No cleared route between regions") end
        path[#path+1]=r.entry
        local tail=bfs(S.cur,r.entry.x,r.entry.z,t.x,t.z)
        if not tail then fail("No cleared route inside target region") end
        append(path,tail,2)
    else
        path=bfs(S.cur,p.x,p.z,t.x,t.z)
        if not path then fail("No cleared route within layer") end
    end
    if budget(#path-1+d+#S.cur.regions[b].up+2+S.margin) then return true end
    return pushWalk(path)
end
handlers.below = function(t)
    if not S.par then return pop() end
    if t.stage=="dig" then
        t.stage="done_cell"
        return pushMine(point(t.x,S.par.y,t.z),"below")
    end
    if t.stage=="done_cell" then
        if result() then setCell(S.par,t.x,t.z,-2); S.total=S.total+1 end
        t.stage="find"
    end
    for i=t.i,side*side do
        local x,z=cellAt(i)
        if get(S.par,x,z)==0 and get(S.cur,x,z)>0 then
            t.i,t.x,t.z,t.stage=i+1,x,z,"dig"
            return push("gotoCell",{x=x,z=z})
        end
    end
    return pop()
end
handlers.descend = function(t)
    local c=S.cur
    if t.stage=="dig" then
        t.up=routeFrom(c,t.x,t.z); t.stage="land"
        return pushMine(point(t.x,c.y-1,t.z),"normal")
    end
    if t.stage=="land" then
        if result() then newLayer(t.up); return pop(true) end
        setCell(c,t.x,t.z,get(c,t.x,t.z)-1)
        t.stage="find"; t.up=nil
    end
    local best,k
    for key,v in pairs(c.cells) do
        if v>0 and v%2==1 then
            local d,r=cellInfo(c,xz(key)); local cost=d+#c.regions[r].up
            if not best or cost<best or (cost==best and key<k) then best,k=cost,key end
        end
    end
    if not k then return pop(false) end
    t.x,t.z=xz(k); t.stage="dig"
    return push("gotoCell",{x=t.x,z=t.z})
end
handlers.job = function(t)
    if t.stage=="start" then
        t.stage="first"
        return push("base",{stage="validate_output",need=2*S.progress+S.margin})
    elseif t.stage=="first" then
        t.stage="first_land"
        return pushMine(point(0,-1,0),"normal")
    elseif t.stage=="first_land" then
        if not result() then fail("Cannot dig below home") end
        newLayer({HOME}); t.stage="layer"
        return true
    elseif t.stage=="layer" then
        t.stage="below"
        return push("layer",{stage="sweep",i=1})
    elseif t.stage=="below" then
        t.stage="descend"
        return push("below",{stage="find",i=1})
    elseif t.stage=="descend" then
        t.stage="next"
        return push("descend",{stage="find"})
    elseif t.stage=="next" then
        if result() then t.stage="layer"; return true end
        t.stage="final"
        return pushWalk(routeHome())
    elseif t.stage=="final" then
        t.stage="done"
        return push("base",{stage="unload",final=true,need=0})
    end
    if not same(S.pos,HOME) or S.pos.h~=0 then fail("Completion outside original home pose") end
    pop()
    S.done=true
    return true
end

local stages={
    job={start=true,first=true,first_land=true,layer=true,below=true,descend=true,next=true,final=true,done=true},
    base={validate_output=true,validate_fuel=true,invalid_base=true,unload=true,waiting_output=true,refuel=true,waiting_fuel=true,orient=true},
    service={out=true,at_base=true,back=true,restore=true},
    layer={sweep=true,find=true,island=true}, isolated={plan=true,down=true,land=true,retry=true,blocked=true},
    below={find=true,dig=true,done_cell=true}, descend={find=true,dig=true,land=true},
}
validTask=function(t,i)
    if type(t)~="table" or not handlers[t.kind] or (t.kind=="job")~=(i==1)
        or (stages[t.kind] and not stages[t.kind][t.stage])
        or (t.moved~=nil and (t.moved~=true or (t.kind~="walk" and t.kind~="mine")))
        or (t.sharedFuelSlot~=nil and (t.kind~="base" or not integer(t.sharedFuelSlot,1,16))) then return false end
    local k=t.kind
    if k=="walk" then return verifyRoute(t.path) and integer(t.i,2,#t.path+1) end
    if k=="mine" then return validPoint(t.p) and ({normal=true,isolated=true,below=true})[t.mode] end
    if k=="service" then return verifyRoute(t.path) and validPoint(t.saved,true)
        and same(t.path[1],t.saved) and same(t.path[#t.path],HOME) and type(t.reason)=="string"
        and (t.transit=="returning_to_unload" or t.transit=="returning_to_refuel")
        and integer(t.need,0,2^52) end
    if k=="base" then return integer(t.need,0,2^52) and (t.final==nil or t.final==true)
        and (t.stage~="invalid_base" or type(t.problem)=="string") end
    if k=="sweep" then return integer(t.i,1,side*side) and type(t.unreached)=="table"
        and (not t.target or validPoint(t.target)) end
    if k=="layer" then return integer(t.i,1,side*side+1) end
    if k=="below" and not integer(t.i,1,side*side+1) then return false end
    if k=="gotoCell" or k=="isolated" or ((k=="descend" or k=="below") and t.stage~="find") then
        if not integer(t.x,0,side-1) or not integer(t.z,0,side-1) then return false end
    end
    if k=="isolated" and t.stage~="plan" then return verifyRoute(t.path) and verifyRoute(t.up) end
    if k=="descend" and t.stage=="land" then return verifyRoute(t.up) end
    return true
end

local function reportPhase()
    local t=task()
    if t.kind=="base" then
        reserve=0
        if t.stage=="waiting_output" or t.stage=="waiting_fuel" then
            if status~=t.stage then announce(t.stage,"Retrying saved base operation") end
        elseif t.stage=="unload" then announce("unloading")
        elseif t.stage=="refuel" then announce("refueling","need " .. t.need)
        end
        return
    end
    for i=#S.tasks,1,-1 do
        local s=S.tasks[i]
        if s.kind=="service" then
            if t.kind=="walk" then
                local steps=t.i-2+(t.moved and 1 or 0)
                reserve=(s.stage=="restore" and steps or #t.path-1-steps)+S.margin
            end
            if s.stage=="at_base" or s.stage=="out" then announce(s.transit,s.reason)
            else announce("resuming","back to " .. describe(s.saved)) end
            return
        end
    end
    if S.tasks[1].stage=="final" then
        if t.kind=="walk" then reserve=#t.path-t.i+1-(t.moved and 1 or 0)+S.margin end
        announce("returning_home","finished at layer " .. S.layer)
    elseif S.layer>0 then announce("mining","layer " .. S.layer)
    else announce("starting","Preparing first layer") end
end

local function run()
    local mode=args[1]
    if not mode then
        print("Usage: chunk_dig <chunks> [job name] [north|east|south|west]")
        print("       chunk_dig resume | status | resolve <generation> <before|after> | migrate-shared")
        return
    end
    local loaded,r=pcall(readState)
    if not loaded then
        r=tostring(r)
        if r:sub(1,10)=="RECOVERY: " then fail(r) end
        recovery("Cannot validate saved state: " .. r)
    end
    if r then S,generation,side=r.job,r.seq,r.job.chunks*16 end
    if mode=="status" then
        if not S then print("No saved quarry job"); return end
        if not S.done then turtle.inspectDown() end
        print(("%s | generation %d | %s\nHome: %s\nSaved: %s"):format(S.name,generation,
            S.done and "completed" or table.concat((function()
                local names={}; for _,t in ipairs(S.tasks) do names[#names+1]=t.kind .. "/" .. (t.stage or "-") end
                return names
            end)()," > "),describe(S.home),describe(S.pos)))
        print("Base: output=" .. S.output .. ", fuel=" .. S.fuel)
        local j=actionRecord()
        if j and j.seq==generation then
            print(("Pending %s #%d\nBefore: %s\nAfter: %s"):format(j.op,j.seq,describe(j.before),describe(j.after)))
        elseif same(S.pos,HOME) then
            print("Output check (using saved heading): " .. sideProbe(S.output))
            local which=S.output==S.fuel and fuelDockSide(S.output) or S.fuel
            print((S.output==S.fuel and "Fuel dock check" or "Fuel check") .. " (using saved heading): " .. sideProbe(which))
        end
        return
    end
    if mode=="migrate-shared" then
        if not S or S.done then fail("Migration requires an active saved job") end
        if S.output~="back" or S.fuel~="top" then
            fail("Migration only changes a saved output=back, fuel=top job; run chunk_dig status")
        end
        if not same(S.pos,HOME) then
            fail("Migration requires a saved stop at original home; use the old setup until the turtle reaches base")
        end
        local j=actionRecord()
        if j and j.seq==generation then recovery("Resolve the pending action before migrating; run chunk_dig status") end
        reconcile() -- drain queued commands and verify GPS if configured; no motion
        verifiedPose=true
        if not inventoryAt("back",true) then
            fail("Migration not saved: no adjacent item inventory capability; " .. sideProbe("back"))
        end
        S.fuel,S.sharedMigration="back",generation
        checkpoint()
        print("Saved shared back/back configuration; run chunk_dig resume")
        return
    end
    if mode=="auto" or mode=="resume" or mode=="resolve" then
        if not S or S.done then
            if mode~="auto" then print(S and "Saved job is completed" or "No active quarry checkpoint") end
            return
        end
        turtle.select(1)
        local seq,choice
        if mode=="resolve" then
            seq,choice=tonumber(args[2]),args[3]
            if not integer(seq,1,2^52) or (choice~="before" and choice~="after") then
                fail("Usage: chunk_dig resolve <generation> <before|after>")
            end
        end
        announce("recovering","Validating generation " .. generation)
        reconcile(seq,choice)
        verifiedPose=true
        announce("resumed","Continuing saved " .. task().kind .. " step")
    else
        local chunks=tonumber(mode)
        if not integer(chunks,1,64) or (args[3] and cardinal[args[3]]==nil) then fail("Invalid quarry size or cardinal facing; run chunk_dig for usage") end
        if S then fail("A saved quarry exists; use resume, or archive " .. DIR .. " before starting a new job") end
        if not sides[OUTPUT_SIDE] or not sides[FUEL_SIDE] then fail("Invalid output or fuel side") end
        local anchor
        if args[3] then
            anchor=locate(2)
            if not anchor then fail("GPS home fix unavailable; no job created") end
            anchor.h=cardinal[args[3]]
        end
        local name=args[2] or os.getComputerLabel() or ("Quarry " .. os.getComputerID())
        if #name>200 then fail("Job name is too long") end
        turtle.select(1)
        S={owner=os.getComputerID(),created=os.epoch("utc"),chunks=chunks,name=name,output=OUTPUT_SIDE,fuel=FUEL_SIDE,
            margin=SAFETY_MARGIN,progress=MIN_PROGRESS,retry=RETRY_SECONDS,anchor=anchor,
            home=HOME,pos=HOME,layer=0,total=0,trips=0,done=false,lastFuel="none consumed yet",
            tasks={{kind="job",stage="start"}}}
        side,generation,verifiedPose=chunks*16,0,true
        fs.makeDir(DIR)
        checkpoint()
        announce("starting",side .. "x" .. side .. ", output " .. S.output .. ", fuel " .. S.fuel)
    end
    while not S.done do
        reportPhase()
        local t=task()
        if handlers[t.kind](t) then checkpoint() end
        telemetry()
    end
    reserve=0
    announce("complete",S.total .. " cells, " .. S.layer .. " layers, " .. S.trips .. " service trips")
    while true do sleep(3); telemetry(true) end
end

local ok,why=pcall(run)
if not ok then
    turtle.select(1)
    why=tostring(why)
    if pending then verifiedPose=false end
    local needRecovery=why:sub(1,10)=="RECOVERY: " or pending~=nil
    local state=needRecovery and "recovery_required" or (why=="Terminated" and "stopped" or "error")
    announce(state,why)
end
