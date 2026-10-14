-- Install only on a fresh turtle. Existing programs and startup are preserved.
local BASE = "https://raw.githubusercontent.com/XJIe6yLLIEK4/cc-resumable-branch-miner/main/"
local STAGE = "/.branchminer-install"
if not turtle then error("Run this installer on a mining turtle.", 0) end
for _, path in ipairs({ "/branchminer.lua", "/startup.lua" }) do
    if fs.exists(path) then error("Already exists: " .. path .. ". Use a fresh installation or review it manually.", 0) end
end
if fs.exists(STAGE) then fs.delete(STAGE) end
fs.makeDir(STAGE)
for _, file in ipairs({ "branchminer.lua", "startup.lua" }) do
    local response, reason = http.get(BASE .. file)
    if not response then error("Download failed: " .. tostring(reason), 0) end
    local code = response.readAll(); response.close()
    local compiled, why = load(code, "@" .. file, "t", _ENV)
    if not compiled then error("Invalid download: " .. tostring(why), 0) end
    local handle = assert(fs.open(STAGE .. "/" .. file, "w"))
    handle.write(code); handle.close()
end
for _, file in ipairs({ "branchminer.lua", "startup.lua" }) do fs.move(STAGE .. "/" .. file, "/" .. file) end
fs.delete(STAGE)
print("Installed. Place OUTPUT CHEST behind the new start and FUEL CHEST below it.")
print("Start: branchminer new 30 20 3")
print("GPS:   branchminer new 30 20 3 --gps --heading north")
print("Continuous: pairs = 0; chunk-load the whole route and output/fuel chests.")
print("Resume never changes the original start. See the repository README.")
