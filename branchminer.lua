-- Resumable Branch Miner for CC:Tweaked 1.108+ / Minecraft 1.20.1.
-- Copyright (c) 2026 XJIe6yLLIEK4. MIT License.
-- No external Lua libraries. Each turtle owns its own /.branchminer directory.
local arguments = { ... }
local VERSION, SCHEMA = "1.0.0", 1
local ROOT = "/.branchminer"
local DIRECTIONS = {
    [0] = { x = 0, z = 1 }, [1] = { x = 1, z = 0 },
    [2] = { x = 0, z = -1 }, [3] = { x = -1, z = 0 },
}
local COMPASS = { south = 0, east = 1, north = 2, west = 3 }
local FUELS = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true,
    ["minecraft:coal_block"] = true }
local PAVING = { ["minecraft:cobblestone"] = true,
    ["minecraft:cobbled_deepslate"] = true, ["minecraft:dirt"] = true,
    ["minecraft:netherrack"] = true }
local COMMON = { ["minecraft:cobblestone"] = true,
    ["minecraft:cobbled_deepslate"] = true, ["minecraft:tuff"] = true,
    ["minecraft:dirt"] = true, ["minecraft:gravel"] = true,
    ["minecraft:netherrack"] = true, ["minecraft:andesite"] = true,
    ["minecraft:diorite"] = true, ["minecraft:granite"] = true }
local UNBREAKABLE = { ["minecraft:bedrock"] = true,
    ["minecraft:reinforced_deepslate"] = true, ["minecraft:end_portal_frame"] = true }
local function copy(v)
    if type(v) ~= "table" then return v end
    local result = {}; for k, value in pairs(v) do result[k] = copy(value) end
    return result
end
local function point(x, y, z, h) return { x = x, y = y, z = z, h = h } end
local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
local function key(p) return p.x .. "," .. p.y .. "," .. p.z end
local function distance(a, b)
    return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end
local function checksum(s)
    local a, b = 1, 0
    for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
    return b * 65536 + a
end
local function readFile(path)
    local handle = fs.open(path, "r"); if not handle then return nil end
    local ok, data = pcall(handle.readAll); pcall(handle.close)
    if not ok then return nil end
    return data
end
local function writeFile(path, data)
    local handle, why = fs.open(path, "w")
    if not handle then error("Cannot write checkpoint: " .. tostring(why), 0) end
    local ok, err = pcall(handle.write, data); pcall(handle.close)
    if not ok then error("Cannot write checkpoint: " .. tostring(err), 0) end
end
local function remove(path) if fs.exists(path) then fs.delete(path) end end
local function decode(raw)
    if not raw then return nil end
    local ok, envelope = pcall(textutils.unserialize, raw)
    if not ok or type(envelope) ~= "table" or type(envelope.payload) ~= "string"
        or envelope.checksum ~= checksum(envelope.payload) then return nil end
    local parsed, job = pcall(textutils.unserialize, envelope.payload)
    if not parsed or type(job) ~= "table" or job.schema ~= SCHEMA
        or type(job.seq) ~= "number" or type(job.home) ~= "table"
        or type(job.pose) ~= "table" or type(job.work) ~= "table"
        or type(job.config) ~= "table" then return nil end
    return job
end
local function loadJob()
    local a, b = decode(readFile(ROOT .. "/job.a")), decode(readFile(ROOT .. "/job.b"))
    if a and b then return a.seq > b.seq and a or b end
    return a or b
end

local Miner = {}; Miner.__index = Miner
function Miner.load()
    local job = loadJob(); if not job then return nil, "No valid saved job." end
    if job.computer ~= os.getComputerID() then
        return nil, "This job belongs to a different turtle. Do not clone job files."
    end
    return setmetatable({ job = job }, Miner)
end
function Miner:save()
    self.job.seq = self.job.seq + 1
    local payload = textutils.serialize(self.job)
    local raw = textutils.serialize({ payload = payload, checksum = checksum(payload) })
    if #raw > 380000 then error("Checkpoint too large; reduce the ore vein limit.", 0) end
    fs.makeDir(ROOT)
    local destination = ROOT .. (self.job.seq % 2 == 0 and "/job.a" or "/job.b")
    writeFile(ROOT .. "/write.tmp", raw)
    -- The other generation stays intact if the replacement is interrupted.
    remove(destination); fs.move(ROOT .. "/write.tmp", destination)
end
local function integer(n, name, minimum, maximum)
    if type(n) ~= "number" or n ~= math.floor(n) or n < minimum or n > maximum then
        error(name .. " must be an integer between " .. minimum .. " and " .. maximum, 0)
    end
end
function Miner.create(options)
    local old = loadJob()
    if old and old.status ~= "completed" and old.status ~= "cancelled" then
        error("An unfinished job exists. Use resume, not new. Cancel explicitly to replace it.", 0)
    end
    if fs.exists(ROOT .. "/run.lock") then error("A miner is already running.", 0) end
    local config = {
        length = 30, pairs = 20, spacing = 3, veins = true, pave = true,
        veinRadius = 6, veinLimit = 128, fuelBuffer = 32, freeSlots = 2,
        discardCommon = false, attack = false, retrySeconds = 3, gps = false,
    }
    for k, v in pairs(options or {}) do config[k] = copy(v) end
    integer(config.length, "Branch length", 1, 512)
    integer(config.pairs, "Branch pairs (0 = continuous)", 0, 1000000)
    integer(config.spacing, "Branch spacing", 2, 64)
    integer(config.veinLimit, "Vein block limit", 1, 512)
    integer(config.veinRadius, "Vein radius", 1, 16)
    integer(config.freeSlots, "Reserved empty slots", 1, 8)
    integer(config.fuelBuffer, "Fuel reserve", 4, 10000)
    if config.bounds then
        for _, name in ipairs({ "minX", "maxX", "minZ", "maxZ" }) do
            integer(config.bounds[name], name, -1000000, 1000000)
        end
        if config.bounds.minX > 0 or config.bounds.maxX < 0
            or config.bounds.minZ > 0 or config.bounds.maxZ < 0
            or config.bounds.minX > config.bounds.maxX
            or config.bounds.minZ > config.bounds.maxZ then
            error("Bounds must contain the original start (0,0).", 0)
        end
    end
    local home = point(0, 0, 0, 0)
    if config.gps then
        if COMPASS[config.heading] == nil then error("GPS mode needs --heading north/east/south/west.", 0) end
        if not gps or not gps.locate then error("GPS API is unavailable.", 0) end
        local x, y, z = gps.locate(2, false)
        if not x then error("GPS is unavailable: check the modem and GPS hosts.", 0) end
        home.world = point(math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5))
        home.worldHeading = COMPASS[config.heading]
    end
    local job = { schema = SCHEMA, version = VERSION, seq = 0,
        computer = os.getComputerID(), id = tostring(os.getComputerID()) .. ":" .. tostring(os.epoch("utc")),
        config = config, home = home, pose = point(0, 0, 0, 0), status = "running",
        work = { pair = 1, phase = "main", step = 1, stage = "move" },
        stats = { moves = 0, blocks = 0, ores = 0, pairs = 0, serviceTrips = 0 },
    }
    local instance = setmetatable({ job = job }, Miner)
    remove(ROOT .. "/control"); instance:save(); return instance
end
function Miner:status(status, reason)
    if self.job.status ~= status or self.job.reason ~= reason then
        self.job.status, self.job.reason = status, reason; self:save()
    end
    return false, reason
end
function Miner:waiting(reason) return self:status("waiting", reason) end
function Miner:control()
    local raw = readFile(ROOT .. "/control")
    if not raw then return end
    local ok, message = pcall(textutils.unserialize, raw); remove(ROOT .. "/control")
    if not ok or type(message) ~= "table" or message.id ~= self.job.id then return end
    if message.action == "pause" then self:status("paused", "Paused by user.")
    elseif message.action == "cancel" then self:status("cancelled", "Cancelled by user.")
    elseif message.action == "resume" then self:status("running") end
end
function Miner:inside(p)
    local bounds = self.job.config.bounds
    return not bounds or (p.x >= bounds.minX and p.x <= bounds.maxX
        and p.z >= bounds.minZ and p.z <= bounds.maxZ)
end
function Miner:inventoryUsed()
    local used = 0; for slot = 1, 16 do if turtle.getItemCount(slot) > 0 then used = used + 1 end end
    return used
end
function Miner:refuel(required)
    local level = turtle.getFuelLevel()
    if level == "unlimited" or level >= required then return true end
    local selected = turtle.getSelectedSlot()
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and FUELS[item.name] then
            turtle.select(slot)
            while turtle.getItemCount(slot) > 0 and turtle.getFuelLevel() < required do
                local ok = turtle.refuel(1); if not ok then break end
            end
        end
        if turtle.getFuelLevel() >= required then break end
    end
    turtle.select(selected)
    return turtle.getFuelLevel() >= required
end
local function ore(data)
    if not data then return false end
    if data.name == "minecraft:ancient_debris" or data.name:match("_ore$") then return true end
    for name, present in pairs(data.tags or {}) do
        if present and (name == "forge:ores" or name == "c:ores"
            or name:match("^forge:ores/") or name:match("^c:ores/")) then return true end
    end
    return false
end
local function protected(data)
    return data and (UNBREAKABLE[data.name] or data.name:match("^computercraft:")
        or data.name:match("chest$") or data.name:match("barrel$"))
end
function Miner:dig(direction)
    local suffix = direction == "up" and "Up" or direction == "down" and "Down" or ""
    local exists, data = turtle["inspect" .. suffix]()
    if not exists then return true end
    if protected(data) then return self:waiting("Protected/unbreakable block: " .. data.name) end
    if self:inventoryUsed() >= 16 then return self:waiting("Inventory full; free a slot.") end
    local ok, reason = turtle["dig" .. suffix]()
    if not ok then return self:waiting("Cannot dig: " .. tostring(reason)) end
    self.job.stats.blocks = self.job.stats.blocks + 1; self:save()
    return false -- Re-inspect on the next tick; falling blocks may arrive.
end
function Miner:motion(method, target)
    self:control()
    if self.job.status == "paused" or self.job.status == "cancelled" then return false end
    if not self:inside(target) then return self:waiting("Outside configured loaded area. Extend bounds after chunk-loading it.") end
    self.job.pending = { kind = method, from = copy(self.job.pose), to = copy(target),
        fuel = turtle.getFuelLevel() }
    self:save() -- Write-ahead journal, before the physical action can happen.
    local ok, reason = turtle[method]()
    if ok then
        self.job.pose = copy(target)
        if method ~= "turnLeft" and method ~= "turnRight" then
            self.job.stats.moves = self.job.stats.moves + 1
        end
    end
    self.job.pending = nil; self:save()
    if ok then return true end
    if method == "turnLeft" or method == "turnRight" then
        return self:waiting("Turn failed: " .. tostring(reason))
    end
    local direction = method == "up" and "up" or method == "down" and "down" or "front"
    local suffix = direction == "up" and "Up" or direction == "down" and "Down" or ""
    if turtle["detect" .. suffix]() then return self:dig(direction) end
    if self.job.config.attack then turtle["attack" .. suffix]() end
    return self:waiting("Movement blocked: " .. tostring(reason))
end
function Miner:face(heading)
    local p = self.job.pose; if p.h == heading then return true end
    local delta = (heading - p.h) % 4
    local target = copy(p); target.h = (p.h + (delta == 3 and -1 or 1)) % 4
    self:motion(delta == 3 and "turnLeft" or "turnRight", target)
    return false
end
function Miner:go(target)
    local p = self.job.pose; if same(p, target) then return true end
    local nextPoint = copy(p)
    if p.y ~= target.y then
        local up = target.y > p.y; nextPoint.y = p.y + (up and 1 or -1)
        self:motion(up and "up" or "down", nextPoint)
    else
        local heading
        if p.x ~= target.x then heading = target.x > p.x and 1 or 3
        else heading = target.z > p.z and 0 or 2 end
        if not self:face(heading) then return false end
        nextPoint.x = p.x + DIRECTIONS[heading].x
        nextPoint.z = p.z + DIRECTIONS[heading].z
        self:motion("forward", nextPoint)
    end
    return false -- Physical progress is committed before advancing the task.
end
function Miner:gpsPosition()
    local home = self.job.home
    if not home.world or not gps or not gps.locate then return nil end
    local x, y, z = gps.locate(2, false); if not x then return nil end
    local dx, dz = math.floor(x + 0.5) - home.world.x, math.floor(z + 0.5) - home.world.z
    local forward, right = DIRECTIONS[home.worldHeading], DIRECTIONS[(home.worldHeading + 3) % 4]
    return point(dx * right.x + dz * right.z, math.floor(y + 0.5) - home.world.y,
        dx * forward.x + dz * forward.z)
end
function Miner:resolveProbe()
    local pending = self.job.pending
    local actual = self:gpsPosition()
    if not actual then return self:status("recovery", "GPS unavailable during orientation recovery. Restore GPS and resume.") end
    if pending.phase == "out" and not same(actual, pending.anchor) then
        if distance(actual, pending.anchor) ~= 1 or actual.y ~= pending.anchor.y or not pending.attempt then
            return self:status("recovery", "Unexpected position during GPS recovery; manual position verification required.")
        end
        local sign = pending.attempt == "back" and -1 or 1
        local dx, dz = (actual.x - pending.anchor.x) * sign, (actual.z - pending.anchor.z) * sign
        local heading
        for h = 0, 3 do if DIRECTIONS[h].x == dx and DIRECTIONS[h].z == dz then heading = h end end
        if heading == nil then return self:status("recovery", "Invalid GPS probe direction.") end
        pending.heading, pending.out, pending.phase = heading, copy(actual), "return"
        self.job.pose = point(actual.x, actual.y, actual.z, heading); self:save()
    end
    if pending.phase == "return" then
        if same(actual, pending.anchor) then
            self.job.pose = point(actual.x, actual.y, actual.z, pending.heading)
            self.job.pending = nil; self:save(); return true
        end
        if not same(actual, pending.out) then return self:status("recovery", "GPS probe return position differs from its journal.") end
        if not self:refuel(1) then return self:status("recovery", "Add fuel to finish the GPS recovery move.") end
        -- The return action is also covered by the probe journal.
        local ok = turtle[pending.attempt == "back" and "forward" or "back"]()
        if not ok then return self:status("recovery", "Clear the GPS probe return cell, then resume.") end
        return false
    end
    if not self:refuel(2) then return self:status("recovery", "Add fuel for GPS orientation recovery.") end
    for _ = 1, 4 do
        for _, method in ipairs({ "forward", "back" }) do
            pending.attempt = method; self:save()
            if turtle[method]() then return false end
        end
        pending.attempt = nil; self:save()
        -- Heading is deliberately unknown here. A later GPS probe measures it.
        turtle.turnRight()
    end
    return self:status("recovery", "GPS orientation needs one free adjacent cell. Clear a cell and resume.")
end
function Miner:resolve()
    local pending = self.job.pending; if not pending then return true end
    if pending.kind == "probe" then return self:resolveProbe() end
    if pending.kind == "turnLeft" or pending.kind == "turnRight" then
        if not self.job.home.world then
            return self:status("recovery", "Turn outcome is unknown. Confirm with recover before or recover after; old home is preserved.")
        end
        local actual = self:gpsPosition()
        if not actual or not same(actual, pending.from) then
            return self:status("recovery", "GPS cannot confirm the saved turn position.")
        end
        self.job.pending = { kind = "probe", phase = "out", anchor = copy(actual), original = copy(pending) }
        self:save(); return false
    end
    local actual = self.job.home.world and self:gpsPosition() or nil
    local completed
    if self.job.home.world then
        if actual and same(actual, pending.to) then completed = true
        elseif actual and same(actual, pending.from) then completed = false
        else return self:status("recovery", "GPS position differs from the movement journal. No new home will be created.") end
    else
        local fuel = turtle.getFuelLevel()
        if type(fuel) == "number" and type(pending.fuel) == "number" then
            if fuel == pending.fuel - 1 then completed = true
            elseif fuel == pending.fuel then completed = false end
        end
        if completed == nil then return self:status("recovery", "Movement outcome is unknown. Use recover before/after after checking the turtle.") end
    end
    self.job.pose = copy(completed and pending.to or pending.from)
    if completed then self.job.stats.moves = self.job.stats.moves + 1 end
    self.job.pending = nil; self:save(); return true
end
function Miner:verify()
    if self.job.pending then return true end
    if self.job.home.world then
        local actual = self:gpsPosition()
        if not actual or not same(actual, self.job.pose) then
            return self:status("recovery", "GPS position does not match the saved job. Keep the original home; verify position manually.")
        end
    end
    return true
end
function Miner:recover(outcome)
    local pending = self.job.pending
    if not pending or pending.kind == "probe" then error("No ordinary pending movement to confirm. GPS probes require GPS recovery.", 0) end
    if outcome ~= "before" and outcome ~= "after" then error("Use recover before or recover after.", 0) end
    local target = outcome == "after" and pending.to or pending.from
    local actual = self:gpsPosition()
    if actual and not same(actual, target) then error("GPS disagrees with the requested recovery position.", 0) end
    self.job.pose = copy(target)
    if outcome == "after" and pending.kind ~= "turnLeft" and pending.kind ~= "turnRight" then
        self.job.stats.moves = self.job.stats.moves + 1
    end
    self.job.pending = nil; self:status("paused", "Recovery confirmed. Use resume."); self:save()
end

local function add(route, p)
    if #route == 0 or not same(route[#route], p) then route[#route + 1] = copy(p) end
end
function Miner:homeRoute()
    local route = {}; add(route, self.job.pose)
    local vein = self.job.vein
    if vein then
        -- Include the parent when a child move committed before its stack entry.
        for index = #vein.stack, 1, -1 do add(route, vein.stack[index].pos) end
    end
    local base = route[#route]
    add(route, point(base.x, 0, base.z)); add(route, point(0, 0, base.z))
    add(route, self.job.home); return route
end
local function routeCost(pose, route, index)
    local total, previous = 0, pose
    for i = index or 1, #route do total = total + distance(previous, route[i]); previous = route[i] end
    return total
end
function Miner:startService(final)
    local route = self:homeRoute()
    self.job.service = { phase = "home", route = route, index = 1,
        position = copy(self.job.pose), heading = self.job.pose.h,
        cost = routeCost(self.job.pose, route), final = final == true }
    self.job.stats.serviceTrips = self.job.stats.serviceTrips + 1; self:save()
end
local function inventoryPeripheral(side)
    local wrapped = peripheral and peripheral.wrap and peripheral.wrap(side)
    return wrapped and type(wrapped.size) == "function" and type(wrapped.list) == "function"
end
function Miner:unload()
    if not same(self.job.pose, self.job.home) then error("Refusing to unload away from the original home.", 0) end
    if not self:face(2) then return false end
    if not inventoryPeripheral("front") then return self:waiting("Place an output chest behind the ORIGINAL start, at the same height.") end
    local selected, fuelKept, pavingKept = turtle.getSelectedSlot(), 0, 0
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item then
            local count, keep = turtle.getItemCount(slot), 0
            if FUELS[item.name] then keep = math.min(count, math.max(0, 64 - fuelKept)); fuelKept = fuelKept + keep
            elseif self.job.config.pave and PAVING[item.name] then
                keep = math.min(count, math.max(0, 32 - pavingKept)); pavingKept = pavingKept + keep
            end
            if count > keep then
                turtle.select(slot); turtle.drop(count - keep)
                if turtle.getItemCount(slot) > keep then
                    turtle.select(selected); return self:waiting("Original output chest is full. Waiting for space.")
                end
            end
        end
    end
    turtle.select(selected); return true
end
function Miner:service()
    local service = self.job.service
    if service.phase == "home" then
        local required = routeCost(self.job.pose, service.route, service.index)
        if not self:refuel(required) then return self:waiting("Not enough fuel to reach original home. Add coal here.") end
        local target = service.route[service.index]
        if target then
            if self:go(target) then service.index = service.index + 1; self:save() end
            return true
        end
        service.phase = "unload"; self:save()
    end
    if service.phase == "unload" then
        if not self:unload() then return false end
        service.phase = "fuel"; self:save()
    end
    if service.phase == "fuel" then
        local required = service.final and 0 or service.cost * 2 + self.job.config.fuelBuffer + 4
        if not self:refuel(required) then
            if inventoryPeripheral("bottom") then turtle.suckDown(64) end
            if not self:refuel(required) then return self:waiting("Waiting for coal: fuel chest belongs BELOW the original start.") end
        end
        service.phase, service.index = "work", #service.route; self:save()
    end
    if service.phase == "work" then
        if service.final then
            if not self:face(0) then return true end
            self.job.service = nil; self:status("completed", "Finished and unloaded at the original home."); return false
        end
        local target = service.route[service.index]
        if target then
            if self:go(target) then service.index = service.index - 1; self:save() end
            return true
        end
        if not self:face(service.heading) then return true end
        self.job.service = nil; self:save()
    end
    return true
end
function Miner:resources()
    if self.job.config.discardCommon then
        local selected, pavingKept = turtle.getSelectedSlot(), 0
        for slot = 1, 16 do
            local item = turtle.getItemDetail(slot)
            if item and COMMON[item.name] then
                local count, keep = turtle.getItemCount(slot), 0
                if self.job.config.pave and PAVING[item.name] then
                    keep = math.min(count, math.max(0, 32 - pavingKept)); pavingKept = pavingKept + keep
                end
                if count > keep then turtle.select(slot); turtle.dropUp(count - keep) end
            end
        end
        turtle.select(selected)
    end
    local cost = routeCost(self.job.pose, self:homeRoute())
    local enough = self:refuel(cost + self.job.config.fuelBuffer + 2)
    local full = self:inventoryUsed() >= 16 - self.job.config.freeSlots
    if full or not enough then
        if not self:refuel(cost) then return self:waiting("Insufficient return fuel. Add coal; this job and home are retained.") end
        self:startService(false); return false
    end
    return true
end
function Miner:pave()
    if not self.job.config.pave or turtle.detectDown() then return end
    local selected = turtle.getSelectedSlot()
    for slot = 1, 16 do
        local item = turtle.getItemDetail(slot)
        if item and PAVING[item.name] then turtle.select(slot); turtle.placeDown(); break end
    end
    turtle.select(selected)
end
function Miner:vein()
    local vein = self.job.vein
    if vein.travel then
        local destination = vein.travel.pos
        if self:go(destination) then
            if vein.travel.returning then table.remove(vein.stack)
            else
                vein.visited[key(destination)] = true; vein.count = vein.count + 1
                self.job.stats.ores = self.job.stats.ores + 1
                vein.stack[#vein.stack + 1] = { pos = copy(destination), next = 1, directions = { 0, 1, 2, 3, "up", "down" } }
            end
            vein.travel = nil; self:save()
        end
        return true
    end
    local node = vein.stack[#vein.stack]
    if not node then self.job.vein = nil; self:save(); return true end
    local direction = node.directions[node.next]
    if direction == nil then
        if #vein.stack == 1 then self.job.vein = nil; self:save()
        else vein.travel = { pos = copy(vein.stack[#vein.stack - 1].pos), returning = true }; self:save() end
        return true
    end
    local target, inspected, data = copy(self.job.pose)
    if direction == "up" or direction == "down" then
        target.y = target.y + (direction == "up" and 1 or -1)
        inspected, data = turtle[direction == "up" and "inspectUp" or "inspectDown"]()
    else
        if not self:face(direction) then return true end
        target.x, target.z = target.x + DIRECTIONS[direction].x, target.z + DIRECTIONS[direction].z
        inspected, data = turtle.inspect()
    end
    local radius = math.max(math.abs(target.x - vein.root.x), math.abs(target.y - vein.root.y), math.abs(target.z - vein.root.z))
    if inspected and ore(data) and not vein.visited[key(target)] and self:inside(target)
        and radius <= self.job.config.veinRadius and vein.count < self.job.config.veinLimit then
        -- Keep the parent at its own position until the child move commits.
        vein.travel = { pos = target }; node.next = node.next + 1
    else node.next = node.next + 1 end
    self:save(); return true
end
function Miner:workTarget()
    local w, config = self.job.work, self.job.config
    local z = w.pair * config.spacing
    if w.phase == "main" then return point(0, 0, (w.pair - 1) * config.spacing + w.step) end
    local side = w.phase:match("^left") and -1 or 1
    if w.phase:match("_out$") then return point(side * w.step, 0, z)
    elseif w.phase:match("_raise$") then return point(side * config.length, 1, z)
    elseif w.phase:match("_back$") then return point(side * (config.length - w.step), 1, z)
    elseif w.phase:match("_lower$") then return point(0, 0, z) end
end
function Miner:advance()
    local w, config = self.job.work, self.job.config
    local limit = w.phase == "main" and config.spacing or config.length
    if w.phase == "main" or w.phase:match("_out$") or w.phase:match("_back$") then
        if w.step < limit then w.step = w.step + 1; w.stage = "move"; self:save(); return end
    end
    local phases = { main = "left_out", left_out = "left_raise", left_raise = "left_back",
        left_back = "left_lower", left_lower = "right_out", right_out = "right_raise",
        right_raise = "right_back", right_back = "right_lower" }
    if w.phase == "right_lower" then
        self.job.stats.pairs = self.job.stats.pairs + 1; w.pair = w.pair + 1
        w.phase = config.pairs > 0 and w.pair > config.pairs and "finished" or "main"
    else w.phase = phases[w.phase] end
    w.step, w.stage = 1, "move"; self:save()
end
function Miner:tick()
    self:control()
    if self.job.status == "paused" or self.job.status == "cancelled" or self.job.status == "completed" then return false end
    if self.job.pending then return self:resolve() end
    if self.job.status == "recovery" then return false end
    if self.job.service then return self:service() end
    if self.job.work.phase == "finished" then self:startService(true); return true end
    if not self:resources() then return false end
    if self.job.status == "waiting" then self:status("running") end
    if self.job.vein then return self:vein() end
    local w = self.job.work
    if w.stage == "move" then
        if self:go(self:workTarget()) then w.stage = "head"; self:save() end
    elseif w.stage == "head" then
        if (w.phase == "main" or w.phase:match("_out$")) and not self:dig("up") then return false end
        w.stage = "scan"; self:save()
    elseif w.stage == "scan" then
        -- Vein traversal may change heading. Scan relative to the tunnel, not
        -- the last incidental ore movement, including the upper endpoint.
        if self.job.config.veins and not w.phase:match("_lower$") then
            local headings = { main = 0, left_out = 3, left_raise = 1, left_back = 1,
                right_out = 1, right_raise = 3, right_back = 3 }
            if not self:face(headings[w.phase]) then return false end
        end
        w.stage = "advance"
        if self.job.config.veins and not w.phase:match("_lower$") then
            local h = self.job.pose.h
            self.job.vein = { root = copy(self.job.pose), count = 0,
                visited = { [key(self.job.pose)] = true },
                stack = { { pos = copy(self.job.pose), next = 1,
                    directions = { (h + 3) % 4, (h + 1) % 4, self.job.pose.y == 1 and "up" or "down" } } } }
        end
        self:save()
    else
        if self.job.pose.y == 0 then self:pave() end
        self:advance()
    end
    return true
end

local function sendControl(job, action)
    fs.makeDir(ROOT); writeFile(ROOT .. "/control", textutils.serialize({ id = job.id, action = action }))
end
local function summary(job)
    print("Resumable Branch Miner " .. VERSION .. " | " .. job.status)
    print("Original home: 0,0,0; output chest behind that ORIGINAL start.")
    if job.home.world then print("World home: " .. key(job.home.world)) end
    print("Position: " .. key(job.pose) .. " heading " .. job.pose.h)
    print("Pair " .. job.work.pair .. " | " .. job.work.phase .. " | step " .. job.work.step .. " | " .. job.work.stage)
    if job.service then print("Service: " .. job.service.phase .. "; returning to the saved work position afterwards.") end
    if job.reason then print(job.reason) end
    if job.pending then print("Pending movement: " .. job.pending.kind) end
end
local function run(instance)
    if fs.exists(ROOT .. "/run.lock") then
        sendControl(instance.job, "resume"); print("Resume requested for the existing worker."); return
    end
    if instance.job.status == "completed" or instance.job.status == "cancelled" then summary(instance.job); return end
    if not instance:verify() then summary(instance.job); return end
    writeFile(ROOT .. "/run.lock", instance.job.id)
    print("Mining. Use another shell tab for status/pause, or Ctrl+T to stop safely.")
    local lastReason
    local ok, why = pcall(function()
        instance:status("running")
        while true do
            local progress = instance:tick()
            local state = instance.job.status
            if state == "paused" or state == "cancelled" or state == "completed" or state == "recovery" then break end
            if instance.job.reason ~= lastReason then
                lastReason = instance.job.reason; if lastReason then print(lastReason) end
            end
            sleep(progress and 0 or instance.job.config.retrySeconds)
        end
    end)
    remove(ROOT .. "/run.lock")
    if not ok then
        -- A possibly unfinished physical action remains journaled for recovery.
        instance.job.status = "paused"; instance.job.reason = tostring(why)
        pcall(function() instance:save() end)
        print("Stopped: " .. tostring(why) .. ". Saved home and job retained; use resume.")
    else summary(instance.job) end
end
local function parse(args)
    local config = { length = tonumber(args[2]) or 30, pairs = tonumber(args[3]) or 20,
        spacing = tonumber(args[4]) or 3 }
    local i = 5
    while i <= #args do
        local flag = args[i]
        if flag == "--gps" then config.gps = true
        elseif flag == "--heading" then i = i + 1; config.heading = args[i]
        elseif flag == "--no-veins" then config.veins = false
        elseif flag == "--no-pave" then config.pave = false
        elseif flag == "--discard-common" then config.discardCommon = true
        elseif flag == "--attack" then config.attack = true
        elseif flag == "--bounds" then
            i = i + 1
            local a, b, c, d = tostring(args[i]):match("^(-?%d+),(-?%d+),(-?%d+),(-?%d+)$")
            if not a then error("Bounds format: minX,maxX,minZ,maxZ, relative to ORIGINAL start.", 0) end
            config.bounds = { minX = tonumber(a), maxX = tonumber(b), minZ = tonumber(c), maxZ = tonumber(d) }
        else error("Unknown option: " .. tostring(flag), 0) end
        i = i + 1
    end
    return config
end
local API = { Miner = Miner, checksum = checksum, decode = decode, parse = parse, version = VERSION,
    sendControl = sendControl, same = same, key = key, run = run }
if arguments[1] == "__test__" then return API end
local function main()
    local command = arguments[1]
    if command == "new" then run(Miner.create(parse(arguments))); return end
    if command == "boot" then
        -- Only startup.lua calls boot: runtime ownership ends with a computer boot.
        remove(ROOT .. "/run.lock")
        local instance = Miner.load()
        if instance and instance.job.status ~= "paused" then run(instance) end
        return
    end
    local instance = Miner.load()
    if command == "status" then if instance then summary(instance.job) else print("No saved job.") end; return end
    if command == "resume" then if not instance then error("No saved job. Put the turtle at its NEW base and use new.", 0) end; run(instance); return end
    if command == "pause" or command == "cancel" then
        if not instance then error("No saved job.", 0) end
        if fs.exists(ROOT .. "/run.lock") then sendControl(instance.job, command)
        else instance:status(command == "pause" and "paused" or "cancelled", "Requested by user.") end
        print(command .. " requested; original home is retained."); return
    end
    if command == "recover" then
        if not instance then error("No saved job.", 0) end
        if fs.exists(ROOT .. "/run.lock") then error("Pause the worker before manual recovery.", 0) end
        instance:recover(arguments[2]); summary(instance.job); return
    end
    print("Resumable Branch Miner " .. VERSION)
    print("branchminer new <branchLength> <pairs|0> <spacing> [options]")
    print("branchminer resume | pause | status | cancel")
    print("branchminer recover before|after  (only when action outcome is unknown)")
    print("Options: --gps --heading north|east|south|west --no-veins --no-pave")
    print("         --bounds minX,maxX,minZ,maxZ --discard-common --attack")
end
local ok, why = pcall(main)
if not ok then printError(tostring(why)) end
