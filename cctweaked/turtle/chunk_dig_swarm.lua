-- chunk_dig_swarm start|resume|status|resolve [before|after]
-- Configuration is /chunk_dig_swarm.json. Never opens standalone state.
local mode,choice=...
assert(turtle,"Run chunk_dig_swarm on a mining turtle")
assert(mode=="start" or mode=="resume" or mode=="status" or mode=="resolve",
    "Usage: chunk_dig_swarm start|resume|status|resolve [before|after]")
assert(not fs.exists("/.chunk_dig"),"Standalone quarry save exists; swarm will not touch it")
local M=assert(loadfile(fs.combine(fs.getDir(shell.getRunningProgram()),"swarm_common.lua")))()
local c=M.config("/chunk_dig_swarm.json")
M.xyz(c.staging)
local headings={north=0,east=1,south=2,west=3}
local heading=headings[c.facing]
local serviceBelow=c.serviceBelow or 800
assert(heading and type(c.coordinator)=="number" and c.coordinator%1==0 and c.coordinator>=0
    and type(c.quarryId)=="string" and type(c.manifestId)=="string" and type(c.dimension)=="string"
    and (c.sharedStation==nil or type(c.sharedStation)=="boolean")
    and type(serviceBelow)=="number" and serviceBelow%1==0 and serviceBelow>=0 and serviceBelow<=1000000
    and not (c.sharedStation and c.output)
    and (c.output==nil or c.output=="top" or c.output=="front"),"invalid swarm worker configuration")
local me=os.getComputerID()
local DIR="/.chunk_dig_swarm"
local function locate()
    local x,y,z=gps.locate(2)
    if not x then return nil end
    return M.key(x,y,z)
end
local s,commit
if mode=="start" then
    if fs.exists(DIR) then error("Saved swarm state exists; run chunk_dig_swarm resume",0) end
    assert(locate()==c.staging,"GPS does not match staging")
    s,commit=M.store(DIR,true)
    s={seq=0,boot=0,worker=me,stage=c.staging,stageHeading=heading,coordinator=c.coordinator,
        quarryId=c.quarryId,manifestId=c.manifestId,dimension=c.dimension,heading=heading,trail={c.staging}}
    commit(s)
else s,commit=M.store(DIR) end
assert(s.worker==me and s.stage==c.staging and s.stageHeading==heading and s.coordinator==c.coordinator
    and s.quarryId==c.quarryId and s.manifestId==c.manifestId and s.dimension==c.dimension,
    "worker config and saved state disagree; do not move")
local function pos() return s.trail[#s.trail] end
if mode=="status" then
    print(("Swarm %s | assignment %s | saved %s heading %s"):format(
        s.quarryId,s.grant and s.grant.id or "none",pos(),s.heading))
    if s.motion then print(("Pending %s: %s -> %s, heading %s -> %s"):format(
        s.motion.op,s.motion.from,s.motion.to,s.heading,s.motion.heading or s.heading)) end
    if s.request then print("Pending "..s.request.kind.." #"..s.request.seq) end
    return
end

local function applyMotion(m)
    if m.heading then s.heading=m.heading
    elseif m.back then s.trail[#s.trail]=nil
    else
        s.trail[#s.trail+1]=m.to
        if m.mine then s.outcomes[m.to]="clear" end
    end
end

local function reconcile()
    if mode=="start" then return end
    turtle.inspectDown() -- drain the existing turtle command queue before GPS
    local fix=assert(locate(),"GPS unavailable; cannot verify swarm position")
    if s.motion then
        local m=s.motion
        if m.heading then
            assert(fix==pos() and mode=="resolve" and (choice=="before" or choice=="after"),
                "Pending turn: verify actual facing, then use chunk_dig_swarm resolve before|after")
            if choice=="after" then applyMotion(m) end
        else
            assert(mode~="resolve","Pending translation is resolved by GPS on resume")
            if fix==m.to then applyMotion(m)
            else assert(fix==m.from,"GPS disagrees with both pending move poses") end
        end
        s.motion=nil; commit(s)
    else
        assert(mode~="resolve","No unresolved turn")
        assert(fix==pos(),"GPS disagrees with saved swarm position")
    end
end
local tokenCounter,lastSync,lastReport=0,-math.huge,-math.huge
local state,detail,reason="starting","",""
local function report(force)
    local now=os.clock()
    if not force and now-lastReport<3 then return end
    lastReport=now
    local used,items,cleared,blocked=0,0,0,0
    for i=1,16 do
        local n=turtle.getItemCount(i)
        used=used+(n>0 and 1 or 0); items=items+n
    end
    for _,v in pairs(s.outcomes or {}) do
        cleared=cleared+(v=="clear" and 1 or 0); blocked=blocked+(v=="blocked" and 1 or 0)
    end
    local x,y,z=M.xyz(pos())
    local ax,ay,az=M.xyz(s.stage)
    local dx,dz=x-ax,z-az
    local f=({[0]=-dz,dx,dz,-dx})[heading]
    local r=({[0]=dx,dz,-dx,-dz})[heading]
    rednet.broadcast({
        type="quarry",version=1,id=me,name=os.getComputerLabel() or ("Swarm "..me),
        status=state,detail=detail,fuel=turtle.getFuelLevel(),fuelLimit=turtle.getFuelLimit(),
        fuelType=c.sharedStation and "shared coal station" or "carried fuel",
        reserve=#s.trail-1+(s.grant and s.grant.serviceReserve or 0),
        job={layer=ay-y,layerCleared=cleared,layerBlocked=blocked,cells=cleared,
            area=s.grant and #s.grant.cells or 0},
        inventory={usedSlots=used,totalSlots=16,percent=used*100/16,items=items},
        location={relative={x=f,y=y-ay,z=r},heading=(s.heading-heading)%4},
        swarm={quarryId=s.quarryId,assignmentId=s.grant and s.grant.id,
            area=s.grant and (s.grant.station and ("service bay "..s.grant.route[#s.grant.route])
                or (s.grant.cells[1].." +"..(#s.grant.cells-1).." cells")),
            waitingReason=reason}
    },M.telemetry)
end

local function announce(st,message,waiting)
    if state~=st or detail~=message then
        state,detail,reason=st,message,waiting or ""
        print(st..": "..message)
        report(true)
    else report() end
end

local function rpc(request)
    tokenCounter=tokenCounter+1
    local token=("%.0f:%.0f"):format(s.boot,tokenCounter)
    local msg={}
    for k,v in pairs(request) do msg[k]=v end
    msg.token,msg.stage=token,s.stage
    rednet.send(c.coordinator,M.envelope(c,msg),M.protocol)
    local deadline=os.clock()+3
    while os.clock()<deadline do
        local from,reply=rednet.receive(M.protocol,math.max(0.05,deadline-os.clock()))
        if not from then break end
        if from==c.coordinator and M.sameJob(c,reply) and reply.token==token and reply.kind==request.kind then
            if reply.error then error("Coordinator rejected "..request.kind..": "..reply.error,0) end
            assert(type(reply.result)=="table","invalid coordinator response")
            return reply.result
        end
    end
end

local function checkGrant(g)
    assert(type(g)=="table" and g.worker==me and type(g.id)=="number" and g.id>=1 and g.id%1==0
        and type(g.fuelNeed)=="number" and g.fuelNeed%1==0
        and #g.route>=1 and #g.cells<=256 and g.route[1]==s.stage
        and g.fuelNeed>=2*(#g.route-1+#g.cells),"invalid swarm grant")
    if g.station then
        assert(c.sharedStation and #g.route>1 and #g.cells==0 and not g.serviceReserve
            and headings[g.station.facing] and type(g.station.fuelTarget)=="number"
            and g.station.fuelTarget%1==0 and g.station.fuelTarget>=1 and g.station.fuelTarget<=1000000,
            "invalid shared station grant")
    else
        local reserve=g.serviceReserve or 0
        assert(#g.cells>=1 and type(reserve)=="number" and reserve%1==0 and reserve>=0
            and g.fuelNeed>=2*(#g.route-1+#g.cells)+reserve,"invalid mining grant")
    end
    local used={}
    for i,p in ipairs(g.route) do
        M.xyz(p); assert(not used[p],"overlapping route")
        if i>1 then M.step(g.route[i-1],p) end
        used[p]=true
    end
    local children={}
    for i,p in ipairs(g.cells) do
        M.xyz(p); assert(not used[p],"overlapping grant")
        local parent
        if i==1 then
            parent=g.route[#g.route]; M.step(parent,p)
        else
            for _,n in ipairs(M.neighbors(p)) do if used[n]=="work" then parent=n; break end end
        end
        assert(parent,"disconnected grant")
        children[parent]=children[parent] or {}
        children[parent][#children[parent]+1]=p
        used[p]="work"
    end
    return children
end

local function sameGrant(a,b)
    checkGrant(b)
    if a.id~=b.id or a.fuelNeed~=b.fuelNeed or a.serviceReserve~=b.serviceReserve
        or (a.station~=nil)~=(b.station~=nil)
        or #a.route~=#b.route or #a.cells~=#b.cells then return false end
    if a.station and (a.station.facing~=b.station.facing or a.station.fuelTarget~=b.station.fuelTarget) then return false end
    for i,p in ipairs(a.route) do if b.route[i]~=p then return false end end
    for i,p in ipairs(a.cells) do if b.cells[i]~=p then return false end end
    return true
end

local function sync()
    if os.clock()-lastSync<5 then return true end
    local reply=rpc({kind="sync",id=s.grant.id})
    if not reply then return false end
    assert(sameGrant(s.grant,reply.grant),"assignment and checkpoint disagree")
    lastSync=os.clock()
    return true
end

local function fuel()
    local n=turtle.getFuelLevel()
    return n=="unlimited" and math.huge or n
end

local function motion(op,to,h,back,mine)
    assert(not s.motion and s.grant and not s.request,"motion without active assignment")
    local m={op=op,from=pos(),to=to,heading=h,back=back,mine=mine}
    s.motion=m; commit(s)
    local ok=turtle[op]()
    if ok then applyMotion(m) end
    s.motion=nil; commit(s)
    return ok
end

local function face(h)
    if s.heading==h then return true end
    local delta=(h-s.heading)%4==3 and -1 or 1
    assert(motion(delta==1 and "turnRight" or "turnLeft",pos(),(s.heading+delta)%4),"turn failed")
    return false
end

local function isTurtle(b)
    return b.name=="computercraft:turtle_normal" or b.name=="computercraft:turtle_advanced"
        or (b.tags and b.tags["computercraft:turtle"]==true)
end

local function inspect(suffix)
    local fn=turtle["inspect"..suffix]
    local present,b=fn()
    local waited=false
    while present and isTurtle(b) do
        waited=true
        local dir=suffix=="" and "front" or suffix:lower()
        announce("waiting_turtle",dir.." blocked by "..b.name,"turtle_"..dir)
        local untilTime=os.clock()+60
        while os.clock()<untilTime do sleep(math.min(5,untilTime-os.clock())); report() end
        present,b=fn()
    end
    return present,b,waited
end

local function protected(b)
    local n=b.name
    return n=="minecraft:bedrock" or (n:match("^allthemodium:") and n:find("ore"))
        or n:find("chest") or n:find("barrel") or n:find("shulker") or n:find("drawer")
end

local function emptySlot()
    for i=1,16 do if turtle.getItemCount(i)==0 then return true end end
    return false
end

local function step(to,mine,back)
    local suffix,h=M.step(pos(),to)
    if h and not face(h) then return end
    local present,b,waited=inspect(suffix)
    if waited then return end -- re-enter dispatcher and recheck sync/fuel
    if present then
        if not mine then
            announce("blocked","Reserved route obstructed at "..to,"route_obstructed"); sleep(5); return
        end
        if protected(b) then s.outcomes[to]="blocked"; commit(s); return end
        -- This is the only dig call. Re-inspect immediately before it.
        present,b,waited=inspect(suffix)
        if waited or not present then return end
        if protected(b) then s.outcomes[to]="blocked"; commit(s); return end
        if not turtle["dig"..suffix]() then
            local still,_,paused=inspect(suffix)
            if not paused and still then
                s.outcomes[to]="blocked"; commit(s)
                announce("blocked","Dig failed at "..to,"dig_failed")
            end
        end
        return
    end
    if not motion(suffix=="" and "forward" or suffix:lower(),to,nil,back,mine) then
        local _,_,paused=inspect(suffix)
        if not paused then announce("blocked","Move failed at "..to,"move_failed"); sleep(5) end
    end
end

local allowedFuel={["minecraft:coal_block"]=true,["minecraft:coal"]=true,["minecraft:charcoal"]=true}
local function cargoSlot()
    for i=1,16 do
        local d=turtle.getItemDetail(i)
        if d and not allowedFuel[d.name] then return i end
    end
end
local function service()
    local cap=turtle.getFuelLimit()
    local values={["minecraft:coal_block"]=800,["minecraft:coal"]=80,["minecraft:charcoal"]=80}
    for i=1,16 do
        local d=turtle.getItemDetail(i)
        if d and allowedFuel[d.name] and type(cap)=="number" then
            local count=math.min(d.count,math.floor((cap-fuel())/values[d.name]))
            if count>0 then turtle.select(i); turtle.refuel(count) end
        end
    end
    if c.output then
        for i=1,16 do
            local d=turtle.getItemDetail(i)
            if d and not allowedFuel[d.name] then
                if not peripheral.hasType(c.output,"inventory") then break end
                turtle.select(i)
                if not (c.output=="top" and turtle.dropUp or turtle.drop)() then break end
            end
        end
    end
    turtle.select(1)
end

local function settleStationFuel()
    local slot=s.stationFuelSlot
    if not slot then return end
    local got=turtle.getItemDetail(slot)
    if got then
        assert(got.name=="minecraft:coal_block" and got.count==1,
            "Unexpected item in station fuel slot "..slot.."; fix it before resuming")
        local before=fuel()
        turtle.select(slot)
        assert(turtle.refuel(1) and fuel()>before and turtle.getItemCount(slot)==0,
            "Cannot burn station coal block in saved fuel slot")
    end
    turtle.select(1)
    s.stationFuelSlot=nil; commit(s)
end

local function stationStep(g)
    local station=g.station
    assert(pos()==g.route[#g.route] and not s.request,"station access outside active bay")
    if not face(headings[station.facing]) then return end
    if not s.bayVerified then
        assert(locate()==pos(),"GPS cannot verify the service bay")
        s.bayVerified=true; commit(s)
    end
    local slot
    for i=1,16 do if turtle.getItemCount(i)>0 then slot=i; break end end
    if slot then
        local present,_,paused=inspect("")
        if paused then return end
        if not present or not peripheral.hasType("front","inventory") then
            announce("waiting_output","Shared station output inventory is missing","station_output_missing")
            sleep(5); return
        end
        announce("unloading","Unloading at shared station")
        turtle.select(slot)
        turtle.drop()
        turtle.select(1)
        if turtle.getItemCount(slot)>0 then
            announce("waiting_output","Shared station output is full or rejects cargo","station_output_full")
            sleep(5)
        end
        return
    end
    local limit=turtle.getFuelLimit()
    local distance=#g.route-1
    local target=limit=="unlimited" and math.huge or math.min(limit,station.fuelTarget+distance)
    if fuel()>=target then s.returning=true; s.stationComplete=true; commit(s); return end
    local present,_,paused=inspect("Up")
    if paused then return end
    if not present or not peripheral.hasType("top","inventory") then
        announce("waiting_fuel","Shared station coal-block inventory is missing","station_fuel_missing")
        sleep(5); return
    end
    local items=peripheral.call("top","list")
    local available=false
    for _,d in pairs(items) do
        if d.name~="minecraft:coal_block" then
            announce("waiting_fuel","Station fuel inventory must contain only coal blocks","station_fuel_contaminated")
            sleep(5); return
        end
        available=true
    end
    if not available then
        announce("waiting_fuel","Shared station is out of coal blocks","station_fuel_empty")
        sleep(5); return
    end
    for i=1,16 do if turtle.getItemCount(i)==0 then slot=i; break end end
    if not slot then
        announce("waiting_fuel","No empty inventory slot for a station coal block","station_fuel_no_slot")
        sleep(5); return
    end
    announce("refueling","Taking a coal block at shared station")
    s.stationFuelSlot=slot; commit(s)
    turtle.select(slot)
    local ok=turtle.suckUp(1)
    assert(not ok or turtle.getItemCount(slot)>0,"Station fuel arrived outside the saved fuel slot")
    settleStationFuel()
    if not ok then
        announce("waiting_fuel","Station fuel inventory rejected extraction","station_fuel_rejected")
        sleep(5)
    end
end

local function request(kind,fields)
    s.seq=s.seq+1
    fields.kind,fields.seq=kind,s.seq
    s.request=fields
    commit(s)
end

local children=s.grant and checkGrant(s.grant)
local function checkTrail()
    assert(s.trail[1]==s.stage and #s.trail>=1 and type(s.heading)=="number"
        and s.heading%1==0 and s.heading>=0 and s.heading<=3,"invalid saved trail")
    if s.bayVerified or s.stationFuelSlot or s.stationComplete then
        assert(s.grant and s.grant.station,"station state without a service grant")
        assert(not s.stationComplete or (s.bayVerified and s.returning),"invalid completed service")
        if s.stationFuelSlot then
            assert(s.bayVerified and pos()==s.grant.route[#s.grant.route] and not s.returning
                and not s.request and not s.motion and s.heading==headings[s.grant.station.facing]
                and type(s.stationFuelSlot)=="number" and s.stationFuelSlot%1==0
                and s.stationFuelSlot>=1 and s.stationFuelSlot<=16,"invalid saved station fuel slot")
        end
    end
    if not s.grant then
        assert(#s.trail==1 and not s.motion,"saved motion without assignment")
        return
    end
    local g=s.grant
    for i,p in ipairs(s.trail) do
        if i<=#g.route then assert(p==g.route[i],"saved transit disagrees with grant")
        else
            local linked=false
            for _,q in ipairs(children[s.trail[i-1]] or {}) do if p==q then linked=true end end
            assert(linked and s.outcomes[p]=="clear","saved patch trail disagrees with grant")
        end
    end
    if s.motion then
        local m=s.motion
        assert(not s.request and m.from==pos(),"invalid pending move")
        if m.heading then
            assert(m.to==pos() and ((m.op=="turnLeft" and m.heading==(s.heading+3)%4)
                or (m.op=="turnRight" and m.heading==(s.heading+1)%4)),"invalid pending turn")
        else
            local suffix,h=M.step(pos(),m.to)
            assert((not h or h==s.heading) and m.op==(suffix=="" and "forward" or suffix:lower()),
                "invalid pending direction")
            local linked=false
            if m.back then linked=m.to==s.trail[#s.trail-1] and not m.mine
            elseif m.mine and #s.trail>=#g.route then
                for _,q in ipairs(children[pos()] or {}) do if m.to==q and not s.outcomes[q] then linked=true end end
            elseif not m.mine then linked=g.route[#s.trail+1]==m.to end
            assert(linked,"pending move outside grant")
        end
    end
end
checkTrail()
reconcile()
s.boot=s.boot+1
commit(s)
M.openModem()
local verifiedGrant=not s.grant
local waiting={
    station_not_configured="Shared station is not configured on the coordinator",
    station_busy="Shared bay or its route is reserved; waiting at staging",
    station_fuel_reserve="Add starter fuel at staging; not enough for a round trip to the shared bay",
    patch_fuel="Not enough fuel for the reachable patch and the required return reserve"
}
while true do
    if s.request then
        assert(pos()==s.stage and not s.motion and s.heading==heading,"invalid pending staging request")
        local reply=rpc(s.request)
        if not reply then
            announce("waiting_swarm","Waiting for coordinator reply","coordinator_unreachable"); sleep(2)
        else
            assert(reply.seq==s.request.seq,"wrong coordinator sequence")
            if s.request.kind=="finish" then
                assert(s.grant and reply.finished==s.grant.id,"wrong finish acknowledgement")
                if s.stationComplete then s.lastStationFuel=turtle.getFuelLevel() end
                s.bayVerified,s.stationComplete=nil,nil
                s.grant,s.outcomes,s.returning,children=nil,nil,nil,nil
            elseif reply.grant then
                assert(not s.grant and (reply.grant.station~=nil)==(s.request.kind=="service"),
                    "unexpected grant type or existing assignment")
                children=checkGrant(reply.grant)
                s.grant,s.outcomes=reply.grant,{}
                if not s.grant.station then s.lastStationFuel=nil end
                s.needsStationFuel=nil
                lastSync=os.clock()
                verifiedGrant=true
            elseif reply.reason=="patch_fuel" and c.sharedStation then
                s.needsStationFuel=true
            end
            s.request=nil; commit(s)
            if reply.reason then
                announce("waiting_swarm",waiting[reply.reason] or "No reachable unclaimed patch with current route and fuel",reply.reason)
                sleep(5)
            end
        end
    elseif not s.grant then
        assert(pos()==s.stage and s.heading==heading and locate()==s.stage,"not at verified staging")
        service()
        local level=turtle.getFuelLevel()
        local tried=s.lastStationFuel==level
        if c.sharedStation and (cargoSlot() or not emptySlot()
                or (not tried and (s.needsStationFuel or fuel()<serviceBelow))) then
            request("service",{fuel=level})
        elseif not emptySlot() then
            announce("waiting_output","Empty cargo at staging or configure an adjacent output inventory","no_empty_slot")
            sleep(5)
        else request("claim",{fuel=turtle.getFuelLevel()}) end
    elseif not verifiedGrant then
        if sync() then verifiedGrant=true
        else announce("waiting_swarm","Cannot verify saved assignment; holding position","coordinator_unreachable"); sleep(2) end
    else
        local g=s.grant
        if s.stationFuelSlot then settleStationFuel() end
        local connected=not s.returning and sync()
        if not connected and not s.returning then s.returning=true; commit(s) end
        if not s.returning and ((#s.trail==1 and fuel()<g.fuelNeed)
                or (g.station and #s.trail<#g.route and fuel()<#s.trail+1)
                or (not g.station and (not emptySlot() or fuel()<#s.trail+1+(g.serviceReserve or 0)))) then
            s.returning=true; commit(s)
        end
        if s.returning then
            if #s.trail>1 then
                assert(fuel()>=#s.trail-1,"insufficient fuel for return; held in reserved space")
                announce("returning_home","Returning through reserved route")
                step(s.trail[#s.trail-1],false,true)
            elseif face(heading) then
                assert(locate()==s.stage,"GPS cannot verify return to staging")
                -- A pending FINISH disarms movement before the coordinator may release.
                request("finish",{id=g.id,evidence=s.outcomes})
            end
        else
            local index=#s.trail
            if index<#g.route then
                announce("resuming",g.station and "Travelling to reserved shared station" or "Travelling to assigned patch")
                step(g.route[index+1],false,false)
            elseif g.station then
                stationStep(g)
            else
                local nextCell
                for _,p in ipairs(children[pos()] or {}) do if not s.outcomes[p] then nextCell=p; break end end
                if nextCell then
                    announce("mining","Working patch #"..g.id)
                    step(nextCell,true,false)
                elseif index>#g.route then
                    step(s.trail[index-1],false,true)
                else s.returning=true; commit(s) end
            end
        end
    end
    report()
end
