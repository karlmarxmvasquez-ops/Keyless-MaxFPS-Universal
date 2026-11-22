--[[
============================================================
 INDUSTRIALIST MAX V18.1 | FULL-WORLD DEFAULTS
 Client-side visual optimizer for Roblox / Delta (native lightweight UI + FPS counter)
============================================================
 NOT TESTED ON DELTA. Written from the V17 source and from
 general Roblox / Rayfield knowledge. Read the stage log
 (Diagnostics button or _G.INDUSTRIALIST_MAX.Diagnostics())
 if anything misbehaves.

 MAIN FIXES vs V17
 1. Optimizer engine is independent of the UI. The UI is now a
    native lightweight panel (no downloads, no Rayfield) plus an
    always-visible FPS counter. Tap the counter to open/close it.
 2. One scheduler thread with time budgets (no more 180-object
    bursts every 25 ms that could starve Rayfield on a weak
    phone). Watchdog restarts a stalled worker.
 3. "cond and false or nil" bug removed. In Lua that expression
    can never return false. Properties are now set through
    setProp(rec, prop, on) where on=true forces and on=false
    restores, so false is never confused with nil.
 4. Slider is 0..512, step 1, synced with the exact input box.
 5. Memory: numeric bucket keys (no string garbage), originals
    stored only for properties actually changed, swap-remove
    lists, no temporary copies of the whole world.
 6. Auto fail-safe: repeated worker errors restore the world.
 7. Terrain grass: tries sethiddenproperty/gethiddenproperty
    (executor feature). Roblox itself marks Decoration as
    not scriptable.
 8. Rayfield removed completely: the native UI needs no download,
    so it cannot hang on a slow network or a bad library.

 KNOWN LIMITATIONS
 - LocalTransparencyModifier only hides rendering. It does NOT
   unload meshes, textures or instances from RAM.
 - Cannot enable Workspace.StreamingEnabled from a client.
 - This is not Minecraft-style chunk unloading.
 - Incremental scanning cannot guarantee an instant blackout of
   parts that exist before the scan reaches them.
 - Distance uses each part's centre (X/Z). A huge floor whose
   centre is far away can be hidden while you stand on it.
 - SurfaceGuis, decals and similar children of hidden parts may
   still draw. I could not verify how they behave.
 - Game scripts that re-enable particles/lights or reset
   properties can override the forced values until the next
   refresh.
 - Foliage detection is by name only ("grass", "plant", ...).
   A machine called "Plant" would be hidden too.
============================================================
]]

local G = _G
local T0 = os.clock()
local VERSION = "V18.1"

-- ============================================================
-- 0. CLEAN UP A PREVIOUS INSTANCE (V17 or V18)
-- ============================================================
if type(G.INDUSTRIALIST_MAX) == "table" then
	print("[MAX] Previous instance found, stopping it first")
	pcall(function()
		G.INDUSTRIALIST_MAX.Stop(true)
	end)
	G.INDUSTRIALIST_MAX = nil
end

-- ============================================================
-- 1. SERVICES
-- ============================================================
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer
if not Player then
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
	Player = Players.LocalPlayer
end

-- ============================================================
-- 2. CONFIGURATION
-- ============================================================
local MIN_DIST, MAX_DIST = 0, 512
local CHUNK = 32

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
	LowDetailMeshes = false, -- MeshPart/Union RenderFidelity = Performance
	RemoveEnvironment = false, -- Atmosphere + Clouds
	SimpleWater = false, -- flat, non-reflective terrain water
	RemoveBillboards = false, -- always hide BillboardGui/SurfaceGui (also culled by distance)
	CompatLighting = false, -- experimental, needs executor hidden-property support
}

local TUNE = {
	TickInterval = 0.05,
	UpdateInterval = 0.20,
	DynamicInterval = 0.50,

	ScanBudgetLoading = 0.0025, -- seconds per tick while the UI is building
	ScanBudgetNormal = 0.006,
	ScanBatchMax = 400,

	InstantBlackout = false, -- disabled: keep the world visible during startup
	ScanBudgetBlackout = 0.015, -- faster scanning while the screen is blacked out
	BlackoutTimeout = 90, -- safety: force the world back after this many seconds

	VisBudget = 0.008,
	RefreshBudget = 0.006,
	DynBudget = 0.003,
	AuditBudget = 0.003,

	StallSeconds = 8,
	UiDelay = 0, -- seconds before the control panel opens
	UiTimeout = 30,
	NoUiDistance = 128, -- used only if NO UI at all could be created
	MaxErrorStreak = 8,
}

-- Re-run this script automatically after you teleport to another game.
-- The script cannot read its own source, so give it ONE of these:
--   Url  = raw link to this script (GitHub raw / pastebin raw)
--   File = file name of this script saved in your executor's workspace folder
local RELOAD = {
	Enabled = true,
	Url = "https://raw.githubusercontent.com/karlmarxmvasquez-ops/Keyless-MaxFPS-Universal/main/Industrialist_MAX_V18_1.lua",
	File = "industrialist_max_v18.lua",
}

-- Options that need a full re-apply to every tracked object
local GLOBAL_ONLY = { LowQuality = true, HideTerrainGrass = true, SimpleWater = true, CompatLighting = true }

-- ============================================================
-- 3. STATE
-- ============================================================
local MAX = {}
G.INDUSTRIALIST_MAX = MAX

local running, paused = true, false

local records, allList, listN = {}, {}, 0
local buckets, bucketCount = {}, 0
local visible = {}
local dynList, dynN, dynCursor = {}, 0, 1
local auditCursor = 0

local scanStack, scanN, scanned, scanDone = {}, 0, 0, false
local refreshActive, refreshCursor = false, 0
local hiddenN = 0
local dirty = true

local character, root
local originX, originZ, hasOrigin, originT = 0, 0, false, -1
local lastOX, lastOZ = math.huge, math.huge
local distSq = CFG.RenderDistance * CFG.RenderDistance

local connections = {}
local gstate = {}
local terrainStatus = "not tried"

local beat, workerGen, restarts = os.clock(), 0, 0
local errStreak, errorCount, lastError = {}, 0, "none"
local failSafeTripped = false

local stageLog = {}

local uiState, uiStart, uiLib = "idle", 0, nil
local uiSync = false
local uiRefs = { Toggles = {} }
local fallbackGui, fallbackLabel, liveParagraph

local syncUI, updateLive, uiToast
local fpsNow = 0

-- ============================================================
-- 4. LOGGING
-- ============================================================
local function stage(msg)
	local line = string.format("[%5.1fs] %s", os.clock() - T0, msg)
	stageLog[#stageLog + 1] = line
	if #stageLog > 60 then
		table.remove(stageLog, 1)
	end
	print("[MAX] " .. line)
end

local function notifyUI(title, msg)
	if uiToast then
		pcall(uiToast, title, msg)
	end
end

local function problem(msg)
	lastError = msg
	stageLog[#stageLog + 1] = string.format("[%5.1fs] PROBLEM: %s", os.clock() - T0, msg)
	if #stageLog > 60 then
		table.remove(stageLog, 1)
	end
	warn("[MAX] " .. msg)
	notifyUI("Problem", msg)
end

-- ============================================================
-- 5. EXECUTOR COMPATIBILITY
-- ============================================================
local CAP = {}
CAP.loadstring = type(loadstring) == "function"
CAP.httpget = (pcall(function()
	return game.HttpGet ~= nil
end))
CAP.gethui = type(gethui) == "function"
CAP.sethidden = type(sethiddenproperty) == "function"
CAP.gethidden = type(gethiddenproperty) == "function"
local queueFn = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
if type(queueFn) ~= "function" then
	queueFn = nil
end
CAP.queue = queueFn ~= nil
CAP.fpscap = type(setfpscap) == "function"
local fpsCapChanged = false
CAP.executor = "unknown"
if type(identifyexecutor) == "function" then
	local ok, name, ver = pcall(identifyexecutor)
	if ok then
		CAP.executor = tostring(name) .. (ver and (" " .. tostring(ver)) or "")
	end
end

-- ============================================================
-- 6. PROPERTY MANAGER
-- Originals are stored ONLY for properties this script changed.
-- Forced values are constants, so they are not stored per object.
-- ============================================================
-- ---- INSTANT BLACKOUT ----------------------------------------
-- Turns 3D rendering off immediately (RunService:Set3dRenderingEnabled)
-- and puts a black cover behind all UI as a backup. Stays on until the
-- initial scan has hidden everything, then the world is shown with only
-- the objects inside the render distance visible.
local blackoutOn, blackoutStart, coverGui = false, 0, nil

local function setBlackout(on)
	if on == blackoutOn then
		return
	end
	blackoutOn = on

	if on then
		blackoutStart = os.clock()
		local okR = pcall(function()
			RunService:Set3dRenderingEnabled(false)
		end)
		local okC, errC = pcall(function()
			local gui = Instance.new("ScreenGui")
			gui.Name = "IndustrialistMaxCover"
			gui.ResetOnSpawn = false
			gui.IgnoreGuiInset = true
			gui.DisplayOrder = -1000
			local parent
			if CAP.gethui then
				local ok, h = pcall(gethui)
				if ok and h then
					parent = h
				end
			end
			parent = parent or Player:FindFirstChildOfClass("PlayerGui")
			gui.Parent = parent
			local f = Instance.new("Frame")
			f.Size = UDim2.fromScale(1, 1)
			f.BackgroundColor3 = Color3.new(0, 0, 0)
			f.BorderSizePixel = 0
			f.Parent = gui
			coverGui = gui
		end)
		stage("Instant blackout ON (3D rendering off: " .. tostring(okR) .. ", cover: " .. tostring(okC) .. ")")
		if not okC then
			warn("[MAX] cover failed: " .. tostring(errC))
		end
	else
		pcall(function()
			RunService:Set3dRenderingEnabled(true)
		end)
		if coverGui then
			pcall(function()
				coverGui:Destroy()
			end)
			coverGui = nil
		end
		stage("Blackout ended, world shown")
	end
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
	Density = 0, -- Atmosphere
}

local function rawGet(o, p)
	return o[p]
end

local function rawSet(o, p, v)
	o[p] = v
end

-- on == true  -> force the value (remember the original)
-- on == false/nil -> restore the original if we still own the value
local function setProp(rec, prop, on)
	local obj = rec.Obj
	local forced = FORCED[prop]
	local orig = rec.Orig

	if on then
		if orig and orig[prop] ~= nil then
			local ok, cur = pcall(rawGet, obj, prop)
			if ok and cur ~= forced then
				pcall(rawSet, obj, prop, forced)
			end
		else
			local ok, cur = pcall(rawGet, obj, prop)
			if not ok or cur == forced then
				return
			end
			if not orig then
				orig = {}
				rec.Orig = orig
			end
			orig[prop] = cur
			pcall(rawSet, obj, prop, forced)
		end
	elseif orig and orig[prop] ~= nil then
		local ok, cur = pcall(rawGet, obj, prop)
		if ok and cur == forced then
			pcall(rawSet, obj, prop, orig[prop])
		end
		orig[prop] = nil
		if next(orig) == nil then
			rec.Orig = nil
		end
	end
end

local function restoreRecord(rec)
	local orig = rec.Orig
	if orig then
		for prop in pairs(orig) do
			setProp(rec, prop, false)
		end
		rec.Orig = nil
	end
	rec.Hid = false
end

-- ============================================================
-- 7. LISTS AND SPATIAL BUCKETS
-- ============================================================
local function bkey(cx, cz)
	return (cx + 32768) * 65536 + (cz + 32768)
end

local function addBucket(rec, key)
	local b = buckets[key]
	if not b then
		b = {}
		buckets[key] = b
		bucketCount += 1
	end
	b[rec] = true
	rec.Key = key
end

local function removeBucket(rec)
	local key = rec.Key
	if not key then
		return
	end
	local b = buckets[key]
	if b then
		b[rec] = nil
		if next(b) == nil then
			buckets[key] = nil
			bucketCount -= 1
		end
	end
	rec.Key = nil
end

local function addDynamic(rec)
	if rec.DIdx then
		return
	end
	dynN += 1
	dynList[dynN] = rec
	rec.DIdx = dynN
end

local function removeDynamic(rec)
	local i = rec.DIdx
	if not i then
		return
	end
	local last = dynList[dynN]
	dynList[i] = last
	last.DIdx = i
	dynList[dynN] = nil
	dynN -= 1
	rec.DIdx = nil
end

-- ============================================================
-- 8. CLASSIFICATION
-- ============================================================
local kindMemo = {}

local function kindOf(obj)
	local cn = obj.ClassName
	local k = kindMemo[cn]
	if k == nil then
		k = false
		if cn == "Terrain" then
			k = false
		elseif obj:IsA("BasePart") then
			k = "Part"
		elseif obj:IsA("ParticleEmitter") or obj:IsA("Fire") or obj:IsA("Smoke") or obj:IsA("Sparkles") then
			k = "Particle"
		elseif obj:IsA("Trail") or obj:IsA("Beam") then
			k = "Trail"
		elseif obj:IsA("Light") then
			k = "Light"
		elseif obj:IsA("PostEffect") then
			k = "PostFX"
		elseif obj:IsA("Atmosphere") or obj:IsA("Clouds") then
			k = "Env"
		elseif obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then
			k = "Gui"
		end
		kindMemo[cn] = k
	end
	return k or nil
end

local FOLIAGE_WORDS = {
	"grass", "foliage", "leaf", "leaves", "plant",
	"weed", "bush", "flower", "vegetation", "shrub",
}
local nameMemo, nameMemoN = {}, 0

local function isFoliageName(name)
	local m = nameMemo[name]
	if m ~= nil then
		return m
	end
	local lower = string.lower(name)
	local hit = false
	for i = 1, #FOLIAGE_WORDS do
		if string.find(lower, FOLIAGE_WORDS[i], 1, true) then
			hit = true
			break
		end
	end
	if nameMemoN < 3000 then
		nameMemo[name] = hit
		nameMemoN += 1
	end
	return hit
end

local function findAnchor(obj)
	local cur = obj.Parent
	while cur and cur ~= Workspace do
		if cur:IsA("BasePart") then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

-- ============================================================
-- 9. ORIGIN, DISTANCE, APPLY
-- ============================================================
local function refreshOrigin(force)
	local now = os.clock()
	if not force and now - originT < 0.1 then
		return hasOrigin
	end
	originT = now

	local r = root
	if r and not r.Parent then
		r = nil
		root = nil
	end
	if not r then
		local char = Player.Character
		if char then
			r = char:FindFirstChild("HumanoidRootPart")
			if r then
				root = r
			end
		end
	end
	if r then
		local ok, p = pcall(rawGet, r, "Position")
		if ok then
			originX, originZ, hasOrigin = p.X, p.Z, true
			return true
		end
	end

	-- No usable character yet: fall back to the camera so the
	-- world can never stay permanently black.
	local cam = Workspace.CurrentCamera
	if cam then
		local ok, cf = pcall(rawGet, cam, "CFrame")
		if ok then
			local p = cf.Position
			originX, originZ, hasOrigin = p.X, p.Z, true
			return true
		end
	end
	hasOrigin = false
	return false
end

local function computeFar(rec)
	if not CFG.Culling or not rec.Anchor or not hasOrigin then
		return false
	end
	local dx, dz = rec.X - originX, rec.Z - originZ
	return dx * dx + dz * dz > distSq
end

-- returns true when the state changed
local function setFar(rec, far)
	if rec.Far == far then
		return false
	end
	rec.Far = far
	if far then
		visible[rec] = nil
	elseif rec.Anchor then
		visible[rec] = true
	end
	return true
end

-- farOnly = true -> only touch properties that depend on distance
local function applyRecord(rec, farOnly)
	local act = running and not paused
	local far = act and CFG.Culling and rec.Far == true
	local kind = rec.Kind

	if kind == "Part" then
		local hide = (far or (act and CFG.RemoveFoliage and rec.Fol)) and true or false
		setProp(rec, "LocalTransparencyModifier", hide)
		if hide ~= rec.Hid then
			rec.Hid = hide
			hiddenN += hide and 1 or -1
		end
		if not farOnly then
			setProp(rec, "CastShadow", act and CFG.RemoveShadows)
			setProp(rec, "Reflectance", act and CFG.RemoveReflections)
			setProp(rec, "Material", act and CFG.SimpleMaterials)
			setProp(rec, "MaterialVariant", act and CFG.RemoveTextures)
			if rec.Mesh then
				setProp(rec, "TextureID", act and CFG.RemoveTextures)
			end
			if rec.Fid then
				setProp(rec, "RenderFidelity", act and CFG.LowDetailMeshes)
			end
		end
	elseif kind == "Particle" then
		setProp(rec, "Enabled", far or (act and CFG.RemoveParticles))
	elseif kind == "Trail" then
		setProp(rec, "Enabled", far or (act and CFG.RemoveTrails))
	elseif kind == "Light" then
		setProp(rec, "Enabled", far or (act and CFG.RemoveLights))
		if not farOnly then
			setProp(rec, "Shadows", act and CFG.RemoveShadows)
		end
	elseif kind == "PostFX" then
		setProp(rec, "Enabled", act and CFG.RemovePostFX)
	elseif kind == "Env" then
		setProp(rec, rec.EnvProp, act and CFG.RemoveEnvironment)
	elseif kind == "Gui" then
		setProp(rec, "Enabled", far or (act and CFG.RemoveBillboards))
	end
end

-- ============================================================
-- 10. REGISTER / UNREGISTER
-- ============================================================
local function register(obj)
	if not running or records[obj] then
		return
	end
	local kind = kindOf(obj)
	if not kind then
		return
	end

	-- never touch the local character
	local char = Player.Character
	if char and (obj == char or obj:IsDescendantOf(char)) then
		return
	end

	local anchor
	if kind == "Part" then
		anchor = obj
	elseif kind == "Particle" or kind == "Trail" or kind == "Light" or kind == "Gui" then
		anchor = findAnchor(obj)
		if anchor and anchor.ClassName == "Terrain" then
			anchor = nil
		end
	end

	local rec = { Obj = obj, Kind = kind, Anchor = anchor, Fol = false, Hid = false }
	if kind == "Part" then
		rec.Fol = isFoliageName(obj.Name)
		rec.Mesh = obj.ClassName == "MeshPart"
		rec.Fid = rec.Mesh or obj.ClassName == "UnionOperation"
	elseif kind == "Env" then
		rec.EnvProp = (obj.ClassName == "Atmosphere") and "Density" or "Enabled"
	end

	if anchor then
		local ok, pos = pcall(rawGet, anchor, "Position")
		if ok then
			rec.X, rec.Z = pos.X, pos.Z
			addBucket(rec, bkey(math.floor(pos.X / CHUNK), math.floor(pos.Z / CHUNK)))
			local okA, anchored = pcall(rawGet, anchor, "Anchored")
			if okA and not anchored then
				addDynamic(rec)
			end
		else
			rec.Anchor = nil
		end
	end

	records[obj] = rec
	listN += 1
	allList[listN] = rec
	rec.Idx = listN

	-- immediate hide of newly discovered objects
	refreshOrigin(false)
	setFar(rec, computeFar(rec))
	applyRecord(rec, false)
end

local function unregister(obj)
	local rec = records[obj]
	if not rec then
		return
	end
	records[obj] = nil
	restoreRecord(rec)
	removeBucket(rec)
	removeDynamic(rec)
	visible[rec] = nil

	local i = rec.Idx
	local last = allList[listN]
	allList[i] = last
	last.Idx = i
	allList[listN] = nil
	listN -= 1
end

-- ============================================================
-- 11. WORK STEPS (all run inside a time budget, none yield)
-- ============================================================
local function updatePos(rec)
	local a = rec.Anchor
	if not a or not a.Parent then
		return false
	end
	local ok, pos = pcall(rawGet, a, "Position")
	if not ok then
		return false
	end
	local x, z = pos.X, pos.Z
	rec.X, rec.Z = x, z
	local key = bkey(math.floor(x / CHUNK), math.floor(z / CHUNK))
	if key ~= rec.Key then
		removeBucket(rec)
		addBucket(rec, key)
		return true
	end
	return false
end

local function scanBudget()
	if blackoutOn then
		return TUNE.ScanBudgetBlackout
	end
	if uiState == "loading" then
		return TUNE.ScanBudgetLoading
	end
	return TUNE.ScanBudgetNormal
end

local function scanStep(budget)
	if scanN == 0 then
		return
	end
	local deadline = os.clock() + budget
	local n = 0
	while scanN > 0 and n < TUNE.ScanBatchMax do
		local o = scanStack[scanN]
		scanStack[scanN] = nil
		scanN -= 1
		n += 1
		scanned += 1

		if o.Parent then
			pcall(register, o)
			local ok, kids = pcall(o.GetChildren, o)
			if ok then
				for i = 1, #kids do
					scanN += 1
					scanStack[scanN] = kids[i]
				end
			end
		end
		if n % 8 == 0 and os.clock() > deadline then
			break
		end
	end
	if scanN == 0 and not scanDone then
		scanDone = true
		stage("Initial scan complete: " .. scanned .. " instances visited, " .. listN .. " tracked")
	end
end

local function dynamicStep(budget)
	if dynN == 0 then
		return
	end
	refreshOrigin(false)
	local deadline = os.clock() + budget
	local n = 0
	while n < 300 and dynN > 0 do
		if dynCursor > dynN then
			dynCursor = 1
		end
		local rec = dynList[dynCursor]
		dynCursor += 1
		n += 1
		if rec then
			updatePos(rec)
			if setFar(rec, computeFar(rec)) then
				applyRecord(rec, true)
			end
		end
		if n % 8 == 0 and os.clock() > deadline then
			break
		end
	end
end

-- Slow audit: catches anchored parts moved by scripts and parts
-- whose Anchored state changed. Walks the list downward.
local function auditStep(budget)
	if listN == 0 then
		return
	end
	refreshOrigin(false)
	local deadline = os.clock() + budget
	local n = 0
	while n < 150 and listN > 0 do
		if auditCursor < 1 or auditCursor > listN then
			auditCursor = listN
		end
		local rec = allList[auditCursor]
		auditCursor -= 1
		n += 1
		local a = rec and rec.Anchor
		if a and a.Parent then
			local ok, anch = pcall(rawGet, a, "Anchored")
			if ok then
				if anch then
					removeDynamic(rec)
				else
					addDynamic(rec)
				end
			end
			updatePos(rec)
			if setFar(rec, computeFar(rec)) then
				applyRecord(rec, true)
			end
		end
		if n % 8 == 0 and os.clock() > deadline then
			break
		end
	end
end

local function queueRefreshAll()
	refreshActive = true
	refreshCursor = listN
	dirty = true
end

-- Full re-apply of every tracked object, walking downward so
-- swap-removes during the pass are safe.
local function refreshStep(budget)
	refreshOrigin(true)
	local deadline = os.clock() + budget
	local n = 0
	if refreshCursor > listN then
		refreshCursor = listN
	end
	while refreshCursor >= 1 do
		local rec = allList[refreshCursor]
		refreshCursor -= 1
		if rec then
			setFar(rec, computeFar(rec))
			applyRecord(rec, false)
		end
		n += 1
		if n % 16 == 0 and os.clock() > deadline then
			return
		end
	end
	refreshActive = false
end

local function updateVisibility(budget)
	budget = budget or TUNE.VisBudget
	if not running or paused or not CFG.Culling then
		dirty = false
		return
	end
	if not refreshOrigin(true) then
		return
	end
	local mx, mz = originX - lastOX, originZ - lastOZ
	if not dirty and (mx * mx + mz * mz) < 1 then
		return
	end

	local deadline = os.clock() + budget
	local applied = 0

	-- 1) hide visible objects that are now outside the radius
	for rec in pairs(visible) do
		if computeFar(rec) then
			setFar(rec, true)
			applyRecord(rec, true)
			applied += 1
			if applied % 16 == 0 and os.clock() > deadline then
				dirty = true
				return
			end
		end
	end

	-- 2) reveal hidden objects inside the radius (nearby buckets only)
	local cx, cz = math.floor(originX / CHUNK), math.floor(originZ / CHUNK)
	local r = math.ceil(CFG.RenderDistance / CHUNK) + 1
	for dx = -r, r do
		for dz = -r, r do
			local b = buckets[bkey(cx + dx, cz + dz)]
			if b then
				for rec in pairs(b) do
					if rec.Far and not computeFar(rec) then
						setFar(rec, false)
						applyRecord(rec, true)
						applied += 1
						if applied % 16 == 0 and os.clock() > deadline then
							dirty = true
							return
						end
					end
				end
			end
		end
	end

	lastOX, lastOZ = originX, originZ
	dirty = false
end

-- ============================================================
-- 12. GLOBAL GRAPHICS (lighting, quality, terrain grass)
-- ============================================================
local function setGlobalProp(key, obj, prop, forced, on)
	local st = gstate[key]
	if on then
		if st then
			return
		end
		local ok, cur = pcall(rawGet, obj, prop)
		if not ok or cur == forced then
			return
		end
		gstate[key] = { Obj = obj, Prop = prop, Orig = cur, Forced = forced }
		pcall(rawSet, obj, prop, forced)
	elseif st then
		local ok, cur = pcall(rawGet, st.Obj, st.Prop)
		if ok and cur == st.Forced then
			pcall(rawSet, st.Obj, st.Prop, st.Orig)
		end
		gstate[key] = nil
	end
end

local function getAny(obj, prop)
	if CAP.gethidden then
		local ok, v = pcall(gethiddenproperty, obj, prop)
		if ok then
			return true, v
		end
	end
	return pcall(rawGet, obj, prop)
end

local function setAny(obj, prop, v)
	if CAP.sethidden then
		if pcall(sethiddenproperty, obj, prop, v) then
			return true
		end
	end
	return (pcall(rawSet, obj, prop, v))
end

local function terrainGrass(on)
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if not terrain then
		terrainStatus = "no terrain"
		return
	end
	local st = gstate.TerrainDecoration
	if on then
		if st then
			return
		end
		local ok, cur = getAny(terrain, "Decoration")
		if not ok then
			terrainStatus = "unavailable on this executor"
			return
		end
		if cur == false then
			terrainStatus = "already off"
			return
		end
		if setAny(terrain, "Decoration", false) then
			gstate.TerrainDecoration = { Orig = cur }
			terrainStatus = "hidden"
		else
			terrainStatus = "write failed"
		end
	elseif st then
		setAny(terrain, "Decoration", st.Orig)
		gstate.TerrainDecoration = nil
		terrainStatus = "restored"
	end
end

local function applyGlobals()
	local act = running and not paused
	setGlobalProp("GlobalShadows", Lighting, "GlobalShadows", false, act and CFG.RemoveShadows)

	local okS, rendering = pcall(function()
		return settings().Rendering
	end)
	if okS and rendering then
		setGlobalProp("Quality", rendering, "QualityLevel", Enum.QualityLevel.Level01, act and CFG.LowQuality)
	end

	terrainGrass(act and CFG.HideTerrainGrass)

	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local w = act and CFG.SimpleWater
		setGlobalProp("WaterWaveSize", terrain, "WaterWaveSize", 0, w)
		setGlobalProp("WaterWaveSpeed", terrain, "WaterWaveSpeed", 0, w)
		setGlobalProp("WaterReflectance", terrain, "WaterReflectance", 0, w)
	end

	-- Lighting.Technology is not scriptable in normal Roblox, so this
	-- only works if the executor exposes hidden properties.
	local gk = "TechnologyHidden"
	local st = gstate[gk]
	if act and CFG.CompatLighting then
		if not st then
			local ok, cur = getAny(Lighting, "Technology")
			if ok and cur ~= Enum.Technology.Compatibility then
				if setAny(Lighting, "Technology", Enum.Technology.Compatibility) then
					gstate[gk] = { Orig = cur }
				end
			end
		end
	elseif st then
		setAny(Lighting, "Technology", st.Orig)
		gstate[gk] = nil
	end
end

-- ============================================================
-- 13. PUBLIC API
-- ============================================================
function MAX.GetDistance()
	return CFG.RenderDistance
end

function MAX.SetDistance(value, source)
	local n = tonumber(value)
	if not n or n ~= n then
		return false
	end
	n = math.floor(math.clamp(n, MIN_DIST, MAX_DIST) + 0.5)

	if n ~= CFG.RenderDistance then
		CFG.RenderDistance = n
		distSq = n * n
		dirty = true
		pcall(updateVisibility, 0.03)
		stage("Render distance = " .. n .. " studs")
	end
	syncUI(source == "slider" and "slider" or nil)
	return true
end

function MAX.SetOption(key, value, source)
	if type(CFG[key]) ~= "boolean" then
		return false
	end
	value = value == true
	if CFG[key] ~= value then
		CFG[key] = value
		if GLOBAL_ONLY[key] then
			pcall(applyGlobals)
		else
			if key == "RemoveShadows" then
				pcall(applyGlobals)
			end
			queueRefreshAll()
		end
		stage("Option " .. key .. " = " .. tostring(value))
	end
	syncUI(source)
	return true
end

function MAX.SetCulling(value)
	return MAX.SetOption("Culling", value)
end

function MAX.Refresh()
	dirty = true
	queueRefreshAll()
	pcall(updateVisibility, 0.03)
end

-- n = 0 means unlimited on most executors. Only works if the executor has setfpscap.
function MAX.SetFpsCap(n)
	if not CAP.fpscap then
		problem("setfpscap is not available on this executor")
		return false
	end
	n = tonumber(n)
	if not n then
		return false
	end
	n = math.clamp(math.floor(n), 0, 360)
	local ok, err = pcall(setfpscap, n)
	if ok then
		fpsCapChanged = true
		stage("FPS cap = " .. (n == 0 and "unlimited" or n))
	else
		problem("setfpscap failed: " .. tostring(err))
	end
	return ok
end

function MAX.Pause()
	if not running or paused then
		return
	end
	paused = true
	setBlackout(false)
	pcall(applyGlobals)
	queueRefreshAll()
	stage("Paused: restoring world")
end

function MAX.Resume()
	if not running or not paused then
		return
	end
	paused = false
	pcall(applyGlobals)
	queueRefreshAll()
	stage("Resumed")
end

local function statusText()
	local state = (not running and "STOPPED") or (paused and "PAUSED") or (blackoutOn and "BLACKOUT (scanning)") or "RUNNING"
	return string.format(
		"%s | distance %d studs | %d FPS\nTracked %d | hidden parts %d | chunks %d\nScan left %d | dynamic %d | errors %d\nUI: %s",
		state, CFG.RenderDistance, math.floor(fpsNow + 0.5), listN, hiddenN, bucketCount, scanN, dynN, errorCount, uiState
	)
end

function MAX.Status()
	return {
		Version = VERSION,
		Running = running,
		Paused = paused,
		Blackout = blackoutOn,
		RenderDistance = CFG.RenderDistance,
		ChunkSize = CHUNK,
		Culling = CFG.Culling,
		TrackedObjects = listN,
		HiddenParts = hiddenN,
		DynamicObjects = dynN,
		IndexedChunks = bucketCount,
		ScanRemaining = scanN,
		Scanned = scanned,
		ScanDone = scanDone,
		UI = uiState,
		WorkerRestarts = restarts,
		Errors = errorCount,
		LastError = lastError,
		TerrainGrass = terrainStatus,
		Executor = CAP.executor,
	}
end

function MAX.Diagnostics()
	print("========== MAX DIAGNOSTICS ==========")
	for _, line in ipairs(stageLog) do
		print(line)
	end
	print("---------- status ----------")
	for k, v in pairs(MAX.Status()) do
		print(k, tostring(v))
	end
	print("---------- executor support ----------")
	for k, v in pairs(CAP) do
		print(k, tostring(v))
	end
	print("=====================================")
	return statusText()
end

-- ============================================================
-- 14. SAFE EXECUTION + STOP / RESTORE
-- ============================================================
local function safe(name, fn, ...)
	local ok, err = pcall(fn, ...)
	if ok then
		errStreak[name] = 0
		return true
	end
	errorCount += 1
	local s = (errStreak[name] or 0) + 1
	errStreak[name] = s
	lastError = name .. ": " .. tostring(err)
	if s == 1 or s % 25 == 0 then
		warn("[MAX] " .. lastError)
	end
	if s >= TUNE.MaxErrorStreak and not failSafeTripped then
		failSafeTripped = true
		warn("[MAX] '" .. name .. "' failed " .. s .. " times in a row. Restoring the world and stopping for safety.")
		MAX.Stop(true)
	end
	return false
end

-- sync = true -> restore everything immediately without yielding
function MAX.Stop(sync)
	if not running then
		return
	end
	running = false
	paused = false
	workerGen += 1
	setBlackout(false)

	for _, c in ipairs(connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	connections = {}

	local list, count = allList, listN
	records, allList, listN = {}, {}, 0
	buckets, bucketCount = {}, 0
	visible = {}
	dynList, dynN, dynCursor = {}, 0, 1
	scanStack, scanN = {}, 0
	refreshActive = false
	hiddenN = 0

	pcall(applyGlobals) -- running == false, so this restores
	if fpsCapChanged and CAP.fpscap then
		pcall(setfpscap, 60) -- Roblox default; the original cap is unknown
		fpsCapChanged = false
	end

	for i = count, 1, -1 do
		local rec = list[i]
		if rec then
			pcall(restoreRecord, rec)
		end
		if not sync and i % 300 == 0 then
			task.wait()
		end
	end

	stage("Stopped. World restored (" .. count .. " objects processed).")

	if uiLib then
		pcall(function()
			uiLib:Destroy()
		end)
		uiLib = nil
	end
	if fallbackGui then
		pcall(function()
			fallbackGui:Destroy()
		end)
		fallbackGui, fallbackLabel = nil, nil
	end
	liveParagraph = nil
	uiRefs = { Toggles = {} }
end

function MAX.Restore()
	MAX.Stop(true)
end

-- ============================================================
-- 15. CHARACTER HANDLING
-- ============================================================
local function bindCharacter(char)
	character = char
	root = nil
	dirty = true

	-- release anything we may have registered under the character
	for _, d in ipairs(char:GetDescendants()) do
		if records[d] then
			unregister(d)
		end
	end

	task.spawn(function()
		local ok, hrp = pcall(char.WaitForChild, char, "HumanoidRootPart", 15)
		if running and Player.Character == char then
			root = (ok and hrp) or char.PrimaryPart or char:FindFirstChildWhichIsA("BasePart")
			dirty = true
			pcall(refreshOrigin, true)
		end
	end)
end

-- ============================================================
-- 16. WORKERS
-- ============================================================
local function workerLoop(gen)
	local lastVis, lastDyn = 0, 0
	while running and workerGen == gen do
		local now = os.clock()
		beat = now

		if not paused then
			if scanN > 0 then
				safe("scan", scanStep, scanBudget())
			end
			if dirty or now - lastVis >= TUNE.UpdateInterval then
				lastVis = now
				safe("visibility", updateVisibility)
			end
			if now - lastDyn >= TUNE.DynamicInterval then
				lastDyn = now
				safe("dynamic", dynamicStep, TUNE.DynBudget)
				safe("audit", auditStep, TUNE.AuditBudget)
			end
		end
		if refreshActive then
			safe("refresh", refreshStep, paused and 0.012 or TUNE.RefreshBudget)
		end

		if blackoutOn then
			if scanDone and not dirty and not refreshActive then
				setBlackout(false)
			elseif now - blackoutStart > TUNE.BlackoutTimeout then
				problem("Blackout timeout: scan not finished after " .. TUNE.BlackoutTimeout .. "s, showing world")
				setBlackout(false)
			end
		end

		task.wait(TUNE.TickInterval)
	end
end

local function startWorker()
	workerGen += 1
	beat = os.clock()
	task.spawn(workerLoop, workerGen)
end

updateLive = function()
	local txt = statusText()
	if fallbackLabel then
		pcall(function()
			fallbackLabel.Text = txt
		end)
	end
	if liveParagraph then
		pcall(function()
			liveParagraph:Set({ Title = "Live status", Content = txt })
		end)
	end
end

local function watchdogLoop()
	local lastScanned, lastProgress = scanned, os.clock()
	while running do
		task.wait(2)
		if not running then
			break
		end
		pcall(function()
			local now = os.clock()

			if now - beat > TUNE.StallSeconds then
				restarts += 1
				problem("Worker stalled for " .. math.floor(now - beat) .. "s, restarting (#" .. restarts .. ")")
				startWorker()
			end

			if scanN > 0 and not paused then
				if scanned ~= lastScanned then
					lastScanned, lastProgress = scanned, now
				elseif now - lastProgress > 15 then
					problem("Scan made no progress for 15s, restarting worker")
					lastProgress = now
					startWorker()
				end
			else
				lastScanned, lastProgress = scanned, now
			end

			if uiState == "building" and now - uiStart > TUNE.UiTimeout then
				problem("UI build exceeded " .. TUNE.UiTimeout .. "s")
				uiState = "failed"
			end

			if blackoutOn and now - blackoutStart > TUNE.BlackoutTimeout then
				problem("Watchdog: blackout exceeded " .. TUNE.BlackoutTimeout .. "s, showing world")
				setBlackout(false)
			end

			updateLive()
		end)
	end
end

-- ============================================================
-- 17. UI
-- ============================================================
local function guard(name, fn)
	return function(...)
		if uiSync then
			return
		end
		local ok, err = pcall(fn, ...)
		if not ok then
			problem("UI '" .. name .. "': " .. tostring(err))
		end
	end
end

syncUI = function(skip)
	if not uiRefs.Slider and not uiRefs.Input and next(uiRefs.Toggles) == nil then
		return
	end
	uiSync = true
	pcall(function()
		if uiRefs.Slider and skip ~= "slider" and uiRefs.Slider.CurrentValue ~= CFG.RenderDistance then
			uiRefs.Slider:Set(CFG.RenderDistance)
		end
		if uiRefs.Input then
			uiRefs.Input:Set(tostring(CFG.RenderDistance))
		end
		for k, t in pairs(uiRefs.Toggles) do
			if k ~= skip and t.CurrentValue ~= CFG[k] then
				t:Set(CFG[k])
			end
		end
	end)
	uiSync = false
end

-- Native lightweight UI: no downloads, no external library.
local function guiParent()
	if CAP.gethui then
		local ok, h = pcall(gethui)
		if ok and h then
			return h
		end
	end
	return Player:FindFirstChildOfClass("PlayerGui")
end

local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do
		o[k] = v
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function corner(o, r)
	make("UICorner", { CornerRadius = UDim.new(0, r or 6) }, o)
end

local COLORS = {
	bg = Color3.fromRGB(22, 22, 28),
	row = Color3.fromRGB(34, 34, 44),
	text = Color3.fromRGB(235, 235, 240),
	dim = Color3.fromRGB(150, 150, 165),
	accent = Color3.fromRGB(70, 130, 255),
	on = Color3.fromRGB(55, 165, 90),
	off = Color3.fromRGB(80, 80, 95),
	danger = Color3.fromRGB(190, 60, 60),
	good = Color3.fromRGB(90, 220, 120),
	warn = Color3.fromRGB(240, 200, 80),
	bad = Color3.fromRGB(240, 90, 90),
}

-- ---- FPS COUNTER (always visible, tap it to open/close the panel) ----
local function buildFpsOverlay()
	local parent = guiParent()
	if not parent then
		problem("FPS counter: no GUI parent available")
		return
	end

	local statsSvc
	pcall(function()
		statsSvc = game:GetService("Stats")
	end)

	local gui = make("ScreenGui", {
		Name = "MaxFps",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1000,
	})
	local pill = make("TextButton", {
		Size = UDim2.fromOffset(160, 34),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 4),
		BackgroundColor3 = COLORS.bg,
		BackgroundTransparency = 0.25,
		TextColor3 = COLORS.good,
		TextSize = 11,
		Font = Enum.Font.Code,
		Text = "measuring FPS...",
	}, gui)
	corner(pill, 8)
	gui.Parent = parent
	fallbackGui = gui -- reused as the overlay handle so Stop() destroys it

	pill.Activated:Connect(function()
		local p = uiRefs.Panel
		if p then
			p.Visible = not p.Visible
		else
			print("[MAX] panel is still loading")
		end
	end)

	local acc, frames, worst = 0, 0, 0
	connections[#connections + 1] = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		frames += 1
		if dt > worst then
			worst = dt
		end
		if acc < 0.5 then
			return
		end

		local fps = frames / acc
		local low = worst > 0 and (1 / worst) or 0
		local ms = acc / frames * 1000
		fpsNow = fps

		local mem, ping = 0, "-"
		if statsSvc then
			local okM, m = pcall(function()
				return statsSvc:GetTotalMemoryUsageMb()
			end)
			if okM and type(m) == "number" then
				mem = m
			end
			local okP, p = pcall(function()
				return statsSvc.Network.ServerStatsItem["Data Ping"]:GetValue()
			end)
			if okP and type(p) == "number" then
				ping = tostring(math.floor(p + 0.5))
			end
		end

		pill.Text = string.format(
			"%d FPS (low %d) %dms\n%d MB | ping %s",
			math.floor(fps + 0.5), math.floor(low + 0.5), math.floor(ms + 0.5),
			math.floor(mem + 0.5), ping
		)
		pill.TextColor3 = fps >= 50 and COLORS.good or (fps >= 30 and COLORS.warn or COLORS.bad)

		acc, frames, worst = 0, 0, 0
	end)
end

local TOGGLES = {
	{ "RemoveFoliage", "Hide grass / foliage (by name)" },
	{ "SimpleMaterials", "Simple plastic materials" },
	{ "RemoveTextures", "Remove textures / variants" },
	{ "RemoveParticles", "Disable particles" },
	{ "RemoveTrails", "Disable trails / beams" },
	{ "RemoveLights", "Disable lights" },
	{ "RemoveShadows", "Disable shadows" },
	{ "RemoveReflections", "Remove reflections" },
	{ "RemovePostFX", "Disable post-processing" },
	{ "LowQuality", "Lowest graphics quality level" },
	{ "HideTerrainGrass", "Hide terrain grass (executor support needed)" },
	{ "LowDetailMeshes", "Low-detail meshes (RenderFidelity)" },
	{ "RemoveEnvironment", "Remove atmosphere / clouds" },
	{ "SimpleWater", "Simple terrain water" },
	{ "RemoveBillboards", "Always hide billboard / surface GUIs" },
	{ "CompatLighting", "Compatibility lighting (experimental)" },
}

local function uiFail(msg)
	uiState = "failed"
	problem("UI: " .. msg)
	if uiLib then
		pcall(function()
			uiLib:Destroy()
		end)
		uiLib = nil
	end
	if CFG.RenderDistance < TUNE.NoUiDistance then
		problem("No control panel available. Setting distance to " .. TUNE.NoUiDistance .. " so the game stays playable.")
		MAX.SetDistance(TUNE.NoUiDistance)
	end
end

local function buildNativeUI()
	uiState = "building"
	uiStart = os.clock()
	stage("UI: building native panel")

	local parent = guiParent()
	if not parent then
		return uiFail("no GUI parent (gethui / PlayerGui missing)")
	end
	local UIS = game:GetService("UserInputService")

	local gui = make("ScreenGui", {
		Name = "MaxPanel",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 999,
	})
	uiLib = gui -- so Stop()/uiFail can always destroy it

	local panel = make("Frame", {
		Size = UDim2.new(0, 300, 1, -60),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 44),
		BackgroundColor3 = COLORS.bg,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
	}, gui)
	corner(panel, 10)

	make("TextLabel", {
		Size = UDim2.new(1, -44, 0, 30),
		Position = UDim2.fromOffset(10, 0),
		BackgroundTransparency = 1,
		Text = "MAX Universal Optimizer " .. VERSION,
		TextColor3 = COLORS.text,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, panel)

	local close = make("TextButton", {
		Size = UDim2.fromOffset(30, 26),
		Position = UDim2.new(1, -34, 0, 2),
		BackgroundColor3 = COLORS.danger,
		Text = "X",
		TextColor3 = COLORS.text,
		TextSize = 14,
		Font = Enum.Font.GothamBold,
	}, panel)
	corner(close, 6)
	close.Activated:Connect(function()
		panel.Visible = false
	end)

	local statusLabel = make("TextLabel", {
		Size = UDim2.new(1, -16, 0, 54),
		Position = UDim2.fromOffset(8, 32),
		BackgroundTransparency = 1,
		Text = statusText(),
		TextColor3 = COLORS.dim,
		TextSize = 11,
		Font = Enum.Font.Code,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	}, panel)

	local scroll = make("ScrollingFrame", {
		Size = UDim2.new(1, -8, 1, -92),
		Position = UDim2.fromOffset(4, 88),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, panel)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)

	local toast = make("TextLabel", {
		Size = UDim2.new(1, -12, 0, 32),
		Position = UDim2.new(0, 6, 1, -38),
		BackgroundColor3 = COLORS.row,
		TextColor3 = COLORS.text,
		TextSize = 11,
		Font = Enum.Font.Gotham,
		TextWrapped = true,
		Visible = false,
		ZIndex = 10,
	}, panel)
	corner(toast, 6)
	local toastToken = 0
	uiToast = function(title, msg)
		toastToken += 1
		local mine = toastToken
		toast.Text = title .. ": " .. msg
		toast.Visible = true
		task.delay(4, function()
			if toastToken == mine then
				toast.Visible = false
			end
		end)
	end

	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	local function addHeader(text)
		make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = COLORS.accent,
			TextSize = 12,
			Font = Enum.Font.GothamBold,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = nextOrder(),
		}, scroll)
	end

	local function addButton(text, fn, color)
		local b = make("TextButton", {
			Size = UDim2.new(1, 0, 0, 32),
			BackgroundColor3 = color or COLORS.row,
			Text = text,
			TextColor3 = COLORS.text,
			TextSize = 12,
			Font = Enum.Font.GothamBold,
			LayoutOrder = nextOrder(),
		}, scroll)
		corner(b)
		b.Activated:Connect(function()
			local ok, e = pcall(fn)
			if not ok then
				problem("UI '" .. text .. "': " .. tostring(e))
			end
		end)
	end

	local function addToggle(key, label)
		local row = make("Frame", {
			Size = UDim2.new(1, 0, 0, 34),
			BackgroundColor3 = COLORS.row,
			LayoutOrder = nextOrder(),
		}, scroll)
		corner(row)
		make("TextLabel", {
			Size = UDim2.new(1, -70, 1, 0),
			Position = UDim2.fromOffset(8, 0),
			BackgroundTransparency = 1,
			Text = label,
			TextColor3 = COLORS.text,
			TextSize = 12,
			Font = Enum.Font.Gotham,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, row)
		local b = make("TextButton", {
			Size = UDim2.fromOffset(52, 24),
			Position = UDim2.new(1, -58, 0.5, -12),
			TextColor3 = COLORS.text,
			TextSize = 12,
			Font = Enum.Font.GothamBold,
		}, row)
		corner(b, 12)

		local obj = { CurrentValue = CFG[key] }
		local function paint(v)
			b.Text = v and "ON" or "OFF"
			b.BackgroundColor3 = v and COLORS.on or COLORS.off
		end
		function obj.Set(self, v)
			self.CurrentValue = v
			paint(v)
		end
		paint(CFG[key])
		uiRefs.Toggles[key] = obj

		b.Activated:Connect(function()
			local ok, e = pcall(function()
				MAX.SetOption(key, not CFG[key], key)
				obj:Set(CFG[key])
			end)
			if not ok then
				problem("UI toggle " .. key .. ": " .. tostring(e))
			end
		end)
	end

	local function addDistanceControls()
		local row = make("Frame", {
			Size = UDim2.new(1, 0, 0, 114),
			BackgroundColor3 = COLORS.row,
			LayoutOrder = nextOrder(),
		}, scroll)
		corner(row)

		make("TextLabel", {
			Size = UDim2.new(1, -90, 0, 22),
			Position = UDim2.fromOffset(8, 2),
			BackgroundTransparency = 1,
			Text = "Render distance (studs)",
			TextColor3 = COLORS.text,
			TextSize = 12,
			Font = Enum.Font.GothamBold,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, row)

		local box = make("TextBox", {
			Size = UDim2.fromOffset(64, 22),
			Position = UDim2.new(1, -72, 0, 2),
			BackgroundColor3 = COLORS.bg,
			TextColor3 = COLORS.text,
			TextSize = 12,
			Font = Enum.Font.Code,
			Text = tostring(CFG.RenderDistance),
			PlaceholderText = "0-512",
			ClearTextOnFocus = false,
		}, row)
		corner(box, 4)

		local track = make("Frame", {
			Size = UDim2.new(1, -28, 0, 10),
			Position = UDim2.fromOffset(14, 34),
			BackgroundColor3 = COLORS.bg,
			BorderSizePixel = 0,
		}, row)
		corner(track, 5)
		local fill = make("Frame", {
			Size = UDim2.fromScale(0, 1),
			BackgroundColor3 = COLORS.accent,
			BorderSizePixel = 0,
		}, track)
		corner(fill, 5)
		local knob = make("Frame", {
			Size = UDim2.fromOffset(22, 22),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			BackgroundColor3 = COLORS.text,
			BorderSizePixel = 0,
		}, track)
		corner(knob, 11)
		local hit = make("TextButton", {
			Size = UDim2.new(1, 0, 0, 34),
			Position = UDim2.new(0, 0, 0.5, -17),
			BackgroundTransparency = 1,
			Text = "",
		}, track)

		local function paintSlider(v)
			local r = math.clamp(v / MAX_DIST, 0, 1)
			fill.Size = UDim2.fromScale(r, 1)
			knob.Position = UDim2.fromScale(r, 0.5)
		end

		uiRefs.Slider = { CurrentValue = CFG.RenderDistance }
		function uiRefs.Slider.Set(self, v)
			self.CurrentValue = v
			paintSlider(v)
		end
		uiRefs.Input = {}
		function uiRefs.Input.Set(_, text)
			box.Text = text
		end
		paintSlider(CFG.RenderDistance)

		local dragging, lastApply, pending = false, 0, CFG.RenderDistance
		local function fromInput(pos)
			local w = track.AbsoluteSize.X
			if w <= 0 then
				return
			end
			local r = math.clamp((pos.X - track.AbsolutePosition.X) / w, 0, 1)
			local v = math.floor(r * MAX_DIST + 0.5)
			pending = v
			paintSlider(v)
			box.Text = tostring(v)
			local now = os.clock()
			if now - lastApply >= 0.06 then
				lastApply = now
				MAX.SetDistance(v, "slider")
			end
		end

		hit.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				dragging = true
				scroll.ScrollingEnabled = false
				fromInput(input.Position)
			end
		end)
		connections[#connections + 1] = UIS.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement) then
				fromInput(input.Position)
			end
		end)
		connections[#connections + 1] = UIS.InputEnded:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1) then
				dragging = false
				scroll.ScrollingEnabled = true
				MAX.SetDistance(pending, "slider")
			end
		end)

		box.FocusLost:Connect(function()
			local n = tonumber(box.Text)
			if not n or n ~= n then
				notifyUI("Invalid distance", "Type a number from 0 to 512.")
			else
				MAX.SetDistance(n, "input")
			end
			box.Text = tostring(CFG.RenderDistance)
			paintSlider(CFG.RenderDistance)
		end)

		local steps = { { "-16", -16 }, { "-1", -1 }, { "+1", 1 }, { "+16", 16 } }
		for i, s in ipairs(steps) do
			local b = make("TextButton", {
				Size = UDim2.new(0.25, -4, 0, 26),
				Position = UDim2.new((i - 1) * 0.25, 2, 0, 56),
				BackgroundColor3 = COLORS.bg,
				Text = s[1],
				TextColor3 = COLORS.text,
				TextSize = 12,
				Font = Enum.Font.GothamBold,
			}, row)
			corner(b, 5)
			b.Activated:Connect(function()
				MAX.SetDistance(CFG.RenderDistance + s[2])
			end)
		end

		local presets = { 0, 16, 32, 64, 128, 256, 512 }
		for i, d in ipairs(presets) do
			local b = make("TextButton", {
				Size = UDim2.new(1 / 7, -4, 0, 26),
				Position = UDim2.new((i - 1) / 7, 2, 0, 84),
				BackgroundColor3 = COLORS.bg,
				Text = tostring(d),
				TextColor3 = COLORS.accent,
				TextSize = 11,
				Font = Enum.Font.GothamBold,
			}, row)
			corner(b, 5)
			b.Activated:Connect(function()
				MAX.SetDistance(d)
			end)
		end
	end

	addHeader("Render")
	addDistanceControls()
	addToggle("Culling", "Enable distance culling")

	addHeader("Visuals")
	for _, t in ipairs(TOGGLES) do
		addToggle(t[1], t[2])
	end

	addHeader("System")
	if CAP.fpscap then
		for _, f in ipairs({ 30, 45, 60, 0 }) do
			addButton("FPS cap: " .. (f == 0 and "unlimited" or f), function()
				MAX.SetFpsCap(f)
			end)
		end
	end
	addButton("Pause (restore world)", function()
		MAX.Pause()
	end)
	addButton("Resume", function()
		MAX.Resume()
	end)
	addButton("Refresh visibility", function()
		MAX.Refresh()
		notifyUI("Refresh", "Visibility refresh queued.")
	end)
	addButton("Diagnostics (see console)", function()
		notifyUI("Diagnostics", MAX.Diagnostics())
	end)
	addButton("EMERGENCY RESTORE", function()
		MAX.Restore()
	end, COLORS.danger)
	addButton("Stop optimizer", function()
		MAX.Stop(false)
	end)

	uiRefs.Panel = panel
	liveParagraph = {
		Set = function(_, t)
			statusLabel.Text = t.Content
		end,
	}
	gui.Parent = parent
	uiState = "ready"
	stage("UI ready")
	notifyUI("MAX " .. VERSION, "Loaded at " .. CFG.RenderDistance .. " studs.")
end

-- ============================================================
-- 18. BOOT SEQUENCE (every step isolated, none can abort the rest)
-- ============================================================
local function armReload()
	if not RELOAD.Enabled then
		stage("Reload after teleport: disabled")
		return
	end
	if game.JobId ~= "" and G.INDUSTRIALIST_QUEUED_JOB == game.JobId then
		return -- already queued for this server
	end
	if not queueFn then
		problem("Reload after teleport unavailable: this executor has no queue_on_teleport")
		return
	end

	local haveFile = false
	if RELOAD.File ~= "" and type(isfile) == "function" then
		local ok, r = pcall(isfile, RELOAD.File)
		haveFile = ok and r == true
	end
	if RELOAD.Url == "" and not haveFile then
		problem("Reload after teleport NOT armed. Set RELOAD.Url or save this script as '" .. RELOAD.File .. "' in your executor workspace folder.")
		return
	end

	local code = string.format([[
if not game:IsLoaded() then game.Loaded:Wait() end
task.wait(2)
local url, file = %q, %q
local src
if url ~= "" then
	local ok, r = pcall(function() return game:HttpGet(url) end)
	if ok and type(r) == "string" and #r > 500 then src = r end
end
if not src and file ~= "" and type(isfile) == "function" and isfile(file) then
	local ok, r = pcall(readfile, file)
	if ok and type(r) == "string" then src = r end
end
if src then
	local fn, err = loadstring(src)
	if fn then fn() else warn("[MAX] reload compile failed: " .. tostring(err)) end
else
	warn("[MAX] reload failed: no script source found")
end
]], RELOAD.Url, RELOAD.File)

	local ok, err = pcall(queueFn, code)
	if ok then
		G.INDUSTRIALIST_QUEUED_JOB = game.JobId
		stage("Reload after teleport armed (" .. (RELOAD.Url ~= "" and "URL" or "file") .. ")")
	else
		problem("queue_on_teleport failed: " .. tostring(err))
	end
end

local function bootStep(label, fn)
	stage("Boot: " .. label)
	local ok, err = pcall(fn)
	if not ok then
		problem("Boot step '" .. label .. "' failed: " .. tostring(err))
	end
	return ok
end

stage("Industrialist MAX " .. VERSION .. " starting. Executor: " .. CAP.executor)

bootStep("instant blackout", function()
	if TUNE.InstantBlackout then
		setBlackout(true)
	end
end)

bootStep("executor support check", function()
	stage(string.format(
		"loadstring=%s HttpGet=%s gethui=%s sethiddenproperty=%s",
		tostring(CAP.loadstring), tostring(CAP.httpget), tostring(CAP.gethui), tostring(CAP.sethidden)
	))
end)

bootStep("global graphics", applyGlobals)

bootStep("arm reload after teleport", function()
	armReload()
	connections[#connections + 1] = Player.OnTeleport:Connect(function(state)
		if state == Enum.TeleportState.Started then
			pcall(armReload)
		end
	end)
end)

bootStep("character binding", function()
	connections[#connections + 1] = Player.CharacterAdded:Connect(function(char)
		local ok, err = pcall(bindCharacter, char)
		if not ok then
			problem("CharacterAdded: " .. tostring(err))
		end
	end)
	connections[#connections + 1] = Player.CharacterRemoving:Connect(function()
		root = nil
		character = nil
		dirty = true
	end)
	if Player.Character then
		bindCharacter(Player.Character)
	end
end)

bootStep("world events", function()
	connections[#connections + 1] = Workspace.DescendantAdded:Connect(function(o)
		pcall(register, o)
	end)
	connections[#connections + 1] = Workspace.DescendantRemoving:Connect(function(o)
		if records[o] then
			pcall(unregister, o)
		end
	end)
	connections[#connections + 1] = Lighting.DescendantAdded:Connect(function(o)
		pcall(register, o)
	end)
	connections[#connections + 1] = Lighting.DescendantRemoving:Connect(function(o)
		if records[o] then
			pcall(unregister, o)
		end
	end)
end)

bootStep("scan Lighting (small, synchronous)", function()
	for _, o in ipairs(Lighting:GetDescendants()) do
		pcall(register, o)
	end
end)

bootStep("queue Workspace scan (incremental)", function()
	scanN += 1
	scanStack[scanN] = Workspace
end)

bootStep("start worker", startWorker)
bootStep("start watchdog", function()
	task.spawn(watchdogLoop)
end)
bootStep("FPS counter", buildFpsOverlay)

bootStep("start UI thread", function()
	uiState = "waiting"
	task.spawn(function()
		stage("UI: opening control panel immediately")
		if TUNE.UiDelay > 0 then task.wait(TUNE.UiDelay) end
		if not running then
			return
		end
		local ok, err = pcall(buildNativeUI)
		if not ok then
			uiFail("unexpected error: " .. tostring(err))
		end
	end)
end)

stage("Optimizer running at " .. CFG.RenderDistance .. " studs. UI loads in the background.")
print("==========================================")
print(" INDUSTRIALIST MAX " .. VERSION .. " RUNNING")
print(" Status:      _G.INDUSTRIALIST_MAX.Status()")
print(" Diagnostics: _G.INDUSTRIALIST_MAX.Diagnostics()")
print(" Distance:    _G.INDUSTRIALIST_MAX.SetDistance(128)")
print(" Restore:     _G.INDUSTRIALIST_MAX.Restore()")
print("==========================================")
