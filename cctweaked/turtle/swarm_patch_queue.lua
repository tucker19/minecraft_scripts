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
    for owner,r in pairs(s.replay) do
        assert(integer(owner,0,2^31-1) and integer(r.seq,1,2^52)
            and s.staging[r.stage],"invalid replay record")
        if r.kind=="claim" then
            assert((r.fuel=="unlimited" or integer(r.fuel,0,2^52))
                and ((s.active[owner] and r.reason==nil)
                    or (not s.active[owner] and (r.reason=="no_safe_patch" or r.reason=="staging_reserved"))),
                "invalid claim replay")
        else
            assert(r.kind=="finish" and not s.active[owner] and integer(r.id,1,s.nextId-1)
                and type(r.evidence)=="table","invalid finish replay")
        end
    end
    local ids={}
    for owner,g in pairs(s.active) do
        assert(integer(owner,0,2^31-1) and owner==g.worker and integer(g.id,1,s.nextId-1)
            and not ids[g.id] and #g.cells>=1 and #g.cells<=s.patchSize
            and s.staging[g.route[1]] and adjacent(g.route[#g.route],g.cells[1])
            and g.fuelNeed==2*(#g.route-1+#g.cells)+s.margin
            and s.replay[owner] and s.replay[owner].stage==g.route[1],
            "invalid active grant")
        ids[g.id]=true
        for i,p in ipairs(g.route) do
            assert((s.clearApproach[p] or s.work[p]=="clear")
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
        work={},clearApproach={},staging={},active={},replay={},nextId=1}
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
                    if not prev[q] and not s.staging[q] and
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

function Queue:claim(worker,seq,stage,fuel)
    local ok,why=checkRequest(self,worker,seq,stage)
    if not ok then return nil,why end
    local requestedFuel=fuel
    if fuel=="unlimited" then fuel=math.huge
    elseif not integer(fuel,0,2^52) then return nil,"invalid_fuel" end
    local s=self.state
    local old=s.replay[worker]
    if old and seq<=old.seq then
        if seq==old.seq and old.kind=="claim" and old.stage==stage and old.fuel==requestedFuel then
            return {seq=seq,grant=copy(s.active[worker]),reason=old.reason}
        end
        return nil,"stale_request"
    end
    local active=s.active[worker]
    if active and active.route[1]~=stage then return nil,"assignment_mismatch" end
    local grant,reason
    if active then grant=active else grant,reason=proposal(s,stage,fuel) end
    local nextState=copy(s)
    if grant and not active then
        assert(s.nextId<2^52,"assignment IDs exhausted")
        grant.id,grant.worker=s.nextId,worker
        nextState.nextId=s.nextId+1
        nextState.active[worker]=grant
    end
    local response={seq=seq,grant=grant,reason=reason}
    nextState.replay[worker]={seq=seq,kind="claim",stage=stage,fuel=requestedFuel,reason=reason}
    return self:_publish(nextState,response)
end

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
