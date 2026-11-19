local M={protocol="turtle_quarry_swarm_v1",telemetry="turtle_quarry_v1"}

function M.key(x,y,z)
    assert(type(x)=="number" and type(y)=="number" and type(z)=="number"
        and x%1==0 and y%1==0 and z%1==0,"expected block coordinates")
    return ("%d,%d,%d"):format(x,y,z)
end

function M.xyz(s)
    assert(type(s)=="string","expected coordinates")
    local x,y,z=s:match("^(-?%d+),(-?%d+),(-?%d+)$")
    x,y,z=tonumber(x),tonumber(y),tonumber(z)
    assert(M.key(x,y,z)==s and math.abs(x)<=30000000 and math.abs(y)<=30000000
        and math.abs(z)<=30000000,"invalid world coordinates")
    return x,y,z
end

function M.step(a,b)
    local x,y,z=M.xyz(a)
    local u,v,w=M.xyz(b)
    local dx,dy,dz=u-x,v-y,w-z
    assert(math.abs(dx)+math.abs(dy)+math.abs(dz)==1,"nonadjacent swarm step")
    if dy~=0 then return dy>0 and "Up" or "Down" end
    return "",dx==1 and 1 or dx==-1 and 3 or dz==1 and 2 or 0
end

function M.neighbors(s)
    local x,y,z=M.xyz(s)
    return {M.key(x,y-1,z),M.key(x-1,y,z),M.key(x,y,z-1),M.key(x,y,z+1),M.key(x+1,y,z),M.key(x,y+1,z)}
end

local function read(path)
    local f=assert(fs.open(path,"r"))
    local value=f.readAll()
    f.close()
    return assert(value,"empty file: "..path)
end

function M.config(path)
    return assert(textutils.unserializeJSON(read(path)),"invalid swarm JSON: "..path)
end

local function checksum(s)
    local a,b=1,0
    for i=1,#s do a=(a+s:byte(i))%65521; b=(b+a)%65521 end
    return ("%.0f"):format(a+b*65536)
end

-- Append a committed generation, then prune. Never replace the latest one in
-- place, nor fall back after finding a corrupt committed snapshot.
function M.store(dir,initialize)
    if initialize then
        assert(not fs.exists(dir),"swarm store already exists")
        fs.makeDir(dir)
    else assert(fs.isDir(dir),"swarm store missing; do not recreate an active ledger") end
    local gen,history=0,{}
    for _,name in ipairs(fs.list(dir)) do
        local n=tonumber(name:match("^state%-(%d+)$"))
        if n then
            assert(n>=1 and n<2^52 and ("state-%.0f"):format(n)==name,"invalid swarm generation")
            gen=math.max(gen,n); history[#history+1]=n
        end
    end
    local function path(n) return fs.combine(dir,("state-%.0f"):format(n)) end
    local function decode(blob,n)
        local version,g,digest,body=blob:match("^SWARM (%d+) (%d+) (%d+)\n(.*)$")
        assert(version=="1" and tonumber(g)==n and checksum(body or "")==digest,"corrupt swarm snapshot")
        local state=textutils.unserialize(body)
        assert(type(state)=="table","invalid swarm snapshot")
        return state
    end
    local state
    if initialize then assert(gen==0,"nonempty new swarm store")
    else
        assert(gen>0,"swarm store has no committed snapshot")
        assert(gen==1 or fs.exists(path(gen-1)),"previous swarm generation is missing")
        state=decode(read(path(gen)),gen)
        if gen>1 then decode(read(path(gen-1)),gen-1) end
    end
    local function commit(value)
        local n=gen+1
        assert(n<2^52 and not fs.exists(path(n)),"concurrent writer or generation exhausted")
        local body=textutils.serialize(value,{compact=true,allow_repetitions=true})
        local blob=("SWARM 1 %.0f %s\n"):format(n,checksum(body))..body
        local tmp=path(n)..".tmp"
        local f=assert(fs.open(tmp,"w"))
        f.write(blob); f.close()
        assert(read(tmp)==blob,"swarm staged write failed verification")
        fs.move(tmp,path(n))
        gen=n
        for i=#history,1,-1 do
            if history[i]<gen-1 then
                fs.delete(path(history[i]))
                table.remove(history,i)
            end
        end
        history[#history+1]=gen
        return true
    end
    return state,commit
end

function M.openModem()
    local modem=assert(peripheral.find("modem",function(_,m) return m.isWireless and m.isWireless() end),
        "wireless or Ender modem required")
    rednet.open(peripheral.getName(modem))
end

function M.sameJob(c,m)
    return type(m)=="table" and m.version==1 and m.quarryId==c.quarryId
        and m.manifestId==c.manifestId and m.dimension==c.dimension
end

function M.envelope(c,m)
    m.version,m.quarryId,m.manifestId,m.dimension=1,c.quarryId,c.manifestId,c.dimension
    return m
end

return M
