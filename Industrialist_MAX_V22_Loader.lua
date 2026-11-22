-- INDUSTRIALIST MAX V22 | ONE-PASTE LOADER
local URL = "https://raw.githubusercontent.com/karlmarxmvasquez-ops/Keyless-MaxFPS-Universal/main/Industrialist_MAX_V22.lua"
local ok, source = pcall(function() return game:HttpGet(URL) end)
if not ok or type(source) ~= "string" or #source == 0 then
    warn("[MAX V22] Download failed: " .. tostring(source))
    return
end
local fn, err = loadstring(source)
if not fn then
    warn("[MAX V22] Compile failed: " .. tostring(err))
    return
end
fn()