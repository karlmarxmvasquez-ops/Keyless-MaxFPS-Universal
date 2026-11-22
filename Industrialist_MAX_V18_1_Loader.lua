-- INDUSTRIALIST MAX V18.1 | ONE-PASTE LOADER
local URL = "https://raw.githubusercontent.com/karlmarxmvasquez-ops/Keyless-MaxFPS-Universal/main/Industrialist_MAX_V18_1.lua"
local ok, source = pcall(function() return game:HttpGet(URL) end)
if not ok or type(source) ~= "string" or source == "" then
    warn("[MAX] Download failed: " .. tostring(source))
    return
end
local compile, err = loadstring(source)
if not compile then warn("[MAX] Compile failed: " .. tostring(err)); return end
local ran, runErr = pcall(compile)
if not ran then warn("[MAX] Runtime error: " .. tostring(runErr)) end
