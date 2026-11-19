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
            -- First turtle in bay 0,70,0 probed north; 1 chunk down to y=-64.
            local s=Queue.define{worker=7,bay="0,70,0",park="0,69,-1",heading=0,chunks=1,bottom=-64,
                quarryId="q",manifestId="m",dimension="auto"}
            assert(s.box.x0==0 and s.box.x1==15 and s.box.z0==-15 and s.box.z1==0)
            assert(s.box.y0==-64 and s.box.y1==69 and s.station.facing=="south")
            assert(s.staging["0,69,-1"] and s.parked[7]=="0,69,-1" and s.clearApproach["0,69,0"])
            local route=s.station.routes["0,69,-1"]
            assert(#route==3 and route[2]=="0,69,0" and route[3]=="0,70,0")
            -- 134 layers x 256 cells are stored as one character per uniform layer.
            assert(commit(s))
            assert(#read_commit()<20000,"compact ledger is "..#read_commit().." bytes")
            local q=reopen()
            -- Newcomer before any extra parking exists: refused with no change.
            assert(q:join(8,"0,70,0",0).reason=="no_parking")
            assert(q:join(8,"5,70,5",0)==nil)
            -- The first claim digs the lane and parking rows before anything else.
            local r=claim(q,7,2,"0,69,-1",5000)
            for _,p in ipairs(r.grant.cells) do assert(q.state.auto.infra[p],p.." is not lane/parking") end
            local evidence={}
            for _,p in ipairs(r.grant.cells) do evidence[p]="clear" end
            assert(q:finish(7,3,"0,69,-1",r.grant.id,evidence))
            q=reopen()
            assert(q.state.staging["1,69,-1"] and q.state.clearApproach["1,69,0"])
            assert(#q.state.layers[69]==256 and #q.state.layers[68]==1)
            -- A service grant holds the bay, so a newcomer is told to wait.
            assert(q:service(7,4,"0,69,-1",5000).grant)
            assert(q:join(8,"0,70,0",0).reason=="bay_busy")
            assert(q:finish(7,5,"0,69,-1",q.state.active[7].id,{}))
            local j=q:join(8,"0,70,0","unlimited")
            local g=j.grant
            assert(g.relocate and j.stage=="1,69,-1" and j.seq==1 and #g.route==4)
            assert(g.route[1]=="0,70,0" and g.route[2]=="0,69,0" and g.route[3]=="1,69,0" and g.route[4]=="1,69,-1")
            -- Duplicate join (lost reply) returns the same grant; others wait.
            local again=q:join(8,"0,70,0","unlimited")
            assert(again.grant.id==g.id and again.seq==1)
            assert(q:join(9,"0,70,0",0).reason=="bay_busy")
            q=reopen()
            assert(q:finish(8,2,"1,69,-1",g.id,{}))
            assert(not q.state.active[8] and q.state.parked[8]=="1,69,-1")
            -- Mining routes never use the service lane.
            local m=claim(q,8,3,"1,69,-1",5000)
            for _,p in ipairs(m.grant.route) do assert(q.state.auto.infra[p]~="lane" or p==m.grant.route[1]) end
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
