-- First turtle, sitting in the bay facing the quarry:  chunk_dig_swarm new <chunks> [bottomY]
-- Every later turtle, placed in the same bay:          chunk_dig_swarm
-- Recovery and inspection:                             chunk_dig_swarm resume|status|resolve before|after
-- Startup hook (added automatically):                  chunk_dig_swarm auto
-- Advanced manual manifest: chunk_dig_swarm start with /chunk_dig_swarm.json.
-- Never opens standalone state.
local mode,choice,extra=...
assert(turtle,"Run chunk_dig_swarm on a mining turtle")
local usage="Usage: chunk_dig_swarm new <chunks> [bottomY] | join | resume | status | resolve before|after"
assert(mode==nil or ({new=true,join=true,start=true,resume=true,status=true,resolve=true,auto=true})[mode],usage)
assert(not fs.exists("/.chunk_dig"),"Standalone quarry save exists; swarm will not touch it")
local M=assert(loadfile(fs.combine(fs.getDir(shell.getRunningProgram()),"swarm_common.lua")))()
local DIR,SETUP,MANUAL="/.chunk_dig_swarm","/.chunk_dig_swarm_setup","/chunk_dig_swarm.json"
local headings={north=0,east=1,south=2,west=3}
local me=os.getComputerID()
local function locate()
    local x,y,z=gps.locate(2)
    if not x then return nil end
    return M.key(x,y,z)
end
if mode==nil or mode=="auto" then
    -- An unfinished setup always wins: its main state (if any) was never used.
    if fs.exists(SETUP) then mode="setup"
    elseif fs.exists(DIR) then mode="resume"
    elseif mode=="auto" then return
    else mode="join" end
elseif mode=="resume" and fs.exists(SETUP) then mode="setup" end
if mode=="status" and fs.exists(SETUP) then
    print("Swarm setup in progress; run chunk_dig_swarm to continue it")
    return
end
if mode=="status" and not fs.exists(DIR) then
    print("No swarm job on this turtle")
    return
end
local manual=fs.exists(MANUAL)
local c,heading,serviceBelow
local s,commit
if manual then
    assert(mode~="new" and mode~="join" and mode~="setup",
        "Remove /chunk_dig_swarm.json to use automatic setup")
    c=M.config(MANUAL)
    M.xyz(c.staging)
    heading=headings[c.facing]
    serviceBelow=c.serviceBelow or 800
    assert(heading and type(c.coordinator)=="number" and c.coordinator%1==0 and c.coordinator>=0
        and type(c.quarryId)=="string" and type(c.manifestId)=="string" and type(c.dimension)=="string"
        and (c.sharedStation==nil or type(c.sharedStation)=="boolean")
        and type(serviceBelow)=="number" and serviceBelow%1==0 and serviceBelow>=0 and serviceBelow<=1000000
        and not (c.sharedStation and c.output)
        and (c.output==nil or c.output=="top" or c.output=="front"),"invalid swarm worker configuration")
    if mode=="start" then
        if fs.exists(DIR) then error("Saved swarm state exists; run chunk_dig_swarm resume",0) end
        assert(locate()==c.staging,"GPS does not match staging")
        s,commit=M.store(DIR,true)
        s={seq=0,boot=0,worker=me,stage=c.staging,stageHeading=heading,coordinator=c.coordinator,
            quarryId=c.quarryId,manifestId=c.manifestId,dimension=c.dimension,heading=heading,trail={c.staging}}
        commit(s)
    else s,commit=M.store(DIR) end
    assert(not s.auto and s.worker==me and s.stage==c.staging and s.stageHeading==heading
        and s.coordinator==c.coordinator and s.quarryId==c.quarryId and s.manifestId==c.manifestId
        and s.dimension==c.dimension,"worker config and saved state disagree; do not move")
else
    assert(mode~="start",
        "No /chunk_dig_swarm.json needed. First turtle: chunk_dig_swarm new <chunks>. Later turtles: chunk_dig_swarm")
    serviceBelow=800
    c={sharedStation=true}
    if mode~="new" and mode~="join" and mode~="setup" then s,commit=M.store(DIR) end
end
-- Automatic workers carry their whole identity in saved state.
local function useState()
    assert(s.auto==true and s.worker==me and type(s.coordinator)=="number" and type(s.quarryId)=="string"
        and type(s.manifestId)=="string" and type(s.dimension)=="string"
        and type(s.stageHeading)=="number","invalid automatic swarm state")
    c.quarryId,c.manifestId,c.dimension=s.quarryId,s.manifestId,s.dimension
    c.coordinator,c.staging,heading=s.coordinator,s.stage,s.stageHeading
end
if s and not manual then useState() end
local function pos() return s.trail[#s.trail] end
if mode=="status" then
    local function dir(h) return ("%d (%s)"):format(h,({[0]="north","east","south","west"})[h]) end
    print(("Swarm %s | assignment %s | saved %s heading %s"):format(
        s.quarryId,s.grant and s.grant.id or "none",pos(),dir(s.heading)))
    if s.motion then print(("Pending %s: %s -> %s, heading %s -> %s"):format(
        s.motion.op,s.motion.from,s.motion.to,dir(s.heading),dir(s.motion.heading or s.heading))) end
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
    if not (s and s.trail and heading) then return end -- setup has no swarm position yet
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
            area=s.grant and (s.grant.relocate and ("moving to parking "..s.stage)
                or s.grant.station and ("service bay "..s.grant.route[#s.grant.route])
                or s.grant.chunk and ("chunk "..s.grant.chunk.k.." layer "..s.grant.chunk.y..": "..#s.grant.cells.." cells")
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
            if reply.error=="join_revoked" then
                -- Another turtle was placed in the bay while this one had not
                -- left it, so this join was cancelled. Nothing outside the bay
                -- depends on this turtle; forget the join.
                local g=s.grant
                assert(g and g.relocate and not s.departed and #s.trail==1 and s.trail[1]==g.route[1]
                    and not s.motion,"Coordinator cancelled a join this turtle already acted on")
                fs.delete(DIR)
                error("This turtle's join was cancelled because another turtle used the bay. "
                    .."Place it in the bay and run chunk_dig_swarm to join again.",0)
            end
            if reply.error then error("Coordinator rejected "..request.kind..": "..reply.error,0) end
            assert(type(reply.result)=="table","invalid coordinator response")
            return reply.result
        end
    end
end

local function checkGrant(g)
    assert(type(g)=="table" and g.worker==me and type(g.id)=="number" and g.id>=1 and g.id%1==0
        and type(g.fuelNeed)=="number" and g.fuelNeed%1==0
        and #g.route>=1 and #g.cells<=256
        and (g.relocate and g.route[#g.route]==s.stage and g.fuelNeed==0
            or not g.relocate and g.route[1]==s.stage and g.fuelNeed>=2*(#g.route-1+#g.cells)),
        "invalid swarm grant")
    if g.relocate then
        assert(g.relocate==true and g.station and not manual,"invalid relocation grant")
    end
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
        or (a.station~=nil)~=(b.station~=nil) or a.relocate~=b.relocate
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

local moveFailures={}
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
        local still,_,paused=inspect(suffix)
        if not paused then
            moveFailures[to]=(moveFailures[to] or 0)+1
            -- Empty but impassable (world limit, entity that never leaves): record
            -- it as blocked/unverified instead of holding the patch forever.
            if mine and not still and moveFailures[to]>=3 then
                s.outcomes[to]="blocked"; commit(s)
            end
            announce("blocked","Move failed at "..to,"move_failed"); sleep(5)
        end
    end
end

local COAL_BLOCK="minecraft:coal_block"
local allowedFuel={[COAL_BLOCK]=true,["minecraft:coal"]=true,["minecraft:charcoal"]=true}
local function cargoSlot()
    for i=1,16 do
        if turtle.getItemCount(i)>0 then return i end
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

-- Match the standalone shared base: burn carried coal blocks first, unload
-- directly, and use only a selective wired transfer for external fuel.
local function burn(slot)
    local before=fuel()
    turtle.select(slot)
    local ok=turtle.refuel(1)
    turtle.select(1)
    return ok and fuel()>before
end

local function carried(need)
    for _,blocksOnly in ipairs({true,false}) do
        for i=1,16 do
            while fuel()<need do
                local d=turtle.getItemDetail(i)
                if not d or (blocksOnly and d.name~=COAL_BLOCK) or not burn(i) then break end
            end
        end
    end
end

local function verifyStationBuffer(slot)
    local got=turtle.getItemDetail(slot)
    if got and (got.name~=COAL_BLOCK or got.count~=1) then
        local message="Unexpected item in station fuel slot "..slot.."; stop other access and remove it before resuming"
        announce("recovery_required",message,"station_transfer_unverified")
        error(message,0)
    end
    return got
end

local function settleStationFuel()
    local slot=s.stationFuelSlot
    if not slot then return end
    if verifyStationBuffer(slot) then
        local cap=turtle.getFuelLimit()
        if type(cap)=="number" and fuel()<cap then
            if not burn(slot) then
                announce("waiting_fuel","Cannot burn coal block in saved station slot "..slot,"station_fuel_rejected")
                sleep(5); return
            end
            assert(turtle.getItemCount(slot)==0,"Coal block burn did not empty saved station slot")
        end
    end
    turtle.select(1)
    s.stationFuelSlot=nil; commit(s)
end

local function wireCall(fn,...)
    local ok,value=pcall(fn,...)
    if ok then return value end
    if value=="Terminated" then error(value,0) end
    return nil,tostring(value)
end

local function stationDock()
    local _,_,paused=inspect("Up")
    if paused then return nil,nil,"guard_wait" end
    local m=peripheral.wrap("top")
    if not m or type(m.isWireless)~="function" or m.isWireless()
        or type(m.getNameLocal)~="function" or type(m.getNamesRemote)~="function"
        or type(m.getMethodsRemote)~="function" or type(m.callRemote)~="function" then
        return nil,"Shared station requires a wired dock modem above the bay","station_dock_missing"
    end
    local id=wireCall(m.getNameLocal)
    if type(id)~="string" or id=="" then
        return nil,"Wired dock does not address this turtle; check peripheral mode and keepalive","station_dock_missing"
    end
    local names,why=wireCall(m.getNamesRemote)
    if type(names)~="table" then
        return nil,"Cannot enumerate wired station peripherals: "..tostring(why),"station_dock_missing"
    end
    local name,withDetail
    for _,n in pairs(names) do
        if n~=id then
            local methods={}
            for _,method in pairs(wireCall(m.getMethodsRemote,n) or {}) do methods[method]=true end
            if methods.list and methods.pushItems then
                if name then
                    return nil,"Multiple wired inventories found; connect only the shared barrel and visiting turtle","station_dock_ambiguous"
                end
                name,withDetail=n,methods.getItemDetail
            end
        end
    end
    if not name then
        return nil,"Shared storage must expose wired list and slot-specific pushItems","station_dock_missing"
    end
    return {id=id,detail=withDetail,call=function(method,...)
        return wireCall(m.callRemote,name,method,...)
    end}
end

local function stationBuffer(cap)
    for i=1,16 do if turtle.getItemCount(i)==0 then return i end end
    -- First merge compatible partial stacks; transferTo checks actual
    -- compatibility even when two item names match.
    for j=16,2,-1 do
        local d=turtle.getItemDetail(j)
        for i=1,j-1 do
            local a=turtle.getItemDetail(i)
            if d and a and a.name==d.name and turtle.getItemSpace(i)>0 then
                turtle.select(j)
                turtle.transferTo(i)
                turtle.select(1)
                if turtle.getItemCount(j)==0 then return j end
            end
        end
    end
    local max=math.floor((cap-fuel())/800)-1
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
        if type(i)=="number" and i%1==0 and i>=1 and i<=2^31-1
            and type(d)=="table" and d.name==COAL_BLOCK and type(d.count)=="number"
            and d.count>0 and not tried[i] then
            count=count+1
            if not best or d.count<best or (d.count==best and i<from) then from,best=i,d.count end
        end
    end
    return from,count
end

local function stationPull(cap,target)
    if fuel()>=cap then return false,"Fuel tank has no room for a coal block","station_fuel_no_room" end
    local headroom=cap-fuel()
    if headroom<800 and fuel()>=target then
        return false,"Fuel tank has no room for a coal block","station_fuel_no_room"
    end
    local dock,why,reason=stationDock()
    if not dock then return false,why,reason end
    local items,err=dock.call("list")
    if type(items)~="table" then
        return false,"Cannot list wired shared inventory: "..tostring(err),"station_fuel_rejected"
    end
    local tried={}
    local _,attempts=coalSlot(items,tried)
    if attempts==0 then return false,"No coal blocks exposed by the wired shared inventory","station_fuel_empty" end
    local into=stationBuffer(cap)
    if not into then return false,"All 16 slots occupied; no temporary coal-block buffer","station_fuel_no_slot" end
    assert(turtle.getItemCount(into)==0,"Station fuel destination is not empty")
    announce("refueling","Taking a coal block from shared station inventory")
    s.stationFuelSlot=into; commit(s)
    local problem="Coal slots changed before transfer"
    for _=1,attempts do
        items,err=dock.call("list")
        if type(items)~="table" then
            problem="Cannot refresh wired shared inventory: "..tostring(err); break
        end
        local from=coalSlot(items,tried)
        if not from then break end
        tried[from]=true
        local d=items[from]
        if dock.detail then
            local detail,detailErr=dock.call("getItemDetail",from)
            if not detailErr then d=detail end
        end
        if d and d.name==COAL_BLOCK then
            local moved,pushErr=dock.call("pushItems",dock.id,from,1,into)
            if verifyStationBuffer(into) then return true end -- burn before another transfer
            if pushErr then
                problem="Wired transfer failed; check writable turtle inventory: "..pushErr; break
            end
            if moved~=0 then
                local message="Wired transfer reported success without delivery to station fuel slot "..into
                announce("recovery_required",message,"station_transfer_unverified")
                error(message,0)
            end
            problem="Coal was listed but not extracted; check storage extraction or compaction"
        end
    end
    s.stationFuelSlot=nil; commit(s)
    return false,problem,"station_fuel_rejected"
end

local function stationStep(g)
    local station=g.station
    local bay=g.relocate and g.route[1] or g.route[#g.route]
    assert(pos()==bay and not s.request,"station access outside active bay")
    if not face(headings[station.facing]) then return end
    if not s.bayVerified then
        assert(locate()==pos(),"GPS cannot verify the service bay")
        s.bayVerified=true; commit(s)
    end
    local limit=turtle.getFuelLimit()
    local cap=limit=="unlimited" and math.huge or limit
    local distance=#g.route-1
    local target=math.min(cap,station.fuelTarget+distance)
    carried(target)
    local present,_,paused=inspect("")
    if paused then return end
    if not present or not peripheral.hasType("front","inventory") then
        announce("waiting_output","No adjacent inventory capability in front of the shared bay","station_output_missing")
        sleep(5); return
    end
    local hasCargo,dropWhy
    for i=1,16 do
        local count=turtle.getItemCount(i)
        if count>0 then
            hasCargo=true
            if not peripheral.hasType("front","inventory") then
                announce("waiting_output","Shared inventory disappeared; cargo retained","station_output_missing")
                sleep(5); return
            end
            announce("unloading","Unloading at shared station")
            turtle.select(i)
            local _,why=turtle.drop()
            turtle.select(1)
            if turtle.getItemCount(i)<count then return end
            dropWhy=why or "shared inventory is full or rejects cargo"
        end
    end
    if not hasCargo and fuel()>=target then
        -- A newcomer heads on to its parking cell instead of returning.
        s.returning=not g.relocate or nil; s.stationComplete=true; commit(s); return
    end
    local ok,why,reason=stationPull(cap,target)
    if ok or reason=="guard_wait" then return end
    if hasCargo then
        announce("waiting_output",dropWhy.."; "..why,"station_output_full")
    else announce("waiting_fuel",why,reason) end
    sleep(5)
end

local function request(kind,fields)
    s.seq=s.seq+1
    fields.kind,fields.seq=kind,s.seq
    s.request=fields
    commit(s)
end

-- Automatic setup. Nothing here needs a config file: the first turtle
-- measures the quarry from its own start cell, and later turtles register by
-- being placed in that same cell (the bay). Setup is journaled in SETUP and
-- every step is re-derived from GPS, so a reboot simply repeats it.
local function installStartup()
    local program="/"..(shell.getRunningProgram():gsub("^/+",""):gsub("%.lua$",""))
    local hook=('shell.execute("%s","auto")'):format(program)
    if fs.isDir("/startup") then
        local path="/startup/99_chunk_dig_swarm.lua"
        if not fs.exists(path) then
            local h=fs.open(path,"w"); h.write(hook.."\n"); h.close()
            print("Added "..path.." so this turtle resumes after reboots")
        end
        return
    end
    local old=""
    if fs.exists("/startup.lua") then
        local h=fs.open("/startup.lua","r"); old=h.readAll() or ""; h.close()
    end
    if old:find(hook,1,true) then return end
    if old~="" and not fs.exists("/startup.lua.before_swarm") then
        local h=fs.open("/startup.lua.before_swarm","w"); h.write(old); h.close()
    end
    local sep=(old=="" or old:sub(-1)=="\n") and "" or "\n"
    local h=fs.open("/startup.lua","w"); h.write(old..sep..hook.."\n"); h.close()
    print("Added swarm auto-resume to the end of /startup.lua (previous copy: /startup.lua.before_swarm)")
end

local function findCoordinator()
    M.openModem()
    print("Looking for the swarm coordinator...")
    local found={rednet.lookup(M.protocol)}
    if #found==0 then error("No swarm coordinator answered; start swarm_coordinator on the dashboard computer first",0) end
    if #found>1 then error("More than one swarm coordinator answered; run only one",0) end
    return found[1]
end

local function setupRpc(msg)
    tokenCounter=tokenCounter+1
    local token=("setup%.0f:%.0f"):format(s.boot,tokenCounter)
    local out={version=1,token=token}
    for k,v in pairs(msg) do out[k]=v end
    rednet.send(s.coordinator,out,M.protocol)
    local deadline=os.clock()+3
    while os.clock()<deadline do
        local from,reply=rednet.receive(M.protocol,math.max(0.05,deadline-os.clock()))
        if not from then break end
        if from==s.coordinator and type(reply)=="table" and reply.version==1
            and reply.token==token and reply.kind==msg.kind then
            if reply.error then return nil,reply.error end
            assert(type(reply.result)=="table" and type(reply.quarryId)=="string"
                and type(reply.manifestId)=="string" and type(reply.dimension)=="string",
                "invalid coordinator response")
            return reply.result,reply
        end
    end
end

local function setupCall(msg)
    while true do
        local result,ident=setupRpc(msg)
        if result or ident then return result,ident end
        announce("waiting_swarm","Waiting for coordinator reply","coordinator_unreachable")
        sleep(2)
    end
end

local function finishSetup(result,ident,grant,current)
    -- Any main state here is a leftover from a reboot before SETUP was removed;
    -- it was never used, and the coordinator answers define/join idempotently.
    if fs.exists(DIR) then fs.delete(DIR) end
    local st,save=M.store(DIR,true)
    st={seq=result.seq,boot=0,worker=me,auto=true,stage=result.stage,stageHeading=result.heading,
        coordinator=s.coordinator,quarryId=ident.quarryId,manifestId=ident.manifestId,
        dimension=ident.dimension,heading=current,trail={grant and grant.route[1] or result.stage},
        grant=grant,outcomes=grant and {} or nil}
    save(st)
    fs.delete(SETUP)
    s,commit=st,save
    installStartup()
end

local function setupFuel(need)
    -- Same selective wired pull as the service bay: one coal block at a time.
    while fuel()<need or s.stationFuelSlot do
        if s.stationFuelSlot then settleStationFuel()
        else
            local limit=turtle.getFuelLimit()
            local ok,why,reason=stationPull(type(limit)=="number" and limit or math.huge,need)
            if not ok and reason~="guard_wait" then
                announce("waiting_fuel",why.."; put coal blocks in the shared barrel",reason); sleep(5)
            end
        end
    end
end

local function probeMove(suffix,what)
    for _=1,20 do
        local present,b=inspect(suffix)
        if present then
            if protected(b) then error("Cannot dig "..what.." ("..b.name.."); clear it and run chunk_dig_swarm",0) end
            turtle["dig"..suffix]()
        elseif (suffix=="Down" and turtle.down or turtle.forward)() then return
        else sleep(1) end
    end
    error("Cannot move into "..what.."; clear it and run chunk_dig_swarm",0)
end

local function setupNew()
    local bx,by,bz=M.xyz(s.bay)
    local below=M.key(bx,by-1,bz)
    turtle.inspectDown() -- drain the turtle command queue before GPS
    local here=assert(locate(),"GPS unavailable")
    if here==s.bay then
        setupFuel(100)
        announce("setup","Probing quarry heading (dig down, then forward; no turns)")
        probeMove("Down","the block below the bay")
        here=assert(locate(),"GPS unavailable")
    end
    if here==below then
        probeMove("","the block ahead, below the bay")
        here=assert(locate(),"GPS unavailable")
    end
    local x,y,z=M.xyz(here)
    if y~=by-1 or math.abs(x-bx)+math.abs(z-bz)~=1 then
        error("Setup found this turtle at "..here.."; put it back in the bay at "..s.bay
            .." facing the quarry, then run chunk_dig_swarm",0)
    end
    local h=x>bx and 1 or x<bx and 3 or z>bz and 2 or 0
    announce("setup","Defining "..s.chunks.." chunk quarry with the coordinator")
    local result,ident=setupCall({kind="define",bay=s.bay,stage=here,heading=h,chunks=s.chunks,bottom=s.bottom})
    if not result then
        -- Nothing was recorded on the coordinator, so forget this setup.
        fs.delete(SETUP)
        error("Coordinator refused the quarry: "..tostring(ident)..". Put this turtle back in the bay at "
            ..s.bay.." facing the quarry and run chunk_dig_swarm new again.",0)
    end
    assert(result.seq==1 and result.stage==here and result.heading==h,"coordinator defined a different quarry")
    finishSetup(result,ident,nil,h)
    print("Quarry defined. Add more turtles by placing them in the bay at "..M.key(bx,by,bz)
        .." and running chunk_dig_swarm")
    return true
end

local joinWait={
    bay_busy="Another turtle is using the bay. Lift this one out and try again in a moment.",
    lane_busy="The bay lane is in use. Try again in a moment.",
    no_parking="No free parking cell yet; the swarm digs more as it works. Try again later.",
    swarm_full="This quarry already has one turtle per chunk; no more can join"
}
local function setupJoin()
    local here=assert(locate(),"GPS unavailable")
    if here~=s.bay then fs.delete(SETUP); error("Turtle moved during join; place it in the bay and retry",0) end
    local result,ident=setupCall({kind="join",stage=here,fuel=turtle.getFuelLevel()})
    if not result or result.reason then
        -- Refusals change nothing on the coordinator, so nothing is kept here.
        fs.delete(SETUP)
        if result then print(joinWait[result.reason] or result.reason); return false end
        error("Coordinator refused join: "..tostring(ident),0)
    end
    local g=result.grant
    assert(type(g)=="table" and g.relocate and g.route[1]==here and g.route[#g.route]==result.stage
        and g.station and headings[g.station.facing],"invalid join grant")
    -- The barrel tells this turtle which way it faces. Turning cannot collide.
    announce("setup","Finding the shared barrel beside the bay")
    local hits={}
    for turn=0,3 do
        if peripheral.hasType("front","inventory") then hits[#hits+1]=turn end
        turtle.turnRight()
    end
    if #hits~=1 then
        error("Expected exactly one inventory beside the bay (the shared barrel), found "..#hits
            .."; run chunk_dig_swarm again after fixing it",0)
    end
    for _=1,hits[1] do turtle.turnRight() end
    finishSetup(result,ident,g,headings[g.station.facing])
    print("Joined swarm; moving to parking "..s.stage.." after refuelling")
    return true
end

if mode=="new" then
    local chunks,bottom=tonumber(choice),tonumber(extra or "-64")
    if not (chunks and chunks%1==0 and chunks>=1 and chunks<=9) then
        error("Usage: chunk_dig_swarm new <chunks 1-9> [bottomY]",0)
    end
    if not (bottom and bottom%1==0) then error("bottomY must be a whole number",0) end
    if fs.exists(DIR) then error("Saved swarm state exists; run chunk_dig_swarm resume",0) end
    local here=assert(locate(),"GPS unavailable; a GPS constellation is required")
    local _,hy=M.xyz(here)
    if bottom>hy-1 then error("bottomY must be below the turtle",0) end
    if not peripheral.hasType("back","inventory") then
        error("Put the shared barrel directly behind this turtle (it should face into the quarry)",0)
    end
    local dock,why=stationDock()
    if not dock then error(why or "Wired dock above the bay is blocked",0) end
    local coordinator=findCoordinator()
    s,commit=M.store(SETUP,true)
    s={phase="new",worker=me,bay=here,chunks=chunks,bottom=bottom,coordinator=coordinator,boot=0}
    commit(s)
elseif mode=="join" then
    if fs.exists(DIR) then error("Saved swarm state exists; run chunk_dig_swarm resume",0) end
    local here=assert(locate(),"GPS unavailable; a GPS constellation is required")
    local coordinator=findCoordinator()
    s,commit=M.store(SETUP,true)
    s={phase="join",worker=me,bay=here,coordinator=coordinator,boot=0}
    commit(s)
end
if mode=="new" or mode=="join" or mode=="setup" then
    if mode=="setup" then s,commit=M.store(SETUP) end
    assert(s.worker==me and (s.phase=="new" or s.phase=="join") and M.xyz(s.bay),"invalid swarm setup journal")
    s.boot=s.boot+1; commit(s)
    M.openModem()
    if not (s.phase=="new" and setupNew() or s.phase=="join" and setupJoin()) then return end
    useState()
    mode="resume"
end

local children=s.grant and checkGrant(s.grant)
local function checkTrail()
    assert(#s.trail>=1 and type(s.heading)=="number"
        and s.heading%1==0 and s.heading>=0 and s.heading<=3,"invalid saved trail")
    local g=s.grant
    local relocating=g and g.relocate
    assert(s.trail[1]==s.stage or (relocating and s.trail[1]==g.route[1]),"invalid saved trail")
    if s.bayVerified or s.stationFuelSlot or s.stationComplete then
        assert(g and g.station,"station state without a service grant")
        assert(not s.stationComplete or (s.bayVerified and (s.returning or relocating)),"invalid completed service")
        if s.stationFuelSlot then
            local bay=relocating and g.route[1] or g.route[#g.route]
            assert(s.bayVerified and pos()==bay and not s.returning
                and not s.request and not s.motion and s.heading==headings[s.grant.station.facing]
                and type(s.stationFuelSlot)=="number" and s.stationFuelSlot%1==0
                and s.stationFuelSlot>=1 and s.stationFuelSlot<=16,"invalid saved station fuel slot")
        end
    end
    if not g then
        assert(#s.trail==1 and not s.motion,"saved motion without assignment")
        return
    end
    if relocating then
        -- Bay -> lane -> parking, then the trail collapses to the parking cell.
        if s.trail[1]~=s.stage then
            for i,p in ipairs(s.trail) do assert(p==g.route[i],"saved relocation disagrees with grant") end
            assert(#s.trail==1 or s.departed,"left the bay without departure")
        else assert(#s.trail==1,"invalid relocation trail") end
        local m=s.motion
        if m then
            assert(not s.request and m.from==pos() and not m.back and not m.mine,"invalid pending move")
            if m.heading then
                assert(m.to==pos() and ((m.op=="turnLeft" and m.heading==(s.heading+3)%4)
                    or (m.op=="turnRight" and m.heading==(s.heading+1)%4)),"invalid pending turn")
            else
                local suffix,h=M.step(pos(),m.to)
                assert((not h or h==s.heading) and m.op==(suffix=="" and "forward" or suffix:lower())
                    and s.departed and s.trail[1]~=s.stage and m.to==g.route[#s.trail+1],
                    "pending move outside relocation")
            end
        end
        return
    end
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
turtle.select(1)
s.boot=s.boot+1
commit(s)
M.openModem()
local verifiedGrant=not s.grant
local waiting={
    station_not_configured="Shared station is not configured on the coordinator",
    station_busy="Shared bay or its route is reserved; waiting at staging",
    join_pending="A new turtle that joined has not left the bay. If it was picked up, place any turtle in the bay and run chunk_dig_swarm",
    station_fuel_reserve="Add starter fuel at staging; not enough for a round trip to the shared bay",
    patch_fuel="Not enough fuel for the reachable patch and the required return reserve",
    coordinator_disk="Coordinator disk is nearly full; no new work until space is freed"
}
while true do
    if s.request then
        if s.request.kind=="depart" then
            assert(s.grant and s.grant.relocate and #s.trail==1 and pos()==s.grant.route[1] and not s.motion,
                "invalid pending depart request")
        else
            assert(pos()==s.stage and not s.motion and s.heading==heading,"invalid pending staging request")
        end
        local reply=rpc(s.request)
        if not reply then
            announce("waiting_swarm","Waiting for coordinator reply","coordinator_unreachable"); sleep(2)
        else
            assert(reply.seq==s.request.seq,"wrong coordinator sequence")
            if s.request.kind=="depart" then
                assert(s.grant and reply.departed==s.grant.id,"wrong depart acknowledgement")
                s.departed=true
            elseif s.request.kind=="finish" then
                assert(s.grant and reply.finished==s.grant.id,"wrong finish acknowledgement")
                if s.stationComplete then s.lastStationFuel=turtle.getFuelLevel() end
                s.bayVerified,s.stationComplete,s.departed=nil,nil,nil
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
                if reply.reason=="station_fuel_reserve" then
                    local cap=turtle.getFuelLimit()
                    if type(cap)=="number" then carried(math.min(fuel()+1,cap)) end
                end
                announce("waiting_swarm",waiting[reply.reason] or "No reachable unclaimed patch with current route and fuel",reply.reason)
                sleep(5)
            end
        end
    elseif not s.grant then
        assert(pos()==s.stage and s.heading==heading and locate()==s.stage,"not at verified staging")
        if not c.sharedStation then service() end
        local level=turtle.getFuelLevel()
        local tried=s.lastStationFuel==level
        if c.sharedStation and (cargoSlot()
                or (not tried and (s.needsStationFuel or fuel()<serviceBelow))) then
            request("service",{fuel=level})
        elseif not emptySlot() then
            announce("waiting_output","Empty cargo at staging or configure an adjacent output inventory","no_empty_slot")
            sleep(5)
        else request("claim",{fuel=turtle.getFuelLevel()}) end
    elseif not verifiedGrant then
        if sync() then verifiedGrant=true
        else announce("waiting_swarm","Cannot verify saved assignment; holding position","coordinator_unreachable"); sleep(2) end
    elseif s.stationFuelSlot then
        settleStationFuel()
    elseif s.grant.relocate then
        -- Newcomer: unload and refuel in the bay, then drive the reserved lane to
        -- parking. The whole route is reserved, so it continues without the coordinator.
        local g=s.grant
        local inBay=s.trail[1]~=s.stage and #s.trail==1
        if inBay and not s.stationComplete then
            stationStep(g)
        elseif inBay and not s.departed then
            -- Ask before leaving. Until the coordinator records this, a turtle
            -- found in the bay later proves this one was picked up.
            request("depart",{id=g.id})
        elseif pos()~=s.stage then
            announce("relocating","Moving from the bay to parking "..s.stage)
            step(g.route[#s.trail+1],false,false)
        elseif #s.trail>1 then
            s.trail={s.stage}; commit(s)
        elseif face(heading) then
            assert(locate()==s.stage,"GPS cannot verify parking")
            request("finish",{id=g.id,evidence={}})
        end
    else
        local g=s.grant
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
