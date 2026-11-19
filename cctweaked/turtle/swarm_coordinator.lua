-- Dashboard computer: swarm_coordinator init|run [config.json]
local mode,path=...
assert(mode=="init" or mode=="run","Usage: swarm_coordinator init|run [config.json]")
assert(not turtle,"Run the coordinator on a dashboard computer")
local dir=fs.getDir(shell.getRunningProgram())
local M=assert(loadfile(fs.combine(dir,"swarm_common.lua")))()
local Queue=assert(loadfile(fs.combine(dir,"swarm_patch_queue.lua")))()
local c=M.config(path or "/swarm_coordinator.json")
assert(type(c.workers)=="table" or c.allowAnyWorker==true,"configure workers or opt into a trusted open swarm")
local STATE="/.chunk_dig_swarm_coordinator"
local state,commit
if mode=="init" then
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
state,commit=M.store(STATE)
assert(state.quarryId==c.quarryId and state.manifestId==c.manifestId and state.dimension==c.dimension,
    "config does not match the saved quarry manifest")
local q=Queue.open(state,commit)
M.openModem()
print("Coordinating swarm "..state.quarryId.." on computer "..os.getComputerID())
local function authorized(sender,stage)
    local allowed=c.workers and c.workers[tostring(sender)]
    return allowed==stage or (c.allowAnyWorker==true and allowed==nil)
end
while true do
    local sender,m=rednet.receive(M.protocol)
    if M.sameJob(c,m) and type(m.stage)=="string" and authorized(sender,m.stage)
        and type(m.token)=="string" and #m.token<=64 then
        local result,why
        if m.kind=="claim" then
            result,why=q:claim(sender,m.seq,m.stage,m.fuel)
        elseif m.kind=="finish" then
            -- Trusted worker emits this only from a persisted, disarmed terminal checkpoint.
            result,why=q:finish(sender,m.seq,m.stage,m.id,m.evidence)
        elseif m.kind=="sync" then
            local g=q.state.active[sender]
            if not q.frozen and g and g.id==m.id and g.route[1]==m.stage then
                result={grant=g}
            else why="assignment_mismatch" end
        end
        if result or why then
            rednet.send(sender,M.envelope(c,{kind=m.kind,token=m.token,result=result,error=why}),M.protocol)
        end
    end
end
