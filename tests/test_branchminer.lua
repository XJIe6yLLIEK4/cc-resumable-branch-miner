-- Real Lua 5.2 execution. Simulated Minecraft world, inventory, GPS and disk.
local function clone(v)
    if type(v) ~= "table" then return v end
    local r = {}; for k, x in pairs(v) do r[k] = clone(x) end; return r
end
local function serial(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}; for k in pairs(v) do keys[#keys+1]=k end
    table.sort(keys,function(a,b)
        if type(a)~=type(b) then return type(a)<type(b) end
        return a<b
    end)
    local parts = {}; for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. serial(k) .. "]=" .. serial(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function parse(v) local f = load("return " .. v, "state", "t", {}); return f and f() end
local DIR = { [0] = {0,1}, [1] = {1,0}, [2] = {0,-1}, [3] = {-1,0} }
local function k(p) return p.x .. "," .. p.y .. "," .. p.z end
local function eq(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
local function expect(value, message) if not value then error(message or "Assertion failed", 2) end end
local function fixture(options)
    options = options or {}
    local f = { files = {}, blocks = {}, pose = {x=0,y=0,z=0,h=0}, fuel = options.fuel or 10000,
        items = {}, selected = 1, output = {}, dropPositions = {}, actions = {}, actionCount = 0,
        chestFull = false, gpsOnline = true, fuelChest = 0, snapshots = {}, messages = {},
        dug = {}, minY = options.minY }
    local env = setmetatable({}, {__index=_G})
    env._G, env._ENV = env, env
    env.print = function(...) f.messages[#f.messages + 1] = table.concat({...}, " ") end
    env.printError = env.print
    env.sleep = function() end
    env.os = { getComputerID=function() return options.id or 1 end,
        epoch=function() return 1000000 end }
    env.textutils = { serialize=serial, unserialize=parse }
    env.fs = {
        exists=function(path) return f.files[path] ~= nil end,
        makeDir=function() end,
        delete=function(path) f.files[path] = nil end,
        move=function(a,b) expect(f.files[a],"Source missing"); f.files[b]=f.files[a]; f.files[a]=nil end,
        open=function(path,mode)
            if mode == "r" then
                if not f.files[path] then return nil end
                return {readAll=function() return f.files[path] end, close=function() end}
            end
            f.files[path] = ""
            return {write=function(data)
                if f.diskFailure then error("Disk full") end
                f.files[path] = f.files[path] .. data
                if path:match("write.tmp$") then f.snapshots[#f.snapshots+1] = data end
            end, close=function() end}
        end,
    }
    local function target(direction)
        local p = clone(f.pose)
        if direction == "up" then p.y=p.y+1
        elseif direction == "down" then p.y=p.y-1
        else local sign=direction=="back" and -1 or 1; p.x=p.x+DIR[p.h][1]*sign; p.z=p.z+DIR[p.h][2]*sign end
        return p
    end
    local function addItem(name,count)
        for slot=1,16 do local item=f.items[slot]
            if item and item.name==name and item.count<64 then local n=math.min(count,64-item.count);item.count=item.count+n;count=count-n end
            if count==0 then return true end
        end
        for slot=1,16 do if not f.items[slot] then
            local n=math.min(count,64);f.items[slot]={name=name,count=n};count=count-n
            if count==0 then return true end
        end end
        return false
    end
    f.addItem=addItem
    local function before(method)
        f.actionCount=f.actionCount+1
        if f.cutBefore==f.actionCount then error({powercut=true,when="before",method=method}) end
    end
    local function after(method,ok)
        f.actions[#f.actions+1]={method=method,ok=ok,pose=clone(f.pose)}
        if f.cutAfter==f.actionCount then error({powercut=true,when="after",method=method}) end
    end
    local function move(method,direction)
        before(method)
        local destination=target(direction);local ok=true;local reason
        if f.fuel==0 then ok=false;reason="Out of fuel"
        elseif f.minY and destination.y<f.minY then ok=false;reason="Too low to move"
        elseif f.blocks[k(destination)] then ok=false;reason="Movement obstructed"
        elseif f.loadedBounds and (destination.x<f.loadedBounds[1] or destination.x>f.loadedBounds[2]
            or destination.z<f.loadedBounds[3] or destination.z>f.loadedBounds[4]) then
            ok=false;reason="Cannot leave loaded world"
        elseif f.entityBlock then ok=false;reason="Movement obstructed by entity"
        end
        if ok then f.pose=destination;f.fuel=f.fuel-1 end
        after(method,ok);return ok,reason
    end
    local function inspect(direction)
        local block=f.blocks[k(target(direction))]
        return block~=nil,block and {name=block,tags={}} or nil
    end
    local function dig(direction)
        local position=target(direction);local block=f.blocks[k(position)]
        if not block then return false,"Nothing to dig" end
        if block=="minecraft:bedrock" then return false,"Unbreakable block" end
        if not addItem(block,1) then return false,"Inventory full" end
        f.blocks[k(position)]=nil;f.dug[#f.dug+1]={position=clone(position),name=block}
        return true
    end
    local t={}
    t.forward=function() return move("forward","front") end
    t.back=function() return move("back","back") end
    t.up=function() return move("up","up") end
    t.down=function() return move("down","down") end
    t.turnRight=function() before("turnRight");f.pose.h=(f.pose.h+1)%4;after("turnRight",true);return true end
    t.turnLeft=function() before("turnLeft");f.pose.h=(f.pose.h+3)%4;after("turnLeft",true);return true end
    t.inspect=function() return inspect("front") end
    t.inspectUp=function() return inspect("up") end
    t.inspectDown=function() return inspect("down") end
    t.detect=function() return f.blocks[k(target("front"))]~=nil end
    t.detectUp=function() return f.blocks[k(target("up"))]~=nil end
    t.detectDown=function() return f.blocks[k(target("down"))]~=nil end
    t.dig=function() return dig("front") end
    t.digUp=function() return dig("up") end
    t.digDown=function() return dig("down") end
    t.attack=function() f.entityBlock=false;return true end
    t.attackUp=t.attack;t.attackDown=t.attack
    t.getFuelLevel=function() return f.fuel end
    t.getSelectedSlot=function() return f.selected end
    t.select=function(slot) f.selected=slot;return true end
    t.getItemCount=function(slot) local item=f.items[slot or f.selected];return item and item.count or 0 end
    t.getItemDetail=function(slot) local item=f.items[slot or f.selected];return item and clone(item) or nil end
    t.refuel=function(count)
        local item=f.items[f.selected]
        if not item or (item.name~="minecraft:coal" and item.name~="minecraft:charcoal" and item.name~="minecraft:coal_block") then return false end
        if count==0 then return true end
        local n=math.min(count or item.count,item.count);local per=item.name=="minecraft:coal_block" and 800 or 80
        f.fuel=f.fuel+n*per;item.count=item.count-n;if item.count==0 then f.items[f.selected]=nil end
        return true
    end
    t.suckDown=function(count)
        if not eq(f.pose,{x=0,y=0,z=0}) or f.fuelChest==0 then return false end
        local n=math.min(count or 64,f.fuelChest);local ok=addItem("minecraft:coal",n)
        if ok then f.fuelChest=f.fuelChest-n end;return ok
    end
    t.drop=function(count)
        expect(eq(f.pose,{x=0,y=0,z=0}) and f.pose.h==2,"Loot unloaded away from ORIGINAL home")
        if f.chestFull then return false end
        local item=f.items[f.selected];if not item then return false end
        local n=math.min(count or item.count,item.count);f.output[item.name]=(f.output[item.name] or 0)+n
        f.dropPositions[#f.dropPositions+1]=clone(f.pose);item.count=item.count-n
        if item.count==0 then f.items[f.selected]=nil end;return true
    end
    t.dropUp=function(count) local item=f.items[f.selected];if not item then return false end
        local n=math.min(count or item.count,item.count);item.count=item.count-n
        if item.count==0 then f.items[f.selected]=nil end;return true end
    t.placeDown=function()
        local item=f.items[f.selected];local destination=target("down")
        if not item or f.blocks[k(destination)] then return false end
        f.blocks[k(destination)]=item.name;item.count=item.count-1
        if item.count==0 then f.items[f.selected]=nil end;return true
    end
    env.turtle=t
    env.peripheral={wrap=function(side)
        if eq(f.pose,{x=0,y=0,z=0}) and ((side=="front" and f.pose.h==2 and not f.noOutput)
            or (side=="bottom" and not f.noFuelChest)) then return {size=function() return 54 end,list=function() return {} end} end
    end}
    env.gps={locate=function()
        if not f.gpsOnline then return nil end
        local basis={north={{1,0},{0,-1}},east={{0,1},{1,0}},south={{-1,0},{0,1}},west={{0,-1},{-1,0}}}
        local b=basis[options.gpsHeading or "north"]
        return 100+f.pose.x*b[1][1]+f.pose.z*b[2][1],30+f.pose.y,200+f.pose.x*b[1][2]+f.pose.z*b[2][2]
    end}
    f.api=assert(load(PROGRAM_SOURCE,"branchminer","t",env))("__test__")
    f.env=env
    return f
end
local function finish(f,m,limit)
    for _=1,limit or 10000 do
        m:tick()
        expect(m.job.home.x==0 and m.job.home.y==0 and m.job.home.z==0,"Home changed")
        if m.job.status=="completed" then return end
        if m.job.status=="recovery" then error(m.job.reason) end
    end
    error("Job did not finish: " .. tostring(m.job.reason) .. "; " .. m.job.work.phase)
end
local passed=0
local function test(name,fn)
    fn();passed=passed+1;print("PASS " .. name)
end
test("main tunnel and two-high left/right branches; finish at original home",function()
    local f=fixture();local m=f.api.Miner.create({length=3,pairs=2,spacing=3,veins=false,pave=false})
    for z=1,6 do f.blocks["0,0,"..z]="minecraft:stone";f.blocks["0,1,"..z]="minecraft:stone" end
    for _,z in ipairs({3,6}) do for x=-3,3 do if x~=0 then
        f.blocks[x..",0,"..z]="minecraft:stone";f.blocks[x..",1,"..z]="minecraft:stone"
    end end end
    finish(f,m);expect(m.job.stats.pairs==2);expect(eq(f.pose,{x=0,y=0,z=0}));expect(next(f.blocks)==nil,"Tunnel missed cells")
    expect(m.job.stats.moves==44,"Unexpected baseline path length: "..m.job.stats.moves)
end)
test("saving does not create a second origin on resume",function()
    local f=fixture();local m=f.api.Miner.create({length=2,pairs=1,spacing=3,veins=false,pave=false})
    for _=1,35 do m:tick() end
    expect(f.pose.z>0 or f.pose.x~=0,"Did not leave origin")
    local oldHome=serial(m.job.home);local oldCursor=serial(m.job.work)
    local loaded=assert(f.api.Miner.load());expect(serial(loaded.job.home)==oldHome);expect(serial(loaded.job.work)==oldCursor)
    finish(f,loaded);expect(eq(f.pose,{x=0,y=0,z=0}))
end)
test("GPS frame maps north and east/right correctly",function()
    for _,heading in ipairs({"north","east","south","west"}) do
        local f=fixture({gpsHeading=heading});local m=f.api.Miner.create({gps=true,heading=heading,veins=false,pave=false})
        f.pose.x,f.pose.y,f.pose.z=7,-2,9
        expect(eq(m:gpsPosition(),{x=7,y=-2,z=9}),"GPS coordinate rotation is incorrect: "..heading)
    end
end)
test("pause request, resume, and replacement rejection keep original job",function()
    local f=fixture();local m=f.api.Miner.create({length=2,pairs=1,spacing=3,veins=false,pave=false})
    for _=1,20 do m:tick() end
    f.api.sendControl(m.job,"pause");m:tick();expect(m.job.status=="paused")
    local cursor=serial(m.job.work);m:tick();expect(serial(m.job.work)==cursor)
    local ok=pcall(f.api.Miner.create,{length=3});expect(not ok,"New overwrote active job")
    f.api.sendControl(m.job,"resume");m:tick();finish(f,m)
end)
test("zero fuel waits and resumes after coal delivery",function()
    local f=fixture({fuel=0});local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false})
    for _=1,15 do m:tick() end;expect(m.job.status=="waiting");expect(eq(f.pose,{x=0,y=0,z=0}))
    f.fuelChest=64;finish(f,m);expect(m.job.status=="completed")
end)
test("full original chest waits; clears and returns to same work position",function()
    local f=fixture();local m=f.api.Miner.create({length=3,pairs=1,spacing=3,veins=false,pave=false})
    for _=1,27 do m:tick() end
    local cursor=serial(m.job.work);local original=serial(m.job.home)
    for i=1,14 do f.items[i]={name="test:loot"..i,count=1} end;f.chestFull=true
    for _=1,150 do m:tick() end
    expect(m.job.status=="waiting" and eq(f.pose,{x=0,y=0,z=0}));expect(serial(m.job.work)==cursor)
    f.chestFull=false;finish(f,m);expect(serial(m.job.home)==original);expect(f.output["test:loot14"]==1)
end)
test("vein mining follows connected ores, respects radius, and returns home",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,pave=false,veinRadius=2})
    f.blocks["1,0,1"]="minecraft:iron_ore";f.blocks["2,0,1"]="minecraft:iron_ore"
    f.blocks["3,0,1"]="minecraft:iron_ore";f.blocks["1,-1,1"]="minecraft:iron_ore"
    finish(f,m);expect(f.output["minecraft:iron_ore"]==3,"Connected vein count incorrect")
    expect(f.blocks["3,0,1"]~=nil,"Ore radius was ignored")
end)
test("inventory service during an entered vein returns through its parent",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,pave=false})
    f.blocks["1,0,1"]="minecraft:gold_ore";f.blocks["2,0,1"]="minecraft:gold_ore"
    for _=1,200 do m:tick();if m.job.vein and m.job.vein.travel and eq(f.pose,m.job.vein.travel.pos) then break end end
    expect(m.job.vein and m.job.vein.travel,"Could not reach uncommitted vein child")
    for i=1,14 do f.items[i]={name="test:ore"..i,count=1} end
    finish(f,m);expect(eq(f.pose,{x=0,y=0,z=0}));expect(m.job.stats.ores==2)
end)
test("upper endpoint scans both walls and ceiling after lower vein turns",function()
    local f=fixture();local m=f.api.Miner.create({length=2,pairs=1,spacing=2,pave=false})
    f.blocks["-2,1,3"]="minecraft:diamond_ore"
    f.blocks["-2,2,2"]="minecraft:lapis_ore"
    finish(f,m)
    expect(f.output["minecraft:diamond_ore"]==1,"Upper endpoint wall was missed")
    expect(f.output["minecraft:lapis_ore"]==1,"Upper endpoint ceiling was missed")
end)
test("configured chunk-load bounds pause without changing home or job",function()
    local f=fixture();local m=f.api.Miner.create({length=2,pairs=1,spacing=2,veins=false,pave=false,
        bounds={minX=-2,maxX=2,minZ=0,maxZ=1}})
    for _=1,80 do m:tick() end
    expect(m.job.status=="waiting");expect(f.pose.z==1)
    m.job.config.bounds.maxZ=2;m:save();finish(f,m)
end)
test("unbreakable blocks and other turtles remain intact",function()
    for _,block in ipairs({"minecraft:bedrock","computercraft:turtle_advanced"}) do
        local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false})
        f.blocks["0,0,1"]=block
        for _=1,12 do m:tick() end
        expect(f.blocks["0,0,1"]==block);expect(m.job.status=="waiting");expect(m.job.work.step==1)
    end
end)
test("non-GPS move interruption reconciles successful and failed fuel deltas",function()
    for _,outcome in ipairs({"before","after"}) do
        local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false})
        if outcome=="before" then f.cutBefore=1 else f.cutAfter=1 end
        expect(not pcall(function()m:tick()end));f.cutBefore=nil;f.cutAfter=nil
        m=assert(f.api.Miner.load());expect(m.job.pending~=nil);m:resolve();expect(m.job.pending==nil)
        expect(eq(f.pose,m.job.pose));finish(f,m)
    end
end)
test("non-GPS ambiguous turns require confirmation and preserve original base",function()
    for _,outcome in ipairs({"before","after"}) do
        local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false})
        if outcome=="before" then f.cutBefore=1 else f.cutAfter=1 end
        expect(not pcall(function()m:face(1)end));f.cutBefore=nil;f.cutAfter=nil
        m=assert(f.api.Miner.load());m:resolve();expect(m.job.status=="recovery")
        m:recover(outcome);expect(m.job.pose.h==f.pose.h);expect(eq(m.job.home,{x=0,y=0,z=0}))
        m:status("running");finish(f,m)
    end
end)
test("GPS recovers every action boundary before and after a power interruption",function()
    local baseline=fixture();local bm=baseline.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false,gps=true,heading="north"})
    finish(baseline,bm);local total=baseline.actionCount
    for _,outcome in ipairs({"before","after"}) do
        for cutoff=1,total do
            local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false,gps=true,heading="north"})
            if outcome=="before" then f.cutBefore=cutoff else f.cutAfter=cutoff end
            local ok=pcall(function()finish(f,m)end);expect(not ok,"Power cut did not occur")
            f.cutBefore=nil;f.cutAfter=nil;m=assert(f.api.Miner.load())
            finish(f,m);expect(eq(f.pose,{x=0,y=0,z=0}));expect(f.pose.h==0)
        end
    end
    print("  " .. (total*2) .. " injected movement/turn interruptions")
end)
test("recovery probe is itself restart-safe",function()
    for extra=1,2 do
        local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false,gps=true,heading="north"})
        f.cutAfter=1;expect(not pcall(function()m:face(1)end));f.cutAfter=nil
        m=assert(f.api.Miner.load());m:resolve();expect(m.job.pending.kind=="probe")
        f.cutAfter=f.actionCount+extra
        expect(not pcall(function()for _=1,10 do m:tick()end end));f.cutAfter=nil
        m=assert(f.api.Miner.load());finish(f,m);expect(eq(f.pose,{x=0,y=0,z=0}))
    end
end)
test("corrupt newest snapshot falls back to intact checksummed generation",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false,gps=true,heading="north"})
    m:tick();local seq=m.job.seq;local file="/.branchminer/job."..(seq%2==0 and "a" or "b")
    f.files[file]="truncated"
    local loaded=assert(f.api.Miner.load());expect(loaded.job.seq<seq);finish(f,loaded)
end)
test("disk failure prevents the next physical movement",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false})
    f.diskFailure=true;expect(not pcall(function()m:tick()end));expect(f.actionCount==0)
end)
test("continuous mode retains a bounded state and the old base",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=0,spacing=2,veins=false,pave=false})
    for _=1,2000 do m:tick() end
    expect(m.job.status~="completed");expect(m.job.stats.pairs>10)
    expect(#serial(m.job)<20000,"Continuous job stores an unbounded route")
    expect(eq(m.job.home,{x=0,y=0,z=0}))
end)
test("GPS absence and external relocation stop recovery without inventing a base",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false,gps=true,heading="north"})
    f.pose.x=10;expect(not m:verify());expect(m.job.status=="recovery");expect(m.job.home.world.x==100)
    f.pose.x=0;f.gpsOnline=false;expect(not m:verify());expect(m.job.home.world.x==100)
end)
test("invalid options never create a job or move a turtle",function()
    local f=fixture();expect(not pcall(f.api.Miner.create,{length=-1}));expect(not f.api.Miner.load());expect(f.actionCount==0)
end)
test("completed jobs remain completed when GPS hosts are offline",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false,gps=true,heading="north"})
    finish(f,m);f.gpsOnline=false;local actions=f.actionCount
    f.api.run(m);expect(m.job.status=="completed");expect(f.actionCount==actions)
end)
test("GPS recovery uses a free cell behind and never digs during localization",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false,gps=true,heading="north"})
    f.cutAfter=1;expect(not pcall(function()m:face(1)end));f.cutAfter=nil
    f.blocks["1,0,0"]="minecraft:stone"
    m=assert(f.api.Miner.load());m:resolve()
    for _=1,10 do if not m.job.pending then break end;m:resolve() end
    expect(not m.job.pending);expect(f.blocks["1,0,0"]=="minecraft:stone");expect(eq(f.pose,{x=0,y=0,z=0}))
    finish(f,m)
end)
test("boxed-in GPS recovery waits until a free cell becomes available",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false,gps=true,heading="north"})
    f.cutAfter=1;expect(not pcall(function()m:face(1)end));f.cutAfter=nil
    for _,p in ipairs({"1,0,0","-1,0,0","0,0,1","0,0,-1"}) do f.blocks[p]="minecraft:stone" end
    m=assert(f.api.Miner.load());m:resolve();m:resolve();expect(m.job.status=="recovery")
    expect(eq(f.pose,{x=0,y=0,z=0}));f.blocks["0,0,1"]=nil;m:status("running")
    finish(f,m)
end)
test("restart during mid-job unload and return does not restart the work cursor",function()
    for _,stage in ipairs({"home","unload","fuel","work"}) do
        local f=fixture();local m=f.api.Miner.create({length=3,pairs=1,spacing=3,veins=false,pave=false,gps=true,heading="north"})
        for _=1,27 do m:tick() end
        for i=1,14 do f.items[i]={name="test:valuable"..i,count=1} end
        f.fuel=math.abs(f.pose.x)+math.abs(f.pose.y)+math.abs(f.pose.z)
        f.chestFull=stage=="unload"
        f.fuelChest=stage=="fuel" and 0 or 64
        local cursor=serial(m.job.work)
        for _=1,300 do m:tick();if m.job.service and m.job.service.phase==stage then break end end
        expect(m.job.service and m.job.service.phase==stage,"Could not enter service stage "..stage)
        expect(serial(m.job.work)==cursor,"Service advanced the mining cursor")
        m=assert(f.api.Miner.load());expect(m.job.home.world.x==100)
        f.chestFull=false;f.fuelChest=64;finish(f,m)
        expect(eq(f.pose,{x=0,y=0,z=0}));expect(m.job.stats.pairs==1)
        expect(f.output["test:valuable14"]==1,"Restart duplicated or lost cargo")
    end
end)
test("restart in the middle of an ore vein keeps its traversal and original home",function()
    for _,when in ipairs({"before","after"}) do
        local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,pave=false,gps=true,heading="north"})
        f.blocks["1,0,1"]="minecraft:gold_ore";f.blocks["2,0,1"]="minecraft:gold_ore"
        f.blocks["2,-1,1"]="minecraft:gold_ore"
        for _=1,200 do m:tick();if m.job.vein and #m.job.vein.stack>=2 then break end end
        expect(m.job.vein and #m.job.vein.stack>=2)
        if when=="before" then f.cutBefore=f.actionCount+1 else f.cutAfter=f.actionCount+1 end
        expect(not pcall(function()finish(f,m)end));f.cutBefore=nil;f.cutAfter=nil
        m=assert(f.api.Miner.load());finish(f,m)
        expect(f.output["minecraft:gold_ore"]==3);expect(m.job.home.world.x==100)
    end
end)
local function quarryFixture(radius, floor, uneven)
    local f=fixture();local expected=0
    f.blocks["0,-1,0"]="minecraft:chest";f.blocks["0,0,-1"]="minecraft:chest"
    for z=1,radius*2+1 do for x=-radius,radius do
        local bottom=uneven and (floor+((x+radius+z)%3)) or floor
        for y=0,bottom+1,-1 do
            f.blocks[x..","..y..","..z]="minecraft:stone";expected=expected+1
        end
        f.blocks[x..","..bottom..","..z]="minecraft:bedrock"
    end end
    -- Ores outside the requested volume must not attract the quarry.
    f.blocks[(radius+1)..",-1,2"]="minecraft:diamond_ore"
    f.quarryExpected=expected
    return f
end
local function assertQuarry(f,m,radius)
    expect(m.job.status=="completed");expect(eq(f.pose,{x=0,y=0,z=0}) and f.pose.h==0)
    expect(f.output["minecraft:stone"]==f.quarryExpected,"Quarry lost or missed stone")
    expect(f.blocks["0,-1,0"]=="minecraft:chest","Fuel chest was destroyed")
    expect(f.blocks["0,0,-1"]=="minecraft:chest","Output chest was destroyed")
    expect(f.blocks[(radius+1)..",-1,2"]=="minecraft:diamond_ore","Quarry mined outside its footprint")
    for _,dug in ipairs(f.dug) do local p=dug.position
        expect(p.x>=-radius and p.x<=radius and p.z>=1 and p.z<=radius*2+1 and p.y<=0,"Dig outside quarry volume")
    end
    for _,block in pairs(f.blocks) do expect(block~="minecraft:stone","Stone remains above bedrock") end
end
test("square quarry clears every layer and preserves both original home chests",function()
    local f=quarryFixture(1,-3);local m=f.api.Miner.create(f.api.parse({"quarry","1","--no-veins"}))
    expect(m.job.config.veins==false and m.job.config.pave==false)
    finish(f,m);assertQuarry(f,m,1);expect(m.job.stats.layers==3)
    expect(m.job.work.blockedCount==9)
end)
test("irregular bedrock is bypassed; all remaining columns reach their own bottom",function()
    local f=quarryFixture(2,-4,true);local m=f.api.Miner.create({mode="quarry",veins=false,radius=2})
    finish(f,m);assertQuarry(f,m,2);expect(m.job.work.blockedCount==25)
    expect(m.job.work.safeY==-1,"Approach plane was not retained above the highest bedrock")
end)
test("quarry returns through the cleared prefix of an unfinished first layer",function()
    for _,position in ipairs({{x=0,y=0,z=1},{x=-1,y=0,z=2},{x=0,y=0,z=3},{x=-2,y=0,z=4}}) do
        local f=quarryFixture(2,-2);local m=f.api.Miner.create({mode="quarry",veins=false,radius=2})
        for _=1,1000 do m:tick();if eq(f.pose,position) then break end end
        expect(eq(f.pose,position),"Could not reach first-layer service point")
        local cursor=serial(m.job.work)
        for i=1,14 do expect(f.addItem("test:quarryLoot"..i,1)) end
        m:tick();expect(m.job.service~=nil)
        for _=1,1000 do
            if not m.job.service then break end
            m:tick();expect(serial(m.job.work)==cursor,"Service advanced quarry cursor")
        end
        expect(not m.job.service,"First-layer service did not finish")
        expect(eq(f.pose,position),"Service returned to a new work position")
        finish(f,m);assertQuarry(f,m,2);expect(f.output["test:quarryLoot14"]==1)
    end
end)
test("quarry restart during each service phase preserves deep work and original home",function()
    for _,stage in ipairs({"home","unload","fuel","work"}) do
        local f=quarryFixture(1,-5,true)
        local m=f.api.Miner.create({mode="quarry",veins=false,radius=1,gps=true,heading="north"})
        for _=1,2000 do m:tick();if m.job.work.safeY and f.pose.y<m.job.work.safeY then break end end
        expect(m.job.work.safeY~=nil and f.pose.y<m.job.work.safeY)
        for i=1,14 do expect(f.addItem("test:quarryCargo"..i,1)) end
        f.fuel=math.abs(f.pose.x)+math.abs(f.pose.y)+math.abs(f.pose.z)
        f.chestFull=stage=="unload";f.fuelChest=stage=="fuel" and 0 or 64
        local cursor=serial(m.job.work)
        for _=1,500 do m:tick();if m.job.service and m.job.service.phase==stage then break end end
        expect(m.job.service and m.job.service.phase==stage,"Quarry service phase not reached: "..stage)
        expect(serial(m.job.work)==cursor)
        m=assert(f.api.Miner.load());expect(m.job.home.world.x==100)
        f.chestFull=false;f.fuelChest=64;finish(f,m);assertQuarry(f,m,1)
        expect(f.output["test:quarryCargo14"]==1)
    end
end)
test("quarry GPS resumes every physical action before and after interruption",function()
    local injected=0
    for _,shape in ipairs({"flat","uneven"}) do
        local baseline=quarryFixture(1,-3,shape=="uneven")
        local bm=baseline.api.Miner.create({mode="quarry",veins=false,radius=1,gps=true,heading="north"})
        finish(baseline,bm);local total=baseline.actionCount
        for _,when in ipairs({"before","after"}) do for cutoff=1,total do
            local f=quarryFixture(1,-3,shape=="uneven")
            local m=f.api.Miner.create({mode="quarry",veins=false,radius=1,gps=true,heading="north"})
            if when=="before" then f.cutBefore=cutoff else f.cutAfter=cutoff end
            expect(not pcall(function()finish(f,m)end),"Quarry power cut did not occur")
            f.cutBefore=nil;f.cutAfter=nil;m=assert(f.api.Miner.load())
            finish(f,m);assertQuarry(f,m,1);injected=injected+1
        end end
    end
    print("  " .. injected .. " injected quarry movement/turn interruptions")
end)
test("quarry GPS lift/probe/lower recovery survives another interruption",function()
    for _,phase in ipairs({"lift","out","return","lower"}) do for _,when in ipairs({"before","after"}) do
        local f=quarryFixture(1,-4);local m=f.api.Miner.create({mode="quarry",veins=false,radius=1,gps=true,heading="north"})
        for _=1,1000 do m:tick();if f.pose.y==-2 and m.job.work.cell==0 then break end end
        expect(f.pose.y==-2 and m.job.work.cell==0,"Could not enter isolated deep column")
        f.cutAfter=f.actionCount+1
        expect(not pcall(function()m:face((f.pose.h+1)%4)end));f.cutAfter=nil
        m=assert(f.api.Miner.load());m:resolve()
        for _=1,20 do
            if m.job.pending and m.job.pending.phase==phase then break end
            m:resolve()
        end
        expect(m.job.pending and m.job.pending.phase==phase,"Quarry recovery phase not reached: "..phase)
        if when=="before" then f.cutBefore=f.actionCount+1 else f.cutAfter=f.actionCount+1 end
        expect(not pcall(function()for _=1,20 do m:resolve() end end))
        f.cutBefore=nil;f.cutAfter=nil;m=assert(f.api.Miner.load())
        finish(f,m);assertQuarry(f,m,1)
    end end
end)
test("quarry pause, resume, replacement protection and chunk bounds share branch behavior",function()
    local f=quarryFixture(1,-2);local m=f.api.Miner.create({mode="quarry",veins=false,radius=1,
        bounds={minX=-1,maxX=1,minZ=0,maxZ=2}})
    for _=1,200 do m:tick() end;expect(m.job.status=="waiting" and f.pose.z==2)
    local cursor=serial(m.job.work);f.api.sendControl(m.job,"pause");m:tick()
    expect(m.job.status=="paused" and serial(m.job.work)==cursor)
    expect(not pcall(f.api.Miner.create,{mode="quarry",veins=false,radius=2}))
    m=assert(f.api.Miner.load());m.job.config.bounds.maxZ=3;m:save()
    f.api.sendControl(m.job,"resume");finish(f,m);assertQuarry(f,m,1)
end)
test("quarry protected structures wait rather than being mistaken for its bottom",function()
    for _,block in ipairs({"minecraft:chest","computercraft:turtle_advanced","minecraft:reinforced_deepslate"}) do
        local f=quarryFixture(0,-3);f.blocks["0,-1,1"]=block
        local m=f.api.Miner.create({mode="quarry",veins=false,radius=0})
        for _=1,50 do m:tick() end
        expect(m.job.status=="waiting" and m.job.work.blockedCount==0)
        expect(f.blocks["0,-1,1"]==block)
        f.blocks["0,-1,1"]="minecraft:stone";finish(f,m);assertQuarry(f,m,0)
    end
end)
test("quarry reaches the actual build-height limit in a world without bedrock",function()
    local f=fixture({minY=-2});local m=f.api.Miner.create({mode="quarry",veins=false,radius=1})
    finish(f,m);expect(eq(f.pose,{x=0,y=0,z=0}));expect(m.job.work.bottom=="World height limit reached.")
    expect(m.job.stats.layers==3);expect(m.job.work.layer==3)
end)
test("quarry fuel waits at the original base and continues after replenishment",function()
    local f=quarryFixture(1,-2);f.fuel=0
    local m=f.api.Miner.create({mode="quarry",veins=false,radius=1})
    for _=1,20 do m:tick() end
    expect(m.job.status=="waiting" and eq(f.pose,{x=0,y=0,z=0}))
    f.fuelChest=64;finish(f,m);assertQuarry(f,m,1)
end)
test("old 1.0 branch jobs without a mode still resume after the quarry update",function()
    local f=fixture();local m=f.api.Miner.create({length=1,pairs=1,spacing=2,veins=false,pave=false})
    for _=1,12 do m:tick() end
    m.job.config.mode=nil;m.job.config.radius=nil;m.job.version="1.0.0";m:save()
    local home=serial(m.job.home);local cursor=serial(m.job.work)
    m=assert(f.api.Miner.load());expect(serial(m.job.home)==home and serial(m.job.work)==cursor)
    finish(f,m);expect(m.job.stats.pairs==1)
end)
test("quarry argument and radius validation happen before creating or moving a job",function()
    local f=fixture()
    for _,args in ipairs({{"quarry"},{"quarry","nope"}}) do expect(not pcall(f.api.parse,args)) end
    for _,radius in ipairs({-1,1.5,33}) do expect(not pcall(f.api.Miner.create,{mode="quarry",veins=false,radius=radius})) end
    local config=f.api.parse({"quarry","5","--gps","--heading","north","--bounds","-5,5,0,11"})
    expect(config.mode=="quarry" and config.radius==5 and config.gps and config.heading=="north")
    expect(config.bounds.maxZ==11);expect(f.actionCount==0);expect(not f.api.Miner.load())
end)
test("branch length 20 mines connected ores past block 21 at lower and upper endcaps",function()
    local f=fixture();local m=f.api.Miner.create({length=20,pairs=1,spacing=2,pave=false})
    f.blocks["-21,1,2"]="minecraft:diamond_ore";f.blocks["-22,1,2"]="minecraft:diamond_ore"
    f.blocks["21,0,2"]="minecraft:iron_ore";f.blocks["22,0,2"]="minecraft:iron_ore"
    f.blocks["22,-1,2"]="minecraft:iron_ore";f.blocks["0,0,3"]="minecraft:lapis_ore"
    f.blocks["-21,0,2"]="minecraft:obsidian";f.blocks["23,0,2"]="minecraft:obsidian"
    finish(f,m,30000)
    expect(f.output["minecraft:diamond_ore"]==2,"Upper endcap ore was missed")
    expect(f.output["minecraft:iron_ore"]==3,"Lower endcap vein was missed")
    expect(f.output["minecraft:lapis_ore"]==1,"Main tunnel endcap was missed")
    expect(f.blocks["-21,0,2"]=="minecraft:obsidian" and f.blocks["23,0,2"]=="minecraft:obsidian")
    expect(m.job.config.length==20 and m.job.stats.pairs==1 and eq(f.pose,{x=0,y=0,z=0}))
end)
test("quarry mines boundary veins on all sides, above it and below uneven bedrock",function()
    local f=quarryFixture(1,-4)
    for _,p in ipairs({"3,-1,2","3,-2,2"}) do f.blocks[p]="minecraft:diamond_ore" end
    for _,p in ipairs({"-2,-2,1","-3,-2,1"}) do f.blocks[p]="minecraft:iron_ore" end
    for _,p in ipairs({"1,-1,0","1,-2,0"}) do f.blocks[p]="minecraft:lapis_ore" end
    for _,p in ipairs({"0,-1,4","0,-1,5"}) do f.blocks[p]="minecraft:gold_ore" end
    for _,p in ipairs({"0,1,2","0,2,2"}) do f.blocks[p]="minecraft:ancient_debris" end
    for _,p in ipairs({"0,-4,2","0,-5,2"}) do f.blocks[p]="minecraft:copper_ore" end
    f.blocks["0,-6,2"]="minecraft:bedrock"
    for _,p in ipairs({"3,0,2","2,0,2","4,-1,2"}) do f.blocks[p]="minecraft:obsidian" end
    local m=f.api.Miner.create(f.api.parse({"quarry","1"}));expect(m.job.config.veins)
    finish(f,m,30000)
    expect(f.output["minecraft:diamond_ore"]==3 and f.output["minecraft:iron_ore"]==2)
    expect(f.output["minecraft:lapis_ore"]==2 and f.output["minecraft:gold_ore"]==2)
    expect(f.output["minecraft:ancient_debris"]==2 and f.output["minecraft:copper_ore"]==2)
    expect(f.output["minecraft:stone"]==f.quarryExpected)
    for _,p in ipairs({"3,0,2","2,0,2","4,-1,2"}) do expect(f.blocks[p]=="minecraft:obsidian","Ordinary boundary rock was excavated") end
    expect(f.blocks["0,-1,0"]=="minecraft:chest" and f.blocks["0,0,-1"]=="minecraft:chest")
    expect(eq(f.pose,{x=0,y=0,z=0}) and m.job.work.blockedCount==9)
end)
test("outside quarry vein unload/restart retraces ore parents and keeps the original cursor",function()
    for _,stage in ipairs({"home","unload","fuel","work"}) do
        local f=quarryFixture(1,-3);f.blocks["3,-1,2"]="minecraft:diamond_ore"
        f.blocks["3,0,2"]="minecraft:obsidian";f.blocks["2,0,2"]="minecraft:obsidian"
        local m=f.api.Miner.create({mode="quarry",radius=1,gps=true,heading="north"})
        for _=1,3000 do
            m:tick()
            if m.job.vein and m.job.vein.travel and not m.job.vein.travel.returning
                and eq(f.pose,m.job.vein.travel.pos) and f.pose.x==3 then break end
        end
        expect(m.job.vein and m.job.vein.travel and f.pose.x==3,"Uncommitted boundary ore child not reached")
        local cursor,vein,home=serial(m.job.work),serial(m.job.vein),serial(m.job.home)
        for i=1,14 do expect(f.addItem("test:boundaryLoot"..i,1)) end
        f.fuel=10;f.chestFull=stage=="unload";f.fuelChest=stage=="fuel" and 0 or 64
        for _=1,500 do m:tick();if m.job.service and m.job.service.phase==stage then break end end
        expect(m.job.service and m.job.service.phase==stage,"Boundary service stage not reached: "..stage)
        expect(serial(m.job.work)==cursor and serial(m.job.vein)==vein)
        m=assert(f.api.Miner.load());expect(serial(m.job.home)==home)
        f.chestFull=false;f.fuelChest=64;finish(f,m,30000)
        expect(f.output["minecraft:diamond_ore"]==2 and f.output["test:boundaryLoot14"]==1)
        expect(f.blocks["3,0,2"]=="minecraft:obsidian" and f.blocks["2,0,2"]=="minecraft:obsidian")
        expect(f.output["minecraft:stone"]==f.quarryExpected and eq(f.pose,{x=0,y=0,z=0}))
    end
end)
test("ore beyond mining dimensions still respects explicit chunk bounds and no-veins",function()
    local f=quarryFixture(1,-2);local m=f.api.Miner.create({mode="quarry",radius=1,
        bounds={minX=-1,maxX=1,minZ=0,maxZ=3}})
    finish(f,m);expect(f.blocks["2,-1,2"]=="minecraft:diamond_ore")
    f=quarryFixture(1,-2);m=f.api.Miner.create(f.api.parse({"quarry","1","--no-veins"}))
    finish(f,m);assertQuarry(f,m,1)
end)
test("1.1 quarry migration enables boundary ores without replacing its saved home or cursor",function()
    local f=quarryFixture(1,-2);local m=f.api.Miner.create({mode="quarry",radius=1,veins=false})
    for _=1,12 do m:tick() end
    m.job.version="1.1.0";m:save();local cursor,home=serial(m.job.work),serial(m.job.home)
    m=assert(f.api.Miner.load());expect(m.job.config.veins and m.job.version==f.api.version)
    expect(serial(m.job.work)==cursor and serial(m.job.home)==home)
    finish(f,m);expect(f.output["minecraft:diamond_ore"]==1 and eq(f.pose,{x=0,y=0,z=0}))
end)
local function boxedBoundaryVein(mode)
    local f,m
    if mode=="quarry" then
        f=quarryFixture(1,-3)
        f.blocks["2,-2,2"]="minecraft:diamond_ore";f.blocks["2,-3,2"]="minecraft:diamond_ore"
        for _,p in ipairs({"2,0,2","3,-2,2","2,-2,1","2,-2,3","2,-4,2"}) do f.blocks[p]="minecraft:obsidian" end
        m=f.api.Miner.create({mode="quarry",radius=1,gps=true,heading="north"})
    else
        f=fixture()
        f.blocks["-1,2,2"]="minecraft:diamond_ore";f.blocks["-1,3,2"]="minecraft:diamond_ore"
        for y=2,3 do for _,p in ipairs({{x=0,z=2},{x=-2,z=2},{x=-1,z=1},{x=-1,z=3}}) do
            f.blocks[p.x..","..y..","..p.z]="minecraft:obsidian"
        end end
        m=f.api.Miner.create({length=1,pairs=1,spacing=2,pave=false,gps=true,heading="north"})
    end
    for _=1,4000 do
        m:tick()
        if m.job.vein and #m.job.vein.stack>=3 and m.job.vein.travel==nil then break end
    end
    expect(m.job.vein and #m.job.vein.stack>=3,"Isolated boundary ore cell not reached: "..mode)
    expect(f.pose.y==(mode=="quarry" and -2 or 3))
    return f,m
end
local function assertBoundaryVein(f,m,mode)
    expect(f.output["minecraft:diamond_ore"]==(mode=="quarry" and 3 or 2))
    expect(eq(f.pose,{x=0,y=0,z=0}) and f.pose.h==0)
    for _,dug in ipairs(f.dug) do expect(dug.name~="minecraft:obsidian","Recovery cut through ordinary boundary rock") end
    if mode=="quarry" then expect(f.output["minecraft:stone"]==f.quarryExpected) end
end
test("GPS resumes every remaining vein action in boxed ore outside both mining geometries",function()
    local injected=0
    for _,mode in ipairs({"quarry","branch"}) do
        local baseline,bm=boxedBoundaryVein(mode);local first=baseline.actionCount+1
        for _=1,1000 do bm:tick();if not bm.job.vein then break end end
        expect(not bm.job.vein,"Boundary vein did not return to root")
        local last=baseline.actionCount
        for _,when in ipairs({"before","after"}) do for cutoff=first,last do
            local f,m=boxedBoundaryVein(mode)
            if when=="before" then f.cutBefore=cutoff else f.cutAfter=cutoff end
            expect(not pcall(function()finish(f,m,30000)end),"Boundary power cut did not happen")
            f.cutBefore=nil;f.cutAfter=nil;m=assert(f.api.Miner.load())
            finish(f,m,30000);assertBoundaryVein(f,m,mode);injected=injected+1
        end end
    end
    print("  "..injected.." injected boundary-vein interruptions")
end)
test("ore GPS vertical escape and return survive another cut above and below the root",function()
    for _,mode in ipairs({"quarry","branch"}) do for _,phase in ipairs({"lift","out","return","lower"}) do
        for _,when in ipairs({"before","after"}) do
            local f,m=boxedBoundaryVein(mode);local base=clone(f.pose)
            f.cutAfter=f.actionCount+1
            expect(not pcall(function()m:face((f.pose.h+1)%4)end));f.cutAfter=nil
            m=assert(f.api.Miner.load());m:resolve()
            expect(m.job.pending.phase=="lift")
            expect(mode=="quarry" and m.job.pending.anchor.y>base.y or mode=="branch" and m.job.pending.anchor.y<base.y)
            for _=1,30 do if m.job.pending and m.job.pending.phase==phase then break end;m:resolve() end
            expect(m.job.pending and m.job.pending.phase==phase,"Ore probe phase not reached")
            if when=="before" then f.cutBefore=f.actionCount+1 else f.cutAfter=f.actionCount+1 end
            expect(not pcall(function()for _=1,30 do m:resolve() end end))
            f.cutBefore=nil;f.cutAfter=nil;m=assert(f.api.Miner.load())
            finish(f,m,30000);assertBoundaryVein(f,m,mode)
        end
    end end
end)
local function install(f,...)
    f.env.http={get=function(url)
        local file=url:match("([^/]+)$")
        local code=file=="branchminer.lua" and PROGRAM_SOURCE or "return true"
        if f.downloads and f.downloads[file]~=nil then code=f.downloads[file] end
        if code==false then return nil,"Network unavailable" end
        return {readAll=function()return code end,close=function()end}
    end}
    return assert(load(INSTALLER_SOURCE,"install","t",f.env))(...)
end
test("updating the program preserves the saved quarry, startup and previous version",function()
    local f=quarryFixture(1,-2);local m=f.api.Miner.create({mode="quarry",veins=false,radius=1})
    for _=1,20 do m:tick() end
    local savedA,savedB=f.files["/.branchminer/job.a"],f.files["/.branchminer/job.b"]
    f.files["/branchminer.lua"]="old version";f.files["/startup.lua"]="custom startup"
    f.files["/branchminer.lua.previous"]="even older version"
    local actions=f.actionCount;install(f,"--update")
    expect(f.files["/branchminer.lua"]==PROGRAM_SOURCE)
    expect(f.files["/branchminer.lua.previous.1"]=="old version")
    expect(f.files["/startup.lua"]=="custom startup")
    expect(f.files["/.branchminer/job.a"]==savedA and f.files["/.branchminer/job.b"]==savedB)
    expect(f.actionCount==actions);m=assert(f.api.Miner.load());finish(f,m);assertQuarry(f,m,1)
end)
test("updates reject an active worker and invalid downloads without changing its program",function()
    for _,failure in ipairs({"active","syntax","network"}) do
        local f=fixture();f.files["/branchminer.lua"]="old version"
        if failure=="active" then f.files["/.branchminer/run.lock"]="working"
        else f.downloads={["branchminer.lua"]=failure=="syntax" and "not valid Lua!" or false} end
        expect(not pcall(install,f,"--update"));expect(f.files["/branchminer.lua"]=="old version")
        expect(f.actionCount==0)
    end
end)
test("installer checks all downloads before fresh install and restores a failed update",function()
    local f=fixture();f.downloads={["startup.lua"]="not valid Lua!"}
    expect(not pcall(install,f));expect(not f.files["/branchminer.lua"] and not f.files["/startup.lua"])
    f=fixture();f.files["/branchminer.lua"]="old version";local move=f.env.fs.move
    f.env.fs.move=function(a,b)
        if a=="/.branchminer-install/branchminer.lua" and b=="/branchminer.lua" then error("Disk failure") end
        return move(a,b)
    end
    expect(not pcall(install,f,"--update"));expect(f.files["/branchminer.lua"]=="old version")
end)
print("RESULT: " .. passed .. " test scenarios passed in Lua 5.2")
