-- Fresh install, or an explicitly requested update preserving job and startup.
local args = { ... }
local update = args[1] == "--update"
local BASE = "https://raw.githubusercontent.com/XJIe6yLLIEK4/cc-resumable-branch-miner/main/"
local STAGE = "/.branchminer-install"
if not turtle then error("Run this installer on a mining turtle.", 0) end
if #args > (update and 1 or 0) then error("Usage: install.lua [--update]", 0) end
if fs.exists("/.branchminer/run.lock") then error("Pause the miner and wait for it to exit before updating.", 0) end
local files = update and { "branchminer.lua" } or { "branchminer.lua", "startup.lua" }
if update then
    if not fs.exists("/branchminer.lua") then error("No installed miner. Run the installer without --update.", 0) end
else
    for _, file in ipairs(files) do
        if fs.exists("/" .. file) then error("Already exists: /" .. file .. ". Use --update for an installed miner.", 0) end
    end
end
if fs.exists(STAGE) then fs.delete(STAGE) end
fs.makeDir(STAGE)
for _, file in ipairs(files) do
    local response, reason = http.get(BASE .. file)
    if not response then error("Download failed: " .. tostring(reason), 0) end
    local code = response.readAll(); response.close()
    local compiled, why = load(code, "@" .. file, "t", _ENV)
    if not compiled then error("Invalid download: " .. tostring(why), 0) end
    local handle = assert(fs.open(STAGE .. "/" .. file, "w"))
    handle.write(code); handle.close()
end
if update then
    local backup, number = "/branchminer.lua.previous", 0
    while fs.exists(backup) do number = number + 1; backup = "/branchminer.lua.previous." .. number end
    fs.move("/branchminer.lua", backup)
    local ok, why = pcall(fs.move, STAGE .. "/branchminer.lua", "/branchminer.lua")
    if not ok then fs.move(backup, "/branchminer.lua"); error("Update failed: " .. tostring(why), 0) end
    print("Updated program; old version: " .. backup)
    print("Saved job, original home and startup preserved. Use branchminer resume for the old job.")
else
    for _, file in ipairs(files) do fs.move(STAGE .. "/" .. file, "/" .. file) end
end
fs.delete(STAGE)
if not update then print("Installed. Place OUTPUT CHEST behind the new start and FUEL CHEST below it.") end
print("New branch job: branchminer new 30 20 3")
print("New quarry job: branchminer quarry 5  (11x11 ahead of the base, down to bedrock)")
print("GPS:   branchminer new 30 20 3 --gps --heading north")
print("Continuous: pairs = 0; chunk-load the whole route and output/fuel chests.")
print("Resume never changes the original start. See the repository README.")
