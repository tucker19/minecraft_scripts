"""Offline Lua tests for the dynamic swarm scheduling core (requires lupa)."""
import tempfile
import unittest
from pathlib import Path

try:
    from lupa.lua52 import LuaRuntime
except ImportError:
    from lupa import LuaRuntime


class PatchQueueTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "queue.lua"
        self.lua = LuaRuntime()
        g = self.lua.globals()
        g.Queue = self.lua.execute(Path(__file__).with_name("swarm_patch_queue.lua").read_text())

        def commit(data):
            staged = path.with_suffix(".tmp")
            staged.write_text(data)
            staged.replace(path)
            return True

        g.write_commit = commit
        g.read_commit = path.read_text
        self.lua.execute("""
            local function encode(v)
                if type(v)=="string" then return ("%q"):format(v) end
                if type(v)~="table" then return tostring(v) end
                local parts={}
                for k,x in pairs(v) do
                    parts[#parts+1]="["..encode(k).."]="..encode(x)
                end
                return "{"..table.concat(parts,",").."}"
            end
            function commit(state) return write_commit("return "..encode(state)) end
            function reopen() return Queue.open(assert(load(read_commit()))(),commit) end
            function create(stage,approach,work,patchSize,margin)
                assert(commit(Queue.initial{quarryId="q",manifestId="settings-1",dimension="overworld",
                    staging=stage,clearApproach=approach,work=work,patchSize=patchSize,margin=margin}))
                return reopen()
            end
            function claim(q,id,seq,stage,fuel)
                local reply,why=q:claim(id,seq,stage,fuel)
                assert(reply,why)
                return reply
            end
        """)

    def test_automatic_layout_promotes_parking_and_gates_joins(self):
        self.lua.execute("""
            -- First turtle in bay 0,70,0 probed north; 2x2 chunks down to y=-64.
            local s=Queue.define{worker=7,bay="0,70,0",park="0,69,-1",heading=0,chunks=2,bottom=-64,
                quarryId="q",manifestId="m",dimension="auto"}
            assert(s.box.x0==0 and s.box.x1==31 and s.box.z0==-31 and s.box.z1==0 and s.box.n==2)
            assert(s.box.y0==-64 and s.box.y1==69 and s.station.facing=="south")
            -- One parking cell per chunk: the turtle limit is the chunk count.
            local park=s.auto.park
            assert(#park==4 and park[1]=="0,69,-1" and park[2]=="16,69,-1" and park[3]=="1,69,-1" and park[4]=="17,69,-1")
            assert(s.staging["0,69,-1"] and s.parked[7]=="0,69,-1" and s.clearApproach["0,69,0"])
            local route=s.station.routes["0,69,-1"]
            assert(#route==3 and route[2]=="0,69,0" and route[3]=="0,70,0")
            -- Untouched layers are stored as one character.
            assert(commit(Queue.pack(s)))
            assert(#read_commit()<4000,"compact ledger is "..#read_commit().." bytes")
            local q=reopen()
            local seq={[7]=1}
            local function nextSeq(w) seq[w]=(seq[w] or 0)+1; return seq[w] end
            local function clearAll(w,r)
                local evidence={}
                for _,p in ipairs(r.grant.cells) do evidence[p]="clear" end
                assert(q:finish(w,nextSeq(w),q.state.parked[w],r.grant.id,evidence))
            end
            -- Newcomer before any extra parking exists: refused with no change.
            assert(q:join(8,"0,70,0",0).reason=="no_parking")
            assert(q:join(8,"5,70,5",0)==nil)
            -- The first claim digs this chunk's lane and parking cells first.
            local r=claim(q,7,nextSeq(7),"0,69,-1",5000)
            assert(r.grant.chunk.k==2 and r.grant.chunk.y==69)
            for _,p in ipairs(r.grant.cells) do assert(q.state.auto.infra[p],p.." is not lane/parking") end
            clearAll(7,r)
            q=reopen()
            assert(q.state.staging["1,69,-1"] and q.state.clearApproach["1,69,0"])
            -- A service grant holds the bay, so a newcomer is told to wait.
            assert(q:service(7,nextSeq(7),"0,69,-1",5000).grant)
            assert(q:join(8,"0,70,0",0).reason=="bay_busy")
            assert(q:finish(7,nextSeq(7),"0,69,-1",q.state.active[7].id,{}))
            local j=q:join(8,"0,70,0","unlimited")
            local g=j.grant
            assert(g.relocate and j.stage=="1,69,-1" and j.seq==1 and #g.route==4)
            assert(g.route[1]=="0,70,0" and g.route[2]=="0,69,0" and g.route[3]=="1,69,0" and g.route[4]=="1,69,-1")
            local again=q:join(8,"0,70,0","unlimited")
            assert(again.grant.id==g.id and again.seq==1)
            assert(q:depart(8,2,"1,69,-1",g.id).departed==g.id)
            assert(q:join(9,"0,70,0",0).reason=="bay_busy")
            q=reopen()
            assert(q:finish(8,3,"1,69,-1",g.id,{}))
            seq[8]=3
            assert(not q.state.active[8] and q.state.parked[8]=="1,69,-1")
            -- Turtle 7 keeps mining until the far chunk's lane and parking exist.
            local guard=0
            while not (q.state.staging["16,69,-1"] and q.state.staging["17,69,-1"]) do
                guard=guard+1; assert(guard<40,"far parking never opened")
                clearAll(7,claim(q,7,nextSeq(7),"0,69,-1",5000))
            end
            -- Turtle 9 joins but is picked up before departing; turtle 10 clears it.
            local j9=q:join(9,"0,70,0",0)
            assert(j9.grant and j9.stage=="16,69,-1")
            local _,why=q:service(8,nextSeq(8),"1,69,-1",5000)
            assert(q.state.replay[8].reason=="join_pending")
            local j10=q:join(10,"0,70,0",0)
            assert(j10.grant and j10.stage=="16,69,-1" and q.state.revoked[9]==j9.grant.id)
            assert(q:depart(9,2,"16,69,-1",j9.grant.id)==nil)
            q=reopen()
            assert(q:depart(10,2,"16,69,-1",j10.grant.id))
            assert(q:finish(10,3,"16,69,-1",j10.grant.id,{}))
            seq[10]=3
            local again9=q:join(9,"0,70,0",0)
            assert(again9.grant and again9.stage=="17,69,-1" and not q.state.revoked[9])
            assert(q:depart(9,again9.seq+1,again9.stage,again9.grant.id))
            assert(q:finish(9,again9.seq+2,again9.stage,again9.grant.id,{}))
            seq[9]=again9.seq+2
            -- Four chunks, four turtles: the next one is told the swarm is full.
            assert(q:join(11,"0,70,0",0).reason=="swarm_full")
            -- All four claim at once: one assignment per chunk, never under an unmined cell,
            -- and mining routes never use the service lane.
            local function char(p)
                local x,y,z=p:match("^(-?%d+),(-?%d+),(-?%d+)$")
                x,y,z=tonumber(x),tonumber(y),tonumber(z)
                local b=q.state.box
                local xi,zi=x-b.x0,z-b.z0
                local e=q.state.layers[y][math.floor(xi/16)*b.n+math.floor(zi/16)+1]
                if #e==1 then return e end
                local i=(xi%16)*16+zi%16+1
                return e:sub(i,i)
            end
            local deepest=69
            for round=1,30 do
                local held,chunks={},{}
                for _,w in ipairs({7,8,9,10}) do
                    local r=claim(q,w,nextSeq(w),q.state.parked[w],100000)
                    if r.grant then
                        local c=r.grant.chunk
                        assert(not chunks[c.k],"two assignments in chunk "..c.k); chunks[c.k]=true
                        for _,p in ipairs(r.grant.route) do assert(q.state.auto.infra[p]~="lane" or p==r.grant.route[1]) end
                        for _,p in ipairs(r.grant.cells) do
                            local x,y,z=p:match("^(-?%d+),(-?%d+),(-?%d+)$")
                            assert(tonumber(y)==c.y)
                            if c.y<69 then assert(char(x..","..(c.y+1)..","..z)~="u","cell under unmined "..p) end
                        end
                        deepest=math.min(deepest,c.y)
                        held[#held+1]={w,r}
                    end
                end
                assert(round>3 or #held>=2,"turtles did not work in parallel")
                for _,h in ipairs(held) do clearAll(h[1],h[2]) end
            end
            assert(deepest<69,"never went below the top layer")
        """)

    def test_packed_ledger_round_trips(self):
        self.lua.execute("""
            local s=Queue.define{worker=1,bay="0,70,0",park="0,69,-1",heading=0,chunks=3,bottom=0,
                quarryId="q",manifestId="m",dimension="auto"}
            math.randomseed(3)
            local sym={"u","c","b"}
            for y=0,69 do
                for k=1,9 do
                    local mode=(y+k)%4
                    if mode==0 then s.layers[y][k]=sym[math.random(1,3)]
                    else
                        local t={}
                        for i=1,256 do
                            t[i]=mode==1 and (i<=100 and "c" or "u") or sym[math.random(1,3)]
                        end
                        s.layers[y][k]=table.concat(t)
                    end
                end
            end
            for k=1,9 do s.layers[69][k]="c" end
            for k=1,9 do s.layers[68][k]="b" end
            local p=Queue.pack(s)
            assert(p.packed and p.layers[69]=="c" and p.layers[68]=="b")
            local u=Queue.unpack(p)
            for y=0,69 do for k=1,9 do assert(u.layers[y][k]==s.layers[y][k],y.." "..k) end end
            -- RLE for runs, 4 cells per character otherwise.
            assert(#p.layers[2]<9*70)
            -- Routes and cells are stored compactly and unpack to the same lists.
            local r={"0,69,-1","1,69,-1","1,68,-1","1,68,-2"}
            local c={"1,67,-2","2,67,-2","2,67,-3"}
            s.active[1]={id=9,worker=1,route=r,cells=c,fuelNeed=0}
            local again=Queue.unpack(Queue.pack(s)).active[1]
            for i=1,4 do assert(again.route[i]==r[i]) end
            for i=1,3 do assert(again.cells[i]==c[i]) end
            assert(type(Queue.pack(s).active[1].route.dirs)=="string")
            -- A ledger written before chunk layers existed is refused clearly.
            local old={box={x0=0,x1=15,y0=0,y1=1,z0=0,z1=15,area=256},layers={},active={}}
            local ok,why=pcall(Queue.open,old,function() return true end)
            assert(not ok and tostring(why):find("older swarm version",1,true),tostring(why))
            -- A full-depth 9x9 quarry fits the coordinator's normal disk.
            local big=Queue.define{worker=1,bay="0,70,0",park="0,69,-1",heading=0,chunks=9,bottom=-64,
                quarryId="q",manifestId="m",dimension="auto"}
            assert(Queue.diskNeeded(big)<1000000,Queue.diskNeeded(big))
        """)

    def test_low_coordinator_disk_pauses_new_work(self):
        self.lua.execute("""
            local s=Queue.define{worker=7,bay="0,70,0",park="0,69,-1",heading=0,chunks=1,bottom=60,
                quarryId="q",manifestId="m",dimension="auto"}
            assert(commit(Queue.pack(s)))
            local q=reopen()
            q.diskLow=true
            local r=claim(q,7,2,"0,69,-1",5000)
            assert(r.reason=="coordinator_disk" and not r.grant)
            q=reopen()
            assert(q.state.replay[7].reason=="coordinator_disk")
            -- Space freed: the next request gets work.
            assert(claim(q,7,3,"0,69,-1",5000).grant)
        """)

    def test_six_joins_in_same_chunk_without_overlapping_work_or_routes(self):
        self.lua.execute("""
            local staging,work={},{}
            for x=0,5 do
                staging[#staging+1]=x..",0,0"
                for z=0,3 do work[#work+1]=x..",-1,"..z end
            end
            local q=create(staging,staging,work,2,1)
            local reserved={}
            for i=1,6 do
                if i==5 then q=reopen() end
                local g=assert(claim(q,i,1,staging[i],10).grant)
                assert(g.id==i and #g.cells==2 and g.route[1]==staging[i] and #g.route==1)
                for _,p in ipairs(g.cells) do assert(not reserved[p]); reserved[p]=i end
            end
            assert(claim(q,7,1,staging[1],10).reason=="staging_reserved")
        """)

    def test_shared_access_conflict_wraps_up_then_reuses_cleared_route(self):
        self.lua.execute("""
            local a,b,c="0,0,0","2,0,0","1,0,0"
            local upper,lower="1,-1,0","1,-2,0"
            local q=create({a,b},{a,b,c},{upper,lower},1,1)
            local g=assert(claim(q,10,1,a,5).grant)
            assert(g.route[2]==c and g.cells[1]==upper)
            assert(claim(q,11,1,b,9).reason=="no_safe_patch")
            q=reopen()
            assert(claim(q,10,1,a,5).grant.id==g.id)
            assert(claim(q,11,2,b,9).reason=="no_safe_patch")
            assert(not q:finish(11,3,b,g.id,{}))
            assert(not q:finish(10,2,a,g.id,{[lower]="clear"}))
            assert(q:finish(10,2,a,g.id,{[upper]="clear"}).finished==g.id)
            q=reopen()
            assert(q:finish(10,2,a,g.id,{[upper]="clear"}).finished==g.id)
            assert(not q:finish(10,2,a,g.id,{}))
            assert(not q:claim(10,1,a,5))
            assert(claim(q,11,2,b,9).reason=="no_safe_patch") -- replay stays stable
            assert(claim(q,11,3,b,6).reason=="no_safe_patch") -- not enough round-trip fuel
            local h=assert(claim(q,11,4,b,7).grant)
            assert(h.route[2]==c and h.route[3]==upper and h.cells[1]==lower and h.id~=g.id)
            assert(h.fuelNeed==7)
        """)

    def test_partial_return_does_not_certify_the_rest_and_worker_can_claim_again(self):
        self.lua.execute("""
            local a="0,0,0"
            local p,r,s="0,-1,0","0,-1,1","0,-2,0"
            local q=create({a},{a},{p,r,s},3,1)
            local g=assert(claim(q,1,1,a,7).grant)
            assert(#g.cells==3)
            assert(q:finish(1,2,a,g.id,{[p]="clear",[r]="blocked"}))
            local h=assert(claim(reopen(),1,3,a,"unlimited").grant)
            assert(h.id~=g.id and h.route[2]==p and h.cells[1]==s and #h.cells==1)
        """)

    def test_failed_commit_freezes_but_reopen_replays_committed_grant(self):
        self.lua.execute("""
            local a="0,0,0"
            create({a},{a},{"0,-1,0"},2,1)
            local q=Queue.open(assert(load(read_commit()))(),function(state)
                commit(state)
                error("lost commit acknowledgement")
            end)
            assert(not pcall(q.claim,q,1,1,a,5))
            local result,why=q:claim(1,1,a,5)
            assert(not result and why=="queue_frozen")
            local g=assert(claim(reopen(),1,1,a,5).grant)
            assert(g.id==1)
            assert(not reopen():claim(1,1,a,6))
        """)

    def test_station_enable_preserves_work_and_shares_the_mining_route_lock(self):
        self.lua.execute("""
            local a,b,hub,bay="0,0,0","2,0,0","1,0,0","1,0,1"
            local done,shared,behind="0,1,0","1,-1,0","1,-1,1"
            local q=create({a,b},{a,b,hub},{done,shared,behind},1,1)
            local config={bay=bay,facing="south",fuelTarget=900,
                routes={[a]={a,hub,bay},[b]={b,hub,bay}}}
            local g=assert(claim(q,1,1,a,20).grant)
            assert(not pcall(Queue.withStation,q.state,config,{bay}))
            assert(q:finish(1,2,a,g.id,{[done]="clear"}))
            assert(not pcall(Queue.withStation,q.state,config,{bay,"1,1,1"}))
            assert(commit(Queue.withStation(q.state,config,{bay})))
            q=reopen()
            assert(q.state.work[done]=="clear" and q.state.nextId==g.id+1)
            assert(claim(q,1,3,a,9).reason=="patch_fuel")
            local mine=assert(claim(q,1,4,a,10).grant)
            assert(mine.route[2]==hub and mine.cells[1]==shared and mine.serviceReserve==5)
            assert(q:service(2,1,b,20).reason=="station_busy")
            assert(q:finish(1,5,a,mine.id,{}))
            local service=assert(q:service(2,2,b,20).grant)
            assert(claim(q,1,6,a,20).reason=="no_safe_patch")
            assert(not q:finish(2,3,b,service.id,{[shared]="clear"}))
            assert(q:finish(2,3,b,service.id,{}))
            assert(not q:service(2,2,b,20))
            local mine2=assert(claim(q,1,7,a,20).grant)
            assert(q:finish(1,8,a,mine2.id,{[shared]="blocked"}))
            assert(claim(q,1,9,a,20).reason=="no_safe_patch")
            assert(q.state.work[behind]=="unclaimed") -- never traverse the bay to mine
        """)


if __name__ == "__main__":
    unittest.main(verbosity=2)
