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
    for p,status in pairs(s.work) do
        assert(coords(p) and not s.staging[p]
            and (status=="unclaimed" or status=="clear" or status=="blocked"),
            "invalid work cell")
    end
    for p in pairs(s.clearApproach) do assert(coords(p) and not s.work[p],"invalid approach") end
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
            assert(not s.work[p] and not s.clearApproach[p],"station inventory is in work or travel space")
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
            and s.staging[r.stage],"invalid replay record")
        if r.kind=="claim" or r.kind=="service" then
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
        local stage=g.route[1]
        local planned=s.station and s.station.routes[stage]
        local service=g.station~=nil
        assert(integer(owner,0,2^31-1) and owner==g.worker and integer(g.id,1,s.nextId-1)
            and not ids[g.id] and s.staging[stage]
            and g.fuelNeed==2*(#g.route-1+#g.cells)+s.margin+(g.serviceReserve or 0)
            and s.replay[owner] and s.replay[owner].stage==g.route[1],
            "invalid active grant")
        if service then
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
            assert((s.clearApproach[p] or s.work[p]=="clear")
                and (service or not s.station or p~=s.station.bay)
                and (i==1 or (not s.staging[p] and adjacent(g.route[i-1],p))),"invalid grant route")
        end
        local connected={}
        for i,p in ipairs(g.cells) do
            assert(s.work[p]=="unclaimed","invalid grant work")
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

local function proposal(s,stage,fuel)
    local used=reservations(s)
    if used[stage] then return nil,"staging_reserved" end
    local routeQ,prev,dist={stage},{[stage]=stage},{[stage]=0}
    local first,entry
    local i=1
    -- Search only known clear, unreserved transit cells, closest first.
    while routeQ[i] do
        local p=routeQ[i]
        if 2*(dist[p]+1)+s.margin<=fuel then
            for _,q in ipairs(neighbors(p)) do
                if not used[q] then
                    if s.work[q]=="unclaimed" then first,entry=q,p; break end
                    if not prev[q] and not s.staging[q] and (not s.station or q~=s.station.bay) and
                        (s.clearApproach[q] or s.work[q]=="clear") then
                        prev[q],dist[q]=p,dist[p]+1
                        routeQ[#routeQ+1]=q
                    end
                end
            end
            if first then break end
        end
        i=i+1
    end
    if not first then return nil,"no_safe_patch" end
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
            if not seen[q] and not used[q] and s.work[q]=="unclaimed" then
                seen[q]=true; cells[#cells+1]=q
            end
        end
        i=i+1
    end
    return {route=route,cells=cells,fuelNeed=2*(dist[entry]+#cells)+s.margin}
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
    if active and (active.route[1]~=stage or (active.station~=nil)~=(kind=="service")) then
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
    if not g or g.id~=id or g.route[1]~=stage then return nil,"assignment_mismatch" end
    local allowed={}
    for _,p in ipairs(g.cells) do allowed[p]=true end
    for p,v in pairs(evidence) do
        if not allowed[p] or (v~="clear" and v~="blocked") then return nil,"invalid_evidence" end
    end
    local nextState=copy(s)
    for p,v in pairs(evidence) do nextState.work[p]=v end
    nextState.active[worker]=nil
    local response={seq=seq,finished=id}
    nextState.replay[worker]={seq=seq,kind="finish",stage=stage,id=id,
        evidence=copy(evidence)}
    return self:_publish(nextState,response)
end

return Queue
