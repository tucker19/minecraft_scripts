"""Offline simulation tests. Requires Python package lupa; not used in-game."""
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).parent
HARNESS = r'''
local px, py, pz, hd = 0, 0, 0, 0
local time, fuel, consumed = 0, INITIAL_FUEL, 0
local removed, packets, occupied = {}, {}, {}
local deployed = false
local selected = 1
local last
local vectors = {[0]={1,0}, {0,1}, {-1,0}, {0,-1}}
local function key(x,y,z) return x..","..y..","..z end
local function coord(dir)
    local v=vectors[hd]
    if dir=="up" then return px,py+1,pz end
    if dir=="down" then return px,py-1,pz end
    return px+v[1],py,pz+v[2]
end
local function inspect(dir)
    local x,y,z=coord(dir)
    if dir=="up" and (deployed or (FIXED_CHEST and px==0 and py==0 and pz==0)) then
        return true,{name="minecraft:chest"}
    end
    if y<=-2 then return true,{name="minecraft:bedrock"} end
    if OBSTACLE and x==3 and y==0 and z==0 then
        return true,{name="allthemodium:allthemodium_ore"}
    end
    if x==0 and y==0 and z==0 then return false end
    if y<=0 and not removed[key(x,y,z)] then
        return true,{name="minecraft:stone"}
    end
    return false
end
local function move(dir)
    if fuel~="unlimited" and fuel<=0 then return false end
    if inspect(dir) then return false end
    local x,y,z=coord(dir)
    px,py,pz=x,y,z
    if fuel~="unlimited" then fuel=fuel-1 end
    return true
end
local function dig(dir)
    local found,block=inspect(dir)
    if not found or block.name=="minecraft:bedrock" then return false end
    local x,y,z=coord(dir)
    removed[key(x,y,z)]=true
    return true
end
os.getComputerID=function() return 12 end
os.getComputerLabel=function() return "Test Turtle" end
os.clock=function() return time end
print=function() end
sleep=function(n)
    time=time+n
    if last and (last.status=="complete" or last.status=="stopped"
        or last.status==STOP_STATUS) then error("TEST_END") end
end
peripheral={
    find=function() if MODEM then return {isWireless=function() return true end} end end,
    getName=function() return "right" end,
    wrap=function(side)
        if side=="top" and (deployed or (FIXED_CHEST and px==0 and py==0 and pz==0)) then
            return {list=function() return {} end}
        end
    end,
}
rednet={
    isOpen=function() return false end, open=function() end,
    broadcast=function(packet,protocol)
        assert(protocol=="turtle_quarry_v1")
        last=packet; packets[#packets+1]=packet
    end,
}
gps={locate=function() return nil end}
turtle={
    select=function(i) selected=i return true end,
    getFuelLevel=function() return fuel end,
    getFuelLimit=function() return fuel=="unlimited" and "unlimited" or 20000 end,
    getItemCount=function(i) return occupied[i] or 0 end,
    getItemSpace=function(i) return 64-(occupied[i] or 0) end,
    getItemDetail=function(i)
        if occupied[i] and occupied[i]>0 then
            return {name=i==15 and "enderstorage:ender_chest" or "minecraft:coal"}
        end
    end,
    refuel=function(n)
        if selected==15 or not occupied[selected] or occupied[selected]==0 then return false end
        if n==0 then return true end
        if fuel=="unlimited" then return false end
        occupied[selected]=occupied[selected]-1
        fuel=fuel+80; consumed=consumed+1
        return true
    end,
    suckUp=function()
        if inspect("up") and SOURCE_FUEL then occupied[selected]=64 return true end
        return false
    end,
    dropUp=function() occupied[selected]=0 return true end,
    placeUp=function()
        if selected==15 and not inspect("up") then
            occupied[15]=0; deployed=true; return true
        end
        return false
    end,
    digUp=function()
        if deployed then occupied[15]=1; deployed=false; return true end
        return dig("up")
    end,
    inspect=function() return inspect("forward") end,
    inspectUp=function() return inspect("up") end,
    inspectDown=function() return inspect("down") end,
    detectUp=function() return inspect("up") end,
    dig=function() return dig("forward") end,
    digDown=function() return dig("down") end,
    forward=function() return move("forward") end,
    up=function() return move("up") end,
    down=function() return move("down") end,
    turnRight=function() hd=(hd+1)%4 return true end,
    attack=function() end, attackUp=function() end, attackDown=function() end,
}
if PORTABLE then occupied[15]=1 end
function results()
    return {x=px,y=py,z=pz,heading=hd,last=last,packets=#packets,
        fuelConsumed=consumed,portableRecovered=not deployed and occupied[15]==1,
        waiting=(function()
            for _,p in ipairs(packets) do
                if p.status=="waiting_fuel" then return true end
            end
            return false
        end)()}
end
'''

def run(**options):
    lua = LuaRuntime(unpack_returned_tuples=True)
    settings = dict(INITIAL_FUEL=10000, MODEM=True, FIXED_CHEST=False,
                    SOURCE_FUEL=False, PORTABLE=False, OBSTACLE=False, STOP_STATUS="")
    settings.update(options)
    for k, v in settings.items():
        lua.globals()[k] = v
    lua.execute(HARNESS)
    code = (ROOT / "chunk_dig.lua").read_text()
    program = lua.eval("function(...) " + code + " end")
    try:
        program("1", "Test Quarry")
    except Exception as error:
        if "TEST_END" not in str(error):
            raise
    return lua.globals().results()

def main():
    for path in ROOT.glob("*.lua"):
        LuaRuntime().execute("function syntax_check(...) " + path.read_text() + " end")
        print("PASS syntax", path.name)
    for options in ({}, {"FIXED_CHEST": True, "SOURCE_FUEL": True, "INITIAL_FUEL": 0},
                    {"PORTABLE": True, "SOURCE_FUEL": True, "INITIAL_FUEL": 0},
                    {"INITIAL_FUEL": "unlimited"}, {"OBSTACLE": True}):
        r = run(**options)
        assert (r["x"], r["y"], r["z"], r["heading"]) == (0, 0, 0, 0)
        p = r["last"]
        assert p["status"] == "complete", p["detail"]
        assert p["job"]["cells"] == 512
        assert p["job"]["side"] == 16
        assert p["location"]["relative"]["x"] == 0
        assert p["inventory"]["totalSlots"] == 14
        if options.get("SOURCE_FUEL"):
            assert r["fuelConsumed"] > 0
            assert p["fuelType"] == "minecraft:coal"
        if options.get("PORTABLE"):
            assert r["portableRecovered"]
        print("PASS quarry/home/telemetry", options)
    r = run(INITIAL_FUEL=0, STOP_STATUS="waiting_fuel")
    assert r["waiting"]
    assert r["x"] == r["y"] == r["z"] == 0
    print("PASS empty fuel waits without movement")
    test_dashboard()

def test_dashboard():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(r'''
        local clock, event, cursor, writes = 0, 0, 1, 0
        local lines = {}
        colors={cyan=1,gray=2,white=3,yellow=4,lime=5,orange=6,lightBlue=7,black=8}
        keys={right=1,left=2}
        local monitor={
            getSize=function() return 90,25 end,
            setTextScale=function() end, setCursorBlink=function() end,
            setBackgroundColor=function() end, setTextColor=function() end,
            setCursorPos=function(x,y) cursor=y end,
            write=function(t) lines[cursor]=t; writes=writes+1 end,
        }
        peripheral={find=function(kind)
            if kind=="modem" then return {} end
            return monitor
        end, getName=function() return "right" end}
        rednet={open=function() end,host=function() end}
        os.getComputerLabel=function() return "Test Dash" end
        os.clock=function() return clock end
        os.startTimer=function() return 1 end
        os.pullEvent=function()
            event=event+1
            if event<=2 then
                return "rednet_message",event,{
                    type="quarry",version=1,name="Turtle "..event,status="mining",
                    fuel=1000,fuelLimit=20000,fuelType="minecraft:coal",
                    job={chunks=1,side=16,layer=2,cells=512},
                    inventory={usedSlots=7,totalSlots=14,percent=50,items=200},
                    location={relative={x=1,y=-2,z=3}},
                },"turtle_quarry_v1"
            elseif event==3 then
                local all=table.concat(lines,"\n")
                assert(all:find("2 turtles"))
                assert(all:find("#1 Turtle 1") and all:find("#2 Turtle 2"))
                assert(all:find("50%%") and all:find("minecraft:coal"))
                clock=20
                return "timer",1
            elseif event==4 then
                assert(table.concat(lines,"\n"):find("OFFLINE"))
                SAVED_WRITES=writes
                return "timer",1
            end
            assert(writes==SAVED_WRITES, "unchanged frame was redrawn")
            error("TEST_END")
        end
    ''')
    try:
        lua.execute((ROOT / "turtle_wireless_dash.lua").read_text())
    except Exception as error:
        if "TEST_END" not in str(error):
            raise
    print("PASS dashboard multiple turtles / fields / offline / incremental redraw")

if __name__ == "__main__":
    main()
