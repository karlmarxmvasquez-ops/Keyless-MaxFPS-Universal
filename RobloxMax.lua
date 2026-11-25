--[[
ROBLOX MAX v1.0.0 - universal client-side performance toolkit (single file, Delta-friendly)

Everything is OFF at startup. Nothing scans or applies on load. Opening the menu does nothing.

API NOTES (from knowledge of the Creator Hub reference, NOT re-verified live in this build;
every write is pcall'd, so a wrong assumption fails soft instead of crashing)
 EXPECTED OK : ParticleEmitter/Trail/Beam/Light/PostEffect/Clouds .Enabled, Lighting.GlobalShadows,
               Terrain.Decoration, MeshPart.RenderFidelity, Stats:GetTotalMemoryUsageMb()
 CONDITIONAL : Terrain.WaterWaveSize, setfpscap/getfpscap, settings().Rendering.QualityLevel, gethui
 EXPERIMENTAL: collectgarbage("collect") (Roblox may restrict it; only frees the Lua heap)
 REJECTED    : per-part CastShadow sweeps (too heavy), blanking textures, destroying objects, getgc,
               remote/network interference, per-frame manual culling, forcing StreamingEnabled
 NOT BUILT v1: animation / UI-reduction / camera modules (no universal safe change with proven gain),
               physics is diagnostics only (unanchored count), no persistence (session-only settings)
 Client script cannot touch: CPU/GPU clocks, thermals, Android LMK, native texture/mesh memory, server work.
]]

local VERSION = "1.0.0"
local okEnv, genv = pcall(function() return getgenv() end)
local G = (okEnv and genv) or _G
if G.ROBLOX_MAX and type(G.ROBLOX_MAX.Unload) == "function" then pcall(G.ROBLOX_MAX.Unload) end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Stats = game:GetService("Stats")

local CAP = {
	setfpscap = type(setfpscap) == "function",
	getfpscap = type(getfpscap) == "function",
	gethui = type(gethui) == "function",
	quality = (pcall(function() return settings().Rendering.QualityLevel end)),
}

local MODE_NAMES = { "SAFE", "AGGRESSIVE", "EXPERIMENTAL" }
local S = { unloaded = false, mode = 1, interval = 1, fpsCap = 60, conns = {}, tab = "HOME", note = nil }
local stats = { processed = 0, failed = 0, restoreFailed = 0, errors = 0 }
local ui = { built = false }

-- ---------- bounded, de-duplicated error log ----------
local errLog, errCount = {}, {}
local function logErr(msg)
	msg = tostring(msg)
	stats.errors += 1
	if errCount[msg] then errCount[msg] += 1 return end
	if #errLog >= 20 then errCount[table.remove(errLog, 1)] = nil end
	errLog[#errLog + 1] = msg
	errCount[msg] = 1
end
local function track(c) S.conns[#S.conns + 1] = c return c end

-- ---------- property manager: stores originals, multi-owner, weak refs ----------
local Prop = { records = setmetatable({}, { __mode = "k" }), byOwner = {}, count = {} }

function Prop.set(owner, inst, prop, value)
	local recs = Prop.records[inst]
	if not recs then recs = {}; Prop.records[inst] = recs end
	local rec = recs[prop]
	if not rec then
		local ok, orig = pcall(function() return inst[prop] end)
		if not ok then stats.failed += 1; logErr("read " .. prop .. ": " .. tostring(orig)) return false end
		rec = { orig = orig, owners = {} }
		recs[prop] = rec
	end
	local idx = Prop.byOwner[owner]
	if not idx then idx = setmetatable({}, { __mode = "k" }); Prop.byOwner[owner] = idx end
	local props = idx[inst]
	if not props then props = {}; idx[inst] = props end
	if not props[prop] then Prop.count[owner] = (Prop.count[owner] or 0) + 1 end
	props[prop] = true
	rec.owners[owner] = true
	local ok, err = pcall(function() inst[prop] = value end)
	if not ok then stats.failed += 1; logErr("write " .. prop .. ": " .. tostring(err)) return false end
	return true
end

function Prop.release(owner)
	local idx = Prop.byOwner[owner]
	Prop.byOwner[owner] = nil
	Prop.count[owner] = nil
	if not idx then return end
	for inst, props in idx do
		local recs = Prop.records[inst]
		if recs then
			for prop in props do
				local rec = recs[prop]
				if rec then
					rec.owners[owner] = nil
					if next(rec.owners) == nil then -- last owner: restore original
						recs[prop] = nil
						local ok, err = pcall(function() inst[prop] = rec.orig end)
						if not ok then stats.restoreFailed += 1; logErr("restore " .. prop .. ": " .. tostring(err)) end
					end
				end
			end
			if next(recs) == nil then Prop.records[inst] = nil end
		end
	end
end

-- ---------- scheduler: one Heartbeat connection, only while something needs it ----------
local Sched = { jobs = {}, hook = nil, conn = nil }
local function schedEnsure()
	local need = Sched.hook or next(Sched.jobs)
	if need and not Sched.conn then
		Sched.conn = RunService.Heartbeat:Connect(function(dt)
			local h = Sched.hook
			if h then h(dt) end
			for _, job in Sched.jobs do
				job.acc += dt
				if job.acc >= job.every then
					job.acc = 0
					local ok, err = pcall(job.fn)
					if not ok then logErr(err) end
				end
			end
		end)
	elseif not need and Sched.conn then
		Sched.conn:Disconnect(); Sched.conn = nil
	end
end

-- ---------- discovery hub: scoped, event-driven, batched scans ----------
local Hub = { byClass = {}, owners = {}, scans = {}, conns = {}, roots = { workspace, Lighting } }

local function traverse(token, visit)
	for _, root in Hub.roots do
		local list = root:GetDescendants()
		for i = 1, #list do
			if token.cancel then return false end
			visit(list[i])
			if i % 400 == 0 then task.wait() end
		end
	end
	return true
end

local function dispatch(inst)
	local t = Hub.byClass[inst.ClassName]
	if not t then return end
	for _, fn in t do
		stats.processed += 1
		local ok, err = pcall(fn, inst)
		if not ok then logErr(err) end
	end
end

local rowRefresh = {}
function Hub.remove(owner)
	local token = Hub.scans[owner]
	if token then token.cancel = true; Hub.scans[owner] = nil end
	local classes = Hub.owners[owner]
	if classes then
		for cls in classes do
			local t = Hub.byClass[cls]
			if t then t[owner] = nil; if next(t) == nil then Hub.byClass[cls] = nil end end
		end
		Hub.owners[owner] = nil
	end
	if next(Hub.owners) == nil then
		for _, c in Hub.conns do c:Disconnect() end
		Hub.conns = {}
	end
	Prop.release(owner)
end

function Hub.add(owner, classes, fn)
	Hub.remove(owner)
	Hub.owners[owner] = classes
	for cls in classes do
		local t = Hub.byClass[cls]
		if not t then t = {}; Hub.byClass[cls] = t end
		t[owner] = fn
	end
	if #Hub.conns == 0 then
		for _, root in Hub.roots do Hub.conns[#Hub.conns + 1] = root.DescendantAdded:Connect(dispatch) end
	end
	local token = { cancel = false }
	Hub.scans[owner] = token
	task.spawn(function()
		local done = traverse(token, function(inst)
			if classes[inst.ClassName] then
				stats.processed += 1
				local ok, err = pcall(fn, inst)
				if not ok then logErr(err) end
			end
		end)
		if done and rowRefresh[owner] then rowRefresh[owner]() end
	end)
end

-- ---------- options ----------
local Opts = { list = {}, byKey = {} }
local function noop() end
local updateHome, updateDiagLabels, refreshStats = noop, noop, noop

local function classOpt(key, classes, prop, value)
	return function()
		Hub.add(key, classes, function(inst) Prop.set(key, inst, prop, value) end)
	end, function() Hub.remove(key) end
end
local function terrain() return workspace:FindFirstChildOfClass("Terrain") end
local function directOpt(key, getTarget, prop, value)
	return function()
		local t = getTarget()
		if not t then logErr(key .. ": target missing") return false end
		return Prop.set(key, t, prop, value)
	end, function() Prop.release(key) end
end
local function add(o) o.kind = o.kind or "toggle"; o.value = false; Opts.list[#Opts.list + 1] = o; Opts.byKey[o.key] = o end

-- frame-time monitor (ring buffer, bounded)
local RING = 240
local ring, ringN, ringI, tmp = table.create(RING, 0), 0, 0, {}
local res = {}
local function frameStats()
	if ringN < 10 then return nil end
	table.clear(tmp)
	local sum = 0
	for i = 1, ringN do local v = ring[i]; tmp[i] = v; sum += v end
	local avg = sum / ringN
	local var = 0
	for i = 1, ringN do local d = tmp[i] - avg; var += d * d end
	table.sort(tmp)
	res.avgMs = avg * 1000
	res.fps = 1 / avg
	res.medMs = tmp[(ringN + 1) // 2] * 1000
	res.low1 = 1 / tmp[math.max(1, math.ceil(ringN * 0.99))]
	res.jitterMs = math.sqrt(var / ringN) * 1000
	res.n = ringN
	return res
end

local function render(opt) -- tab placement is set below
	return opt
end

add(render({ key = "monitor", tab = "HOME", tier = 1, name = "Monitor FPS / frame time",
	desc = "Samples frame times (small cost). Off = N/A everywhere.",
	enable = function()
		ringN, ringI = 0, 0
		Sched.hook = function(dt) ringI = ringI % RING + 1; ring[ringI] = dt; if ringN < RING then ringN += 1 end end
		Sched.jobs.ui = { acc = 0, every = S.interval, fn = refreshStats }
		schedEnsure()
	end,
	disable = function()
		Sched.hook = nil; Sched.jobs.ui = nil; schedEnsure()
		ringN = 0
		refreshStats()
	end }))

do
	local e, d = classOpt("particles", { ParticleEmitter = true }, "Enabled", false)
	add({ key = "particles", tab = "RENDER", tier = 1, name = "Stop particle emission",
		desc = "Disables ParticleEmitters. Particles already alive finish normally.", enable = e, disable = d })
	e, d = classOpt("trails", { Trail = true }, "Enabled", false)
	add({ key = "trails", tab = "RENDER", tier = 1, name = "Disable trails", desc = "Turns off Trail objects.", enable = e, disable = d })
	e, d = classOpt("beams", { Beam = true }, "Enabled", false)
	add({ key = "beams", tab = "RENDER", tier = 1, name = "Disable beams", desc = "Turns off Beam objects.", enable = e, disable = d })
	e, d = classOpt("clouds", { Clouds = true }, "Enabled", false)
	add({ key = "clouds", tab = "RENDER", tier = 1, name = "Hide clouds", desc = "Disables the Clouds object on terrain.", enable = e, disable = d })
	e, d = directOpt("terrainDeco", terrain, "Decoration", false)
	add({ key = "terrainDeco", tab = "RENDER", tier = 1, name = "Terrain decoration off", desc = "Turns off grass decoration. Terrain shape untouched.", enable = e, disable = d })

	add({ key = "clearParticles", tab = "RENDER", tier = 2, kind = "button", name = "Clear live particles",
		desc = "One-shot wipe of particles on screen. Can't be undone; effects replay.",
		run = function()
			local token = { cancel = false }
			S.note = "Clearing particles..."; updateHome()
			task.spawn(function()
				local n = 0
				traverse(token, function(i)
					if i.ClassName == "ParticleEmitter" then pcall(i.Clear, i); n += 1 end
				end)
				S.note = "Cleared " .. n .. " emitters."; updateHome()
			end)
		end })
	e, d = directOpt("shadows", function() return Lighting end, "GlobalShadows", false)
	add({ key = "shadows", tab = "RENDER", tier = 2, name = "Global shadows off", desc = "Often a big GPU saver; scenes look flatter.", enable = e, disable = d })
	e, d = classOpt("postFx", { BloomEffect = true, BlurEffect = true, ColorCorrectionEffect = true, DepthOfFieldEffect = true, SunRaysEffect = true }, "Enabled", false)
	add({ key = "postFx", tab = "RENDER", tier = 2, name = "Post-processing off", desc = "Bloom, blur, color correction, DoF, sun rays. Look changes.", enable = e, disable = d })
	e, d = classOpt("lights", { PointLight = true, SpotLight = true, SurfaceLight = true }, "Enabled", false)
	add({ key = "lights", tab = "RENDER", tier = 2, name = "Decorative lights off", desc = "Disables Point/Spot/Surface lights. Dark areas get darker.", enable = e, disable = d })
	e, d = classOpt("meshFidelity", { MeshPart = true }, "RenderFidelity", Enum.RenderFidelity.Performance)
	add({ key = "meshFidelity", tab = "RENDER", tier = 2, name = "Mesh fidelity: performance", desc = "RenderFidelity=Performance on MeshParts. Distant LOD may pop.", enable = e, disable = d })
	e, d = directOpt("water", terrain, "WaterWaveSize", 0)
	add({ key = "water", tab = "RENDER", tier = 2, name = "Flat water", desc = "Terrain water wave size to 0 (may be blocked).", enable = e, disable = d })
end

add({ key = "fpsCap", tab = "SYSTEM", tier = 3, name = "FPS cap", avail = function() return CAP.setfpscap end,
	desc = "Executor setfpscap. Limits frames; adds no GPU power. Value in CFG.",
	enable = function()
		if CAP.getfpscap then local ok, v = pcall(getfpscap); S.prevCap = ok and tonumber(v) or nil else S.prevCap = nil end
		local ok, err = pcall(setfpscap, S.fpsCap)
		if not ok then logErr("setfpscap: " .. tostring(err)) return false end
	end,
	disable = function() pcall(setfpscap, S.prevCap or 60) end }) -- unknown previous cap restores to 60
add({ key = "quality", tab = "SYSTEM", tier = 3, name = "Graphics quality level 1", avail = function() return CAP.quality end,
	desc = "Executor-dependent. Previous level restored on OFF.",
	enable = function() return Prop.set("quality", settings().Rendering, "QualityLevel", Enum.QualityLevel.Level01) end,
	disable = function() Prop.release("quality") end })
add({ key = "manualGC", tab = "SYSTEM", tier = 3, kind = "button", name = "Lua GC (one-shot)",
	desc = "One collectgarbage pass. Frees Lua heap only, not engine memory.",
	run = function()
		local before = collectgarbage("count") / 1024
		local ok, err = pcall(collectgarbage, "collect")
		if not ok then S.note = "GC blocked here."; logErr("gc: " .. tostring(err))
		else S.note = string.format("Lua heap %.1f -> %.1f MB", before, collectgarbage("count") / 1024) end
		updateHome()
	end })

local function runScan()
	if S.scanning then return end
	S.scanning = true
	local token = { cancel = false }; S.scanToken = token
	local c = { total = 0, parts = 0, unanch = 0, emit = 0, trails = 0, beams = 0, lights = 0, fx = 0 }
	S.note = "Scanning..."; updateHome()
	task.spawn(function()
		local done = traverse(token, function(i)
			c.total += 1
			local cn = i.ClassName
			if cn == "ParticleEmitter" then c.emit += 1
			elseif cn == "Trail" then c.trails += 1
			elseif cn == "Beam" then c.beams += 1
			elseif i:IsA("BasePart") then c.parts += 1; if not i.Anchored then c.unanch += 1 end
			elseif i:IsA("Light") then c.lights += 1
			elseif i:IsA("PostEffect") then c.fx += 1 end
		end)
		S.scanning = false
		if done then S.scan = c; S.note = "Scan done."; updateHome(); updateDiagLabels() end
	end)
end
add({ key = "scan", tab = "DIAG", tier = 1, kind = "button", name = "Scan instances",
	desc = "One-time batched count: parts, unanchored, emitters, lights, effects.", run = runScan })
add({ key = "baseline", tab = "DIAG", tier = 1, kind = "button", name = "Mark baseline",
	desc = "Saves current frame stats so you can compare after toggling.",
	run = function()
		local fs = frameStats()
		if not fs then S.note = "Turn Monitor on first."; updateHome() return end
		S.base = { fps = fs.fps, low1 = fs.low1, ms = fs.avgMs }
		S.note = "Baseline saved."; updateHome(); updateDiagLabels()
	end })

function Opts.set(opt, val)
	if S.unloaded or val == opt.value then return end
	if val then
		if opt.tier > S.mode then S.note = "Raise mode in CFG first."; updateHome() return end
		if opt.avail and not opt.avail() then return end
		local ok, r = pcall(opt.enable)
		if not ok then logErr(opt.key .. ": " .. tostring(r)); pcall(opt.disable) elseif r == false then pcall(opt.disable) else opt.value = true end
	else
		local ok, err = pcall(opt.disable)
		if not ok then logErr(opt.key .. " disable: " .. tostring(err)) end
		opt.value = false
	end
	if rowRefresh[opt.key] then rowRefresh[opt.key]() end
	updateHome()
end

local function restoreAll()
	for _, o in Opts.list do if o.value then Opts.set(o, false) end end
	S.note = "Everything restored."; updateHome()
end

-- ---------- UI ----------
local C = {
	bg = Color3.fromRGB(18, 20, 26), row = Color3.fromRGB(29, 32, 41), accent = Color3.fromRGB(70, 140, 255),
	on = Color3.fromRGB(52, 178, 112), off = Color3.fromRGB(62, 66, 80), text = Color3.fromRGB(235, 237, 242),
	sub = Color3.fromRGB(145, 152, 170), red = Color3.fromRGB(200, 70, 70),
}
local TAG = { "", ' <font color="#ffb347">AGGR</font>', ' <font color="#ff6b6b">EXP</font>' }

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in props do o[k] = v end
	o.Parent = parent
	return o
end
local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r) }, o) end

local gui = Instance.new("ScreenGui")
gui.Name = "RobloxMaxUI"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true; gui.DisplayOrder = 999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
do
	local parent
	if CAP.gethui then local ok, h = pcall(gethui); if ok then parent = h end end
	local placed = false
	if parent then placed = pcall(function() gui.Parent = parent end) end
	if not placed then placed = pcall(function() gui.Parent = game:GetService("CoreGui") end) end
	if not placed then gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end
end

local win = new("Frame", { Name = "Window", Size = UDim2.fromOffset(300, 300), Position = UDim2.fromOffset(16, 48),
	BackgroundColor3 = C.bg, BorderSizePixel = 0, Active = true }, gui)
corner(win, 10)
local float = new("TextButton", { Name = "Float", Size = UDim2.fromOffset(44, 44), Position = UDim2.fromOffset(16, 48),
	BackgroundColor3 = C.accent, TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 14,
	Text = "RM", AutoButtonColor = false, Visible = false, Active = true, ZIndex = 10 }, gui)
corner(float, 22)
ui.win = win

local dragConns = {}
local function clampPos(target, x, y)
	local gs = gui.AbsoluteSize
	local w, h = target.Size.X.Offset, target.Size.Y.Offset
	return math.clamp(x, 0, math.max(0, gs.X - w)), math.clamp(y, 0, math.max(0, gs.Y - h))
end
local function makeDraggable(handle, target, onTap)
	track(handle.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t ~= Enum.UserInputType.Touch and t ~= Enum.UserInputType.MouseButton1 then return end
		local startPos = input.Position
		local ox, oy = target.Position.X.Offset, target.Position.Y.Offset
		local moved = false
		local moveConn, endConn
		moveConn = UIS.InputChanged:Connect(function(i)
			if i ~= input and i.UserInputType ~= Enum.UserInputType.MouseMovement then return end
			local d = i.Position - startPos
			if not moved and math.abs(d.X) + math.abs(d.Y) < 8 then return end
			moved = true
			local x, y = clampPos(target, ox + d.X, oy + d.Y)
			target.Position = UDim2.fromOffset(x, y)
		end)
		endConn = input.Changed:Connect(function()
			if input.UserInputState ~= Enum.UserInputState.End then return end
			moveConn:Disconnect(); endConn:Disconnect()
			dragConns[moveConn] = nil; dragConns[endConn] = nil
			if not moved and onTap then onTap() end
		end)
		dragConns[moveConn] = true; dragConns[endConn] = true
	end))
end
track(gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	for _, f in { win, float } do
		local x, y = clampPos(f, f.Position.X.Offset, f.Position.Y.Offset)
		f.Position = UDim2.fromOffset(x, y)
	end
end))

-- header
local header = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1 }, win)
local dragArea = new("Frame", { Size = UDim2.new(1, -44, 1, 0), BackgroundTransparency = 1, Active = true }, header)
new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -10, 1, 0),
	Font = Enum.Font.GothamBold, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.text,
	Text = "ROBLOX MAX  v" .. VERSION }, dragArea)
local minBtn = new("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0),
	Size = UDim2.fromOffset(36, 28), BackgroundColor3 = C.off, TextColor3 = C.text, Font = Enum.Font.GothamBold,
	TextSize = 16, Text = "-", AutoButtonColor = false }, header)
corner(minBtn, 6)

local function minimize()
	local x, y = clampPos(float, win.Position.X.Offset, win.Position.Y.Offset)
	float.Position = UDim2.fromOffset(x, y)
	win.Visible = false; float.Visible = true
end
local function restore()
	float.Visible = false; win.Visible = true
	refreshStats(); updateDiagLabels()
end
makeDraggable(dragArea, win)
makeDraggable(float, float, restore)
track(minBtn.Activated:Connect(minimize))

-- tabs + pages (built once, only toggled)
local TABS = { "HOME", "RENDER", "SYSTEM", "DIAG", "CFG" }
local tabBar = new("Frame", { Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 }, win)
local pages, tabBtns, pageOrder = {}, {}, {}
local function nextOrder(name) pageOrder[name] = (pageOrder[name] or 0) + 1 return pageOrder[name] end
local function selectTab(name)
	S.tab = name
	for n, p in pages do p.Visible = (n == name); tabBtns[n].BackgroundColor3 = (n == name) and C.accent or C.row end
	if name == "DIAG" then updateDiagLabels() end
end
for i, name in TABS do
	local b = new("TextButton", { Position = UDim2.new(0.2 * (i - 1), 2, 0, 0), Size = UDim2.new(0.2, -4, 1, -2),
		BackgroundColor3 = C.row, TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 10, Text = name,
		AutoButtonColor = false }, tabBar)
	corner(b, 6)
	tabBtns[name] = b
	track(b.Activated:Connect(function() selectTab(name) end))
	local sf = new("ScrollingFrame", { Name = name, BackgroundTransparency = 1, BorderSizePixel = 0,
		Position = UDim2.fromOffset(4, 66), Size = UDim2.new(1, -8, 1, -70), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 3, Visible = false }, win)
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, sf)
	pages[name] = sf
end

local function infoLabel(page, text)
	return new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -6, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		Font = Enum.Font.Gotham, TextSize = 11, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.sub, Text = text, LayoutOrder = nextOrder(page.Name) }, page)
end

local function buildRow(page, opt)
	local row = new("Frame", { Size = UDim2.new(1, -6, 0, 54), BackgroundColor3 = C.row, BorderSizePixel = 0,
		LayoutOrder = nextOrder(page.Name) }, page)
	corner(row, 8)
	local nameL = new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 5), Size = UDim2.new(1, -72, 0, 16),
		Font = Enum.Font.GothamMedium, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.text,
		RichText = true, Text = opt.name }, row)
	new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 22), Size = UDim2.new(1, -72, 0, 28),
		Font = Enum.Font.Gotham, TextSize = 10, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.sub, Text = opt.desc }, row)
	local btn = new("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(52, 32),
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 11, AutoButtonColor = false }, row)
	corner(btn, 6)
	local function refresh()
		local locked = opt.tier > S.mode
		local na = opt.avail and not opt.avail()
		local txt = opt.name .. TAG[opt.tier]
		local cnt = Prop.count[opt.key]
		if opt.value and cnt then txt ..= ' <font color="#8892a6">- ' .. cnt .. '</font>' end
		nameL.Text = txt
		if na then btn.Text = "N/A"; btn.BackgroundColor3 = C.off
		elseif locked then btn.Text = "LOCK"; btn.BackgroundColor3 = C.off
		elseif opt.kind == "button" then btn.Text = "RUN"; btn.BackgroundColor3 = C.accent
		else btn.Text = opt.value and "ON" or "OFF"; btn.BackgroundColor3 = opt.value and C.on or C.off end
	end
	rowRefresh[opt.key] = refresh
	track(btn.Activated:Connect(function()
		if (opt.avail and not opt.avail()) then return end
		if opt.tier > S.mode then S.note = "Raise mode in CFG first."; updateHome() return end
		if opt.kind == "button" then local ok, err = pcall(opt.run); if not ok then logErr(err) end
		else Opts.set(opt, not opt.value) end
	end))
	refresh()
end

local function buttonRow(page, labelFn, onClick, color)
	local b = new("TextButton", { Size = UDim2.new(1, -6, 0, 36), BackgroundColor3 = color or C.row, TextColor3 = C.text,
		Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = false, Text = labelFn(), LayoutOrder = nextOrder(page.Name) }, page)
	corner(b, 8)
	track(b.Activated:Connect(function() onClick(); b.Text = labelFn() end))
	return b
end

-- HOME
ui.homeA = infoLabel(pages.HOME, "")
ui.homeB = infoLabel(pages.HOME, "FPS N/A  |  frame N/A  (Monitor is OFF)")
buildRow(pages.HOME, Opts.byKey.monitor)
buttonRow(pages.HOME, function() return "Restore everything" end, restoreAll)
-- RENDER / SYSTEM / DIAG
for _, o in Opts.list do if o.tab ~= "HOME" then buildRow(pages[o.tab], o) end end
infoLabel(pages.SYSTEM, "Client scripts can't change CPU/GPU clocks, thermals, native texture memory or server load. Physics = diagnostics only (see DIAG).")
-- DIAG labels (placed after rows via LayoutOrder)
ui.frameL = infoLabel(pages.DIAG, "Frame stats: turn Monitor on (HOME).")
ui.memL = infoLabel(pages.DIAG, "")
ui.scanL = infoLabel(pages.DIAG, "Instances: run a scan.")
ui.ovL = infoLabel(pages.DIAG, "")
ui.errL = infoLabel(pages.DIAG, "")
-- CFG
local INTERVALS, CAPS = { 0.5, 1, 2 }, { 30, 45, 60, 90 }
local function cycle(list, v) for i, x in list do if x == v then return list[i % #list + 1] end end return list[1] end
buttonRow(pages.CFG, function() return "Mode: " .. MODE_NAMES[S.mode] .. " (tap to change)" end, function()
	S.mode = S.mode % 3 + 1
	for _, o in Opts.list do if o.tier > S.mode and o.value then Opts.set(o, false) end end
	for _, r in rowRefresh do r() end
	updateHome()
end)
buttonRow(pages.CFG, function() return "Monitor interval: " .. S.interval .. "s" end, function()
	S.interval = cycle(INTERVALS, S.interval)
	if Sched.jobs.ui then Sched.jobs.ui.every = S.interval end
end)
buttonRow(pages.CFG, function() return "FPS cap value: " .. S.fpsCap end, function()
	S.fpsCap = cycle(CAPS, S.fpsCap)
	if Opts.byKey.fpsCap.value then pcall(setfpscap, S.fpsCap) end
end)
buttonRow(pages.CFG, function() return "Restore everything" end, restoreAll)
local RM = { Version = VERSION, Capabilities = CAP }
buttonRow(pages.CFG, function() return "Unload ROBLOX MAX" end, function() RM.Unload() end, C.red)
infoLabel(pages.CFG, "Settings are session-only. Nothing auto-applies on load.")

-- live labels
local function f(fmt, ...) return string.format(fmt, ...) end
function updateHome()
	if not ui.built then return end
	local n = 0
	for _, o in Opts.list do if o.value then n += 1 end end
	ui.homeA.Text = f("Mode %s  |  %d active\n%s", MODE_NAMES[S.mode], n, S.note or "Idle: nothing applied.")
	for _, r in rowRefresh do r() end
end
function updateDiagLabels()
	if not ui.built or not win.Visible then return end
	local ok, tot = pcall(Stats.GetTotalMemoryUsageMb, Stats)
	ui.memL.Text = f("Lua heap %.1f MB (script memory only)\nClient total: %s (approx, from Stats)", collectgarbage("count") / 1024,
		ok and f("%.0f MB", tot) or "N/A")
	local sc = S.scan
	ui.scanL.Text = sc and f("Instances %d | parts %d (unanchored %d)\nemitters %d | trails %d | beams %d\nlights %d | effects %d  (as of last scan)",
		sc.total, sc.parts, sc.unanch, sc.emit, sc.trails, sc.beams, sc.lights, sc.fx) or "Instances: run a scan."
	local jobs = 0
	for _ in Sched.jobs do jobs += 1 end
	ui.ovL.Text = f("Optimizer: jobs %d | conns %d | processed %d\nfailed writes %d | failed restores %d | errors %d",
		jobs, #S.conns + #Hub.conns + (Sched.conn and 1 or 0), stats.processed, stats.failed, stats.restoreFailed, stats.errors)
	ui.errL.Text = #errLog > 0 and ("Last error: " .. errLog[#errLog]) or "No errors logged."
end
function refreshStats()
	if not ui.built then return end
	local fs = frameStats()
	if not Opts.byKey.monitor.value then
		ui.homeB.Text = "FPS N/A  |  frame N/A  (Monitor is OFF)"
		ui.frameL.Text = "Frame stats: turn Monitor on (HOME)."
	elseif not fs then
		ui.homeB.Text = "Collecting frames..."
	elseif win.Visible then
		ui.homeB.Text = f("FPS %.0f  |  frame %.1f ms  |  1%% low %.0f", fs.fps, fs.avgMs, fs.low1)
		local t = f("Avg %.1f ms | median %.1f | jitter %.1f\nFPS %.0f | 1%% low %.0f  (last %d frames)", fs.avgMs, fs.medMs, fs.jitterMs, fs.fps, fs.low1, fs.n)
		if S.base then t ..= f("\nBaseline: %.0f fps, 1%% low %.0f, %.1f ms. One reading is not proof; compare in the same scene.", S.base.fps, S.base.low1, S.base.ms) end
		ui.frameL.Text = t
	end
	updateDiagLabels()
end

ui.built = true
selectTab("HOME")
updateHome()

-- ---------- lifecycle ----------
function RM.Enable(key) local o = Opts.byKey[key]; if o and o.kind == "toggle" then Opts.set(o, true) end end
function RM.Disable(key) local o = Opts.byKey[key]; if o and o.kind == "toggle" then Opts.set(o, false) end end
RM.RestoreAll = restoreAll
function RM.Unload()
	if S.unloaded then return end
	pcall(restoreAll)
	S.unloaded = true
	if S.scanToken then S.scanToken.cancel = true end
	for owner in Hub.owners do Hub.remove(owner) end
	Sched.hook = nil; Sched.jobs = {}; schedEnsure()
	for _, c in S.conns do pcall(function() c:Disconnect() end) end
	for c in dragConns do pcall(function() c:Disconnect() end) end
	S.conns = {}; dragConns = {}
	pcall(function() gui:Destroy() end)
	if G.ROBLOX_MAX == RM then G.ROBLOX_MAX = nil end
end
G.ROBLOX_MAX = RM