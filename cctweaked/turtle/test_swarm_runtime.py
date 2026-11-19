"""Offline integration of the real Lua programs using simulated CC APIs."""
import unittest
from pathlib import Path

try:
    from lupa.lua52 import LuaRuntime
except ImportError:
    from lupa import LuaRuntime


HARNESS = r'''
local clock, jobs, inbox, files, dirs, robots, world, packets = 0, {}, {}, {}, {}, {}, {}, {}
local cuts, events = {}, {}
local inventories,docks,hosts={},{},{}
local cutPush,loseFinish,duplicateService,loseKind
local COORD=99
local function key(x,y,z) return x..","..y..","..z end
local function clone(x)
    if type(x)~="table" then return x end
    local t={}; for k,v in pairs(x) do t[k]=clone(v) end; return t
end
local function encode(x)
    if type(x)=="string" then return ("%q"):format(x) end
    if type(x)~="table" then return tostring(x) end
    local t={}
    for k,v in pairs(x) do t[#t+1]="["..encode(k).."]="..encode(v) end
    return "{"..table.concat(t,",").."}"
end
local function decode(x) return assert(load("return "..x,"test fixture","t",{}))() end
local function tick() coroutine.yield(clock+0.05) end
local v={[0]={0,-1},{1,0},{0,1},{-1,0}}
local function target(r,suffix)
    if suffix=="Up" then return key(r.x,r.y+1,r.z),r.x,r.y+1,r.z end
    if suffix=="Down" then return key(r.x,r.y-1,r.z),r.x,r.y-1,r.z end
    local d=v[r.h]
    return key(r.x+d[1],r.y,r.z+d[2]),r.x+d[1],r.y,r.z+d[2]
end
local function at(p,exclude)
    for id,r in pairs(robots) do if id~=exclude and key(r.x,r.y,r.z)==p then return true end end
end
local function env(id,program)
    local f,d,r=files[id],dirs[id],robots[id]
    local e=setmetatable({},{__index=_G})
    e._G=e
    e.fs={
        combine=function(a,b) return (a=="/" and "" or a).."/"..b end,
        getDir=function() return "/" end,
        exists=function(p) return f[p]~=nil or d[p]~=nil end,
        isDir=function(p) return d[p]~=nil end,
        makeDir=function(p) d[p]=true end,
        delete=function(p)
            f[p],d[p]=nil,nil
            for a in pairs(f) do if a:sub(1,#p+1)==p.."/" then f[a]=nil end end
        end,
        move=function(a,b) assert(f[a] and not f[b]); f[b],f[a]=f[a],nil end,
        list=function(p)
            local t={}
            for a in pairs(f) do
                if a:sub(1,#p+1)==p.."/" then t[#t+1]=a:sub(#p+2) end
            end
            return t
        end,
        open=function(p,mode)
            if mode=="r" and not f[p] then return nil,"file not found: "..p end
            return {readAll=function() return f[p] end,write=function(s) f[p]=s end,close=function() end}
        end
    }
    e.shell={getRunningProgram=function() return program end}
    e.loadfile=function(p) return load(assert(SOURCES[p],p),p,"t",e) end
    e.textutils={serialize=encode,unserialize=decode,unserializeJSON=decode}
    e.os={clock=function() return clock end,getComputerLabel=function() return "Test "..id end,
        getComputerID=function() return id end}
    e.sleep=function(n) coroutine.yield(clock+n) end
    e.print=function() end
    e.peripheral={find=function() return {isWireless=function() return true end} end,
        getName=function() return "right" end,
        hasType=function(side,kind)
            if not r or kind~="inventory" then return false end
            if side=="back" then
                local d=v[(r.h+2)%4]
                return inventories[key(r.x+d[1],r.y,r.z+d[2])]~=nil
            end
            return inventories[target(r,side=="top" and "Up" or "")]~=nil
        end,
        wrap=function(side)
            local dock=r and side=="top" and docks[target(r,"Up")]
            if not dock or not dock.online then return end
            return {
                isWireless=function() return false end,
                getNameLocal=function() return "turtle_"..id end,
                getNamesRemote=function() return {"keepalive","shared_storage",dock.ambiguous and "other_storage" or nil} end,
                getMethodsRemote=function(name)
                    if name=="keepalive" then return {"turnOn"} end
                    return {"list","getItemDetail","pushItems"}
                end,
                callRemote=function(name,method,a,from,n,into)
                    assert(name=="shared_storage")
                    local inv=dock.storage
                    if method=="list" then return clone(inv.items) end
                    if method=="getItemDetail" then return clone(inv.items[a]) end
                    assert(method=="pushItems" and a=="turtle_"..id and n==1 and not r.items[into])
                    local d=assert(inv.items[from])
                    assert(d.name=="minecraft:coal_block","attempted extraction from a cargo slot")
                    inv.attempts=inv.attempts or {}; inv.attempts[#inv.attempts+1]=from
                    if inv.blocked and inv.blocked[from] then return 0 end
                    d.count=d.count-1
                    r.items[into]={name=inv.wrongItem or d.name,count=1}
                    if d.count==0 then inv.items[from]=nil end
                    inv.taken=(inv.taken or 0)+1
                    if inv.fullWhenCoal and d.count==0 then inv.full=false end
                    if cutPush==id then cutPush=nil; coroutine.yield(math.huge,false,"cut") end
                    tick(); return 1
                end
            }
        end}
    e.rednet={
        open=function() end,
        host=function(protocol,name) hosts[#hosts+1]={id=id,protocol=protocol,name=name} end,
        lookup=function(protocol)
            local found,seen={},{}
            for _,h in ipairs(hosts) do
                if h.protocol==protocol and jobs[h.id] and not seen[h.id] then
                    seen[h.id]=true; found[#found+1]=h.id
                end
            end
            return table.unpack(found)
        end,
        send=function(dest,msg,protocol)
            if loseFinish==dest and msg.kind=="finish" and id==COORD then
                loseFinish=nil; return true
            end
            if loseKind and msg.kind==loseKind and id==COORD then
                loseKind=nil; return true
            end
            local pending=inbox[dest]
            pending[#pending+1]={sender=id,msg=clone(msg),protocol=protocol}
            if id==duplicateService and msg.kind=="service" then
                pending[#pending+1]=clone(pending[#pending]); duplicateService=nil
            end
            if jobs[dest] and jobs[dest].listening then jobs[dest].wake=clock end
            return true
        end,
        receive=function(protocol,timeout)
            local due=timeout and clock+timeout or math.huge
            while true do
                local m=table.remove(inbox[id],1)
                if m and m.protocol==protocol then return m.sender,m.msg,m.protocol end
                if clock>=due then return end
                if not m then coroutine.yield(due,true) end
            end
        end,
        broadcast=function(msg)
            packets[#packets+1]={time=clock,id=id,msg=clone(msg)}
        end
    }
    if r then
        e.gps={locate=function() return r.x,r.y,r.z end}
        e.turtle={
            getFuelLevel=function() return r.fuel end,
            getFuelLimit=function() return r.fuel=="unlimited" and "unlimited" or (r.cap or 1000) end,
            getItemCount=function(i)
                local d=r.items[i or r.slot]; return d and d.count or 0
            end,
            getItemDetail=function(i) return clone(r.items[i or r.slot]) end,
            getItemSpace=function(i) return 64-(r.items[i] and r.items[i].count or 0) end,
            select=function(i) r.slot=i; return true end,
            transferTo=function(i)
                local a,b=r.items[i],r.items[r.slot]
                if not a or not b or a.name~=b.name then return false end
                local n=math.min(64-a.count,b.count)
                a.count,b.count=a.count+n,b.count-n
                if b.count==0 then r.items[r.slot]=nil end
                tick(); return n>0
            end,
            drop=function()
                local inv=assert(inventories[target(r,"")])
                if inv.full then return false,"No space for items" end
                local d=assert(r.items[r.slot])
                local n=math.min(inv.partial or d.count,d.count)
                local i=1; while inv.items[i] do i=i+1 end
                inv.items[i]={name=d.name,count=n}
                d.count=d.count-n
                if d.count==0 then r.items[r.slot]=nil end
                tick(); return true
            end,
            suckUp=function() error("indiscriminate extraction must not be used") end,
            refuel=function(n)
                local d=r.items[r.slot]
                local value=d and ({["minecraft:coal_block"]=800,["minecraft:coal"]=80,["minecraft:charcoal"]=80})[d.name]
                if not value then return false end
                d.count=d.count-n; r.fuel=math.min(r.cap or 1000,r.fuel+value*n)
                events[#events+1]={op="burn",id=id,name=d.name}
                if d.count==0 then r.items[r.slot]=nil end
                tick(); return true
            end,
            turnLeft=function() r.h=(r.h+3)%4; r.turns=r.turns+1; tick(); return true end,
            turnRight=function() r.h=(r.h+1)%4; r.turns=r.turns+1; tick(); return true end
        }
        for _,suffix in ipairs({"","Up","Down"}) do
            e.turtle["inspect"..suffix]=function()
                local p=target(r,suffix)
                if at(p,id) then return true,{name="computercraft:turtle_advanced"} end
                if world[p] then return true,{name=world[p]} end
                return false,"No block"
            end
            e.turtle["dig"..suffix]=function()
                local p=target(r,suffix)
                assert(not at(p,id),"attempted to dig another turtle")
                if not world[p] then return false end
                world[p]=nil; r.digs=r.digs+1; events[#events+1]={op="dig",id=id,p=p}; tick()
                return true
            end
            e.turtle[suffix=="" and "forward" or suffix:lower()]=function()
                local p,x,y,z=target(r,suffix)
                if world[p] or at(p,id) then return false end
                r.x,r.y,r.z=x,y,z
                if r.fuel~="unlimited" then r.fuel=r.fuel-1; assert(r.fuel>=0) end
                r.moves=r.moves+1; events[#events+1]={op="move",id=id,p=p}
                if cuts[id]==p then cuts[id]=nil; coroutine.yield(math.huge,false,"cut") end
                tick(); return true
            end
        end
    end
    return e
end
local function launch(id,program,...)
    local e=env(id,program)
    local fn=assert(load(SOURCES[program],program,"t",e))
    local co=coroutine.create(fn)
    jobs[id]={co=co,args={...},wake=clock}
end
local function drive(untilFn,limit)
    for _=1,limit or 30000 do
        if untilFn() then return end
        local id,nextJob
        for a,j in pairs(jobs) do
            if j.wake<math.huge and (not nextJob or j.wake<nextJob.wake
                or (j.wake==nextJob.wake and a<id)) then id,nextJob=a,j end
        end
        assert(nextJob,"simulation stalled")
        clock=math.max(clock,nextJob.wake)
        local ok,wake,listening,cut=coroutine.resume(nextJob.co,table.unpack(nextJob.args or {}))
        assert(ok,tostring(id)..": "..tostring(wake))
        nextJob.args=nil
        if coroutine.status(nextJob.co)=="dead" then jobs[id]=nil
        else nextJob.wake,nextJob.listening,nextJob.cut=wake,listening,cut end
    end
    error("simulation did not reach expected outcome")
end
local worker="/chunk_dig_swarm.lua"
local coordinator="/swarm_coordinator.lua"
local function ledger(id,dir)
    local latest,n=nil,0
    for p,data in pairs(files[id]) do
        local g=tonumber(p:match("^/"..dir.."/state%-(%d+)$"))
        if g and g>n then latest,n=data,g end
    end
    return latest and decode(assert(latest:match("\n(.*)$")))
end
local function snapshot(id) return ledger(id,"%.chunk_dig_swarm") end
local function queue() return ledger(COORD,"%.chunk_dig_swarm_coordinator") end
local function setup(stage,work,station,approach)
    local c={quarryId="test",manifestId="immutable",dimension="overworld",staging=stage,
        clearApproach=approach or stage,work=work,patchSize=1,margin=1,allowAnyWorker=true,station=station}
    files[COORD],dirs[COORD],inbox[COORD]={["/swarm_coordinator.json"]=encode(c)},{},{}
    for _,p in ipairs(work) do world[p]="minecraft:stone" end
    launch(COORD,coordinator,"init")
    drive(function() return jobs[COORD]==nil end)
    launch(COORD,coordinator,"run")
end
local function robot(id,x,y,z,off,shared)
    robots[id]={x=x,y=y,z=z,h=0,fuel=id==2 and "unlimited" or 100,digs=0,moves=0,turns=0,items={},slot=1}
    local c={quarryId="test",manifestId="immutable",dimension="overworld",
        staging=key(x,y,z),facing="north",coordinator=COORD,sharedStation=shared}
    files[id],dirs[id],inbox[id]={["/chunk_dig_swarm.json"]=encode(c)},{},{}
    if not off then launch(id,worker,"start") end
end
local function finished(p)
    local s=queue()
    for _,coord in ipairs(p) do if s.work[coord]~="clear" then return false end end
    return next(s.active)==nil
end

function late_join_and_reboot()
    local a,b="0,-1,0","1,-1,0"
    setup({"0,0,0","1,0,0"},{a,b})
    robot(1,0,0,0)
    cuts[1]=a
    drive(function() return jobs[1] and jobs[1].cut end)
    local snap=snapshot(1)
    assert(snap.motion.to==a and queue().active[1].id==snap.grant.id)
    robot(2,1,0,0)
    launch(COORD,coordinator,"run") -- discard program memory, retain files
    drive(function() return queue().work[b]=="clear" end)
    assert(queue().active[1].id==snap.grant.id and not world[b])
    inbox[1]={}
    launch(1,worker,"resume")
    drive(function() return finished({a,b}) end)
    assert(robots[1].moves==2 and robots[1].digs==1)
    assert(robots[2].moves==2 and robots[2].digs==1)
    assert(robots[1].y==0 and robots[2].y==0)
end

function turtle_waits_without_advancing(dy,dz,dir)
    local a=key(0,dy,dz)
    setup({"0,0,0"},{a})
    robot(1,0,0,0)
    robot(2,0,dy,dz,true)
    world[a]=nil
    drive(function()
        for _,p in ipairs(packets) do
            if p.msg.status=="waiting_turtle" and p.msg.swarm.waitingReason=="turtle_"..dir then return true end
        end
    end)
    local start=clock
    local before=snapshot(1)
    drive(function() return clock>=start+65 end)
    assert(robots[1].moves==0 and robots[1].turns==0 and robots[1].digs==0)
    assert(snapshot(1).seq==before.seq and not snapshot(1).motion and not snapshot(1).outcomes[a])
    robots[2]=nil
    drive(function() return finished({a}) end)
    assert(clock>=start+120 and robots[1].moves==2)
end

function reboot_without_coordinator_holds_position()
    local a="0,-1,0"
    setup({"0,0,0"},{a})
    robot(1,0,0,0)
    cuts[1]=a
    drive(function() return jobs[1] and jobs[1].cut end)
    jobs[COORD]=nil
    inbox[1]={}
    launch(1,worker,"resume")
    local start=clock
    drive(function() return clock>start+11 end)
    assert(robots[1].y==-1 and robots[1].moves==1 and queue().active[1])
    launch(COORD,coordinator,"run")
    drive(function() return finished({a}) end)
end

function transit_does_not_redig_verified_cells()
    local upper,lower="0,-1,0","0,-2,0"
    setup({"0,0,0"},{upper,lower})
    robot(1,0,0,0)
    drive(function() return finished({upper,lower}) end)
    assert(robots[1].digs==2 and robots[1].moves==6)
    local dug={}
    for _,e in ipairs(events) do
        if e.op=="dig" then assert(not dug[e.p]); dug[e.p]=true end
    end
    assert(dug[upper] and dug[lower] and robots[1].y==0)
end

local function stationFixture()
    local a,b,hub,bay="0,0,0","2,0,0","1,0,0","1,0,1"
    local out,top="1,0,2","1,1,1"
    local work={"0,-1,0","2,-1,0"}
    setup({a,b},work,{bay=bay,facing="south",fuelTarget=900,
        routes={[a]={a,hub,bay},[b]={b,hub,bay}}},{a,b,hub,bay})
    world[out],world[top]="minecraft:barrel","computercraft:wired_modem_full"
    inventories[out]={items={[1]={name="minecraft:stone",count=8},[5]={name="minecraft:coal_block",count=4}}}
    docks[top]={online=true,storage=inventories[out]}
    robot(1,0,0,0,true,true)
    robot(2,2,0,0,true,true)
    for _,id in ipairs({1,2}) do
        robots[id].fuel=150
        robots[id].items[16]={name="minecraft:cobblestone",count=id}
    end
    return work,bay,hub,inventories[out],docks[top]
end

local function stock(inv,name)
    local n=0
    for _,d in pairs(inv.items) do if d.name==name then n=n+d.count end end
    return n
end

function station_contention_and_recovery()
    local work,bay,hub,out=stationFixture()
    cutPush,duplicateService=1,1
    launch(1,worker,"start")
    launch(2,worker,"start")
    drive(function() return jobs[1].cut and queue().replay[2] and queue().replay[2].reason=="station_busy" end)
    local g=queue().active[1]
    assert(g.station and #g.cells==0 and at(bay) and robots[2].moves==0)
    assert(snapshot(1).stationFuelSlot and out.taken==1 and stock(out,"minecraft:cobblestone")==1)
    jobs[COORD],inbox[COORD]=nil,{}
    launch(1,worker,"resume")
    local begin=clock
    drive(function() return clock>begin+12 end)
    assert(queue().active[1].id==g.id and out.taken==1 and robots[2].moves==0)
    launch(COORD,coordinator,"run")
    loseFinish=1
    drive(function() return finished(work) and not snapshot(1).grant and not snapshot(2).grant end)
    assert(stock(out,"minecraft:cobblestone")==3 and stock(out,"minecraft:stone")==8
        and out.taken==2 and robots[1].fuel>=900 and robots[2].fuel>=900)
    local bayMoves={}
    for _,e in ipairs(events) do
        if e.op=="move" and e.p==bay then bayMoves[#bayMoves+1]=e.id end
    end
    assert(#bayMoves==2 and bayMoves[1]==1 and bayMoves[2]==2)
end

local function saw(id,reason)
    for _,p in ipairs(packets) do if p.id==id and p.msg.swarm.waitingReason==reason then return true end end
end

function station_waits_for_supplies_and_clear_route()
    local work,bay,hub,out,dock=stationFixture()
    local coal=out.items[5]
    out.items[5]=nil
    out.full=true
    robot(3,1,0,0,true)
    launch(1,worker,"start")
    drive(function() return saw(1,"turtle_front") end)
    local start=clock
    drive(function() return clock>start+62 end)
    assert(robots[1].moves==0 and robots[1].digs==0 and queue().active[1].station)
    robots[3]=nil
    drive(function() return saw(1,"station_output_full") end)
    assert(at(bay) and robots[1].items[16].count==1 and not out.taken)
    out.full=false
    dock.online=false
    drive(function() return saw(1,"station_dock_missing") end)
    assert(stock(out,"minecraft:cobblestone")==1 and not out.taken)
    dock.online=true; dock.ambiguous=true
    drive(function() return saw(1,"station_dock_ambiguous") end)
    dock.ambiguous=false
    drive(function() return saw(1,"station_fuel_empty") end)
    assert(at(bay) and stock(out,"minecraft:stone")==8 and not out.taken and queue().active[1].station)
    out.items[5]=coal
    drive(function() return queue().work[work[1]]=="clear" and not queue().active[1] end)
    assert(out.taken==1 and not at(bay) and robots[1].h==0)
end

function station_requires_round_trip_fuel()
    local _,bay,_,out=stationFixture()
    robots[1].fuel=4
    launch(1,worker,"start")
    drive(function() return saw(1,"station_fuel_reserve") end)
    assert(robots[1].moves==0 and not queue().active[1] and not at(bay) and not out.taken)
    robots[1].fuel=150
    drive(function() return out.taken==1 end)
end

function station_frees_space_with_selective_fuel()
    local work,_,_,out=stationFixture()
    out.full,out.fullWhenCoal,out.partial=true,true,1
    out.items[6]={name="minecraft:coal_block",count=1}
    out.items[7]={name="minecraft:coal_block",count=1}
    out.blocked={[6]=true}
    for i=1,16 do robots[1].items[i]={name="minecraft:cobblestone",count=2} end
    launch(1,worker,"start")
    drive(function() return queue().work[work[1]]=="clear" and not queue().active[1] end)
    assert(out.taken==1 and #out.attempts==2 and out.attempts[1]==6 and out.attempts[2]==7)
    assert(stock(out,"minecraft:cobblestone")==32 and stock(out,"minecraft:stone")==8)
    assert(robots[1].slot==1 and robots[1].fuel>=900)
end

function station_prefers_carried_coal_blocks_and_unloads_surplus()
    local work,_,_,out=stationFixture()
    robots[1].items[1]={name="minecraft:coal",count=3}
    robots[1].items[15]={name="minecraft:coal_block",count=2}
    launch(1,worker,"start")
    drive(function() return queue().work[work[1]]=="clear" and not queue().active[1] end)
    local burns=0
    for _,e in ipairs(events) do
        if e.op=="burn" then assert(e.name=="minecraft:coal_block"); burns=burns+1 end
    end
    assert(burns==1 and not out.taken)
    assert(stock(out,"minecraft:coal")==3 and stock(out,"minecraft:coal_block")==5)
end

function station_stops_on_unexpected_delivery()
    local _,bay,_,out=stationFixture()
    out.wrongItem="minecraft:granite"
    launch(1,worker,"start")
    local ok,why=pcall(drive,function() return false end)
    assert(not ok and tostring(why):find("Unexpected item in station fuel slot",1,true),tostring(why))
    local slot=snapshot(1).stationFuelSlot
    assert(at(bay) and slot and robots[1].items[slot].name=="minecraft:granite" and queue().active[1].station)
    assert(out.taken==1 and robots[1].fuel<150 and stock(out,"minecraft:granite")==0)
end

-- Zero-config fixture: bay 0,0,0; the first turtle faces north, so the quarry
-- is x=0..15, z=-15..0 below the bay. Barrel behind (south), wired dock above.
local BAY,BARREL,DOCK="0,0,0","0,0,1","0,1,0"
local function autoFixture(bottom)
    files[COORD],dirs[COORD],inbox[COORD]={},{},{}
    launch(COORD,coordinator)
    drive(function() return #hosts>0 end)
    world[BARREL],world[DOCK]="minecraft:barrel","computercraft:wired_modem_full"
    inventories[BARREL]={items={[1]={name="minecraft:coal_block",count=64}}}
    docks[DOCK]={online=true,storage=inventories[BARREL]}
    for x=0,15 do for z=-15,0 do for y=bottom,-1 do world[key(x,y,z)]="minecraft:stone" end end end
end
local function place(id,h,fuel)
    assert(not at(BAY),"bay occupied")
    robots[id]={x=0,y=0,z=0,h=h,fuel=fuel,digs=0,moves=0,turns=0,items={},slot=1}
    files[id],dirs[id],inbox[id]={},{},{}
end
local function noConfigFiles()
    for id,f in pairs(files) do
        for p in pairs(f) do assert(not p:find("%.json$"),"config file "..p.." on "..id) end
    end
end
local function staged()
    local n=0
    for _ in pairs(queue().staging) do n=n+1 end
    return n
end
local function bayFree()
    if at(BAY) then return false end
    for _,g in pairs(queue().active) do for _,p in ipairs(g.route) do if p==BAY then return false end end end
    return true
end
local function parkedAt(id,p)
    local snap=snapshot(id)
    return snap and not dirs[id]["/.chunk_dig_swarm_setup"] and not snap.grant
        and key(robots[id].x,robots[id].y,robots[id].z)==p and snap.stage==p
end
local function joinWhenFree(id,h)
    drive(function() return bayFree() and staged()>=id end,60000)
    place(id,h,0)
    launch(id,worker)
end

function auto_define_join_and_finish_layer()
    autoFixture(-1)
    place(1,0,0)
    launch(1,worker,"new","1","-1")
    drive(function() return snapshot(1) and staged()>=3 end,60000)
    local q=queue()
    assert(q.auto.definer==1 and q.auto.heading==0 and q.station.facing=="south")
    assert(q.box.x0==0 and q.box.x1==15 and q.box.z0==-15 and q.box.z1==0 and q.box.y0==-1)
    assert(q.parked[1]=="0,-1,-1" and inventories[BARREL].taken>=1)
    assert(not dirs[1]["/.chunk_dig_swarm_setup"])
    assert(files[1]["/startup.lua"]:find('shell.execute("/chunk_dig_swarm","auto")',1,true))
    -- Probe moved straight down and forward without turning.
    local first={}
    for _,e in ipairs(events) do if e.id==1 and e.op=="move" then first[#first+1]=e.p end end
    assert(first[1]=="0,-1,0" and first[2]=="0,-1,-1")
    -- Turtle 2 is placed facing east, with no fuel; it finds the barrel itself.
    joinWhenFree(2,1)
    drive(function() return parkedAt(2,"1,-1,-1") end,60000)
    assert(robots[2].h==0 and queue().parked[2]=="1,-1,-1")
    -- Turtle 3 faces west.
    joinWhenFree(3,3)
    drive(function() return parkedAt(3,"2,-1,-1") end,60000)
    drive(function()
        local s=queue()
        return s.layers[-1]=="c" and next(s.active)==nil
    end,400000)
    for x=0,15 do for z=-15,0 do assert(not world[key(x,-1,z)],"left stone at "..key(x,-1,z)) end end
    local dug={}
    for _,e in ipairs(events) do
        if e.op=="dig" then assert(not dug[e.p],"dug twice "..e.p); dug[e.p]=true end
    end
    for id=1,3 do assert(robots[id].y==-1 and robots[id].z==-1,"turtle "..id.." not parked") end
    noConfigFiles()
end

function auto_define_survives_reboot_and_lost_reply()
    autoFixture(-2)
    place(1,0,500)
    files[1]["/startup.lua"]='shell.execute("/chunk_dig", "auto")\n'
    cuts[1]="0,-1,0"
    launch(1,worker,"new","1","-2")
    drive(function() return jobs[1].cut end)
    assert(dirs[1]["/.chunk_dig_swarm_setup"] and not dirs[1]["/.chunk_dig_swarm"] and not queue())
    -- Power returns: coordinator restarts first, the define reply is lost once.
    launch(COORD,coordinator)
    loseKind="define"
    inbox[1]={}
    launch(1,worker,"auto")
    drive(function() return snapshot(1) and not dirs[1]["/.chunk_dig_swarm_setup"] end)
    assert(loseKind==nil and queue().auto.definer==1 and queue().parked[1]=="0,-1,-1")
    assert(robots[1].moves==2 and robots[1].turns==0)
    -- Existing startup logic is kept, and the hook is appended once.
    local start=files[1]["/startup.lua"]
    assert(start:sub(1,36)=='shell.execute("/chunk_dig", "auto")\n',start)
    assert(files[1]["/startup.lua.before_swarm"]=='shell.execute("/chunk_dig", "auto")\n')
    -- Running "new" again cannot start a second quarry or redefine home.
    jobs[1]=nil
    launch(1,worker,"new","1","-2")
    local ok,why=pcall(drive,function() return jobs[1]==nil end)
    assert(not ok and tostring(why):find("Saved swarm state exists",1,true),tostring(why))
    noConfigFiles()
end

function auto_join_recovers_mid_route()
    autoFixture(-1)
    place(1,0,0)
    launch(1,worker,"new","1","-1")
    drive(function() return snapshot(1) and staged()>=2 end,60000)
    drive(function() return bayFree() end,60000)
    place(2,2,0)
    cuts[2]="1,-1,0" -- second lane cell, after servicing in the bay
    launch(2,worker)
    drive(function() return jobs[2].cut end,60000)
    local snap=snapshot(2)
    assert(snap.grant.relocate and snap.stationComplete and snap.stage=="1,-1,-1")
    local taken=inventories[BARREL].taken
    jobs[COORD],inbox[COORD]=nil,{}
    inbox[2]={}
    launch(2,worker,"auto")
    local start=clock
    drive(function() return clock>start+10 end)
    -- Without the coordinator it cannot verify the grant, so it holds still.
    assert(robots[2].x==1 and robots[2].z==0 and queue().active[2])
    launch(COORD,coordinator)
    drive(function() return parkedAt(2,"1,-1,-1") end,60000)
    assert(inventories[BARREL].taken>=taken and robots[2].h==0 and robots[2].fuel>=900)
end

function coordinator_startup_hook_preserves_existing_startup()
    multishell={}
    files[COORD],dirs[COORD],inbox[COORD]={["/startup.lua"]='shell.run("turtle_wireless_dash")\n'},{},{}
    launch(COORD,coordinator)
    drive(function() return #hosts>0 end)
    multishell=nil
    local start=files[COORD]["/startup.lua"]
    assert(start=='if multishell then shell.openTab("/swarm_coordinator") end\nshell.run("turtle_wireless_dash")\n',start)
    assert(files[COORD]["/startup.lua.before_swarm"]=='shell.run("turtle_wireless_dash")\n')
    launch(COORD,coordinator)
    multishell={}
    drive(function() return #hosts>1 end)
    multishell=nil
    assert(files[COORD]["/startup.lua"]==start,"hook added twice")
end

function auto_join_before_define_is_refused()
    autoFixture(-1)
    place(5,1,0)
    launch(5,worker)
    local ok,why=pcall(drive,function() return jobs[5]==nil end)
    assert(not ok and tostring(why):find("No quarry defined yet",1,true),tostring(why))
    assert(not dirs[5]["/.chunk_dig_swarm_setup"] and not dirs[5]["/.chunk_dig_swarm"] and robots[5].moves==0)
end
'''


class SwarmRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime()
        source = {
            "/" + name: (Path(__file__).parent / name).read_text()
            for name in ("chunk_dig_swarm.lua", "swarm_common.lua",
                         "swarm_coordinator.lua", "swarm_patch_queue.lua")
        }
        self.lua.globals().SOURCES = self.lua.table_from(source)
        self.lua.execute(HARNESS)

    def test_late_joiner_during_worker_power_cut_and_coordinator_restart(self):
        self.lua.globals().late_join_and_reboot()

    def test_worker_waits_two_full_collision_cycles_down(self):
        self.lua.globals().turtle_waits_without_advancing(-1, 0, "down")

    def test_worker_waits_two_full_collision_cycles_up(self):
        self.lua.globals().turtle_waits_without_advancing(1, 0, "up")

    def test_worker_waits_two_full_collision_cycles_in_front(self):
        self.lua.globals().turtle_waits_without_advancing(0, -1, "front")

    def test_reboot_without_coordinator_holds_position(self):
        self.lua.globals().reboot_without_coordinator_holds_position()

    def test_verified_cells_are_transit_only_on_the_next_patch(self):
        self.lua.globals().transit_does_not_redig_verified_cells()

    def test_shared_station_serializes_recovery_and_replayed_packets(self):
        self.lua.globals().station_contention_and_recovery()

    def test_shared_station_holds_on_blocked_route_and_inventory_failures(self):
        self.lua.globals().station_waits_for_supplies_and_clear_route()

    def test_shared_station_requires_round_trip_fuel(self):
        self.lua.globals().station_requires_round_trip_fuel()

    def test_shared_station_makes_room_in_full_barrel_and_full_turtle(self):
        self.lua.globals().station_frees_space_with_selective_fuel()

    def test_shared_station_prefers_carried_coal_blocks_and_unloads_surplus(self):
        self.lua.globals().station_prefers_carried_coal_blocks_and_unloads_surplus()

    def test_shared_station_stops_on_unexpected_fuel_delivery(self):
        self.lua.globals().station_stops_on_unexpected_delivery()

    def test_zero_config_define_join_and_finish_layer(self):
        self.lua.globals().auto_define_join_and_finish_layer()

    def test_zero_config_define_survives_reboot_and_lost_reply(self):
        self.lua.globals().auto_define_survives_reboot_and_lost_reply()

    def test_zero_config_join_recovers_mid_route(self):
        self.lua.globals().auto_join_recovers_mid_route()

    def test_coordinator_startup_hook_preserves_existing_startup(self):
        self.lua.globals().coordinator_startup_hook_preserves_existing_startup()

    def test_zero_config_join_before_define_is_refused(self):
        self.lua.globals().auto_join_before_define_is_refused()


if __name__ == "__main__":
    unittest.main(verbosity=2)
