--[[
============================================================
 INDUSTRIALIST MAX V21 (single file, self-contained)
 Run this whole file in your executor. Nothing else is needed.

 The real script is stored inside this file as a string (SRC).
 That is what lets it re-run itself after a teleport or game
 change: it hands its own source to queue_on_teleport, and the
 reloaded copy does the same, so it follows you game to game.

 Turn auto reload off: "Auto reload" toggle, Stop, or Restore.
 No queue_on_teleport on your executor? Put this file in the
 executor's autoexec folder instead.
============================================================
]]

local SRC = [==[
--[[
============================================================
 INDUSTRIALIST MAX V21 | UNIVERSAL OPTIMIZER
 Client-side visual optimizer for Roblox / Delta (Rayfield UI)
============================================================
 NOT TESTED ON DELTA. Written from the V18 source and from
 general Roblox / Rayfield knowledge. Read the stage log
 (Diagnostics button or _G.INDUSTRIALIST_MAX.Diagnostics())
 if anything misbehaves.

 WHAT CHANGED vs V18 (the "instant" change)
 1. The first scan of Workspace is now SYNCHRONOUS. The script
    walks every instance in one go and hides it before it
    returns, so the world goes blank the moment you execute
    the script instead of fading out gradually.
    Set TUNE.InstantScan = false to get the old gradual scan.
 2. Render distance 0 now hides everything even if your
    character / camera position is not known yet.
 3. Objects added later are still hidden immediately by the
    DescendantAdded hook (unchanged from V18).
 4. AUTO RELOAD: the script re-runs itself after every teleport
    or game change with no setup. It carries its own source
    inside the file, hands it to queue_on_teleport, and the
    reloaded copy queues itself again, so it keeps chaining
    from game to game. The "Auto reload" toggle, Stop and
    Restore turn it off.

 5. UNIVERSAL OPTIMIZATIONS (all toggles, all restorable except
    the two marked irreversible):
    - Atmosphere / clouds / stars / sun and moon
    - Decals and textures, billboard and surface GUIs, highlights
    - MeshPart / union RenderFidelity -> Performance
    - SurfaceAppearance (PBR) maps removed
    - Animations of far / hidden characters are stopped
    - Calm water (wave size, speed, reflectance), softer shadows,
      no environment specular
    - Optional: mute sounds, hide core GUI (player list, chat)
    - Optional: FPS cap through the executor's setfpscap
    - Optional, IRREVERSIBLE: destroy effects instead of disabling,
      clear terrain locally
    - One-click profiles: MAX and BALANCED (System tab)
 Research notes (what was checked, what was left out):
    - Roblox's own docs list: fewer draw calls, RenderFidelity,
      shadows, transparency, particles, humanoid / animation cost,
      collision fidelity, instance streaming, SLIM avatars.
    - NOT done on purpose: StreamingEnabled and its radii cannot be
      changed by a client; FastFlags are restricted by Roblox since
      Sep 30 2025; CollisionFidelity / CanCollide edits could change
      how the game plays; Lighting.Technology is deprecated.
    - A developer thread disputes how much CastShadow matters, so
      shadows are a toggle, not a promise.
    - The lowest in-game quality level still draws at least 500
      studs, so the distance culling here goes further than
      Roblox's own lowest setting.

 TRADE-OFF
 - On a very large map the one-time scan can freeze the game
   for a moment (roughly 0.5 to several seconds on a weak
   phone). That freeze is the price of an instant blackout.

 KNOWN LIMITATIONS
 - LocalTransparencyModifier only hides rendering. It does NOT
   unload meshes, textures or instances from RAM.
 - Terrain (the voxel ground and water) is not a part, so it
   cannot be hidden this way. Terrain grass is only attempted
   through your executor's hidden-property functions.
 - Cannot enable Workspace.StreamingEnabled from a client.
 - This is not Minecraft-style chunk unloading.
 - Collision is not affected: you still stand on invisible
   floors and bump into invisible walls.
 - Distance uses each part's centre (X/Z). A huge floor whose
   centre is far away can be hidden while you stand on it.
 - SurfaceGuis, decals and similar children of hidden parts may
   still draw. I could not verify how they behave.
 - Game scripts that re-enable particles/lights or reset
   properties can override the forced values until the next
   refresh.
 - Foliage detection is by name only ("grass", "plant", ...).
   A machine called "Plant" would be hidden too.
 - If something goes wrong, run
   _G.INDUSTRIALIST_MAX.Restore()
   or press EMERGENCY RESTORE in the UI.
============================================================
]]

local G = _G
-- GENV survives teleports on most executors; used for the reload flags.
local GENV = G
if type(getgenv) == "function" then
	local okG, envG = pcall(getgenv)
	if okG and type(envG) == "table" then
		GENV = envG
	end
end
local T0 = os.clock()
local VERSION = "V21"

-- ============================================================
-- 0. CLEAN UP A PREVIOUS INSTANCE (V17, V18 or V19)
-- ============================================================
if type(G.INDUSTRIALIST_MAX) == "table" then
	print("[MAX] Previous instance found, stopping it first")
	pcall(function()
		G.INDUSTRIALIST_MAX.Stop(true, true)
	end)
	G.INDUSTRIALIST_MAX = nil
end

-- ============================================================
-- 1. SERVICES
-- ============================================================
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")

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
	RenderDistance = 0,

	Culling = true,
	RemoveFoliage = true,
	SimpleMaterials = true,
	RemoveTextures = true,
	RemoveParticles = true,
	RemoveTrails = true,
	RemoveLights = true,
	RemoveShadows = true,
	RemoveReflections = true,
	RemovePostFX = true,
	LowQuality = true,
	HideTerrainGrass = true,
	RemoveAtmosphere = true,
	RemoveDecals = true,
	RemoveWorldGuis = true,
	RemoveHighlights = true,
	LowMeshDetail = true,
	FreezeFarAnimations = true,
	CalmWater = true,
	RemoveSounds = false,
	HideCoreGui = false,
	DestroyEffects = false, -- irreversible
	ClearTerrain = false, -- irreversible
	AutoReload = true,
}

local TUNE = {
	InstantScan = true, -- true: hide the whole world synchronously at load

	TickInterval = 0.05,
	UpdateInterval = 0.20,
	DynamicInterval = 0.50,

	ScanBudgetLoading = 0.0025, -- seconds per tick while Rayfield is loading (gradual scan only)
	ScanBudgetNormal = 0.006,
	ScanBatchMax = 400,

	VisBudget = 0.008,
	RefreshBudget = 0.006,
	DynBudget = 0.003,
	AuditBudget = 0.003,
	AnimBudget = 0.003,

	StallSeconds = 8,
	UiDelay = 10, -- seconds before Rayfield starts loading
	UiTimeout = 30,
	NoUiDistance = 128, -- used only if NO UI at all could be created
	MaxErrorStreak = 8,
}

-- Auto reload after teleport is controlled by CFG.AutoReload (see section 18).

-- Options that need a full re-apply to every tracked object
local GLOBAL_ONLY = { LowQuality = true, HideTerrainGrass = true, CalmWater = true, HideCoreGui = true }

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
local animSet = {}
local fpsCap, fpsOrig = 0, nil
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

local syncUI, buildFallbackUI, updateLive, syncReload

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
	if uiLib then
		pcall(function()
			uiLib:Notify({ Title = title, Content = msg, Duration = 5 })
		end)
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
CAP.setfps = type(setfpscap) == "function"
CAP.getfps = type(getfpscap) == "function"
local queueFn = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
if type(queueFn) ~= "function" then
	queueFn = nil
end
CAP.queue = queueFn ~= nil
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
local FORCED = {
	LocalTransparencyModifier = 1,
	CastShadow = false,
	Reflectance = 0,
	Material = Enum.Material.Plastic,
	MaterialVariant = "",
	TextureID = "",
	Enabled = false,
	Shadows = false,
	Volume = 0,
	Playing = false,
	Transparency = 1,
	Density = 0,
	Haze = 0,
	Glare = 0,
	StarCount = 0,
	CelestialBodiesShown = false,
	RenderFidelity = Enum.RenderFidelity.Performance,
	ColorMap = "",
	NormalMap = "",
	MetalnessMap = "",
	RoughnessMap = "",
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
		elseif obj:IsA("Decal") then
			k = "Decal" -- Texture inherits from Decal
		elseif obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then
			k = "Gui"
		elseif obj:IsA("Sound") then
			k = "Sound"
		elseif cn == "Highlight" then
			k = "Highlight"
		elseif cn == "Atmosphere" then
			k = "Atmosphere"
		elseif cn == "Clouds" then
			k = "Clouds"
		elseif cn == "Sky" then
			k = "Sky"
		elseif cn == "SurfaceAppearance" then
			k = "SurfaceApp"
		elseif cn == "Animator" then
			k = "Animator"
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
	if not CFG.Culling or not rec.Anchor then
		return false
	end
	-- Distance 0 means "hide everything", so no position is needed.
	if not hasOrigin then
		return distSq == 0
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

-- kinds that never belong to a part position
local NOANCHOR = { PostFX = true, Atmosphere = true, Sky = true, Clouds = true, SurfaceApp = true }

-- with CFG.DestroyEffects these are destroyed instead of disabled
local DESTROY_OPT = {
	Particle = "RemoveParticles",
	Trail = "RemoveTrails",
	Light = "RemoveLights",
	PostFX = "RemovePostFX",
	Highlight = "RemoveHighlights",
}

local function stopTracks(animator)
	local ok, tracks = pcall(animator.GetPlayingAnimationTracks, animator)
	if ok and type(tracks) == "table" then
		for i = 1, #tracks do
			pcall(tracks[i].Stop, tracks[i], 0)
		end
	end
end

-- farOnly = true -> only touch properties that depend on distance
local function applyRecord(rec, farOnly)
	local act = running and not paused
	local far = act and CFG.Culling and rec.Far == true
	local kind = rec.Kind

	local destroyKey = DESTROY_OPT[kind]
	if act and CFG.DestroyEffects and destroyKey and CFG[destroyKey] then
		pcall(rec.Obj.Destroy, rec.Obj) -- DescendantRemoving unregisters it
		return
	end

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
			if rec.Fid then
				setProp(rec, "RenderFidelity", act and CFG.LowMeshDetail)
			end
			if rec.Mesh then
				setProp(rec, "TextureID", act and CFG.RemoveTextures)
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
	elseif kind == "Decal" then
		setProp(rec, "Transparency", far or (act and CFG.RemoveDecals))
	elseif kind == "Gui" then
		setProp(rec, "Enabled", far or (act and CFG.RemoveWorldGuis))
	elseif kind == "Highlight" then
		setProp(rec, "Enabled", far or (act and CFG.RemoveHighlights))
	elseif kind == "Sound" then
		local mute = act and CFG.RemoveSounds
		setProp(rec, "Volume", mute)
		setProp(rec, "Playing", mute)
	elseif kind == "Atmosphere" then
		local on = act and CFG.RemoveAtmosphere
		setProp(rec, "Density", on)
		setProp(rec, "Haze", on)
		setProp(rec, "Glare", on)
	elseif kind == "Clouds" then
		setProp(rec, "Enabled", act and CFG.RemoveAtmosphere)
	elseif kind == "Sky" then
		local on = act and CFG.RemoveAtmosphere
		setProp(rec, "StarCount", on)
		setProp(rec, "CelestialBodiesShown", on)
	elseif kind == "SurfaceApp" then
		local on = act and CFG.RemoveTextures
		setProp(rec, "ColorMap", on)
		setProp(rec, "NormalMap", on)
		setProp(rec, "MetalnessMap", on)
		setProp(rec, "RoughnessMap", on)
	elseif kind == "Animator" then
		if far and CFG.FreezeFarAnimations then
			stopTracks(rec.Obj)
		end
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
	elseif kind == "Animator" then
		local hum = obj.Parent
		local model = hum and hum.Parent
		if model and model ~= Workspace then
			local r = model:FindFirstChild("HumanoidRootPart") or (model:IsA("Model") and model.PrimaryPart) or nil
			if r and r:IsA("BasePart") then
				anchor = r
			end
		end
	elseif not NOANCHOR[kind] then
		anchor = findAnchor(obj)
		if anchor and anchor.ClassName == "Terrain" then
			anchor = nil
		end
	end

	local rec = { Obj = obj, Kind = kind, Anchor = anchor, Fol = false, Hid = false }
	if kind == "Part" then
		rec.Fol = isFoliageName(obj.Name)
		rec.Mesh = obj.ClassName == "MeshPart"
		rec.Fid = rec.Mesh or obj:IsA("PartOperation")
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
	if kind == "Animator" then
		animSet[rec] = true
	end

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
	animSet[rec] = nil

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
	if uiState == "loading" then
		return TUNE.ScanBudgetLoading
	end
	return TUNE.ScanBudgetNormal
end

-- Gradual scan (only used when TUNE.InstantScan is false, or as
-- a fallback if the instant scan cannot run).
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

-- Instant scan: walks the whole Workspace in ONE go, without
-- yielding, so everything is hidden before the script returns.
local function instantScan()
	refreshOrigin(true)
	local t = os.clock()
	local ok, list = pcall(Workspace.GetDescendants, Workspace)
	if not ok or type(list) ~= "table" then
		problem("GetDescendants failed (" .. tostring(list) .. "). Falling back to the gradual scan.")
		scanN += 1
		scanStack[scanN] = Workspace
		return
	end
	local count = #list
	for i = 1, count do
		local o = list[i]
		if o.Parent then
			pcall(register, o)
		end
	end
	scanned += count
	scanDone = true
	dirty = true
	stage(string.format(
		"Instant scan: %d instances visited, %d tracked, %d parts hidden, %.2fs",
		count, listN, hiddenN, os.clock() - t
	))
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

-- Keeps far / hidden characters from animating (nobody can see them).
local function animStep(budget)
	if not (CFG.FreezeFarAnimations and CFG.Culling) then
		return
	end
	local deadline = os.clock() + budget
	local n = 0
	for rec in pairs(animSet) do
		if rec.Far and rec.Anchor then
			local a = rec.Obj
			if a.Parent then
				stopTracks(a)
			end
		end
		n += 1
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

local CORE_GUIS = { Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Chat, Enum.CoreGuiType.EmotesMenu }

local function coreGui(on)
	local okS, sg = pcall(game.GetService, game, "StarterGui")
	if not okS or not sg then
		return
	end
	local st = gstate.CoreGui
	if on then
		if st then
			return
		end
		st = {}
		for _, t in ipairs(CORE_GUIS) do
			local ok, cur = pcall(sg.GetCoreGuiEnabled, sg, t)
			if ok and cur then
				st[#st + 1] = t
				pcall(sg.SetCoreGuiEnabled, sg, t, false)
			end
		end
		gstate.CoreGui = st
	elseif st then
		for _, t in ipairs(st) do
			pcall(sg.SetCoreGuiEnabled, sg, t, true)
		end
		gstate.CoreGui = nil
	end
end

-- IRREVERSIBLE for this session (local only, the server is not affected)
local function clearTerrain()
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if not terrain then
		return
	end
	local ok, err = pcall(terrain.Clear, terrain)
	if ok then
		stage("Terrain cleared locally (cannot be undone until you rejoin)")
	else
		problem("Terrain clear failed: " .. tostring(err))
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

	setGlobalProp("ShadowSoftness", Lighting, "ShadowSoftness", 0, act and CFG.RemoveShadows)
	setGlobalProp("EnvSpecular", Lighting, "EnvironmentSpecularScale", 0, act and CFG.RemoveReflections)

	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local calm = act and CFG.CalmWater
		setGlobalProp("WaterWaveSize", terrain, "WaterWaveSize", 0, calm)
		setGlobalProp("WaterWaveSpeed", terrain, "WaterWaveSpeed", 0, calm)
		setGlobalProp("WaterReflectance", terrain, "WaterReflectance", 0, calm)
	end

	coreGui(act and CFG.HideCoreGui)
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
		if key == "AutoReload" then
			pcall(syncReload)
		elseif key == "ClearTerrain" then
			if value then
				pcall(clearTerrain)
			end
		elseif GLOBAL_ONLY[key] then
			pcall(applyGlobals)
		else
			if key == "RemoveShadows" or key == "RemoveReflections" then
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

function MAX.SetFpsCap(value)
	local n = tonumber(value)
	if not n or n ~= n then
		return false
	end
	if not CAP.setfps then
		problem("FPS cap unavailable: this executor has no setfpscap")
		return false
	end
	n = math.floor(math.clamp(n, 0, 240) + 0.5)
	if n == fpsCap then
		return true
	end
	if fpsCap == 0 and n > 0 and fpsOrig == nil and CAP.getfps then
		local ok, cur = pcall(getfpscap)
		if ok and type(cur) == "number" then
			fpsOrig = cur
		end
	end
	fpsCap = n
	pcall(setfpscap, n == 0 and (fpsOrig or 60) or n)
	stage(n == 0 and "FPS cap restored" or ("FPS cap = " .. n))
	return true
end

local PROFILES = {
	max = {
		dist = 0,
		on = {
			"Culling", "RemoveFoliage", "SimpleMaterials", "RemoveTextures", "RemoveParticles",
			"RemoveTrails", "RemoveLights", "RemoveShadows", "RemoveReflections", "RemovePostFX",
			"LowQuality", "HideTerrainGrass", "RemoveAtmosphere", "RemoveDecals", "RemoveWorldGuis",
			"RemoveHighlights", "LowMeshDetail", "FreezeFarAnimations", "CalmWater", "RemoveSounds",
			"HideCoreGui",
		},
		off = {},
	},
	balanced = {
		dist = 128,
		on = {
			"Culling", "RemoveFoliage", "RemoveParticles", "RemoveTrails", "RemoveShadows",
			"RemoveReflections", "RemovePostFX", "LowQuality", "HideTerrainGrass", "RemoveAtmosphere",
			"RemoveHighlights", "LowMeshDetail", "FreezeFarAnimations", "CalmWater",
		},
		off = {
			"SimpleMaterials", "RemoveTextures", "RemoveLights", "RemoveDecals", "RemoveWorldGuis",
			"RemoveSounds", "HideCoreGui",
		},
	},
}

function MAX.SetProfile(name)
	local p = PROFILES[name]
	if not p then
		return false
	end
	for _, k in ipairs(p.on) do
		MAX.SetOption(k, true)
	end
	for _, k in ipairs(p.off) do
		MAX.SetOption(k, false)
	end
	MAX.SetDistance(p.dist)
	stage("Profile: " .. name)
	return true
end

function MAX.Refresh()
	dirty = true
	queueRefreshAll()
	pcall(updateVisibility, 0.03)
end

function MAX.Pause()
	if not running or paused then
		return
	end
	paused = true
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
	local state = (not running and "STOPPED") or (paused and "PAUSED") or "RUNNING"
	return string.format(
		"%s | distance %d studs\nTracked %d | hidden parts %d | chunks %d\nScan left %d | dynamic %d | errors %d\nUI: %s",
		state, CFG.RenderDistance, listN, hiddenN, bucketCount, scanN, dynN, errorCount, uiState
	)
end

function MAX.Status()
	return {
		Version = VERSION,
		Running = running,
		Paused = paused,
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
		InstantScan = TUNE.InstantScan,
		AutoReload = CFG.AutoReload,
		FpsCap = fpsCap,
		FpsCapSupported = CAP.setfps,
		TrackedAnimators = (function()
			local c = 0
			for _ in pairs(animSet) do
				c += 1
			end
			return c
		end)(),
		ReloadQueued = GENV.INDUSTRIALIST_QUEUED_JOB ~= nil,
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
function MAX.Stop(sync, keepReload)
	if not running then
		return
	end
	running = false
	paused = false
	workerGen += 1
	if not keepReload then
		-- queued reload scripts check this flag and do nothing
		GENV.INDUSTRIALIST_AUTORELOAD = false
	end

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
	animSet = {}
	refreshActive = false
	hiddenN = 0

	pcall(applyGlobals) -- running == false, so this restores
	if fpsCap ~= 0 and CAP.setfps then
		pcall(setfpscap, fpsOrig or 60)
	end
	fpsCap = 0

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
				safe("anim", animStep, TUNE.AnimBudget)
			end
		end
		if refreshActive then
			safe("refresh", refreshStep, paused and 0.012 or TUNE.RefreshBudget)
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

			if uiState == "loading" and now - uiStart > TUNE.UiTimeout and not fallbackGui then
				problem("Rayfield did not finish within " .. TUNE.UiTimeout .. "s. Opening fallback panel.")
				buildFallbackUI()
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

-- Small native panel: used only if Rayfield fails or is too slow.
buildFallbackUI = function()
	if fallbackGui or not running then
		return
	end
	local ok, err = pcall(function()
		local gui = Instance.new("ScreenGui")
		gui.Name = "IndustrialistMaxPanel"
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 999

		local parent
		if CAP.gethui then
			local okH, h = pcall(gethui)
			if okH and h then
				parent = h
			end
		end
		parent = parent or Player:FindFirstChildOfClass("PlayerGui")
		gui.Parent = parent

		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromOffset(250, 112)
		frame.Position = UDim2.fromOffset(8, 60)
		frame.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
		frame.BackgroundTransparency = 0.15
		frame.Active = true
		pcall(function()
			frame.Draggable = true
		end)
		frame.Parent = gui

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -8, 0, 56)
		label.Position = UDim2.fromOffset(4, 2)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextSize = 12
		label.Font = Enum.Font.Gotham
		label.TextWrapped = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Top
		label.Text = statusText()
		label.Parent = frame

		local function button(text, x, fn)
			local b = Instance.new("TextButton")
			b.Size = UDim2.fromOffset(56, 40)
			b.Position = UDim2.fromOffset(x, 64)
			b.Text = text
			b.TextSize = 14
			b.Font = Enum.Font.GothamBold
			b.BackgroundColor3 = Color3.fromRGB(45, 45, 58)
			b.TextColor3 = Color3.new(1, 1, 1)
			b.Parent = frame
			b.Activated:Connect(function()
				local okB, e = pcall(fn)
				if not okB then
					problem("panel button: " .. tostring(e))
				end
			end)
		end

		button("-16", 4, function()
			MAX.SetDistance(CFG.RenderDistance - 16)
		end)
		button("+16", 66, function()
			MAX.SetDistance(CFG.RenderDistance + 16)
		end)
		button("128", 128, function()
			MAX.SetDistance(128)
		end)
		button("Restore", 190, function()
			MAX.Restore()
		end)

		fallbackGui, fallbackLabel = gui, label
	end)

	if ok then
		stage("Fallback panel created")
	else
		problem("Fallback panel failed: " .. tostring(err))
		if uiState ~= "ready" and CFG.RenderDistance < TUNE.NoUiDistance then
			problem("No UI available at all. Setting distance to " .. TUNE.NoUiDistance .. " so the game stays playable.")
			MAX.SetDistance(TUNE.NoUiDistance)
		end
	end
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
	{ "RemoveAtmosphere", "Remove atmosphere / clouds / stars" },
	{ "RemoveDecals", "Hide decals and textures (world)" },
	{ "RemoveWorldGuis", "Hide billboard / surface GUIs" },
	{ "RemoveHighlights", "Disable highlights" },
	{ "LowMeshDetail", "Low mesh detail (RenderFidelity)" },
	{ "FreezeFarAnimations", "Stop animations of far characters" },
	{ "CalmWater", "Calm water (no waves / reflections)" },
	{ "RemoveSounds", "Mute all sounds" },
	{ "HideCoreGui", "Hide player list / chat / emotes" },
	{ "DestroyEffects", "DESTROY effects instead of disabling (cannot undo)" },
	{ "ClearTerrain", "CLEAR terrain locally (cannot undo)" },
	{ "AutoReload", "Auto reload after teleport / game change" },
}

local function uiFail(msg)
	uiState = "failed"
	problem("UI: " .. msg)
	buildFallbackUI()
end

local function buildRayfield()
	uiState = "loading"
	uiStart = os.clock()

	stage("UI 1/5: checking executor support")
	if not CAP.loadstring then
		return uiFail("loadstring is not available on this executor")
	end
	if not CAP.httpget then
		return uiFail("game:HttpGet is not available on this executor")
	end

	stage("UI 2/5: downloading Rayfield")
	local okH, src = pcall(function()
		return game:HttpGet("https://sirius.menu/rayfield")
	end)
	if not okH or type(src) ~= "string" or #src < 1000 then
		return uiFail("Rayfield download failed: " .. tostring(src))
	end
	if not running then
		return
	end

	stage("UI 3/5: compiling Rayfield")
	local fn, cerr = loadstring(src)
	if not fn then
		return uiFail("Rayfield compile failed: " .. tostring(cerr))
	end
	local okR, lib = pcall(fn)
	if not okR or type(lib) ~= "table" then
		return uiFail("Rayfield init failed: " .. tostring(lib))
	end

	stage("UI 4/5: creating window")
	local okW, win = pcall(lib.CreateWindow, lib, {
		Name = "INDUSTRIALIST MAX " .. VERSION,
		LoadingTitle = "Industrialist MAX",
		LoadingSubtitle = VERSION,
		Theme = "Default",
		DisableRayfieldPrompts = true,
		DisableBuildWarnings = true,
		ConfigurationSaving = { Enabled = false },
		KeySystem = false,
	})
	if not okW or not win then
		return uiFail("CreateWindow failed: " .. tostring(win))
	end
	if not running then
		pcall(function()
			lib:Destroy()
		end)
		return
	end
	uiLib = lib

	stage("UI 5/5: building tabs")

	local function section(name, build)
		local ok, err = pcall(build)
		if not ok then
			problem("UI section " .. name .. ": " .. tostring(err))
		end
	end

	local function addToggle(tab, key, label)
		uiRefs.Toggles[key] = tab:CreateToggle({
			Name = label,
			CurrentValue = CFG[key],
			Flag = "T_" .. key,
			Callback = guard("toggle " .. key, function(v)
				MAX.SetOption(key, v, key)
			end),
		})
	end

	section("Render", function()
		local tab = win:CreateTab("Render")

		tab:CreateParagraph({
			Title = "Render distance",
			Content = "0 studs hides the whole world around you. Raise the slider to reveal nearby objects. Distance is measured on the X/Z plane.",
		})

		uiRefs.Slider = tab:CreateSlider({
			Name = "Render distance",
			Range = { 0, 512 },
			Increment = 1,
			Suffix = " studs",
			CurrentValue = CFG.RenderDistance,
			Flag = "RenderDistance",
			Callback = guard("slider", function(v)
				MAX.SetDistance(v, "slider")
			end),
		})

		uiRefs.Input = tab:CreateInput({
			Name = "Exact distance (0 - 512)",
			CurrentValue = tostring(CFG.RenderDistance),
			PlaceholderText = "0 - 512",
			RemoveTextAfterFocusLost = false,
			Flag = "ExactDistance",
			Callback = guard("input", function(text)
				local n = tonumber(text)
				if not n or n ~= n then
					notifyUI("Invalid distance", "Type a number from 0 to 512.")
					syncUI(nil)
					return
				end
				MAX.SetDistance(n, "input")
			end),
		})

		addToggle(tab, "Culling", "Enable distance culling")

		if CAP.setfps then
			tab:CreateSlider({
				Name = "FPS cap (0 = leave unchanged)",
				Range = { 0, 240 },
				Increment = 5,
				Suffix = " fps",
				CurrentValue = fpsCap,
				Flag = "FpsCap",
				Callback = guard("fpscap", function(v)
					MAX.SetFpsCap(v)
				end),
			})
		end

		for _, d in ipairs({ 0, 16, 32, 64, 128, 256, 512 }) do
			tab:CreateButton({
				Name = "Preset: " .. d .. " studs",
				Callback = guard("preset " .. d, function()
					MAX.SetDistance(d)
				end),
			})
		end
	end)

	section("Visuals", function()
		local tab = win:CreateTab("Visuals")
		for _, t in ipairs(TOGGLES) do
			addToggle(tab, t[1], t[2])
		end
		tab:CreateParagraph({
			Title = "Terrain grass",
			Content = "Terrain.Decoration is not scriptable in normal Roblox. This script tries your executor's hidden-property functions. See Diagnostics for the result.",
		})
	end)

	section("System", function()
		local tab = win:CreateTab("System")

		liveParagraph = tab:CreateParagraph({ Title = "Live status", Content = statusText() })

		tab:CreateButton({
			Name = "Profile: MAX (everything, 0 studs)",
			Callback = guard("profile max", function()
				MAX.SetProfile("max")
			end),
		})
		tab:CreateButton({
			Name = "Profile: BALANCED (128 studs)",
			Callback = guard("profile balanced", function()
				MAX.SetProfile("balanced")
			end),
		})

		tab:CreateButton({
			Name = "Pause (restore world)",
			Callback = guard("pause", function()
				MAX.Pause()
			end),
		})
		tab:CreateButton({
			Name = "Resume",
			Callback = guard("resume", function()
				MAX.Resume()
			end),
		})
		tab:CreateButton({
			Name = "Refresh visibility",
			Callback = guard("refresh", function()
				MAX.Refresh()
				notifyUI("Refresh", "Visibility refresh queued.")
			end),
		})
		tab:CreateButton({
			Name = "Diagnostics (see console)",
			Callback = guard("diagnostics", function()
				local txt = MAX.Diagnostics()
				notifyUI("Diagnostics", txt)
			end),
		})
		tab:CreateButton({
			Name = "EMERGENCY RESTORE",
			Callback = guard("restore", function()
				MAX.Restore()
			end),
		})
		tab:CreateButton({
			Name = "Stop optimizer",
			Callback = guard("stop", function()
				MAX.Stop(false)
			end),
		})
	end)

	if fallbackGui then
		pcall(function()
			fallbackGui:Destroy()
		end)
		fallbackGui, fallbackLabel = nil, nil
	end
	uiState = "ready"
	stage("UI ready")
	notifyUI("Industrialist MAX " .. VERSION, "Loaded at " .. CFG.RenderDistance .. " studs.")
end

-- ============================================================
-- 18. BOOT SEQUENCE (every step isolated, none can abort the rest)
-- ============================================================
-- Finds a long-bracket level that does not occur inside s.
local function pickLevel(s)
	local n = 0
	while string.find(s, "]" .. string.rep("=", n) .. "]", 1, true) do
		n += 1
	end
	return string.rep("=", n)
end

-- Runs in the NEW game. SRC is prepended by armReload.
local RELOAD_TAIL = [=[
local env = (type(getgenv) == "function" and getgenv()) or _G
env.INDUSTRIALIST_SRC = SRC
if env.INDUSTRIALIST_AUTORELOAD == false then
	return
end
local fn, err = loadstring(SRC)
if fn then
	local ok, e = pcall(fn)
	if not ok then
		warn("[MAX] reload run failed: " .. tostring(e))
	end
else
	warn("[MAX] reload compile failed: " .. tostring(err))
end
]=]

-- Standard queue_on_teleport pattern: the queued chunk contains the
-- whole script, so no URL or file is needed. The reloaded script
-- calls armReload again, which keeps the chain going.
local function armReload()
	if not queueFn then
		problem("Auto reload unavailable: this executor has no queue_on_teleport. Put the script in your executor's autoexec folder instead.")
		return
	end
	local src = GENV.INDUSTRIALIST_SRC
	if type(src) ~= "string" or #src < 1000 then
		problem("Auto reload NOT armed: script source is not available. Run the whole V20 file, not a fragment.")
		return
	end

	GENV.INDUSTRIALIST_AUTORELOAD = true

	local key = tostring(game.JobId) .. ":" .. tostring(game.PlaceId)
	if GENV.INDUSTRIALIST_QUEUED_JOB == key then
		return -- already queued from this server
	end

	local eq = pickLevel(src)
	local code = "local SRC = [" .. eq .. "[\n" .. src .. "\n]" .. eq .. "]\n" .. RELOAD_TAIL

	local ok, err = pcall(queueFn, code)
	if ok then
		GENV.INDUSTRIALIST_QUEUED_JOB = key
		stage("Auto reload armed (" .. math.floor(#code / 1024) .. " KB queued)")
	else
		problem("queue_on_teleport failed: " .. tostring(err))
	end
end

syncReload = function()
	if running and CFG.AutoReload then
		armReload()
	else
		-- queued copy (if any) will see this flag and not start
		GENV.INDUSTRIALIST_AUTORELOAD = false
		stage("Auto reload off")
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

bootStep("executor support check", function()
	stage(string.format(
		"loadstring=%s HttpGet=%s gethui=%s sethiddenproperty=%s",
		tostring(CAP.loadstring), tostring(CAP.httpget), tostring(CAP.gethui), tostring(CAP.sethidden)
	))
end)

bootStep("global graphics", applyGlobals)

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

-- Hooks go in BEFORE the scan so nothing added during or after
-- the scan can slip through visible.
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
	connections[#connections + 1] = SoundService.DescendantAdded:Connect(function(o)
		pcall(register, o)
	end)
	connections[#connections + 1] = SoundService.DescendantRemoving:Connect(function(o)
		if records[o] then
			pcall(unregister, o)
		end
	end)
end)

bootStep("scan Lighting + SoundService (small, synchronous)", function()
	for _, svc in ipairs({ Lighting, SoundService }) do
		for _, o in ipairs(svc:GetDescendants()) do
			pcall(register, o)
		end
	end
end)

if TUNE.InstantScan then
	bootStep("INSTANT scan of Workspace (may freeze briefly)", instantScan)
else
	bootStep("queue Workspace scan (gradual)", function()
		scanN += 1
		scanStack[scanN] = Workspace
	end)
end

bootStep("start worker", startWorker)
bootStep("start watchdog", function()
	task.spawn(watchdogLoop)
end)

-- Auto reload is armed AFTER the world is already hidden.
bootStep("arm auto reload", function()
	syncReload()
	connections[#connections + 1] = Player.OnTeleport:Connect(function(state)
		if state == Enum.TeleportState.Started and CFG.AutoReload then
			pcall(armReload)
		end
	end)
end)

bootStep("start UI thread", function()
	uiState = "waiting"
	task.spawn(function()
		stage("UI: waiting " .. TUNE.UiDelay .. "s before loading Rayfield (optimizer already running)")
		task.wait(TUNE.UiDelay)
		if not running then
			return
		end
		local ok, err = pcall(buildRayfield)
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

]==]

local env = (type(getgenv) == "function" and getgenv()) or _G
env.INDUSTRIALIST_SRC = SRC

local fn, err = loadstring(SRC)
if not fn then
	warn("[MAX] compile failed: " .. tostring(err))
	return
end
local ok, e = pcall(fn)
if not ok then
	warn("[MAX] run failed: " .. tostring(e))
end
