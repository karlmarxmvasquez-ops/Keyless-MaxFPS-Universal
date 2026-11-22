--[[
============================================================
 INDUSTRIALIST MAX V22 | MEMORY-LEAN BUILD
 Client-side visual optimizer for Roblox / Delta
============================================================
 Based on the supplied V18.1 source.

 V22 changes:
 - Bounded depth-first scanner; no giant flat world queue.
 - Stale tracked records are removed safely.
 - Correct hidden-object accounting.
 - Worker generation token prevents duplicate workers.
 - Adaptive scheduler backs off when idle and under pressure.
 - Bounded diagnostic log and bounded name/class caches.
 - Avoids per-tick full-world copies and unnecessary work.
 - All optimization toggles OFF on startup.
 - No startup delay and no forced blackout.
 - No game objects are destroyed.

 Limitations:
 - Lua heap metrics are not total Roblox/Android memory.
 - The script cannot force Roblox to unload textures, meshes,
   terrain assets, or engine-managed resources.
 - Executor APIs vary. This script is not guaranteed to work
   on every Delta version and has not been runtime-tested here.
============================================================
]]

local G = _G
local VERSION = "V22"
local T0 = os.clock()

-- Stop the previous copy first.
if type(G.INDUSTRIALIST_MAX) == "table" then
    pcall(function() G.INDUSTRIALIST_MAX.Stop(true) end)
    G.INDUSTRIALIST_MAX = nil
end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Player = Players.LocalPlayer
if not Player then
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    Player = Players.LocalPlayer
end

local MIN_DIST, MAX_DIST, CHUNK = 0, 512, 32
local CFG = {
    RenderDistance = 512,
    Culling = false,
    RemoveFoliage = false,
    SimpleMaterials = false,
    RemoveTextures = false,
    RemoveParticles = false,
    RemoveTrails = false,
    RemoveLights = false,
    RemoveShadows = false,
    RemoveReflections = false,
    RemovePostFX = false,
    LowQuality = false,
    HideTerrainGrass = false,
    LowDetailMeshes = false,
    RemoveEnvironment = false,
    SimpleWater = false,
    RemoveBillboards = false,
    CompatLighting = false,
}

local TUNE = {
    Tick = 0.08,
    VisInterval = 0.25,
    DynamicInterval = 0.8,
    ScanBudget = 0.003,
    ScanSteps = 32,
    VisBudget = 0.004,
    AuditBudget = 0.003,
    RefreshBudget = 0.004,
    AuditBatch = 90,
    DynamicBatch = 120,
    StallSeconds = 12,
    MaxErrorStreak = 8,
    UiTimeout = 30,
    LogLimit = 45,
    CacheLimit = 1200,
}

local CAP = {
    gethui = type(gethui) == "function",
    sethidden = type(sethiddenproperty) == "function",
    gethidden = type(gethiddenproperty) == "function",
    fpscap = type(setfpscap) == "function",
}
CAP.executor = "unknown"
if type(identifyexecutor) == "function" then
    local ok, n, v = pcall(identifyexecutor)
    if ok then CAP.executor = tostring(n) .. (v and (" " .. tostring(v)) or "") end
end

local MAX = {}
G.INDUSTRIALIST_MAX = MAX

local running, paused = true, false
local records, allList, listN = {}, {}, 0
local buckets, bucketN, visible = {}, 0, {}
local dynList, dynN, dynCursor = {}, 0, 1
local auditCursor = 0
local scanFrames, scanDepth, scanDone, scanned = {}, 0, false, 0
local refreshActive, refreshCursor = false, 0
local hiddenN = 0
local dirty = true
local originX, originZ, hasOrigin = 0, 0, false
local lastOX, lastOZ = math.huge, math.huge
local distSq = CFG.RenderDistance * CFG.RenderDistance
local root, character
local connections = {}
local globalState = {}
local terrainStatus = "not tried"
local workerGen, beat, restarts = 0, os.clock(), 0
local errorCount, lastError, failSafe = 0, "none", false
local errStreak = {}
local stageLog = {}
local uiState, uiStart = "idle", 0
local panelGui, fpsGui, panelFrame, statusLabel
local uiToast
local fpsNow = 0
local fpsCapChanged = false
local originalFpsCap -- unknown unless executor provides a getter

local function log(msg)
    local line = string.format("[%5.1fs] %s", os.clock() - T0, tostring(msg))
    stageLog[#stageLog + 1] = line
    if #stageLog > TUNE.LogLimit then table.remove(stageLog, 1) end
    print("[MAX] " .. line)
end

local function problem(msg)
    lastError = tostring(msg)
    errorCount += 1
    log("PROBLEM: " .. lastError)
    if uiToast then pcall(uiToast, "Problem", lastError) end
end

local function safe(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then
        errStreak[name] = 0
        return true
    end
    local streak = (errStreak[name] or 0) + 1
    errStreak[name] = streak
    errorCount += 1
    lastError = name .. ": " .. tostring(err)
    if streak == 1 or streak % 20 == 0 then
        warn("[MAX] " .. lastError)
    end
    if streak >= TUNE.MaxErrorStreak and not failSafe then
        failSafe = true
        warn("[MAX] Repeated " .. name .. " errors. Restoring for safety.")
        task.defer(function() pcall(function() MAX.Stop(true) end) end)
    end
    return false
end

local function getHeapKB()
    if type(collectgarbage) == "function" then
        local ok, v = pcall(collectgarbage, "count")
        if ok and type(v) == "number" then return v end
    end
    if type(gcinfo) == "function" then
        local ok, v = pcall(gcinfo)
        if ok and type(v) == "number" then return v end
    end
    return nil
end

local function getGuiParent()
    if CAP.gethui then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    return Player:FindFirstChildOfClass("PlayerGui")
end

local FORCED = {
    LocalTransparencyModifier = 1,
    CastShadow = false,
    Reflectance = 0,
    Material = Enum.Material.Plastic,
    MaterialVariant = "",
    TextureID = "",
    Enabled = false,
    Shadows = false,
    RenderFidelity = Enum.RenderFidelity.Performance,
    Density = 0,
}

local function setProp(rec, prop, enabled)
    local obj = rec.Obj
    local orig = rec.Orig
    local forced = FORCED[prop]
    if enabled then
        if orig and orig[prop] ~= nil then
            local ok, current = pcall(function() return obj[prop] end)
            if ok and current ~= forced then pcall(function() obj[prop] = forced end) end
            return
        end
        local ok, current = pcall(function() return obj[prop] end)
        if not ok or current == forced then return end
        if not orig then orig = {}; rec.Orig = orig end
        orig[prop] = current
        pcall(function() obj[prop] = forced end)
    elseif orig and orig[prop] ~= nil then
        local ok, current = pcall(function() return obj[prop] end)
        if ok and current == forced then
            pcall(function() obj[prop] = orig[prop] end)
        end
        orig[prop] = nil
        if next(orig) == nil then rec.Orig = nil end
    end
end

local function restoreRecord(rec)
    local orig = rec.Orig
    if orig then
        for prop in pairs(orig) do setProp(rec, prop, false) end
        rec.Orig = nil
    end
    if rec.Hid then
        rec.Hid = false
        hiddenN = math.max(0, hiddenN - 1)
    end
    rec.Far = false
end

local function bkey(cx, cz)
    return (cx + 32768) * 65536 + (cz + 32768)
end

local function addBucket(rec, key)
    local b = buckets[key]
    if not b then b = {}; buckets[key] = b; bucketN += 1 end
    b[rec] = true
    rec.Key = key
end

local function removeBucket(rec)
    local key = rec.Key
    if not key then return end
    local b = buckets[key]
    if b then
        b[rec] = nil
        if next(b) == nil then buckets[key] = nil; bucketN -= 1 end
    end
    rec.Key = nil
end

local function addDynamic(rec)
    if rec.DIdx then return end
    dynN += 1
    dynList[dynN] = rec
    rec.DIdx = dynN
end

local function removeDynamic(rec)
    local i = rec.DIdx
    if not i then return end
    local last = dynList[dynN]
    if i ~= dynN then dynList[i] = last; last.DIdx = i end
    dynList[dynN] = nil
    dynN -= 1
    rec.DIdx = nil
    if dynCursor > dynN then dynCursor = 1 end
end

local function kindOf(obj)
    if obj:IsA("BasePart") then return "Part" end
    if obj:IsA("ParticleEmitter") or obj:IsA("Fire") or obj:IsA("Smoke") or obj:IsA("Sparkles") then return "Particle" end
    if obj:IsA("Trail") or obj:IsA("Beam") then return "Trail" end
    if obj:IsA("Light") then return "Light" end
    if obj:IsA("PostEffect") then return "PostFX" end
    if obj:IsA("Atmosphere") or obj:IsA("Clouds") then return "Env" end
    if obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then return "Gui" end
    return nil
end

local foliageWords = {"grass","foliage","leaf","leaves","plant","weed","bush","flower","vegetation","shrub"}
local nameCache, nameCacheN = {}, 0
local function isFoliage(name)
    local cached = nameCache[name]
    if cached ~= nil then return cached end
    local lower, found = string.lower(name), false
    for i = 1, #foliageWords do
        if string.find(lower, foliageWords[i], 1, true) then found = true; break end
    end
    if nameCacheN < TUNE.CacheLimit then
        nameCache[name] = found
        nameCacheN += 1
    end
    return found
end

local function findAnchor(obj)
    local cur = obj.Parent
    while cur and cur ~= Workspace do
        if cur:IsA("BasePart") then return cur end
        cur = cur.Parent
    end
    return nil
end

local function refreshOrigin(force)
    local now = os.clock()
    if not force and now - (MAX._originAt or 0) < 0.12 then return hasOrigin end
    MAX._originAt = now
    local r = root
    if r and not r.Parent then root = nil; r = nil end
    if not r and Player.Character then
        r = Player.Character:FindFirstChild("HumanoidRootPart")
        if r then root = r end
    end
    if r then
        local ok, p = pcall(function() return r.Position end)
        if ok then originX, originZ, hasOrigin = p.X, p.Z, true; return true end
    end
    local cam = Workspace.CurrentCamera
    if cam then
        local ok, cf = pcall(function() return cam.CFrame end)
        if ok then local p = cf.Position; originX, originZ, hasOrigin = p.X, p.Z, true; return true end
    end
    hasOrigin = false
    return false
end

local function computeFar(rec)
    if not CFG.Culling or not rec.Anchor or not hasOrigin then return false end
    local dx, dz = rec.X - originX, rec.Z - originZ
    return dx * dx + dz * dz > distSq
end

local function setFar(rec, far)
    if rec.Far == far then return false end
    rec.Far = far
    if far then visible[rec] = nil
    elseif rec.Anchor then visible[rec] = true end
    return true
end

local function applyRecord(rec, farOnly)
    local active = running and not paused
    local far = active and CFG.Culling and rec.Far == true
    local kind = rec.Kind
    if kind == "Part" then
        local hide = far or (active and CFG.RemoveFoliage and rec.Fol)
        setProp(rec, "LocalTransparencyModifier", hide)
        if hide ~= rec.Hid then
            rec.Hid = hide
            hiddenN = math.max(0, hiddenN + (hide and 1 or -1))
        end
        if not farOnly then
            setProp(rec, "CastShadow", active and CFG.RemoveShadows)
            setProp(rec, "Reflectance", active and CFG.RemoveReflections)
            setProp(rec, "Material", active and CFG.SimpleMaterials)
            setProp(rec, "MaterialVariant", active and CFG.RemoveTextures)
            if rec.Mesh then setProp(rec, "TextureID", active and CFG.RemoveTextures) end
            if rec.Fid then setProp(rec, "RenderFidelity", active and CFG.LowDetailMeshes) end
        end
    elseif kind == "Particle" then
        setProp(rec, "Enabled", far or (active and CFG.RemoveParticles))
    elseif kind == "Trail" then
        setProp(rec, "Enabled", far or (active and CFG.RemoveTrails))
    elseif kind == "Light" then
        setProp(rec, "Enabled", far or (active and CFG.RemoveLights))
        if not farOnly then setProp(rec, "Shadows", active and CFG.RemoveShadows) end
    elseif kind == "PostFX" then
        setProp(rec, "Enabled", active and CFG.RemovePostFX)
    elseif kind == "Env" then
        setProp(rec, rec.EnvProp, active and CFG.RemoveEnvironment)
    elseif kind == "Gui" then
        setProp(rec, "Enabled", far or (active and CFG.RemoveBillboards))
    end
end

local function unregister(obj)
    local rec = records[obj]
    if not rec then return end
    records[obj] = nil
    restoreRecord(rec)
    removeBucket(rec)
    removeDynamic(rec)
    visible[rec] = nil
    local i = rec.Idx
    local last = allList[listN]
    if i and i <= listN then
        if i ~= listN then allList[i] = last; last.Idx = i end
        allList[listN] = nil
        listN -= 1
        if auditCursor > listN then auditCursor = listN end
        if refreshCursor > listN then refreshCursor = listN end
    end
    rec.Obj, rec.Anchor, rec.Orig = nil, nil, nil
end

local function register(obj)
    if not running or records[obj] then return end
    local kind = kindOf(obj)
    if not kind then return end
    local char = Player.Character
    if char and (obj == char or obj:IsDescendantOf(char)) then return end

    local anchor
    if kind == "Part" then anchor = obj
    elseif kind == "Particle" or kind == "Trail" or kind == "Light" or kind == "Gui" then
        anchor = findAnchor(obj)
    end

    local rec = {Obj=obj, Kind=kind, Anchor=anchor, Fol=false, Hid=false}
    if kind == "Part" then
        rec.Fol = isFoliage(obj.Name)
        rec.Mesh = obj.ClassName == "MeshPart"
        rec.Fid = rec.Mesh or obj.ClassName == "UnionOperation"
    elseif kind == "Env" then
        rec.EnvProp = obj.ClassName == "Atmosphere" and "Density" or "Enabled"
    end
    if anchor then
        local ok, pos = pcall(function() return anchor.Position end)
        if ok then
            rec.X, rec.Z = pos.X, pos.Z
            addBucket(rec, bkey(math.floor(pos.X/CHUNK), math.floor(pos.Z/CHUNK)))
            local okA, anchored = pcall(function() return anchor.Anchored end)
            if okA and not anchored then addDynamic(rec) end
        else
            rec.Anchor = nil
        end
    end
    records[obj] = rec
    listN += 1
    allList[listN] = rec
    rec.Idx = listN
    refreshOrigin(false)
    setFar(rec, computeFar(rec))
    applyRecord(rec, false)
end

local function updatePos(rec)
    local a = rec.Anchor
    if not a or not a.Parent then return false end
    local ok, pos = pcall(function() return a.Position end)
    if not ok then return false end
    rec.X, rec.Z = pos.X, pos.Z
    local key = bkey(math.floor(pos.X/CHUNK), math.floor(pos.Z/CHUNK))
    if key ~= rec.Key then removeBucket(rec); addBucket(rec, key); return true end
    return false
end

-- Depth-first scanner. Each frame retains only one parent's child array,
-- rather than a flat queue containing every pending descendant.
local function pushScanRoot(rootObj)
    local ok, children = pcall(function() return rootObj:GetChildren() end)
    if ok and #children > 0 then
        scanDepth += 1
        scanFrames[scanDepth] = {List=children, Index=1, Count=#children}
    end
end

local function scanStep()
    local deadline = os.clock() + TUNE.ScanBudget
    local steps = 0
    while scanDepth > 0 and steps < TUNE.ScanSteps do
        local frame = scanFrames[scanDepth]
        if not frame or frame.Index > frame.Count then
            scanFrames[scanDepth] = nil
            scanDepth -= 1
        else
            local obj = frame.List[frame.Index]
            frame.List[frame.Index] = nil
            frame.Index += 1
            steps += 1
            scanned += 1
            if obj and obj.Parent then
                register(obj)
                pushScanRoot(obj)
            end
        end
        if steps % 4 == 0 and os.clock() >= deadline then break end
    end
    if scanDepth == 0 and not scanDone then
        scanDone = true
        scanFrames = {}
        log("Initial scan complete: " .. scanned .. " visited, " .. listN .. " tracked")
    end
end

local function queueRefresh()
    refreshActive = true
    refreshCursor = listN
    dirty = true
end

local function refreshStep()
    local deadline = os.clock() + TUNE.RefreshBudget
    local n = 0
    if refreshCursor > listN then refreshCursor = listN end
    while refreshCursor >= 1 do
        local rec = allList[refreshCursor]
        refreshCursor -= 1
        if rec then setFar(rec, computeFar(rec)); applyRecord(rec, false) end
        n += 1
        if n % 12 == 0 and os.clock() >= deadline then return end
    end
    refreshActive = false
end

local function updateVisibility()
    if not running or paused or not CFG.Culling then dirty = false; return end
    if not refreshOrigin(true) then return end
    local dx, dz = originX-lastOX, originZ-lastOZ
    if not dirty and dx*dx + dz*dz < 1 then return end
    local deadline = os.clock() + TUNE.VisBudget
    local n = 0
    for rec in pairs(visible) do
        if computeFar(rec) then
            setFar(rec, true); applyRecord(rec, true); n += 1
            if n % 12 == 0 and os.clock() >= deadline then dirty = true; return end
        end
    end
    local cx, cz = math.floor(originX/CHUNK), math.floor(originZ/CHUNK)
    local radius = math.ceil(CFG.RenderDistance/CHUNK) + 1
    for x=-radius,radius do
        for z=-radius,radius do
            local b = buckets[bkey(cx+x, cz+z)]
            if b then
                for rec in pairs(b) do
                    if rec.Far and not computeFar(rec) then
                        setFar(rec, false); applyRecord(rec, true); n += 1
                        if n % 12 == 0 and os.clock() >= deadline then dirty = true; return end
                    end
                end
            end
        end
    end
    lastOX, lastOZ, dirty = originX, originZ, false
end

local function dynamicStep()
    if dynN == 0 then return end
    refreshOrigin(false)
    local deadline = os.clock() + TUNE.AuditBudget
    local n = 0
    while n < TUNE.DynamicBatch and dynN > 0 do
        if dynCursor > dynN then dynCursor = 1 end
        local rec = dynList[dynCursor]
        dynCursor += 1
        n += 1
        if rec then
            if not rec.Obj or not rec.Obj.Parent or not rec.Anchor or not rec.Anchor.Parent then
                if rec.Obj then unregister(rec.Obj) end
            else
                updatePos(rec)
                if setFar(rec, computeFar(rec)) then applyRecord(rec, true) end
            end
        end
        if n % 8 == 0 and os.clock() >= deadline then break end
    end
end

local function auditStep()
    if listN == 0 then return end
    refreshOrigin(false)
    local deadline = os.clock() + TUNE.AuditBudget
    local n = 0
    while n < TUNE.AuditBatch and listN > 0 do
        if auditCursor < 1 or auditCursor > listN then auditCursor = listN end
        local rec = allList[auditCursor]
        auditCursor -= 1
        n += 1
        if rec then
            local obj, a = rec.Obj, rec.Anchor
            if not obj or not obj.Parent or (a and not a.Parent) then
                if obj then unregister(obj) end
            elseif a then
                local ok, anchored = pcall(function() return a.Anchored end)
                if ok then
                    if anchored then removeDynamic(rec) else addDynamic(rec) end
                end
                updatePos(rec)
                if setFar(rec, computeFar(rec)) then applyRecord(rec, true) end
            end
        end
        if n % 8 == 0 and os.clock() >= deadline then break end
    end
end

local function getAny(obj, prop)
    if CAP.gethidden then
        local ok, v = pcall(gethiddenproperty, obj, prop)
        if ok then return true, v end
    end
    return pcall(function() return obj[prop] end)
end

local function setAny(obj, prop, value)
    if CAP.sethidden and pcall(sethiddenproperty, obj, prop, value) then return true end
    return pcall(function() obj[prop] = value end)
end

local function setGlobal(key, obj, prop, forced, enabled)
    local state = globalState[key]
    if enabled then
        if state then return end
        local ok, current = pcall(function() return obj[prop] end)
        if not ok or current == forced then return end
        globalState[key] = {Obj=obj, Prop=prop, Original=current, Forced=forced}
        pcall(function() obj[prop] = forced end)
    elseif state then
        local ok, current = pcall(function() return state.Obj[state.Prop] end)
        if ok and current == state.Forced then
            pcall(function() state.Obj[state.Prop] = state.Original end)
        end
        globalState[key] = nil
    end
end

local function terrainGrass(enabled)
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if not terrain then terrainStatus = "no terrain"; return end
    local state = globalState.TerrainDecoration
    if enabled then
        if state then return end
        local ok, current = getAny(terrain, "Decoration")
        if not ok then terrainStatus = "unsupported"; return end
        if current == false then terrainStatus = "already off"; return end
        if setAny(terrain, "Decoration", false) then
            globalState.TerrainDecoration = {Obj=terrain, Original=current}
            terrainStatus = "hidden"
        else terrainStatus = "write failed" end
    elseif state then
        setAny(state.Obj, "Decoration", state.Original)
        globalState.TerrainDecoration = nil
        terrainStatus = "restored"
    end
end

local function applyGlobals()
    local active = running and not paused
    setGlobal("GlobalShadows", Lighting, "GlobalShadows", false, active and CFG.RemoveShadows)
    local ok, rendering = pcall(function() return settings().Rendering end)
    if ok and rendering then
        setGlobal("Quality", rendering, "QualityLevel", Enum.QualityLevel.Level01, active and CFG.LowQuality)
    end
    terrainGrass(active and CFG.HideTerrainGrass)
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        setGlobal("WaterWaveSize", terrain, "WaterWaveSize", 0, active and CFG.SimpleWater)
        setGlobal("WaterWaveSpeed", terrain, "WaterWaveSpeed", 0, active and CFG.SimpleWater)
        setGlobal("WaterReflectance", terrain, "WaterReflectance", 0, active and CFG.SimpleWater)
    end
    local tech = globalState.Technology
    if active and CFG.CompatLighting then
        if not tech then
            local okT, current = getAny(Lighting, "Technology")
            if okT and current ~= Enum.Technology.Compatibility and setAny(Lighting, "Technology", Enum.Technology.Compatibility) then
                globalState.Technology = {Obj=Lighting, Original=current}
            end
        end
    elseif tech then
        setAny(tech.Obj, "Technology", tech.Original)
        globalState.Technology = nil
    end
end

local function statusText()
    local state = not running and "STOPPED" or (paused and "PAUSED" or "RUNNING")
    local heap = getHeapKB()
    return string.format(
        "%s | %d studs | %d FPS\nTracked %d | hidden %d | dynamic %d\nScan %d | chunks %d | Lua heap %s KB\nErrors %d | UI %s",
        state, CFG.RenderDistance, math.floor(fpsNow+0.5), listN, hiddenN, dynN,
        scanDepth, bucketN, heap and tostring(math.floor(heap)) or "n/a", errorCount, uiState
    )
end

function MAX.Status()
    return {
        Version=VERSION, Running=running, Paused=paused,
        RenderDistance=CFG.RenderDistance, Culling=CFG.Culling,
        TrackedObjects=listN, HiddenParts=hiddenN, DynamicObjects=dynN,
        IndexedChunks=bucketN, ScanFrames=scanDepth, Scanned=scanned,
        ScanDone=scanDone, LuaHeapKB=getHeapKB(), WorkerRestarts=restarts,
        Errors=errorCount, LastError=lastError, TerrainGrass=terrainStatus,
        Executor=CAP.executor, UI=uiState,
    }
end

function MAX.Diagnostics()
    print("========== INDUSTRIALIST MAX " .. VERSION .. " ==========")
    for i=1,#stageLog do print(stageLog[i]) end
    print("---------- status ----------")
    for k,v in pairs(MAX.Status()) do print(k, tostring(v)) end
    print("---------- executor ----------")
    for k,v in pairs(CAP) do print(k, tostring(v)) end
    print("==============================================")
    return statusText()
end

function MAX.GetDistance() return CFG.RenderDistance end

function MAX.SetDistance(value)
    local n = tonumber(value)
    if not n or n ~= n then return false end
    n = math.floor(math.clamp(n, MIN_DIST, MAX_DIST)+0.5)
    if n ~= CFG.RenderDistance then
        CFG.RenderDistance = n
        distSq = n*n
        dirty = true
        log("Render distance = " .. n)
    end
    return true
end

function MAX.SetOption(key, value)
    if type(CFG[key]) ~= "boolean" then return false end
    value = value == true
    if CFG[key] == value then return true end
    CFG[key] = value
    if key == "LowQuality" or key == "HideTerrainGrass" or key == "SimpleWater" or key == "CompatLighting" then
        safe("globals", applyGlobals)
    else
        if key == "RemoveShadows" then safe("globals", applyGlobals) end
        queueRefresh()
    end
    log("Option " .. key .. " = " .. tostring(value))
    return true
end

function MAX.Refresh()
    dirty = true
    queueRefresh()
end

function MAX.SetFpsCap(value)
    if not CAP.fpscap then problem("setfpscap unavailable"); return false end
    local n = tonumber(value)
    if not n then return false end
    n = math.clamp(math.floor(n), 0, 360)
    local ok, err = pcall(setfpscap, n)
    if ok then fpsCapChanged = true; log("FPS cap = " .. (n==0 and "unlimited" or n)); return true end
    problem(err)
    return false
end

function MAX.Pause()
    if not running or paused then return end
    paused = true
    safe("globals", applyGlobals)
    queueRefresh()
    log("Paused; restoring changed properties")
end

function MAX.Resume()
    if not running or not paused then return end
    paused = false
    safe("globals", applyGlobals)
    queueRefresh()
    log("Resumed")
end

function MAX.Stop(sync)
    if not running then return end
    running = false
    paused = false
    workerGen += 1

    for i=1,#connections do
        local c = connections[i]
        if c then pcall(function() c:Disconnect() end) end
        connections[i] = nil
    end

    local oldList, oldCount = allList, listN
    records, allList, listN = {}, {}, 0
    buckets, bucketN, visible = {}, 0, {}
    dynList, dynN, dynCursor = {}, 0, 1
    scanFrames, scanDepth = {}, 0
    refreshActive, refreshCursor = false, 0
    hiddenN = 0

    pcall(applyGlobals)
    if fpsCapChanged and CAP.fpscap then
        -- Do not guess the previous cap. Avoid forcing 60 on stop.
        log("FPS cap was changed; previous cap is unknown, so it was not overwritten.")
        fpsCapChanged = false
    end

    for i=oldCount,1,-1 do
        local rec = oldList[i]
        if rec then pcall(restoreRecord, rec); rec.Obj=nil; rec.Anchor=nil; rec.Orig=nil end
        if not sync and i%250==0 then task.wait() end
        oldList[i] = nil
    end
    for k,state in pairs(globalState) do
        if k == "TerrainDecoration" and state then
            pcall(setAny, state.Obj, "Decoration", state.Original)
        elseif k == "Technology" and state then
            pcall(setAny, state.Obj, "Technology", state.Original)
        elseif state and state.Obj then
            local ok, cur = pcall(function() return state.Obj[state.Prop] end)
            if ok and cur == state.Forced then pcall(function() state.Obj[state.Prop]=state.Original end) end
        end
        globalState[k] = nil
    end

    if panelGui then pcall(function() panelGui:Destroy() end); panelGui=nil end
    if fpsGui then pcall(function() fpsGui:Destroy() end); fpsGui=nil end
    panelFrame, statusLabel, uiToast = nil, nil, nil
    log("Stopped. Restored " .. oldCount .. " tracked records.")
end

function MAX.Restore() MAX.Stop(true) end

local function bindCharacter(char)
    character = char
    root = nil
    dirty = true
    for i=listN,1,-1 do
        local rec = allList[i]
        local obj = rec and rec.Obj
        if obj and (obj == char or obj:IsDescendantOf(char)) then unregister(obj) end
    end
    task.spawn(function()
        local ok, hrp = pcall(function() return char:WaitForChild("HumanoidRootPart", 12) end)
        if running and Player.Character == char then
            root = (ok and hrp) or char.PrimaryPart or char:FindFirstChildWhichIsA("BasePart")
            dirty = true
            refreshOrigin(true)
        end
    end)
end

local function workerLoop(gen)
    local lastVis, lastDyn = 0, 0
    while running and workerGen == gen do
        local now = os.clock()
        beat = now
        if not paused then
            if scanDepth > 0 then safe("scan", scanStep) end
            if dirty or now-lastVis >= TUNE.VisInterval then
                lastVis = now
                safe("visibility", updateVisibility)
            end
            if now-lastDyn >= TUNE.DynamicInterval then
                lastDyn = now
                safe("dynamic", dynamicStep)
                safe("audit", auditStep)
            end
        end
        if refreshActive then safe("refresh", refreshStep) end
        local delay = TUNE.Tick
        if scanDepth == 0 and not refreshActive and dynN == 0 and not dirty then delay = 0.18 end
        task.wait(delay)
    end
end

local function startWorker()
    workerGen += 1
    local gen = workerGen
    beat = os.clock()
    task.spawn(workerLoop, gen)
end

local function watchdogLoop()
    local lastScanned, lastProgress = scanned, os.clock()
    while running do
        task.wait(3)
        if not running then break end
        local now = os.clock()
        if now-beat > TUNE.StallSeconds then
            -- Invalidate the old generation before starting a replacement.
            restarts += 1
            log("Worker heartbeat stale; replacing worker #" .. restarts)
            startWorker()
        end
        if scanDepth > 0 and not paused then
            if scanned ~= lastScanned then lastScanned, lastProgress = scanned, now
            elseif now-lastProgress > 25 then
                log("Scanner made no progress; resetting scan stack and restarting a fresh scan")
                scanFrames, scanDepth = {}, 0
                pushScanRoot(Workspace)
                lastProgress = now
                startWorker()
            end
        else
            lastScanned, lastProgress = scanned, now
        end
        if uiState == "building" and now-uiStart > TUNE.UiTimeout then
            uiState = "failed"
            problem("UI build timed out")
        end
        if statusLabel then pcall(function() statusLabel.Text = statusText() end) end
    end
end

-- Lightweight native panel.
local COLORS = {
    bg=Color3.fromRGB(22,22,28), row=Color3.fromRGB(36,36,46),
    text=Color3.fromRGB(235,235,240), dim=Color3.fromRGB(155,155,170),
    accent=Color3.fromRGB(75,135,255), on=Color3.fromRGB(55,160,90),
    off=Color3.fromRGB(78,78,92), danger=Color3.fromRGB(180,55,55),
}
local function make(class, props, parent)
    local obj = Instance.new(class)
    for k,v in pairs(props) do obj[k]=v end
    obj.Parent = parent
    return obj
end
local function round(obj, radius)
    make("UICorner", {CornerRadius=UDim.new(0,radius or 6)}, obj)
end

local toggleList = {
    {"Culling","Distance culling"},
    {"RemoveFoliage","Hide grass / foliage by name"},
    {"SimpleMaterials","Simple plastic materials"},
    {"RemoveTextures","Remove textures / variants"},
    {"RemoveParticles","Disable particles"},
    {"RemoveTrails","Disable trails / beams"},
    {"RemoveLights","Disable lights"},
    {"RemoveShadows","Disable shadows"},
    {"RemoveReflections","Remove reflections"},
    {"RemovePostFX","Disable post-processing"},
    {"LowQuality","Lowest graphics quality"},
    {"HideTerrainGrass","Hide terrain grass (executor support)"},
    {"LowDetailMeshes","Low-detail meshes"},
    {"RemoveEnvironment","Remove atmosphere / clouds"},
    {"SimpleWater","Simple terrain water"},
    {"RemoveBillboards","Hide billboard / surface GUIs"},
    {"CompatLighting","Compatibility lighting (experimental)"},
}

local function buildUI()
    uiState, uiStart = "building", os.clock()
    local parent = getGuiParent()
    if not parent then uiState="failed"; problem("No GUI parent"); return end

    local gui = make("ScreenGui", {
        Name="IndustrialistMaxV22", ResetOnSpawn=false,
        IgnoreGuiInset=true, DisplayOrder=999,
    }, parent)
    panelGui = gui
    local panel = make("Frame", {
        Size=UDim2.new(0,300,1,-70), Position=UDim2.new(0.5,-150,0,42),
        BackgroundColor3=COLORS.bg, BorderSizePixel=0,
    }, gui)
    panelFrame = panel
    round(panel, 10)

    make("TextLabel", {
        Size=UDim2.new(1,-42,0,30), Position=UDim2.fromOffset(10,0),
        BackgroundTransparency=1, Text="INDUSTRIALIST MAX V22",
        TextColor3=COLORS.text, Font=Enum.Font.GothamBold, TextSize=13,
        TextXAlignment=Enum.TextXAlignment.Left,
    }, panel)
    local close = make("TextButton", {
        Size=UDim2.fromOffset(30,26), Position=UDim2.new(1,-34,0,2),
        BackgroundColor3=COLORS.danger, Text="X", TextColor3=COLORS.text,
        Font=Enum.Font.GothamBold, TextSize=13,
    }, panel)
    round(close)
    close.Activated:Connect(function() panel.Visible=false end)

    statusLabel = make("TextLabel", {
        Size=UDim2.new(1,-16,0,74), Position=UDim2.fromOffset(8,32),
        BackgroundTransparency=1, Text=statusText(), TextColor3=COLORS.dim,
        Font=Enum.Font.Code, TextSize=10, TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Top,
    }, panel)

    local scroll = make("ScrollingFrame", {
        Size=UDim2.new(1,-8,1,-112), Position=UDim2.fromOffset(4,108),
        BackgroundTransparency=1, BorderSizePixel=0, ScrollBarThickness=4,
        AutomaticCanvasSize=Enum.AutomaticSize.Y, CanvasSize=UDim2.new(),
        ScrollingDirection=Enum.ScrollingDirection.Y,
    }, panel)
    make("UIListLayout", {Padding=UDim.new(0,4), SortOrder=Enum.SortOrder.LayoutOrder}, scroll)

    local function header(text)
        make("TextLabel", {
            Size=UDim2.new(1,0,0,22), BackgroundTransparency=1, Text=text,
            TextColor3=COLORS.accent, Font=Enum.Font.GothamBold, TextSize=12,
            TextXAlignment=Enum.TextXAlignment.Left,
        }, scroll)
    end
    local function button(text, fn, color)
        local b=make("TextButton", {
            Size=UDim2.new(1,0,0,30), BackgroundColor3=color or COLORS.row,
            Text=text, TextColor3=COLORS.text, Font=Enum.Font.GothamBold, TextSize=11,
        }, scroll)
        round(b)
        b.Activated:Connect(function()
            local ok,err=pcall(fn)
            if not ok then problem("UI action: "..tostring(err)) end
        end)
    end
    local function toggle(key,label)
        local row=make("Frame",{Size=UDim2.new(1,0,0,33),BackgroundColor3=COLORS.row},scroll)
        round(row)
        make("TextLabel",{
            Size=UDim2.new(1,-70,1,0),Position=UDim2.fromOffset(8,0),
            BackgroundTransparency=1,Text=label,TextColor3=COLORS.text,
            Font=Enum.Font.Gotham,TextSize=11,TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left,
        },row)
        local b=make("TextButton",{
            Size=UDim2.fromOffset(52,24),Position=UDim2.new(1,-58,0.5,-12),
            Text="OFF",TextColor3=COLORS.text,BackgroundColor3=COLORS.off,
            Font=Enum.Font.GothamBold,TextSize=11,
        },row)
        round(b,12)
        local function paint()
            local on=CFG[key]
            b.Text=on and "ON" or "OFF"
            b.BackgroundColor3=on and COLORS.on or COLORS.off
        end
        paint()
        b.Activated:Connect(function() MAX.SetOption(key,not CFG[key]); paint() end)
    end

    header("RENDER DISTANCE")
    local distance=make("TextBox",{
        Size=UDim2.new(1,0,0,30),BackgroundColor3=COLORS.row,
        Text=tostring(CFG.RenderDistance),PlaceholderText="0 to 512",
        TextColor3=COLORS.text,Font=Enum.Font.Code,TextSize=12,
        ClearTextOnFocus=false,
    },scroll)
    round(distance)
    distance.FocusLost:Connect(function()
        MAX.SetDistance(distance.Text)
        distance.Text=tostring(CFG.RenderDistance)
    end)
    local presets={0,16,32,64,128,256,512}
    local presetRow=make("Frame",{Size=UDim2.new(1,0,0,28),BackgroundTransparency=1},scroll)
    for i,d in ipairs(presets) do
        local b=make("TextButton",{
            Size=UDim2.new(1/7,-3,1,0),Position=UDim2.new((i-1)/7,1,0,0),
            BackgroundColor3=COLORS.row,Text=tostring(d),TextColor3=COLORS.text,
            Font=Enum.Font.GothamBold,TextSize=10,
        },presetRow)
        round(b,4)
        b.Activated:Connect(function() MAX.SetDistance(d); distance.Text=tostring(d) end)
    end

    header("OPTIMIZATIONS")
    for _,item in ipairs(toggleList) do toggle(item[1],item[2]) end
    header("SYSTEM")
    button("Pause / restore world",function() MAX.Pause() end)
    button("Resume optimizer",function() MAX.Resume() end)
    button("Refresh visibility",function() MAX.Refresh() end)
    button("Diagnostics (console)",function() MAX.Diagnostics() end)
    if CAP.fpscap then
        button("FPS cap: 30",function() MAX.SetFpsCap(30) end)
        button("FPS cap: 45",function() MAX.SetFpsCap(45) end)
        button("FPS cap: 60",function() MAX.SetFpsCap(60) end)
        button("FPS cap: unlimited",function() MAX.SetFpsCap(0) end)
    end
    button("EMERGENCY RESTORE",function() MAX.Restore() end,COLORS.danger)
    uiState="ready"
    log("Native control panel ready")
end

local function buildFpsOverlay()
    local parent=getGuiParent()
    if not parent then return end
    local gui=make("ScreenGui",{
        Name="IndustrialistMaxFPS",ResetOnSpawn=false,
        IgnoreGuiInset=true,DisplayOrder=1000,
    },parent)
    fpsGui=gui
    local pill=make("TextButton",{
        Size=UDim2.fromOffset(160,36),AnchorPoint=Vector2.new(0.5,0),
        Position=UDim2.new(0.5,0,0,4),BackgroundColor3=COLORS.bg,
        BackgroundTransparency=0.18,TextColor3=Color3.fromRGB(100,220,130),
        Text="MAX V22 | measuring",Font=Enum.Font.Code,TextSize=10,
    },gui)
    round(pill,8)
    pill.Activated:Connect(function()
        if panelFrame then panelFrame.Visible=not panelFrame.Visible end
    end)
    local elapsed,frames,worst=0,0,0
    connections[#connections+1]=RunService.Heartbeat:Connect(function(dt)
        if not running then return end
        elapsed+=dt
        frames+=1
        if dt>worst then worst=dt end
        if elapsed<1 then return end
        local fps=frames/elapsed
        fpsNow=fps
        local mem="n/a"
        local ok,m=pcall(function() return Stats:GetTotalMemoryUsageMb() end)
        if ok and type(m)=="number" then mem=tostring(math.floor(m+0.5)) end
        pill.Text=string.format("%d FPS | %.0f ms | %s MB",math.floor(fps+0.5),elapsed/frames*1000,mem)
        pill.TextColor3=fps>=50 and Color3.fromRGB(100,220,130) or
            (fps>=30 and Color3.fromRGB(240,200,80) or Color3.fromRGB(240,90,90))
        elapsed,frames,worst=0,0,0
    end)
end

-- Events: register only new descendants; unregister removed descendants.
local function connectWorldEvents()
    connections[#connections+1]=Workspace.DescendantAdded:Connect(function(obj)
        if running then register(obj) end
    end)
    connections[#connections+1]=Workspace.DescendantRemoving:Connect(function(obj)
        if records[obj] then unregister(obj) end
    end)
    connections[#connections+1]=Lighting.DescendantAdded:Connect(function(obj)
        if running then register(obj) end
    end)
    connections[#connections+1]=Lighting.DescendantRemoving:Connect(function(obj)
        if records[obj] then unregister(obj) end
    end)
    connections[#connections+1]=Player.CharacterAdded:Connect(function(char)
        if running then bindCharacter(char) end
    end)
    connections[#connections+1]=Player.CharacterRemoving:Connect(function()
        root=nil; character=nil; dirty=true
    end)
end

log("Industrialist MAX "..VERSION.." starting. Executor: "..CAP.executor)
safe("events",connectWorldEvents)
if Player.Character then safe("character",bindCharacter,Player.Character) end

-- Lighting is generally small; register its current descendants.
safe("lighting scan",function()
    local descendants=Lighting:GetDescendants()
    for i=1,#descendants do register(descendants[i]) end
    descendants=nil
end)

-- Start a depth-first Workspace scan without a giant flat descendant array.
safe("workspace scan init",function() pushScanRoot(Workspace) end)
safe("worker start",startWorker)
task.spawn(function()
    while running do
        task.wait(3)
        if not running then break end
        local now=os.clock()
        if now-beat>TUNE.StallSeconds then
            restarts+=1
            log("Worker heartbeat stale; restarting worker #"..restarts)
            startWorker()
        end
        if statusLabel then pcall(function() statusLabel.Text=statusText() end) end
    end
end)

safe("fps overlay",buildFpsOverlay)
task.spawn(function()
    local ok,err=pcall(buildUI)
    if not ok then uiState="failed"; problem("UI build failed: "..tostring(err)) end
end)

-- Queue a fresh V22 load after teleport when the executor supports it.
do
    local teleportURL = "https://raw.githubusercontent.com/karlmarxmvasquez-ops/Keyless-MaxFPS-Universal/main/Industrialist_MAX_V22.lua"
    local queueFn = queue_on_teleport
    if type(queueFn) ~= "function" and type(syn) == "table" then
        queueFn = syn.queue_on_teleport
    end
    if type(queueFn) == "function" then
        local queued = 'loadstring(game:HttpGet("' .. teleportURL .. '"))()'
        local ok, err = pcall(queueFn, queued)
        if ok then log("Teleport auto-reload queued") else log("Teleport auto-reload unavailable: " .. tostring(err)) end
    else
        log("Teleport auto-reload unsupported by this executor")
    end
end

log("Optimizer running. All optimization toggles are OFF.")
print("==========================================")
print(" INDUSTRIALIST MAX "..VERSION.." RUNNING")
print(" Status:      _G.INDUSTRIALIST_MAX.Status()")
print(" Diagnostics: _G.INDUSTRIALIST_MAX.Diagnostics()")
print(" Distance:    _G.INDUSTRIALIST_MAX.SetDistance(128)")
print(" Restore:     _G.INDUSTRIALIST_MAX.Restore()")
print("==========================================")