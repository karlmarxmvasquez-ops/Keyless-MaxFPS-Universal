-- INDUSTRIALIST MAX V18 | ONE-PASTE LOADER
local URL = "https://raw.githubusercontent.com/karlmarxmvasquez-ops/Keyless-MaxFPS-Universal/refs/heads/main/Industrialist_MAX_V18.lua"
local ok, src = pcall(function() return game:HttpGet(URL) end)
if not ok or type(src) ~= "string" or #src < 500 then
    warn("[MAX V18] Download failed: " .. tostring(src))
    return
end
local fn, err = loadstring(src)
if not fn then
    warn("[MAX V18] Compile failed: " .. tostring(err))
    return
end
fn()
