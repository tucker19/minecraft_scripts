-- Coordinator scheduling core. No Rednet, turtle I/O, or standalone state.
-- Coordinates are canonical "x,y,z" strings. One dimension per ledger.
-- The caller verifies sender, staging pose and terminal worker checkpoint.
local Queue = {}
Queue.__index = Queue
-- Chunks per side of an automatic quarry (9 = a 9x9-chunk, 144x144 quarry).
Queue.MAX_CHUNKS=9

local function copy(value)
    if type(value)~="table" then return value end
    local result={}
    for k,v in pairs(value) do result[k]=copy(v) end
    return result
end

-- Snapshot copy for a new commit. Layer tables are shared, and workSet
-- copies a layer the first time this snapshot changes it.
local function copyState(s)
    local out={}
    for k,v in pairs(s) do
        if k=="layers" then
            out.layers={}
            for y,layer in pairs(v) do out.layers[y]=layer end
        else out[k]=copy(v) end
    end
    return out
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

-- A finish replay keeps only a digest of its evidence: enough to recognise
-- an exact duplicate without storing up to 256 cells per worker.
local function digest(evidence)
    local keys={}
    for p in pairs(evidence) do keys[#keys+1]=tostring(p) end
    table.sort(keys)
    local a,b=1,0
    for _,p in ipairs(keys) do
        local text=p.."="..tostring(evidence[p])..";"
        for i=1,#text do a=(a+text:byte(i))%65521; b=(b+a)%65521 end
    end
    return ("%d:%.0f"):format(#keys,a+b*65536)
end

-- Automatic quarries store each layer as one entry per 16x16 chunk: a single
-- character when that chunk's layer is uniform (u/c/b), otherwise 256
-- characters. Snapshots on disk pack mixed entries further (see Queue.pack).
-- Hand-written manifests keep the sparse s.work map used by older ledgers.
local CODE={u="unclaimed",c="clear",b="blocked"}
local CHAR={unclaimed="u",clear="c",blocked="b"}
local floor=math.floor
local function boxCell(s,p)
    local b=s.box
    local x,y,z=coords(p)
    if not b or not x or x<b.x0 or x>b.x1 or z<b.z0 or z>b.z1 or y<b.y0 or y>b.y1 then return end
    local xi,zi=x-b.x0,z-b.z0
    return y,floor(xi/16)*b.n+floor(zi/16)+1,(xi%16)*16+zi%16+1
end
local function rawWork(s,p)
    if not s.box then return s.work[p] end
    local y,k,i=boxCell(s,p)
    if not y then return end
    local e=s.layers[y][k]
    return CODE[#e==1 and e or e:sub(i,i)]
end
local function workGet(s,p)
    if s.box and s.clearApproach[p] then return end
    return rawWork(s,p)
end
local OWNED=setmetatable({},{__mode="kv"})
local function workSet(s,p,v)
    if not s.box then s.work[p]=v; return end
    local y,k,i=boxCell(s,p)
    assert(y and CHAR[v],"cell outside quarry box")
    local layer=s.layers[y]
    if OWNED[layer]~=s then
        -- Layer tables are shared between snapshots until one is changed.
        local own={}
        for j,x in ipairs(layer) do own[j]=x end
        s.layers[y],layer=own,own
        OWNED[own]=s
    end
    local e=layer[k]
    if #e==1 then
        if e==CHAR[v] then return end
        e=e:rep(256)
    end
    e=e:sub(1,i-1)..CHAR[v]..e:sub(i+1)
    local first=e:sub(1,1)
    if not e:find("[^"..first.."]") then e=first end
    s.layers[y][k]=e
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
        assert(not s.work and integer(b.n,1,Queue.MAX_CHUNKS) and integer(b.x0,-30000000,30000000)
            and b.x1==b.x0+16*b.n-1 and integer(b.z0,-30000000,30000000) and b.z1==b.z0+16*b.n-1
            and integer(b.y0,-30000000,30000000) and integer(b.y1,b.y0,b.y0+4096)
            and b.area==(16*b.n)^2 and type(s.layers)=="table","invalid quarry box")
        for y=b.y0,b.y1 do
            local layer=s.layers[y]
            assert(type(layer)=="table" and #layer==b.n*b.n,"invalid quarry layer")
            for _,e in ipairs(layer) do
                assert(type(e)=="string" and (#e==1 or #e==256) and not e:find("[^ucb]"),"invalid quarry layer")
            end
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
            and type(a.lane)=="table" and type(a.park)=="table" and #a.park==a.chunks*a.chunks
            and a.chunks==s.box.n and type(a.parkCol)=="table" and #a.parkCol==#a.park
            and type(a.infra)=="table" and type(s.parked)=="table","invalid automatic layout")
        for i,col in ipairs(a.parkCol) do
            assert(integer(col,0,#a.lane-1) and a.infra[a.park[i]]=="park","invalid parking layout")
        end
        assert(s.revoked==nil or type(s.revoked)=="table","invalid revocations")
        for owner,id in pairs(s.revoked or {}) do
            assert(integer(owner,0,2^31-1) and integer(id,1,s.nextId-1) and not s.active[owner]
                and not s.parked[owner],"invalid revocation")
        end
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
            assert(s.auto and r.stage==s.auto.bay and (not s.active[owner]
                or (s.active[owner].relocate and not s.active[owner].departed)),"invalid join replay")
        elseif r.kind=="depart" then
            local g=s.active[owner]
            assert(g and g.relocate and g.departed and g.id==r.id and home(g)==r.stage,"invalid depart replay")
        elseif r.kind=="claim" or r.kind=="service" then
            assert((r.fuel=="unlimited" or integer(r.fuel,0,2^52))
                and ((s.active[owner] and r.reason==nil)
                    or (not s.active[owner] and
                        ((r.kind=="claim" and (r.reason=="no_safe_patch" or r.reason=="staging_reserved"
                            or r.reason=="patch_fuel" or r.reason=="coordinator_disk"))
                        or (r.kind=="service" and (r.reason=="station_not_configured"
                            or r.reason=="station_busy" or r.reason=="station_fuel_reserve"
                            or r.reason=="join_pending"))))),
                "invalid claim replay")
        else
            assert(r.kind=="finish" and not s.active[owner] and integer(r.id,1,s.nextId-1)
                and type(r.digest)=="string","invalid finish replay")
        end
    end
    local ids,chunks={},{}
    for owner,g in pairs(s.active) do
        local stage=home(g)
        local planned=s.station and s.station.routes[stage]
        local service=g.station~=nil
        assert(integer(owner,0,2^31-1) and owner==g.worker and integer(g.id,1,s.nextId-1)
            and not ids[g.id] and s.staging[stage]
            and (g.relocate and g.fuelNeed==0
                or g.fuelNeed==2*(#g.route-1+#g.cells)+s.margin+(g.serviceReserve or 0))
            and s.replay[owner]
            and s.replay[owner].stage==(g.relocate and g.departed and stage or g.route[1]),
            "invalid active grant")
        if g.relocate then
            -- A newcomer placed in the bay: service there, then drive to its parking cell.
            assert(s.auto and g.relocate==true and planned and #g.cells==0 and #g.route==#planned
                and s.parked[owner]==stage and g.station.facing==s.station.facing
                and g.station.fuelTarget==s.station.fuelTarget
                and (g.departed==nil or g.departed==true)
                and s.replay[owner].kind==(g.departed and "depart" or "join"),"invalid relocation grant")
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
            if s.auto then
                -- One assignment per chunk, all on one layer of that chunk.
                local ch=g.chunk
                assert(type(ch)=="table" and integer(ch.k,1,s.box.n^2) and not chunks[ch.k],"invalid chunk grant")
                chunks[ch.k]=true
                for _,p in ipairs(g.cells) do
                    local y,k=boxCell(s,p)
                    assert(y==ch.y and k==ch.k,"grant cell outside its chunk layer")
                end
            end
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
-- lane j joins the service lane only after lane j-1, and a parking cell
-- becomes a staging cell once the lane reaches its column. Reserved cells wait.
local function promote(s)
    local a=s.auto
    if not a then return end
    local used=reservations(s)
    for _,lane in ipairs(a.lane) do
        if not s.clearApproach[lane] then
            if used[lane] or rawWork(s,lane)~="clear" then break end
            s.clearApproach[lane]=true
        end
    end
    for i,park in ipairs(a.park) do
        local col=a.parkCol[i]
        if not s.clearApproach[park] and s.clearApproach[a.lane[col+1]] and not used[park]
            and rawWork(s,park)=="clear" then
            s.clearApproach[park],s.staging[park]=true,true
            local route={park}
            for j=col+1,1,-1 do route[#route+1]=a.lane[j] end
            route[#route+1]=a.bay
            s.station.routes[park]=route
        end
    end
end

local VEC={[0]={0,-1},{1,0},{0,1},{-1,0}} -- north, east, south, west as dx,dz
local NAMES={[0]="north","east","south","west"}

-- Build an automatic ledger from the first turtle's observations: the bay
-- (its starting cell), the heading it probed, and the chunk count per side.
-- The footprint matches chunk_dig: forward and right of the bay, starting one
-- layer below it. Row 0 is the service lane. Row 1 holds one parking cell per
-- chunk (the swarm's turtle limit), spread so each 16-wide band of chunks has
-- its own parking columns and straight routes into that band.
function Queue.define(p)
    assert(integer(p.worker,0,2^31-1),"invalid worker")
    local bx,by,bz=coords(p.bay)
    assert(bx,"invalid bay")
    assert(integer(p.heading,0,3),"invalid heading")
    assert(integer(p.chunks,1,Queue.MAX_CHUNKS),"chunks must be 1 to "..Queue.MAX_CHUNKS)
    assert(integer(p.bottom,by-4096,by-1),"bottom must be below the bay")
    local f,r=VEC[p.heading],VEC[(p.heading+1)%4]
    local n=p.chunks
    local w=16*n
    local y0=by-1
    local function at(i,j) return key(bx+i*f[1]+j*r[1],y0,bz+i*f[2]+j*r[2]) end
    assert(p.park==at(1,0),"first turtle must define from the cell ahead of the bay")
    local x0,x1=bx,bx+(w-1)*(f[1]+r[1])
    local z0,z1=bz,bz+(w-1)*(f[2]+r[2])
    if x0>x1 then x0,x1=x1,x0 end
    if z0>z1 then z0,z1=z1,z0 end
    local s={version=1,quarryId=p.quarryId,manifestId=p.manifestId,dimension=p.dimension,
        patchSize=256,margin=p.margin or 32,clearApproach={[p.bay]=true},staging={},
        active={},replay={},nextId=1,parked={},layers={},
        box={x0=x0,x1=x1,y0=p.bottom,y1=y0,z0=z0,z1=z1,area=w*w,n=n},
        station={bay=p.bay,facing=NAMES[(p.heading+2)%4],fuelTarget=p.fuelTarget or 4000,routes={}}}
    for y=p.bottom,y0 do
        local layer={}
        for k=1,n*n do layer[k]="u" end
        s.layers[y]=layer
    end
    local a={bay=p.bay,heading=p.heading,chunks=n,bottom=p.bottom,definer=p.worker,
        lane={},park={},parkCol={},infra={}}
    local last=0
    for i=0,n*n-1 do
        local col=(i%n)*16+floor(i/n)
        a.park[i+1],a.parkCol[i+1]=at(1,col),col
        a.infra[at(1,col)]="park"
        last=math.max(last,col)
    end
    for j=0,last do a.lane[j+1]=at(0,j); a.infra[at(0,j)]="lane" end
    s.auto=a
    -- The first turtle dug these two cells while probing its heading.
    workSet(s,at(0,0),"clear"); workSet(s,at(1,0),"clear")
    promote(s)
    s.parked[p.worker]=p.park
    s.replay[p.worker]={seq=1,kind="join",stage=p.bay,fuel=0}
    validate(s)
    return s
end

-- Coordinator disk needed for an automatic quarry: the packed snapshot
-- (layer entries, up to eight mixed layers per chunk, one active assignment,
-- route and replay record per turtle), times the two kept generations plus
-- the staged write. The coordinator also stops handing out work when its free
-- space gets low, so this is the realistic size, not every layer mixed.
function Queue.diskNeeded(s)
    local b=s.box
    local chunks=b.n*b.n
    local layers=b.y1-b.y0+1
    return 3*(layers*(2*chunks+8)+chunks*(8*70+1900))+65536
end

function Queue.defineResult(s)
    local a=s.auto
    return {seq=1,stage=a.park[1],heading=a.heading,bay=a.bay}
end


-- Compact snapshots: what the coordinator writes to disk. In memory the
-- queue always works on the unpacked form.
local ALPHA={}
do
    for c=35,126 do if c~=92 and c~=124 and #ALPHA<81 then ALPHA[#ALPHA+1]=string.char(c) end end
end
local ALPHAINDEX={}
for i,ch in ipairs(ALPHA) do ALPHAINDEX[ch]=i-1 end
local VAL={u=0,c=1,b=2}
local SYM={[0]="u","c","b"}
local function fast(p)
    local x,y,z=p:match("^(-?%d+),(-?%d+),(-?%d+)$")
    return tonumber(x),tonumber(y),tonumber(z)
end
-- Most layer entries are unchanged between commits; remember recent results.
local packCache,packCount={},0
local function packEntry(e)
    if #e==1 then return e end
    local hit=packCache[e]
    if hit then return hit end
    if packCount>=4096 then packCache,packCount={},0 end
    local out=Queue._packEntry(e)
    packCache[e],packCount=out,packCount+1
    return out
end
function Queue._packEntry(e)
    local runs,i={},1
    while i<=#e do
        local ch=e:sub(i,i)
        local j=(e:find("[^"..ch.."]",i) or #e+1)
        runs[#runs+1]=ch..(j-i)
        i=j
    end
    local rle="r"..table.concat(runs)
    if #rle<=65 then return rle end
    local out={}
    for i=1,256,4 do
        local v=0
        for j=i,i+3 do v=v*3+VAL[e:sub(j,j)] end
        out[#out+1]=ALPHA[v+1]
    end
    return "p"..table.concat(out)
end
local function unpackEntry(e)
    if #e==1 then return e end
    local kind,body=e:sub(1,1),e:sub(2)
    local out={}
    if kind=="r" then
        for ch,count in body:gmatch("([ucb])(%d+)") do out[#out+1]=ch:rep(tonumber(count)) end
    else
        assert(kind=="p","invalid packed layer")
        for i=1,#body do
            local v=assert(ALPHAINDEX[body:sub(i,i)],"invalid packed layer")
            local d,c,b2,a2=v%3,floor(v/3)%3,floor(v/9)%3,floor(v/27)
            out[#out+1]=SYM[a2]..SYM[b2]..SYM[c]..SYM[d]
        end
    end
    local text=table.concat(out)
    assert(#text==256,"invalid packed layer")
    return text
end
local STEP={["1,0,0"]="E",["-1,0,0"]="W",["0,0,1"]="S",["0,0,-1"]="N",["0,1,0"]="U",["0,-1,0"]="D"}
local UNSTEP={E={1,0,0},W={-1,0,0},S={0,0,1},N={0,0,-1},U={0,1,0},D={0,-1,0}}
local function packPath(list)
    if #list<2 then return copy(list) end
    local px,py,pz=fast(list[1])
    local dirs={}
    for i=2,#list do
        local x,y,z=fast(list[i])
        local d=x and STEP[(x-px)..","..(y-py)..","..(z-pz)]
        if not d then return copy(list) end
        dirs[#dirs+1]=d
        px,py,pz=x,y,z
    end
    return {from=list[1],dirs=table.concat(dirs)}
end
local function unpackPath(v)
    if v.from==nil then return v end
    local x,y,z=fast(v.from)
    local list={v.from}
    for d in v.dirs:gmatch(".") do
        local s=assert(UNSTEP[d],"invalid packed route")
        x,y,z=x+s[1],y+s[2],z+s[3]
        list[#list+1]=key(x,y,z)
    end
    return list
end
local function packCells(list)
    if #list==0 then return copy(list) end
    local mx,my,mz=fast(list[1])
    local xs,zs={},{}
    for i,p in ipairs(list) do
        local x,y,z=fast(p)
        if not x or y~=my then return copy(list) end
        xs[i],zs[i]=x,z
        mx,mz=math.min(mx,x),math.min(mz,z)
    end
    local out={}
    for i=1,#list do
        local dx,dz=xs[i]-mx,zs[i]-mz
        if dx>15 or dz>15 then return copy(list) end
        out[i]=("%x%x"):format(dx,dz)
    end
    return {at=key(mx,my,mz),rel=table.concat(out)}
end
local function unpackCells(v)
    if v.at==nil then return v end
    local x,y,z=fast(v.at)
    local list={}
    for dx,dz in v.rel:gmatch("(%x)(%x)") do list[#list+1]=key(x+tonumber(dx,16),y,z+tonumber(dz,16)) end
    return list
end

function Queue.pack(state)
    -- Build the packed tables directly instead of copying and replacing them.
    local s={}
    for k,v in pairs(state) do
        if k~="layers" and k~="active" and k~="station" then s[k]=copy(v) end
    end
    s.layers,s.active={},{}
    for owner,g in pairs(state.active) do
        local c={}
        for k,v in pairs(g) do if k~="route" and k~="cells" then c[k]=copy(v) end end
        c.route,c.cells=g.route,g.cells
        s.active[owner]=c
    end
    if state.station then
        s.station={}
        for k,v in pairs(state.station) do if k~="routes" then s.station[k]=copy(v) end end
        s.station.routes={}
        for stage,route in pairs(state.station.routes) do s.station.routes[stage]=route end
    end
    if s.box then
        for y,layer in pairs(state.layers) do
            local same=true
            local out={}
            for k,e in ipairs(layer) do
                out[k]=packEntry(e)
                if e~=layer[1] or #e>1 then same=false end
            end
            s.layers[y]=same and layer[1] or table.concat(out,"|")
        end
    end
    for _,g in pairs(s.active) do g.route,g.cells=packPath(g.route),packCells(g.cells) end
    if s.station then
        for stage,route in pairs(s.station.routes) do s.station.routes[stage]=packPath(route) end
    end
    s.packed=true
    return s
end

function Queue.unpack(state)
    local s=copy(state)
    if not s.packed then return s end
    s.packed=nil
    if s.box then
        assert(s.box.n,"This coordinator ledger is from an older swarm version; finish or archive it first")
        local count=s.box.n*s.box.n
        for y,layer in pairs(s.layers) do
            local out={}
            if #layer==1 then
                for k=1,count do out[k]=layer end
            else
                for e in (layer.."|"):gmatch("([^|]*)|") do out[#out+1]=unpackEntry(e) end
            end
            s.layers[y]=out
        end
    end
    for _,g in pairs(s.active) do g.route,g.cells=unpackPath(g.route),unpackCells(g.cells) end
    if s.station then
        for stage,route in pairs(s.station.routes) do s.station.routes[stage]=unpackPath(route) end
    end
    return s
end

-- Load the caller's last verified commit; never initialize implicitly on boot.
-- commit(snapshot) must synchronously publish or throw, and return true.
function Queue.open(snapshot,commit)
    assert(not snapshot.box or snapshot.box.n or snapshot.packed,
        "This coordinator ledger is from an older swarm version; finish or archive it first")
    snapshot=Queue.unpack(snapshot)
    validate(snapshot)
    assert(type(commit)=="function","durable commit required")
    return setmetatable({state=copy(snapshot),commit=commit},Queue)
end

function Queue.withStation(snapshot,station,approaches)
    assert(not snapshot.station and not next(snapshot.active),"stop all assignments before enabling the station")
    assert(type(station)=="table","station config required")
    local updated=Queue.unpack(snapshot)
    for _,p in ipairs(approaches or {}) do updated.clearApproach[p]=true end
    updated.station=copy(station)
    validate(updated)
    return Queue.pack(updated)
end

function Queue:_publish(nextState,response)
    -- An ambiguous write must freeze this instance, even if the caller catches it.
    self.frozen=true
    assert(self.commit(Queue.pack(nextState))==true,"queue commit not confirmed")
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


-- Automatic quarries: one assignment per chunk, from that chunk's highest
-- workable layer, like chunk_dig mining layer by layer. A cell is workable
-- only once the cell above it is mined or blocked, so falling blocks never
-- drop into cleared space. Routes use only the top layer (shared travel) and
-- the target chunk itself, so a turtle below the top layer of its own chunk
-- never shares space with another turtle's route.
Queue.SEARCH_LIMIT=60000
local DELTAS={{0,-1,0},{-1,0,0},{0,0,-1},{0,0,1},{1,0,0},{0,1,0}}
local PLANE={{-1,0},{0,-1},{0,1},{1,0}}
local function chunkPlan(s,used,stage,fuel)
    local b,a=s.box,s.auto
    local n=b.n
    local W=16*n
    local layers=s.layers
    local function at(xi,y,zi)
        local e=layers[y][floor(xi/16)*n+floor(zi/16)+1]
        if #e==1 then return e end
        local i=(xi%16)*16+zi%16+1
        return e:sub(i,i)
    end
    local function id(xi,y,zi) return ((y-b.y0)*W+xi)*W+zi end
    local function local3(p)
        local x,y,z=p:match("^(-?%d+),(-?%d+),(-?%d+)$")
        x,y,z=tonumber(x),tonumber(y),tonumber(z)
        if x and x>=b.x0 and x<=b.x1 and z>=b.z0 and z<=b.z1 and y>=b.y0 and y<=b.y1 then
            return x-b.x0,y,z-b.z0
        end
    end
    local banned={}
    local function ban(p) local xi,y,zi=local3(p); if xi then banned[id(xi,y,zi)]=true end end
    -- Everything another assignment holds, except the cells of a chunk it is
    -- mining below the top layer: that chunk is busy, so no route enters it.
    for _,g in pairs(s.active) do
        for _,p in ipairs(g.route) do ban(p) end
        if not (g.chunk and g.chunk.y<b.y1) then for _,p in ipairs(g.cells) do ban(p) end end
    end
    for p in pairs(s.staging) do if p~=stage then ban(p) end end
    for p in pairs(s.clearApproach) do if isLane(s,p) then ban(p) end end
    local busy={}
    for _,g in pairs(s.active) do if g.chunk then busy[g.chunk.k]=true end end
    local sx,sy,sz=local3(stage)
    if not sx then return end
    local budget=Queue.SEARCH_LIMIT

    -- Route from the stage to a clear cell next to a workable cell of chunk k
    -- on layer t, then grow the assignment over that chunk layer.
    local function plan(k,t,want)
        local cx,cz=floor((k-1)/n)*16,((k-1)%n)*16
        local ty=t<b.y1 and t+1 or t
        local function workable(xi,zi)
            return at(xi,t,zi)=="u" and not banned[id(xi,t,zi)] and (t==b.y1 or at(xi,t+1,zi)~="u")
                and (not want or want(xi,zi))
        end
        local function h(xi,y,zi)
            local dx=xi<cx and cx-xi or xi>cx+15 and xi-cx-15 or 0
            local dz=zi<cz and cz-zi or zi>cz+15 and zi-cz-15 or 0
            return dx+dz+math.abs(y-ty)
        end
        -- Cheap check before searching: the chunk must touch travel space on
        -- the top layer (a clear cell in it, or beside its edge for top-layer
        -- work); otherwise no route can reach it.
        local seeded=false
        local Y=b.y1
        for xi=cx-1,cx+16 do
            for zi=cz-1,cz+16 do
                local inside=xi>=cx and xi<=cx+15 and zi>=cz and zi<=cz+15
                if xi>=0 and xi<W and zi>=0 and zi<W and (inside or t==Y)
                    and at(xi,Y,zi)=="c" and not banned[id(xi,Y,zi)] then seeded=true; break end
            end
            if seeded then break end
        end
        if not seeded and not (sx>=cx and sx<=cx+15 and sz>=cz and sz<=cz+15) then return end
        local start=id(sx,sy,sz)
        local gs,prev,pos={[start]=0},{},{[start]={sx,sy,sz}}
        local heap,hk={start},{h(sx,sy,sz)*4096}
        local function push(v,key)
            local i=#heap+1
            heap[i],hk[i]=v,key
            while i>1 do
                local j=floor(i/2)
                if hk[j]<=hk[i] then break end
                heap[i],heap[j],hk[i],hk[j]=heap[j],heap[i],hk[j],hk[i]
                i=j
            end
        end
        local function pop()
            local top=heap[1]
            local last=#heap
            heap[1],hk[1]=heap[last],hk[last]
            heap[last],hk[last]=nil,nil
            local i=1
            while true do
                local l,r,m=2*i,2*i+1,i
                if l<last and hk[l]<hk[m] then m=l end
                if r<last and hk[r]<hk[m] then m=r end
                if m==i then break end
                heap[i],heap[m],hk[i],hk[m]=heap[m],heap[i],hk[m],hk[i]
                i=m
            end
            return top
        end
        local closed={}
        local entry,first
        while #heap>0 and budget>0 do
            local v=pop()
            if not closed[v] then
                closed[v]=true
                budget=budget-1
                if budget%2048==0 and Queue.yield then Queue.yield() end
                local p=pos[v]
                local g=gs[v]
                for _,d in ipairs(DELTAS) do
                    local xi,y,zi=p[1]+d[1],p[2]+d[2],p[3]+d[3]
                    if xi>=0 and xi<W and zi>=0 and zi<W and y>=b.y0 and y<=b.y1 then
                        local inChunk=xi>=cx and xi<=cx+15 and zi>=cz and zi<=cz+15
                        if inChunk and y==t and workable(xi,zi) then
                            entry,first=v,{xi,y,zi}; break
                        end
                        local q=id(xi,y,zi)
                        if not closed[q] and not banned[q] and (y==b.y1 or (inChunk and y>=t))
                            and 2*(g+1)+s.margin<=fuel and at(xi,y,zi)=="c"
                            and (not gs[q] or gs[q]>g+1) then
                            gs[q],prev[q],pos[q]=g+1,v,{xi,y,zi}
                            push(q,(g+1+h(xi,y,zi))*4096-(g+1))
                        end
                    end
                end
                if entry then break end
            end
        end
        if not entry then return end
        local back={}
        local v=entry
        while v~=start do back[#back+1]=v; v=prev[v] end
        local route={stage}
        for j=#back,1,-1 do
            local p=pos[back[j]]
            route[#route+1]=key(p[1]+b.x0,p[2],p[3]+b.z0)
        end
        local dist=#route-1
        local cap=math.min(s.patchSize,math.floor((fuel-s.margin)/2)-dist)
        if cap<1 then return end
        local cells,seen,list={},{[first[1]*W+first[3]]=true},{first}
        local i=1
        while list[i] and #cells<cap do
            local c=list[i]
            cells[#cells+1]=key(c[1]+b.x0,t,c[3]+b.z0)
            for _,d in ipairs(PLANE) do
                local xi,zi=c[1]+d[1],c[3]+d[2]
                if xi>=cx and xi<=cx+15 and zi>=cz and zi<=cz+15 and not seen[xi*W+zi] and workable(xi,zi) then
                    seen[xi*W+zi]=true; list[#list+1]={xi,t,zi}
                end
            end
            i=i+1
        end
        return {route=route,cells=cells,fuelNeed=2*(dist+#cells)+s.margin,chunk={k=k,y=t}}
    end

    -- Lane and parking first, so later turtles get somewhere to park.
    local infraChunks={}
    for p in pairs(a.infra) do
        if workGet(s,p)=="unclaimed" and not used[p] then
            local _,k=boxCell(s,p)
            infraChunks[k]=true
        end
    end
    local function isInfra(xi,zi) return a.infra[key(xi+b.x0,b.y1,zi+b.z0)]~=nil end
    local list={}
    for k in pairs(infraChunks) do if not busy[k] then list[#list+1]=k end end
    local function distance(k)
        local cx,cz=floor((k-1)/n)*16,((k-1)%n)*16
        local dx=sx<cx and cx-sx or sx>cx+15 and sx-cx-15 or 0
        local dz=sz<cz and cz-sz or sz>cz+15 and sz-cz-15 or 0
        return dx+dz
    end
    table.sort(list,function(p,q) return distance(p)<distance(q) or (distance(p)==distance(q) and p<q) end)
    for _,k in ipairs(list) do
        local grant=plan(k,b.y1,isInfra)
        if grant then return grant end
    end

    -- Each chunk's highest layer with a workable cell.
    local function topLayer(k)
        for y=b.y1,b.y0,-1 do
            local e=layers[y][k]
            if e=="u" or (#e>1 and e:find("u",1,true)) then
                if y==b.y1 then return y end
                local above=layers[y+1][k]
                if #above==1 then
                    if above~="u" then return y end
                else
                    for i=1,256 do
                        if above:sub(i,i)~="u" and (#e==1 or e:sub(i,i)=="u") then return y end
                    end
                end
                if e=="u" then return end
            end
        end
    end
    -- Prefer this turtle's own band of chunks (straight routes from its
    -- parking column), then the highest unfinished layer, then the nearest.
    local band
    if VEC[a.heading][1]~=0 then band=function(k) return floor(sz/16)==(k-1)%n end
    else band=function(k) return floor(sx/16)==floor((k-1)/n) end end
    local candidates={}
    for k=1,n*n do
        if not busy[k] then
            local y=topLayer(k)
            if y then candidates[#candidates+1]={k=k,y=y,own=band(k) and 0 or 1,d=distance(k)+(b.y1-y)} end
        end
    end
    table.sort(candidates,function(p,q)
        if p.own~=q.own then return p.own<q.own end
        if p.y~=q.y then return p.y>q.y end
        if p.d~=q.d then return p.d<q.d end
        return p.k<q.k
    end)
    for _,c in ipairs(candidates) do
        if budget<=0 then break end
        local grant=plan(c.k,c.y)
        if grant then return grant end
    end
end

local function proposal(s,stage,fuel)
    local used=reservations(s)
    if used[stage] then return nil,"staging_reserved" end
    local grant
    if s.auto then grant=chunkPlan(s,used,stage,fuel)
    else grant=search(s,used,stage,fuel,function() return true end) end
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
    for _,p in ipairs(route) do
        if used[p] then
            local g=s.active[used[p]]
            -- A newcomer that never left the bay is holding it. Placing any
            -- turtle in the bay (or that one again) clears this.
            if g.relocate and not g.departed then return nil,"join_pending" end
            return nil,"station_busy"
        end
    end
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
        if self.diskLow then grant,reason=nil,"coordinator_disk"
        else grant,reason=proposal(s,stage,fuel-reserve) end
        if not grant and route and reason=="no_safe_patch" and proposal(s,stage,math.huge) then
            reason="patch_fuel"
        end
        if grant and reserve>0 then grant.serviceReserve=reserve; grant.fuelNeed=grant.fuelNeed+reserve end
    end
    local nextState=copyState(s)
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
        if seq==old.seq and old.kind=="finish" and old.stage==stage and old.id==id
            and old.digest==digest(evidence) then return {seq=seq,finished=id} end
        return nil,"stale_request"
    end
    local g=s.active[worker]
    if not g or g.id~=id or home(g)~=stage then return nil,"assignment_mismatch" end
    local allowed={}
    for _,p in ipairs(g.cells) do allowed[p]=true end
    for p,v in pairs(evidence) do
        if not allowed[p] or (v~="clear" and v~="blocked") then return nil,"invalid_evidence" end
    end
    local nextState=copyState(s)
    for p,v in pairs(evidence) do workSet(nextState,p,v) end
    nextState.active[worker]=nil
    promote(nextState)
    local response={seq=seq,finished=id}
    nextState.replay[worker]={seq=seq,kind="finish",stage=stage,id=id,digest=digest(evidence)}
    return self:_publish(nextState,response)
end

-- A turtle placed in the bay asks for a parking cell. The bay itself is the
-- check that it belongs here; joins are idempotent while its grant is active.
-- Refusals change nothing (so the user can lift the turtle out and retry),
-- except that an earlier newcomer that never departed is cancelled: two
-- turtles cannot both be in the bay, so that one was picked up.
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
        if active.relocate and not active.departed and active.route[1]==stage then
            return {seq=s.replay[worker].seq,grant=copy(active),stage=home(active),heading=s.auto.heading}
        end
        return nil,"already_working"
    end
    local nextState=copyState(s)
    local holder=reservations(s)[stage]
    local held=holder and s.active[holder]
    if held and held.relocate and not held.departed then
        -- That newcomer never got permission to leave the bay, and this turtle
        -- is standing in the bay now, so it was picked up. Cancel its join.
        nextState.active[holder],nextState.parked[holder]=nil,nil
        nextState.revoked=nextState.revoked or {}
        nextState.revoked[holder]=held.id
        s=nextState
        nextState=copyState(s)
    end
    local revoked=s~=self.state
    local function refuse(reason)
        -- Refusals change nothing, except that a cancelled join is still recorded.
        if revoked then return self:_publish(s,{reason=reason}) end
        return {reason=reason}
    end
    local used=reservations(s)
    if used[stage] then return refuse("bay_busy") end
    local slot=s.parked[worker]
    if not slot then
        local taken={}
        for _,p in pairs(s.parked) do taken[p]=true end
        for _,p in ipairs(s.auto.park) do
            if s.staging[p] and not taken[p] then slot=p; break end
        end
    end
    if not slot then
        local count=0
        for _ in pairs(s.parked) do count=count+1 end
        -- One turtle per chunk: every parking cell already has an owner.
        return refuse(count>=#s.auto.park and "swarm_full" or "no_parking")
    end
    local planned=s.station.routes[slot]
    local route={}
    for i=#planned,1,-1 do
        if used[planned[i]] then return refuse("lane_busy") end
        route[#route+1]=planned[i]
    end
    assert(s.nextId<2^52,"assignment IDs exhausted")
    local grant={id=s.nextId,worker=worker,relocate=true,route=route,cells={},fuelNeed=0,
        station={facing=s.station.facing,fuelTarget=s.station.fuelTarget}}
    if nextState.revoked then nextState.revoked[worker]=nil end
    local seq=(s.replay[worker] and s.replay[worker].seq or 0)+1
    nextState.nextId=s.nextId+1
    nextState.active[worker]=grant
    nextState.parked[worker]=slot
    nextState.replay[worker]={seq=seq,kind="join",stage=stage,fuel=fuel}
    return self:_publish(nextState,{seq=seq,grant=grant,stage=slot,heading=s.auto.heading})
end

-- A serviced newcomer asks before its first move out of the bay. Until this
-- is committed it cannot have left, which is what lets join() above cancel it.
function Queue:depart(worker,seq,stage,id)
    local ok,why=checkRequest(self,worker,seq,stage)
    if not ok then return nil,why end
    local s=self.state
    local old=s.replay[worker]
    if old and seq<=old.seq then
        if seq==old.seq and old.kind=="depart" and old.stage==stage and old.id==id then
            return {seq=seq,departed=id}
        end
        return nil,"stale_request"
    end
    local g=s.active[worker]
    if not g or not g.relocate or g.id~=id or home(g)~=stage then return nil,"assignment_mismatch" end
    local nextState=copyState(s)
    nextState.active[worker].departed=true
    nextState.replay[worker]={seq=seq,kind="depart",stage=stage,id=id}
    return self:_publish(nextState,{seq=seq,departed=id})
end

return Queue
