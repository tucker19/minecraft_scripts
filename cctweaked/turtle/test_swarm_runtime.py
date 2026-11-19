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
local inventories={}
local cutSuck,loseFinish,duplicateService
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
        delete=function(p) f[p]=nil end,
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
            return r and kind=="inventory" and inventories[target(r,side=="top" and "Up" or "")]~=nil
        end,
        call=function(side,method)
            assert(side=="top" and method=="list")
            return clone(inventories[target(r,"Up")].items)
        end}
    e.rednet={
        open=function() end,
        send=function(dest,msg,protocol)
            if loseFinish==dest and msg.kind=="finish" and id==COORD then
                loseFinish=nil; return true
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
            getFuelLimit=function() return r.fuel=="unlimited" and "unlimited" or 1000 end,
            getItemCount=function(i)
                local d=r.items[i or r.slot]; return d and d.count or 0
            end,
            getItemDetail=function(i) return clone(r.items[i or r.slot]) end,
            select=function(i) r.slot=i; return true end,
            drop=function()
                local inv=assert(inventories[target(r,"")])
                if inv.full then return false end
                local d=assert(r.items[r.slot])
                inv.items[#inv.items+1]=d; r.items[r.slot]=nil; tick(); return true
            end,
            suckUp=function(n)
                local inv=assert(inventories[target(r,"Up")])
                local d=inv.items[1]
                if not d then return false end
                assert(n==1 and not r.items[r.slot])
                d.count=d.count-1; r.items[r.slot]={name=d.name,count=1}
                if d.count==0 then inv.items[1]=nil end
                inv.taken=(inv.taken or 0)+1
                if cutSuck==id then cutSuck=nil; coroutine.yield(math.huge,false,"cut") end
                tick(); return true
            end,
            refuel=function(n)
                local d=r.items[r.slot]
                if not d or d.name~="minecraft:coal_block" then return false end
                d.count=d.count-n; r.fuel=math.min(1000,r.fuel+800*n)
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
local function drive(untilFn)
    for _=1,30000 do
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
    world[out],world[top]="minecraft:barrel","minecraft:barrel"
    inventories[out],inventories[top]={items={}},{items={{name="minecraft:coal_block",count=4}}}
    robot(1,0,0,0,true,true)
    robot(2,2,0,0,true,true)
    for _,id in ipairs({1,2}) do
        robots[id].fuel=150
        robots[id].items[16]={name="minecraft:cobblestone",count=id}
    end
    return work,bay,hub,inventories[out],inventories[top]
end

function station_contention_and_recovery()
    local work,bay,hub,out,top=stationFixture()
    cutSuck,duplicateService=1,1
    launch(1,worker,"start")
    launch(2,worker,"start")
    drive(function() return jobs[1].cut and queue().replay[2] and queue().replay[2].reason=="station_busy" end)
    local g=queue().active[1]
    assert(g.station and #g.cells==0 and at(bay) and robots[2].moves==0)
    assert(snapshot(1).stationFuelSlot and top.taken==1 and #out.items==1)
    jobs[COORD],inbox[COORD]=nil,{}
    launch(1,worker,"resume")
    local begin=clock
    drive(function() return clock>begin+12 end)
    assert(queue().active[1].id==g.id and top.taken==1 and robots[2].moves==0)
    launch(COORD,coordinator,"run")
    loseFinish=1
    drive(function() return finished(work) and not snapshot(1).grant and not snapshot(2).grant end)
    assert(#out.items==2 and top.taken==2 and robots[1].fuel>=900 and robots[2].fuel>=900)
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
    local work,bay,hub,out,top=stationFixture()
    local stock=top.items[1]
    top.items[1]=nil
    out.full=true
    robot(3,1,0,0,true)
    launch(1,worker,"start")
    drive(function() return saw(1,"turtle_front") end)
    local start=clock
    drive(function() return clock>start+62 end)
    assert(robots[1].moves==0 and robots[1].digs==0 and queue().active[1].station)
    robots[3]=nil
    drive(function() return saw(1,"station_output_full") end)
    assert(at(bay) and robots[1].items[16].count==1 and not top.taken)
    out.full=false
    drive(function() return saw(1,"station_fuel_empty") end)
    assert(at(bay) and #out.items==1 and queue().active[1].station)
    top.items[1]={name="minecraft:stone",count=8}
    drive(function() return saw(1,"station_fuel_contaminated") end)
    assert(not top.taken and queue().active[1].station)
    top.items[1]=stock
    drive(function() return queue().work[work[1]]=="clear" and not queue().active[1] end)
    assert(top.taken==1 and not at(bay) and robots[1].h==0)
end

function station_requires_round_trip_fuel()
    local _,bay,_,out,top=stationFixture()
    robots[1].fuel=4
    launch(1,worker,"start")
    drive(function() return saw(1,"station_fuel_reserve") end)
    assert(robots[1].moves==0 and not queue().active[1] and not at(bay) and not top.taken)
    robots[1].fuel=150
    drive(function() return top.taken==1 end)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
