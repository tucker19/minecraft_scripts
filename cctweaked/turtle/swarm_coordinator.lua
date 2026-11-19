-- Dashboard computer:
--   swarm_coordinator                 automatic setup and run (no config files)
--   swarm_coordinator init|run|enable-station [config.json]   manual manifests
local mode,path=...
mode=mode or "run"
assert(mode=="init" or mode=="run" or mode=="enable-station",
    "Usage: swarm_coordinator [run] | init|enable-station [config.json]")
assert(not turtle,"Run the coordinator on a dashboard computer")
local dir=fs.getDir(shell.getRunningProgram())
local M=assert(loadfile(fs.combine(dir,"swarm_common.lua")))()
local Queue=assert(loadfile(fs.combine(dir,"swarm_patch_queue.lua")))()
local STATE="/.chunk_dig_swarm_coordinator"
local CONFIG=path or "/swarm_coordinator.json"
local state,commit,c

local function manualConfig()
    local config=M.config(CONFIG)
    assert(type(config.workers)=="table" or config.allowAnyWorker==true,
        "configure workers or opt into a trusted open swarm")
    return config
end

-- Manual manifests (advanced use and older ledgers).
if mode=="init" then
    c=manualConfig()
    if c.workBox then
        assert(not c.work and type(c.workBox)=="table","choose work or workBox")
        local x,y,z=M.xyz(c.workBox.min)
        local u,v,w=M.xyz(c.workBox.max)
        assert(u>=x and v>=y and w>=z and (u-x+1)*(v-y+1)*(w-z+1)<=65536,
            "workBox must be ordered and contain at most 65536 cells")
        c.work={}
        for wx=x,u do for wy=y,v do for wz=z,w do
            c.work[#c.work+1]=M.key(wx,wy,wz)
        end end end
    end
    local initial=Queue.initial(c)
    state,commit=M.store(STATE,true)
    commit(initial)
    print("Created swarm ledger for "..initial.quarryId.."; run swarm_coordinator run")
    return
end
if mode=="run" and fs.isDir(STATE) and #fs.list(STATE)==0 then
    -- Rebooted between creating the ledger folder and its first write. Nothing
    -- was committed or answered, so the first turtle's retry defines it again.
    fs.delete(STATE)
end
if fs.exists(STATE) then
    state,commit=M.store(STATE)
    if state.auto then
        assert(mode=="run","automatic quarries need no enable-station step")
        c={quarryId=state.quarryId,manifestId=state.manifestId,dimension=state.dimension}
    else
        c=manualConfig()
        assert(state.quarryId==c.quarryId and state.manifestId==c.manifestId and state.dimension==c.dimension,
            "config does not match the saved quarry manifest")
        if mode=="enable-station" then
            commit(Queue.withStation(state,c.station,c.clearApproach))
            print("Shared station added to existing swarm; run swarm_coordinator run")
            return
        end
        assert(not c.station or state.station,"station is not installed in the ledger; run enable-station")
    end
else
    assert(mode=="run","No swarm ledger; run swarm_coordinator with no arguments for automatic setup")
end

-- Keep Rednet and other programs responsive during long searches of a large
-- ledger. Events that arrive meanwhile are put back in order.
Queue.yield=function()
    if not os.queueEvent then return end
    local backlog={}
    os.queueEvent("swarm_yield")
    while true do
        local ev=table.pack(os.pullEventRaw())
        if ev[1]=="swarm_yield" then break end
        if ev[1]=="terminate" then error("Terminated",0) end
        if ev[1]~="modem_message" then backlog[#backlog+1]=ev end
    end
    for _,ev in ipairs(backlog) do os.queueEvent(table.unpack(ev,1,ev.n)) end
end

-- Start again after a reboot. Existing startup logic is kept intact: the
-- hook opens a separate tab, then the old startup runs unchanged.
local HOOK=('if multishell then shell.openTab("/%s") end')
    :format((shell.getRunningProgram():gsub("^/+",""):gsub("%.lua$","")))
local function installStartup()
    if not multishell then
        print("Not an advanced computer: add swarm_coordinator to startup yourself to resume after reboots")
        return
    end
    if fs.isDir("/startup") then
        local p="/startup/00_swarm_coordinator.lua"
        if not fs.exists(p) then
            local h=fs.open(p,"w"); h.write(HOOK.."\n"); h.close()
            print("Added "..p)
        end
        return
    end
    local old=""
    if fs.exists("/startup.lua") then
        local h=fs.open("/startup.lua","r"); old=h.readAll() or ""; h.close()
    end
    if old:find(HOOK,1,true) then return end
    if old~="" and not fs.exists("/startup.lua.before_swarm") then
        local h=fs.open("/startup.lua.before_swarm","w"); h.write(old); h.close()
    end
    local h=fs.open("/startup.lua","w"); h.write(HOOK.."\n"..old); h.close()
    print("Added swarm_coordinator tab to /startup.lua (previous copy: /startup.lua.before_swarm)")
end

M.openModem()
rednet.host(M.protocol,"swarm_coordinator_"..os.getComputerID())
installStartup()

local function reply(sender,ident,m,result,why)
    rednet.send(sender,M.envelope(ident,{kind=m.kind,token=m.token,result=result,error=why}),M.protocol)
end
local function plain(why) return (tostring(why):gsub("^[^:]*:%d+: ","")) end
local function request(m)
    return type(m)=="table" and m.version==1 and type(m.token)=="string" and #m.token<=64
end

if not state then
    print("Swarm coordinator "..os.getComputerID().." ready.")
    print("First turtle, sitting in the bay: chunk_dig_swarm new <chunks>")
    local epoch=os.epoch and os.epoch("utc") or 0
    while not state do
        local sender,m=rednet.receive(M.protocol)
        if request(m) and m.kind=="define" then
            local id=("swarm-%d-%.0f"):format(os.getComputerID(),epoch)
            local ok,built=pcall(Queue.define,{worker=sender,bay=m.bay,park=m.stage,heading=m.heading,
                chunks=m.chunks,bottom=m.bottom,quarryId=id,manifestId=id.."-auto",dimension="auto"})
            if ok then
                local _,save=M.store(STATE,true)
                save(built)
                state,commit=built,save
                c={quarryId=built.quarryId,manifestId=built.manifestId,dimension=built.dimension}
                print("Quarry defined by turtle "..sender..": "..m.chunks.." chunk(s) from "..m.bay)
                reply(sender,c,m,Queue.defineResult(state))
            else
                reply(sender,{},m,nil,plain(built))
            end
        elseif request(m) and m.kind=="join" then
            reply(sender,{},m,nil,"No quarry defined yet; run chunk_dig_swarm new <chunks> on the first turtle")
        end
    end
end

local q=Queue.open(state,commit)
print("Coordinating swarm "..state.quarryId.." on computer "..os.getComputerID())
local function authorized(sender,stage)
    if q.state.auto then return q.state.parked[sender]==stage end
    local allowed=c.workers and c.workers[tostring(sender)]
    return allowed==stage or (c.allowAnyWorker==true and allowed==nil)
end
local function sameDefine(a,m)
    return m.bay==a.bay and m.heading==a.heading and m.chunks==a.chunks and m.bottom==a.bottom
end
while true do
    local sender,m=rednet.receive(M.protocol)
    if request(m) and q.state.auto and (m.kind=="define" or m.kind=="join") then
        local a=q.state.auto
        if m.kind=="define" then
            -- A first turtle that lost the reply receives the same answer again.
            if sender==a.definer and sameDefine(a,m) then reply(sender,c,m,Queue.defineResult(q.state))
            else reply(sender,c,m,nil,"Quarry already defined; place this turtle in the bay and run chunk_dig_swarm") end
        else
            local result,why=q:join(sender,m.stage,m.fuel)
            if result or why then reply(sender,c,m,result,why) end
        end
    elseif request(m) and (m.kind=="define" or m.kind=="join") then
        reply(sender,c,m,nil,"This coordinator runs a manual manifest; automatic setup is unavailable")
    elseif request(m) and M.sameJob(c,m) and type(m.stage)=="string" and authorized(sender,m.stage) then
        local result,why
        if m.kind=="claim" then
            result,why=q:claim(sender,m.seq,m.stage,m.fuel)
        elseif m.kind=="service" then
            result,why=q:service(sender,m.seq,m.stage,m.fuel)
        elseif m.kind=="finish" then
            -- Trusted worker emits this only from a persisted, disarmed terminal checkpoint.
            result,why=q:finish(sender,m.seq,m.stage,m.id,m.evidence)
        elseif m.kind=="sync" then
            local g=q.state.active[sender]
            local stage=g and (g.relocate and g.route[#g.route] or g.route[1])
            if not q.frozen and g and g.id==m.id and stage==m.stage then
                result={grant=g}
            else why="assignment_mismatch" end
        end
        if result or why then reply(sender,c,m,result,why) end
    end
end
