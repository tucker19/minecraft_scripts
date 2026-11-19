-- Coordinator scheduling core. No Rednet, turtle I/O, or standalone state.
-- Coordinates are canonical "x,y,z" strings. One dimension per ledger.
-- The caller verifies sender, staging pose and terminal worker checkpoint.
local Queue = {}
Queue.__index = Queue

local function copy(value)
    if type(value)~="table" then return value end
    local result={}
    for k,v in pairs(value) do result[k]=copy(v) end
    return result
end

local function integer(n,min,max)
    return type(n)=="number" and n%1==0 and n>=min and n<=max
end

local function key(x,y,z) return x..","..y..","..z end
local function coords(s)
    if type(s)~="string" then return end
    local x,y,z=s:match("^(-?%d+),(-?%d+),(-?%d+)$")
    x,y,z=tonumber(x),tonumber(y),tonumber(z)
    if integer(x,-30000000,30000000) and integer(y,-30000000,30000000)
        and integer(z,-30000000,30000000) and key(x,y,z)==s then return x,y,z end
end

local function neighbors(s)
    local x,y,z=coords(s)
    return {key(x,y-1,z),key(x-1,y,z),key(x,y,z-1),
        key(x,y,z+1),key(x+1,y,z),key(x,y+1,z)}
end

local function adjacent(a,b)
    local ax,ay,az=coords(a)
    local bx,by,bz=coords(b)
    return ax and bx and math.abs(ax-bx)+math.abs(ay-by)+math.abs(az-bz)==1
end

local function equal(a,b)
    for k,v in pairs(a) do if b[k]~=v then return false end end
    for k,v in pairs(b) do if a[k]~=v then return false end end
    return true
end

-- Automatic quarries store each layer as one compact string (u/c/b per
-- cell, or one character when the whole layer is uniform). Hand-written
-- manifests keep the sparse s.work map used by older ledgers.
local CODE={u="unclaimed",c="clear",b="blocked"}
local CHAR={unclaimed="u",clear="c",blocked="b"}
local function boxIndex(s,p)
    local b=s.box
    local x,y,z=coords(p)
    if not b or not x or x<b.x0 or x>b.x1 or z<b.z0 or z>b.z1 or y<b.y0 or y>b.y1 then return end
    return y,(x-b.x0)*(b.z1-b.z0+1)+(z-b.z0)+1
end
local function rawWork(s,p)
    if not s.box then return s.work[p] end
    local y,i=boxIndex(s,p)
    if not y then return end
    local layer=s.layers[y]
    return CODE[#layer==1 and layer or layer:sub(i,i)]
end
local function workGet(s,p)
    if s.box and s.clearApproach[p] then return end
    return rawWork(s,p)
end
local function workSet(s,p,v)
    if not s.box then s.work[p]=v; return end
    local y,i=boxIndex(s,p)
    assert(y and CHAR[v],"cell outside quarry box")
    local layer=s.layers[y]
    if #layer==1 then
        if layer==CHAR[v] then return end
        layer=layer:rep(s.box.area)
    end
    layer=layer:sub(1,i-1)..CHAR[v]..layer:sub(i+1)
    local first=layer:sub(1,1)
    if not layer:find("[^"..first.."]") then layer=first end
    s.layers[y]=layer
end
local function home(g) return g.relocate and g.route[#g.route] or g.route[1] end
local function isLane(s,p) return s.auto and s.auto.infra[p]=="lane" and s.clearApproach[p] end
Queue.workGet=workGet

local function reservations(state)
    local used={}
    for owner,g in pairs(state.active) do
        for _,list in ipairs({g.route,g.cells}) do
            for _,p in ipairs(list) do
                assert(not used[p], "overlapping active reservation at "..p)
                used[p]=owner
            end
        end
    end
    return used
end

local function validate(s)
    assert(s.version==1 and type(s.quarryId)=="string" and #s.quarryId>0
        and type(s.manifestId)=="string" and #s.manifestId>0
        and type(s.dimension)=="string" and #s.dimension>0, "invalid queue identity")
    assert(integer(s.patchSize,1,256) and integer(s.margin,0,1000000)
        and integer(s.nextId,1,2^52), "invalid queue limits")
    if s.box then
        local b=s.box
        assert(not s.work and integer(b.x0,-30000000,30000000) and integer(b.x1,b.x0,b.x0+255)
            and integer(b.z0,-30000000,30000000) and integer(b.z1,b.z0,b.z0+255)
            and integer(b.y0,-30000000,30000000) and integer(b.y1,b.y0,b.y0+4096)
            and b.area==(b.x1-b.x0+1)*(b.z1-b.z0+1) and type(s.layers)=="table","invalid quarry box")
        for y=b.y0,b.y1 do
            local layer=s.layers[y]
            assert(type(layer)=="string" and (#layer==1 or #layer==b.area)
                and not layer:find("[^ucb]"),"invalid quarry layer")
        end
    else
        for p,status in pairs(s.work) do
            assert(coords(p) and not s.staging[p]
                and (status=="unclaimed" or status=="clear" or status=="blocked"),
                "invalid work cell")
        end
    end
    for p in pairs(s.clearApproach) do
        local raw=rawWork(s,p)
        assert(coords(p) and (raw==nil or (s.box and raw=="clear")),"invalid approach")
    end
    if s.auto then
        local a=s.auto
        assert(s.box and s.station and a.bay==s.station.bay and integer(a.heading,0,3)
            and type(a.lane)=="table" and type(a.park)=="table" and #a.lane==#a.park
            and type(a.infra)=="table" and type(s.parked)=="table","invalid automatic layout")
        local taken={}
        for owner,p in pairs(s.parked) do
            assert(integer(owner,0,2^31-1) and s.staging[p] and not taken[p],"invalid parking record")
            taken[p]=true
        end
    end
    for p in pairs(s.staging) do assert(s.clearApproach[p],"staging must be on a clear approach") end
    if s.station then
        local t=s.station
        assert(coords(t.bay) and s.clearApproach[t.bay] and not s.staging[t.bay]
            and ({north=true,east=true,south=true,west=true})[t.facing]
            and integer(t.fuelTarget,1,1000000) and type(t.routes)=="table","invalid shared station")
        local x,y,z=coords(t.bay)
        local dx=({north=0,east=1,south=0,west=-1})[t.facing]
        local dz=({north=-1,east=0,south=1,west=0})[t.facing]
        for _,p in ipairs({key(x+dx,y,z+dz),key(x,y+1,z)}) do
            assert(not rawWork(s,p) and not s.clearApproach[p],"station inventory is in work or travel space")
        end
        for stage,route in pairs(t.routes) do
            assert(s.staging[stage] and type(route)=="table" and #route>=2
                and route[1]==stage and route[#route]==t.bay,"invalid station route endpoints")
            local seen={}
            for i,p in ipairs(route) do
                assert(not seen[p] and s.clearApproach[p]
                    and (i==1 or (not s.staging[p] and adjacent(route[i-1],p))),"invalid station route")
                seen[p]=true
            end
        end
        for stage in pairs(s.staging) do assert(t.routes[stage],"staging position missing its station route") end
    end
    for owner,r in pairs(s.replay) do
        assert(integer(owner,0,2^31-1) and integer(r.seq,1,2^52)
            and (s.staging[r.stage] or (r.kind=="join" and s.auto and r.stage==s.auto.bay)),
            "invalid replay record")
        if r.kind=="join" then
            assert(s.auto and r.stage==s.auto.bay and (not s.active[owner] or s.active[owner].relocate),
                "invalid join replay")
        elseif r.kind=="claim" or r.kind=="service" then
            assert((r.fuel=="unlimited" or integer(r.fuel,0,2^52))
                and ((s.active[owner] and r.reason==nil)
                    or (not s.active[owner] and
                        ((r.kind=="claim" and (r.reason=="no_safe_patch" or r.reason=="staging_reserved"
                            or r.reason=="patch_fuel"))
                        or (r.kind=="service" and (r.reason=="station_not_configured"
                            or r.reason=="station_busy" or r.reason=="station_fuel_reserve"))))),
                "invalid claim replay")
        else
            assert(r.kind=="finish" and not s.active[owner] and integer(r.id,1,s.nextId-1)
                and type(r.evidence)=="table","invalid finish replay")
        end
    end
    local ids={}
    for owner,g in pairs(s.active) do
        local stage=home(g)
        local planned=s.station and s.station.routes[stage]
        local service=g.station~=nil
        assert(integer(owner,0,2^31-1) and owner==g.worker and integer(g.id,1,s.nextId-1)
            and not ids[g.id] and s.staging[stage]
            and (g.relocate and g.fuelNeed==0
                or g.fuelNeed==2*(#g.route-1+#g.cells)+s.margin+(g.serviceReserve or 0))
            and s.replay[owner] and s.replay[owner].stage==g.route[1],
            "invalid active grant")
        if g.relocate then
            -- A newcomer placed in the bay: service there, then drive to its parking cell.
            assert(s.auto and g.relocate==true and planned and #g.cells==0 and #g.route==#planned
                and s.parked[owner]==stage and g.station.facing==s.station.facing
                and g.station.fuelTarget==s.station.fuelTarget
                and s.replay[owner].kind=="join","invalid relocation grant")
            for i,p in ipairs(g.route) do
                assert(p==planned[#planned+1-i],"relocation route differs from parking route")
            end
        elseif service then
            assert(planned and #g.cells==0 and #g.route==#planned and not g.serviceReserve
                and g.station.facing==s.station.facing and g.station.fuelTarget==s.station.fuelTarget
                and s.replay[owner].kind=="service","invalid service grant")
            for i,p in ipairs(g.route) do assert(p==planned[i],"service route differs from manifest") end
        else
            assert(#g.cells>=1 and #g.cells<=s.patchSize and adjacent(g.route[#g.route],g.cells[1])
                and (g.serviceReserve or 0)==(planned and 2*(#planned-1)+s.margin or 0)
                and s.replay[owner].kind=="claim","invalid mining grant")
        end
        ids[g.id]=true
        for i,p in ipairs(g.route) do
            assert((s.clearApproach[p] or workGet(s,p)=="clear")
                and (service or not s.station or p~=s.station.bay)
                and (service or i==1 or not isLane(s,p))
                and (i==1 or ((not s.staging[p] or (g.relocate and i==#g.route))
                    and adjacent(g.route[i-1],p))),"invalid grant route")
        end
        local connected={}
        for i,p in ipairs(g.cells) do
            assert(workGet(s,p)=="unclaimed","invalid grant work")
            local linked=i==1
            for _,q in ipairs(neighbors(p)) do if connected[q] then linked=true end end
            assert(linked,"disconnected grant patch")
            connected[p]=true
        end
    end
    reservations(s)
end

function Queue.initial(config)
    local s={version=1,quarryId=config.quarryId,manifestId=config.manifestId,dimension=config.dimension,
        patchSize=config.patchSize or 16,margin=config.margin or 32,
        work={},clearApproach={},staging={},active={},replay={},nextId=1,station=copy(config.station)}
    for _,p in ipairs(config.work) do s.work[p]="unclaimed" end
    for _,p in ipairs(config.clearApproach) do s.clearApproach[p]=true end
    for _,p in ipairs(config.staging) do s.staging[p]=true end
    validate(s)
    return s
end

-- Promote dug infrastructure into fixed travel space, in order from the bay:
-- lane j joins the service lane only after lane j-1, and parking j becomes a
-- staging cell with a planned route through the lane. Reserved cells wait.
local function promote(s)
    local a=s.auto
    if not a then return end
    local used=reservations(s)
    for j,lane in ipairs(a.lane) do
        if not s.clearApproach[lane] then
            if used[lane] or rawWork(s,lane)~="clear" then break end
            s.clearApproach[lane]=true
        end
        local park=a.park[j]
        if not s.clearApproach[park] and not used[park] and rawWork(s,park)=="clear" then
            s.clearApproach[park],s.staging[park]=true,true
            local route={park}
            for i=j,1,-1 do route[#route+1]=a.lane[i] end
            route[#route+1]=a.bay
            s.station.routes[park]=route
        end
    end
end

local VEC={[0]={0,-1},{1,0},{0,1},{-1,0}} -- north, east, south, west as dx,dz
local NAMES={[0]="north","east","south","west"}
Queue.MAX_CHUNKS=8

-- Build an automatic ledger from the first turtle's observations: the bay
-- (its starting cell), the heading it probed, and the chunk count. The
-- footprint matches chunk_dig: forward and right of the bay, starting one
-- layer below it. Row 0 is the service lane, row 1 the parking row.
function Queue.define(p)
    assert(integer(p.worker,0,2^31-1),"invalid worker")
    local bx,by,bz=coords(p.bay)
    assert(bx,"invalid bay")
    assert(integer(p.heading,0,3),"invalid heading")
    assert(integer(p.chunks,1,Queue.MAX_CHUNKS),"chunks must be 1 to "..Queue.MAX_CHUNKS)
    assert(integer(p.bottom,by-4096,by-1),"bottom must be below the bay")
    local f,r=VEC[p.heading],VEC[(p.heading+1)%4]
    local w=16*p.chunks
    local y0=by-1
    local function at(i,j) return key(bx+i*f[1]+j*r[1],y0,bz+i*f[2]+j*r[2]) end
    assert(p.park==at(1,0),"first turtle must define from the cell ahead of the bay")
    local x0,x1=bx,bx+(w-1)*(f[1]+r[1])
    local z0,z1=bz,bz+(w-1)*(f[2]+r[2])
    if x0>x1 then x0,x1=x1,x0 end
    if z0>z1 then z0,z1=z1,z0 end
    local s={version=1,quarryId=p.quarryId,manifestId=p.manifestId,dimension=p.dimension,
        patchSize=p.patchSize or 16,margin=p.margin or 32,clearApproach={[p.bay]=true},staging={},
        active={},replay={},nextId=1,parked={},layers={},
        box={x0=x0,x1=x1,y0=p.bottom,y1=y0,z0=z0,z1=z1,area=w*w},
        station={bay=p.bay,facing=NAMES[(p.heading+2)%4],fuelTarget=p.fuelTarget or 4000,routes={}}}
    for y=p.bottom,y0 do s.layers[y]="u" end
    local a={bay=p.bay,heading=p.heading,chunks=p.chunks,bottom=p.bottom,definer=p.worker,
        lane={},park={},infra={}}
    for j=0,math.min(w,64)-1 do
        a.lane[j+1],a.park[j+1]=at(0,j),at(1,j)
        a.infra[at(0,j)],a.infra[at(1,j)]="lane","park"
    end
    s.auto=a
    -- The first turtle dug these two cells while probing its heading.
    workSet(s,at(0,0),"clear"); workSet(s,at(1,0),"clear")
    promote(s)
    s.parked[p.worker]=p.park
    s.replay[p.worker]={seq=1,kind="join",stage=p.bay,fuel=0}
    validate(s)
    return s
end

function Queue.defineResult(s)
    local a=s.auto
    return {seq=1,stage=a.park[1],heading=a.heading,bay=a.bay}
end

-- Load the caller's last verified commit; never initialize implicitly on boot.
-- commit(snapshot) must synchronously publish or throw, and return true.
function Queue.open(snapshot,commit)
    validate(snapshot)
    assert(type(commit)=="function","durable commit required")
    return setmetatable({state=copy(snapshot),commit=commit},Queue)
end

function Queue.withStation(snapshot,station,approaches)
    assert(not snapshot.station and not next(snapshot.active),"stop all assignments before enabling the station")
    assert(type(station)=="table","station config required")
    local updated=copy(snapshot)
    for _,p in ipairs(approaches or {}) do updated.clearApproach[p]=true end
    updated.station=copy(station)
    validate(updated)
    return updated
end

function Queue:_publish(nextState,response)
    -- An ambiguous write must freeze this instance, even if the caller catches it.
    self.frozen=true
    assert(self.commit(copy(nextState))==true,"queue commit not confirmed")
    self.state,self.frozen=nextState,false
    return copy(response)
end

local function search(s,used,stage,fuel,want)
    local routeQ,prev,dist={stage},{[stage]=stage},{[stage]=0}
    local first,entry
    local i=1
    -- Search only known clear, unreserved transit cells, closest first.
    while routeQ[i] do
        local p=routeQ[i]
        if i%2048==0 and Queue.yield then Queue.yield() end
        if 2*(dist[p]+1)+s.margin<=fuel then
            for _,q in ipairs(neighbors(p)) do
                if not used[q] then
                    local status=workGet(s,q)
                    if status=="unclaimed" and want(q) then first,entry=q,p; break end
                    if not prev[q] and not s.staging[q] and (not s.station or q~=s.station.bay)
                        and not isLane(s,q) and (s.clearApproach[q] or status=="clear") then
                        prev[q],dist[q]=p,dist[p]+1
                        routeQ[#routeQ+1]=q
                    end
                end
            end
            if first then break end
        end
        i=i+1
    end
    if not first then return end
    local back,route={},{}
    local p=entry
    while p~=stage do back[#back+1]=p; p=prev[p] end
    route[1]=stage
    for j=#back,1,-1 do route[#route+1]=back[j] end
    local cap=math.min(s.patchSize,math.floor((fuel-s.margin)/2)-dist[entry])
    local cells,seen={first},{[first]=true}
    i=1
    while cells[i] and #cells<cap do
        for _,q in ipairs(neighbors(cells[i])) do
            if #cells==cap then break end
            if not seen[q] and not used[q] and workGet(s,q)=="unclaimed" and want(q) then
                seen[q]=true; cells[#cells+1]=q
            end
        end
        i=i+1
    end
    return {route=route,cells=cells,fuelNeed=2*(dist[entry]+#cells)+s.margin}
end

local function proposal(s,stage,fuel)
    local used=reservations(s)
    if used[stage] then return nil,"staging_reserved" end
    local grant
    if s.auto then
        -- Dig the lane and parking rows first so late turtles get somewhere to park.
        grant=search(s,used,stage,fuel,function(q) return s.auto.infra[q]~=nil end)
    end
    grant=grant or search(s,used,stage,fuel,function() return true end)
    if not grant then return nil,"no_safe_patch" end
    return grant
end

local function checkRequest(self,worker,seq,stage)
    if self.frozen then return nil,"queue_frozen" end
    if not integer(worker,0,2^31-1) or not integer(seq,1,2^52)
        or not self.state.staging[stage] then return nil,"invalid_request" end
    return true
end

local function serviceProposal(s,stage,fuel)
    if not s.station then return nil,"station_not_configured" end
    local route=s.station.routes[stage]
    local need=2*(#route-1)+s.margin
    if fuel<need then return nil,"station_fuel_reserve" end
    local used=reservations(s)
    for _,p in ipairs(route) do if used[p] then return nil,"station_busy" end end
    return {route=copy(route),cells={},fuelNeed=need,
        station={facing=s.station.facing,fuelTarget=s.station.fuelTarget}}
end

local function allocate(self,kind,worker,seq,stage,fuel)
    local ok,why=checkRequest(self,worker,seq,stage)
    if not ok then return nil,why end
    local requestedFuel=fuel
    if fuel=="unlimited" then fuel=math.huge
    elseif not integer(fuel,0,2^52) then return nil,"invalid_fuel" end
    local s=self.state
    local old=s.replay[worker]
    if old and seq<=old.seq then
        if seq==old.seq and old.kind==kind and old.stage==stage and old.fuel==requestedFuel then
            return {seq=seq,grant=copy(s.active[worker]),reason=old.reason}
        end
        return nil,"stale_request"
    end
    local active=s.active[worker]
    if active and (home(active)~=stage or active.relocate
            or (active.station~=nil)~=(kind=="service")) then
        return nil,"assignment_mismatch"
    end
    local grant,reason
    if active then grant=active
    elseif kind=="service" then grant,reason=serviceProposal(s,stage,fuel)
    else
        local route=s.station and s.station.routes[stage]
        local reserve=route and 2*(#route-1)+s.margin or 0
        grant,reason=proposal(s,stage,fuel-reserve)
        if not grant and route and reason=="no_safe_patch" and proposal(s,stage,math.huge) then
            reason="patch_fuel"
        end
        if grant and reserve>0 then grant.serviceReserve=reserve; grant.fuelNeed=grant.fuelNeed+reserve end
    end
    local nextState=copy(s)
    if grant and not active then
        assert(s.nextId<2^52,"assignment IDs exhausted")
        grant.id,grant.worker=s.nextId,worker
        nextState.nextId=s.nextId+1
        nextState.active[worker]=grant
    end
    local response={seq=seq,grant=grant,reason=reason}
    nextState.replay[worker]={seq=seq,kind=kind,stage=stage,fuel=requestedFuel,reason=reason}
    return self:_publish(nextState,response)
end

function Queue:claim(worker,seq,stage,fuel) return allocate(self,"claim",worker,seq,stage,fuel) end
function Queue:service(worker,seq,stage,fuel) return allocate(self,"service",worker,seq,stage,fuel) end

-- Only call after the owner has durably disabled this assignment at its
-- verified staging cell (no pending motion). Report only observed outcomes.
-- Omitted cells remain unfinished. No heartbeat or timeout calls this.
function Queue:finish(worker,seq,stage,id,evidence)
    local ok,why=checkRequest(self,worker,seq,stage)
    if not ok then return nil,why end
    if type(evidence)~="table" then return nil,"invalid_evidence" end
    local s=self.state
    local old=s.replay[worker]
    if old and seq<=old.seq then
        if seq==old.seq and old.kind=="finish" and old.stage==stage and old.id==id then
            if equal(old.evidence,evidence) then return {seq=seq,finished=id} end
        end
        return nil,"stale_request"
    end
    local g=s.active[worker]
    if not g or g.id~=id or home(g)~=stage then return nil,"assignment_mismatch" end
    local allowed={}
    for _,p in ipairs(g.cells) do allowed[p]=true end
    for p,v in pairs(evidence) do
        if not allowed[p] or (v~="clear" and v~="blocked") then return nil,"invalid_evidence" end
    end
    local nextState=copy(s)
    for p,v in pairs(evidence) do workSet(nextState,p,v) end
    nextState.active[worker]=nil
    promote(nextState)
    local response={seq=seq,finished=id}
    nextState.replay[worker]={seq=seq,kind="finish",stage=stage,id=id,
        evidence=copy(evidence)}
    return self:_publish(nextState,response)
end

-- A turtle placed in the bay asks for a parking cell. The bay itself is the
-- check that it belongs here; joins are idempotent while its grant is active.
-- Refusals change nothing, so the user can lift the turtle out and retry.
function Queue:join(worker,stage,fuel)
    if self.frozen then return nil,"queue_frozen" end
    local s=self.state
    if not s.auto then return nil,"not_automatic" end
    if not integer(worker,0,2^31-1) or not (fuel=="unlimited" or integer(fuel,0,2^52)) then
        return nil,"invalid_request"
    end
    if stage~=s.auto.bay then return nil,"not_at_bay" end
    local active=s.active[worker]
    if active then
        if active.relocate and active.route[1]==stage then
            return {seq=s.replay[worker].seq,grant=copy(active),stage=home(active),heading=s.auto.heading}
        end
        return nil,"already_working"
    end
    local used=reservations(s)
    if used[stage] then return {reason="bay_busy"} end
    local slot=s.parked[worker]
    if not slot then
        local taken={}
        for _,p in pairs(s.parked) do taken[p]=true end
        for _,p in ipairs(s.auto.park) do
            if s.staging[p] and not taken[p] then slot=p; break end
        end
    end
    if not slot then return {reason="no_parking"} end
    local planned=s.station.routes[slot]
    local route={}
    for i=#planned,1,-1 do
        if used[planned[i]] then return {reason="lane_busy"} end
        route[#route+1]=planned[i]
    end
    assert(s.nextId<2^52,"assignment IDs exhausted")
    local grant={id=s.nextId,worker=worker,relocate=true,route=route,cells={},fuelNeed=0,
        station={facing=s.station.facing,fuelTarget=s.station.fuelTarget}}
    local nextState=copy(s)
    local seq=(s.replay[worker] and s.replay[worker].seq or 0)+1
    nextState.nextId=s.nextId+1
    nextState.active[worker]=grant
    nextState.parked[worker]=slot
    nextState.replay[worker]={seq=seq,kind="join",stage=stage,fuel=fuel}
    return self:_publish(nextState,{seq=seq,grant=grant,stage=slot,heading=s.auto.heading})
end

return Queue
