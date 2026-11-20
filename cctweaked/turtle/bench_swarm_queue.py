"""Offline benchmark of the swarm coordinator queue (requires lupa).

Simulates a full automatic quarry at the queue level: turtles join through the
bay one at a time, claim chunk-layer assignments, hold them for 1-3 rounds and
finish with random blocked cells (dense near the bottom) and some partial
finishes. Reports claim and finish times and the largest packed ledger.
No turtle movement, Rednet or CC:Tweaked runtime is involved.

Usage: python3 bench_swarm_queue.py <chunks> <bottomY> <sample_every> <max_rounds>
Example (full 9x9 from y=70 to -64, about 25 minutes):
    python3 bench_swarm_queue.py 9 -64 25 200000
"""
import os,sys,time
from pathlib import Path
from lupa.lua52 import LuaRuntime
lua=LuaRuntime()
g=lua.globals()
g.Queue=lua.execute(Path(__file__).with_name('swarm_patch_queue.lua').read_text())
lua.execute(r'''
local function encode(v)
  if type(v)=="string" then return ("%q"):format(v) end
  if type(v)~="table" then return tostring(v) end
  local parts={}
  for k,x in pairs(v) do parts[#parts+1]="["..encode(k).."]="..encode(x) end
  return "{"..table.concat(parts,",").."}"
end
ENCODE=encode
local maxSize,commits,sampleEvery=0,0,1
local lastPacked
local function commit(st)
  commits=commits+1; lastPacked=st
  if commits%sampleEvery==0 then maxSize=math.max(maxSize,#encode(st)) end
  return true
end
function bench(chunks,bottom,every,seed,maxRounds)
  sampleEvery=every
  math.randomseed(seed)
  local s=Queue.define{worker=1,bay="0,70,0",park="0,69,-1",heading=0,chunks=chunks,bottom=bottom,
    quarryId="q",manifestId="m",dimension="auto"}
  local q=Queue.open(Queue.pack(s),commit)
  local N=chunks*chunks
  local seq,holding,joinPending={},{},nil
  seq[1]=1
  local nextWorker=2
  local stats={claims=0,claimTime=0,worst=0,reasons={},finishTime=0,finishes=0,partial=0,joins=0,blocked=0,cells=0}
  local function finish(w,g)
    local ev={}
    local cut=#g.cells
    if #g.cells>8 and math.random()<0.05 then cut=math.floor(#g.cells/2); stats.partial=stats.partial+1 end
    for i=1,cut do
      local p=g.cells[i]
      local y=tonumber(p:match(",(-?%d+),"))
      local blocked=(y<=bottom+4 and math.random()<0.35) or math.random()<0.002
      ev[p]=blocked and "blocked" or "clear"
      if blocked then stats.blocked=stats.blocked+1 end
      stats.cells=stats.cells+1
    end
    seq[w]=seq[w]+1
    local t=os.clock()
    assert(q:finish(w,seq[w],q.state.parked[w],g.id,ev))
    stats.finishTime=stats.finishTime+(os.clock()-t); stats.finishes=stats.finishes+1
  end
  local rounds=0
  while rounds<maxRounds do
    rounds=rounds+1
    -- newcomer at the bay
    if joinPending then
      local w,j=joinPending[1],joinPending[2]
      seq[w]=j.seq+1
      assert(q:depart(w,seq[w],j.stage,j.grant.id))
      seq[w]=seq[w]+1
      assert(q:finish(w,seq[w],j.stage,j.grant.id,{}))
      joinPending=nil
    elseif nextWorker<=N+1 then
      local j=q:join(nextWorker,"0,70,0","unlimited")
      if j and j.grant then joinPending={nextWorker,j}; stats.joins=stats.joins+1; nextWorker=nextWorker+1
      elseif j and j.reason=="swarm_full" then stats.full=(stats.full or 0)+1; nextWorker=N+2 end
    end
    local idle=0
    for w in pairs(q.state.parked) do
      if not (joinPending and joinPending[1]==w) and seq[w] then
        local h=holding[w]
        if h then
          h.left=h.left-1
          if h.left<=0 then finish(w,h.g); holding[w]=nil end
        elseif not q.state.active[w] then
          seq[w]=seq[w]+1
          local t=os.clock()
          local r=q:claim(w,seq[w],q.state.parked[w],100000)
          local dt=os.clock()-t
          stats.claims=stats.claims+1; stats.claimTime=stats.claimTime+dt
          if dt>stats.worst then stats.worst=dt end
          if r.grant then holding[w]={g=r.grant,left=math.random(1,3)}
          else stats.reasons[r.reason]=(stats.reasons[r.reason] or 0)+1; idle=idle+1 end
        end
      end
    end
    if next(holding)==nil and not joinPending and nextWorker>N+1 then
      local done=true
      for y,layer in pairs(q.state.layers) do for k,e in ipairs(layer) do if e:find("u",1,true) then done=false end end end
      if done or idle>0 then if done then break end end
    end
    if rounds%REPORT==0 then
      local mixed=0
      for _,layer in pairs(q.state.layers) do for _,e in ipairs(layer) do if #e>1 then mixed=mixed+1 end end end
      io.stderr:write(("round %d claims %d avg %.1fms worst %.0fms maxsize %dKB mixed chunk-layers %d turtles %d\n"):format(
        rounds,stats.claims,stats.claimTime/stats.claims*1000,stats.worst*1000,math.floor(maxSize/1024),mixed,nextWorker-1))
    end
  end
  local remaining=0
  for y,layer in pairs(q.state.layers) do for k,e in ipairs(layer) do local _,c=e:gsub("u","") if #e==1 and e=="u" then c=256 end remaining=remaining+c end end
  stats.remaining=remaining; stats.rounds=rounds; stats.maxSize=maxSize; stats.commits=commits
  local t=os.clock(); local text=encode(lastPacked); stats.encodeMs=(os.clock()-t)*1000; stats.finalSize=#text
  return stats
end
''')
g.REPORT=int(os.environ.get('EVERY','100'))
chunks=int(sys.argv[1]); bottom=int(sys.argv[2]); every=int(sys.argv[3]); rounds=int(sys.argv[4])
t=time.time()
s=g.bench(chunks,bottom,every,7,rounds)
d={k:s[k] for k in s if k!='reasons'}
print(d); print(dict(s['reasons'])); print('wall',time.time()-t)
