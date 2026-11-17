-- INDUSTRIALIST MAX V21 | ONE-PASTE LOADER
local URL = "https://raw.githubusercontent.com/karlmarxmvasquez-ops/Keyless-MaxFPS-Universal/refs/heads/main/Industrialist_MAX_V21.lua"

local ok, source = pcall(function()
    return game:HttpGet(URL)
end)

if not ok or type(source) ~= "string" or source == "" then
    warn("[MAX] Download failed: " .. tostring(source))
    return
end

local compile, err = loadstring(source)
if not compile then
    warn("[MAX] Compile failed: " .. tostring(err))
    return
end

local ran, runErr = pcall(compile)
if not ran then
    warn("[MAX] Runtime error: " .. tostring(runErr))
end
