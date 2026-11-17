-- Replace the URL below with the GitHub Raw URL of Industrialist_MAX_V21.lua
local URL = "PASTE_YOUR_GITHUB_RAW_URL_HERE"

local ok, source = pcall(function()
    return game:HttpGet(URL)
end)

if not ok or type(source) ~= "string" or source == "" then
    warn("[MAX] Could not download the hosted script: " .. tostring(source))
    return
end

local compile, err = loadstring(source)
if not compile then
    warn("[MAX] Hosted script compile failed: " .. tostring(err))
    return
end

local ran, runErr = pcall(compile)
if not ran then
    warn("[MAX] Hosted script failed: " .. tostring(runErr))
end
