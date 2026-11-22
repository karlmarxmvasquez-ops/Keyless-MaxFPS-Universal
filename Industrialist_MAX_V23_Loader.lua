-- INDUSTRIALIST MAX V23 loader
local url = "https://raw.githubusercontent.com/karlmarxmvasquez-ops/Keyless-MaxFPS-Universal/main/Industrialist_MAX_V23.lua"
local ok, source = pcall(function() return game:HttpGet(url) end)
if not ok or type(source) ~= "string" or #source < 1000 then
    warn("[MAX V23] Failed to download the script.")
    return
end
local fn, err = loadstring(source)
if not fn then
    warn("[MAX V23] Compile error: " .. tostring(err))
    return
end
local ran, runErr = pcall(fn)
if not ran then warn("[MAX V23] Runtime error: " .. tostring(runErr)) end
