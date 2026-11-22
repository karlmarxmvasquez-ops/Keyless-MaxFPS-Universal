--[[
============================================================
 INDUSTRIALIST MAX V23 | RAM-FIRST + FPS
 Client-side visual optimizer for Roblox / Delta
============================================================
 Design:
 - RAM reduction is the primary goal; FPS optimization is included.
 - Every optimization starts OFF.
 - No Workspace scan, no world event hooks, and no worker at startup.
 - Scans only start when a relevant option is enabled.
 - One bounded depth-first scanner; no GetDescendants() mega-array.
 - Tracks only objects/properties required by active features.
 - No duplicate watchdogs, periodic full audits, or giant spatial indexes.
 - Restores modified properties on disable/stop.
 
 IMPORTANT:
 Visual changes may reduce rendering/asset pressure, but hiding a part,
 disabling a texture, or changing a material does NOT guarantee that
 Roblox unloads its mesh/texture from engine memory. LuaHeap is not total
 Roblox/Android RAM. Streaming and asset residency are engine-controlled.
 Executor compatibility varies. This script is not runtime-tested here.
============================================================
]]

local G = _G
local VERSION = "V23"
local T0 = os.clock()

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
if not Player then return end

local CFG = {
    Culling = false,
    RenderDistance = 96,
    RemoveFoliage = false,
    SimpleMaterials = false,
    RemoveTextures = false,
    RemoveParticles = false,
    RemoveTrails = false,
    RemoveLights = false,
    RemoveShadows = false,
    RemoveReflections = false,
    RemovePostFX = false,
    RemoveEnvironment = false,
    RemoveBillboards = false,
    HideTerrainGrass = false,
    SimpleWater = false,
    CompatLighting = false,
    FPSMonitor = false,
}
local MAX = {}
G.INDUSTRIALIST_MAX = MAX

local running, paused = true, false
local records = {}
local recordCount = 0
local scanFrames, scanDepth = {}, 0
local scanning, scanVisited = false, 0
local connections = {}
local globalOriginals = {}
local rootPart
local fpsNow, fpsConn = 0, nil
local lastError = "none"
local errors = 0
local panelGui, panelFrame, statusLabel
local logLines = {}
local function log(s)
    local line = string.format("[MAX %.1fs] %s", os.clock()-T0, tostring(s))
    logLines[#logLines+1] = line
    if #logLines > 30 then table.remove(logLines,1) end
    print(line)
end
local function problem(s)
    lastError = tostring(s)
    errors += 1
    warn("[MAX] "..lastError)
end
local function connect(signal, fn)
    local ok, c = pcall(function() return signal:Connect(fn) end)
    if ok and c then connections[#connections+1] = c end
end
local function getHeapKB()
    if type(collectgarbage) == "function" then
        local ok,v = pcall(collectgarbage,"count")
        if ok and type(v)=="number" then return v end
    end
    if type(gcinfo)=="function" then
        local ok,v = pcall(gcinfo)
        if ok and type(v)=="number" then return v end
    end
    return nil
end
local function getTotalMB()
    local ok,v = pcall(function() return Stats:GetTotalMemoryUsageMb() end)
    if ok and type(v)=="number" then return v end
    return nil
end
local function anyVisualOption()
    for k,v in pairs(CFG) do
        if k ~= "RenderDistance" and k ~= "FPSMonitor" and v == true then return true end
    end
    return false
end
local function cullingOption()
    return CFG.Culling
end
local function wantsPart()
    return CFG.Culling or CFG.RemoveFoliage or CFG.SimpleMaterials or CFG.RemoveTextures
        or CFG.RemoveShadows or CFG.RemoveReflections
end
local function wantsClass(obj)
    if obj:IsA("BasePart") then return wantsPart() end
    if obj:IsA("Decal") or obj:IsA("Texture") then return CFG.RemoveTextures end
    if obj:IsA("ParticleEmitter") or obj:IsA("Fire") or obj:IsA("Smoke") or obj:IsA("Sparkles") then return CFG.RemoveParticles end
    if obj:IsA("Trail") or obj:IsA("Beam") then return CFG.RemoveTrails end
    if obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight") then return CFG.RemoveLights end
    if obj:IsA("PostEffect") then return CFG.RemovePostFX end
    if obj:IsA("Atmosphere") or obj:IsA("Clouds") then return CFG.RemoveEnvironment end
    if obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then return CFG.RemoveBillboards end
    return false
end
local foliageWords = {"grass","foliage","leaf","leaves","plant","weed","bush","flower","vegetation","shrub"}
local function isFoliage(obj)
    local name = string.lower(obj.Name)
    for i=1,#foliageWords do
        if string.find(name,foliageWords[i],1,true) then return true end
    end
    return false
end
local function getOrigin()
    local char = Player.Character
    if char then
        local r = char:FindFirstChild("HumanoidRootPart")
        if r then rootPart = r end
    end
    if rootPart and rootPart.Parent then
        local ok,p = pcall(function() return rootPart.Position end)
        if ok then return p end
    end
    local cam = Workspace.CurrentCamera
    if cam then return cam.CFrame.Position end
    return nil
end
local function setSaved(rec,obj,prop,value)
    local ok,current = pcall(function() return obj[prop] end)
    if not ok or current == value then return end
    rec.Original = rec.Original or {}
    if rec.Original[prop] == nil then rec.Original[prop] = current end
    pcall(function() obj[prop] = value end)
end
local function restore(rec)
    if not rec or not rec.Original then return end
    local obj = rec.Obj
    if obj then
        for prop,value in pairs(rec.Original) do
            pcall(function()
                if obj[prop] ~= value then obj[prop] = value end
            end)
        end
    end
    rec.Original = nil
end
local function applyObject(obj)
    if not running or paused or not obj or not obj.Parent then return end
    if records[obj] then return end
    if not wantsClass(obj) then return end
    local char = Player.Character
    if char and (obj == char or obj:IsDescendantOf(char)) then return end
    local rec = {Obj=obj}
    if obj:IsA("BasePart") then
        if CFG.RemoveFoliage and isFoliage(obj) then
            setSaved(rec,obj,"LocalTransparencyModifier",1)
        end
        if CFG.Culling then
            local origin = getOrigin()
            if origin then
                local ok,pos = pcall(function() return obj.Position end)
                if ok and (pos-origin).Magnitude > CFG.RenderDistance then
                    setSaved(rec,obj,"LocalTransparencyModifier",1)
                end
            end
        end
        if CFG.SimpleMaterials then setSaved(rec,obj,"Material",Enum.Material.Plastic) end
        if CFG.RemoveTextures then
            pcall(function() setSaved(rec,obj,"MaterialVariant","") end)
            if obj:IsA("MeshPart") then pcall(function() setSaved(rec,obj,"TextureID","") end) end
        end
        if CFG.RemoveShadows then setSaved(rec,obj,"CastShadow",false) end
        if CFG.RemoveReflections then setSaved(rec,obj,"Reflectance",0) end
    elseif obj:IsA("Decal") or obj:IsA("Texture") then
        setSaved(rec,obj,"Transparency",1)
    elseif obj:IsA("ParticleEmitter") or obj:IsA("Fire") or obj:IsA("Smoke") or obj:IsA("Sparkles")
        or obj:IsA("Trail") or obj:IsA("Beam") or obj:IsA("PointLight") or obj:IsA("SpotLight")
        or obj:IsA("SurfaceLight") or obj:IsA("PostEffect") or obj:IsA("BillboardGui") or obj:IsA("SurfaceGui") then
        setSaved(rec,obj,"Enabled",false)
    elseif obj:IsA("Atmosphere") then
        setSaved(rec,obj,"Density",0)
        setSaved(rec,obj,"Haze",0)
        setSaved(rec,obj,"Glare",0)
    elseif obj:IsA("Clouds") then
        setSaved(rec,obj,"Enabled",false)
    end
    if rec.Original then
        records[obj] = rec
        recordCount += 1
    end
end
local function removeObject(obj)
    local rec = records[obj]
    if not rec then return end
    restore(rec)
    records[obj] = nil
    recordCount = math.max(0,recordCount-1)
    rec.Obj = nil
end
local function clearTracking()
    for obj,rec in pairs(records) do
        restore(rec)
        rec.Obj = nil
        records[obj] = nil
    end
    recordCount = 0
    scanFrames,scanDepth = {},0
    scanning = false
end
local function pushChildren(parent)
    local ok,children = pcall(function() return parent:GetChildren() end)
    if ok and #children > 0 then
        scanDepth += 1
        scanFrames[scanDepth] = {items=children,index=1,count=#children}
    end
end
local function scanWorker()
    if scanning or not running or paused or not anyVisualOption() then return end
    scanning = true
    scanVisited = 0
    scanFrames,scanDepth = {},0
    pushChildren(Workspace)
    pushChildren(Lighting)
    while running and not paused and scanDepth > 0 do
        local started = os.clock()
        local steps = 0
        while scanDepth > 0 and steps < 55 and os.clock()-started < 0.0025 do
            local frame = scanFrames[scanDepth]
            if not frame or frame.index > frame.count then
                scanFrames[scanDepth] = nil
                scanDepth -= 1
            else
                local obj = frame.items[frame.index]
                frame.items[frame.index] = nil
                frame.index += 1
                steps += 1
                scanVisited += 1
                if obj and obj.Parent then
                    applyObject(obj)
                    pushChildren(obj)
                end
            end
        end
        task.wait()
    end
    scanFrames,scanDepth = {},0
    scanning = false
    log("Feature scan complete: "..scanVisited.." visited; "..recordCount.." objects modified")
end
local function disconnectWorld()
    for i=#connections,1,-1 do
        local c = connections[i]
        if c then pcall(function() c:Disconnect() end) end
        connections[i] = nil
    end
end
local function connectWorld()
    disconnectWorld()
    if not anyVisualOption() then return end
    connect(Workspace.DescendantAdded,function(obj)
        if running and not paused then applyObject(obj) end
    end)
    connect(Workspace.DescendantRemoving,function(obj) removeObject(obj) end)
    connect(Lighting.DescendantAdded,function(obj)
        if running and not paused then applyObject(obj) end
    end)
    connect(Lighting.DescendantRemoving,function(obj) removeObject(obj) end)
    connect(Player.CharacterAdded,function()
        rootPart = nil
    end)
end
local function applyGlobal(key,obj,prop,value)
    local id = key
    if value == nil then
        local old = globalOriginals[id]
        if old then
            pcall(function() obj[prop] = old.value end)
            globalOriginals[id] = nil
        end
        return
    end
    if not globalOriginals[id] then
        local ok,current = pcall(function() return obj[prop] end)
        if ok then globalOriginals[id] = {obj=obj,prop=prop,value=current} end
    end
    pcall(function() obj[prop] = value end)
end
local function applyGlobals()
    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if terrain then
        applyGlobal("TerrainDecoration",terrain,"Decoration",CFG.HideTerrainGrass and false or nil)
        if CFG.SimpleWater then
            applyGlobal("WaterWaveSize",terrain,"WaterWaveSize",0)
            applyGlobal("WaterWaveSpeed",terrain,"WaterWaveSpeed",0)
            applyGlobal("WaterReflectance",terrain,"WaterReflectance",0)
        else
            applyGlobal("WaterWaveSize",terrain,"WaterWaveSize",nil)
            applyGlobal("WaterWaveSpeed",terrain,"WaterWaveSpeed",nil)
            applyGlobal("WaterReflectance",terrain,"WaterReflectance",nil)
        end
    end
    if CFG.CompatLighting then
        local ok,current = pcall(function() return Lighting.Technology end)
        if ok and Enum.Technology.Compatibility then
            if not globalOriginals.Technology then globalOriginals.Technology={obj=Lighting,prop="Technology",value=current} end
            pcall(function() Lighting.Technology=Enum.Technology.Compatibility end)
        end
    elseif globalOriginals.Technology then
        local old=globalOriginals.Technology
        pcall(function() old.obj[old.prop]=old.value end)
        globalOriginals.Technology=nil
    end
end
local function restoreGlobals()
    for key,old in pairs(globalOriginals) do
        pcall(function() old.obj[old.prop]=old.value end)
        globalOriginals[key]=nil
    end
end
local function statusText()
    local heap=getHeapKB()
    local total=getTotalMB()
    return string.format("%s | %d FPS\nRAM metric: %s MB total\nLua heap: %s KB\nModified: %d | Scan: %s (%d)\nErrors: %d",
        paused and "PAUSED" or (running and "RUNNING" or "STOPPED"),
        math.floor(fpsNow+0.5),total and string.format("%.0f",total) or "n/a",
        heap and tostring(math.floor(heap)) or "n/a",recordCount,
        scanning and "active" or "idle",scanVisited,errors)
end
function MAX.Status()
    return {Version=VERSION,Running=running,Paused=paused,ModifiedObjects=recordCount,
        Scanning=scanning,ScanVisited=scanVisited,LuaHeapKB=getHeapKB(),
        TotalMemoryMB=getTotalMB(),FPS=fpsNow,Errors=errors,LastError=lastError,
        Options=CFG}
end
function MAX.Diagnostics()
    print("========== INDUSTRIALIST MAX "..VERSION.." ==========")
    for i=1,#logLines do print(logLines[i]) end
    for k,v in pairs(MAX.Status()) do print(k,v) end
    return statusText()
end
function MAX.SetOption(key,value)
    if type(CFG[key])~="boolean" then return false end
    value=value==true
    if CFG[key]==value then return true end
    CFG[key]=value
    if key=="FPSMonitor" then
        if value then
            if fpsConn then fpsConn:Disconnect() end
            local elapsed,frames=0,0
            fpsConn=RunService.Heartbeat:Connect(function(dt)
                if not running then return end
                elapsed+=dt
                frames+=1
                if elapsed>=1 then fpsNow=frames/elapsed; elapsed,frames=0,0 end
            end)
        elseif fpsConn then
            pcall(function() fpsConn:Disconnect() end)
            fpsConn=nil
            fpsNow=0
        end
        return true
    end
    if key=="HideTerrainGrass" or key=="SimpleWater" or key=="CompatLighting" then
        applyGlobals()
    end
    clearTracking()
    disconnectWorld()
    if anyVisualOption() then
        connectWorld()
        task.spawn(scanWorker)
    else
        restoreGlobals()
    end
    log("Option "..key.." = "..tostring(value))
    return true
end
function MAX.SetDistance(n)
    n=tonumber(n)
    if not n or n~=n then return false end
    CFG.RenderDistance=math.clamp(math.floor(n),0,512)
    if CFG.Culling then
        clearTracking()
        connectWorld()
        task.spawn(scanWorker)
    end
    return true
end
function MAX.Pause()
    if not running or paused then return end
    paused=true
    clearTracking()
    restoreGlobals()
    disconnectWorld()
    log("Paused; modified properties restored")
end
function MAX.Resume()
    if not running or not paused then return end
    paused=false
    if anyVisualOption() then
        connectWorld()
        task.spawn(scanWorker)
    end
    applyGlobals()
    log("Resumed")
end
function MAX.Stop(sync)
    if not running then return end
    running=false
    paused=false
    if fpsConn then pcall(function() fpsConn:Disconnect() end); fpsConn=nil end
    disconnectWorld()
    clearTracking()
    restoreGlobals()
    if panelGui then pcall(function() panelGui:Destroy() end); panelGui=nil end
    panelFrame,statusLabel=nil,nil
    G.INDUSTRIALIST_MAX=nil
    log("Stopped and restored")
end
MAX.Restore=MAX.Stop

local COLORS={bg=Color3.fromRGB(20,21,27),row=Color3.fromRGB(36,38,47),text=Color3.fromRGB(235,237,242),
    dim=Color3.fromRGB(160,165,178),accent=Color3.fromRGB(90,150,255),on=Color3.fromRGB(50,145,90),
    off=Color3.fromRGB(75,78,90),danger=Color3.fromRGB(170,55,55)}
local function make(class,props,parent)
    local obj=Instance.new(class)
    for k,v in pairs(props) do obj[k]=v end
    obj.Parent=parent
    return obj
end
local function round(obj,r)
    make("UICorner",{CornerRadius=UDim.new(0,r or 6)},obj)
end
local function buildUI()
    local parent
    local ok,h=pcall(function()
        if type(gethui)=="function" then return gethui() end
        return Player:FindFirstChildOfClass("PlayerGui")
    end)
    if ok then parent=h end
    if not parent then problem("GUI parent unavailable"); return end
    local gui=make("ScreenGui",{Name="IndustrialistMaxV23",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=999},parent)
    panelGui=gui
    local panel=make("Frame",{Size=UDim2.new(0,300,1,-70),Position=UDim2.new(0.5,-150,0,38),
        BackgroundColor3=COLORS.bg,BorderSizePixel=0},gui)
    panelFrame=panel
    round(panel,9)
    make("TextLabel",{Size=UDim2.new(1,-45,0,30),Position=UDim2.fromOffset(10,0),BackgroundTransparency=1,
        Text="INDUSTRIALIST MAX V23",TextColor3=COLORS.text,Font=Enum.Font.GothamBold,TextSize=13,
        TextXAlignment=Enum.TextXAlignment.Left},panel)
    local close=make("TextButton",{Size=UDim2.fromOffset(30,26),Position=UDim2.new(1,-34,0,2),
        BackgroundColor3=COLORS.danger,Text="X",TextColor3=COLORS.text,Font=Enum.Font.GothamBold,TextSize=12},panel)
    round(close)
    close.Activated:Connect(function() panel.Visible=false end)
    statusLabel=make("TextLabel",{Size=UDim2.new(1,-16,0,82),Position=UDim2.fromOffset(8,32),
        BackgroundTransparency=1,Text=statusText(),TextColor3=COLORS.dim,Font=Enum.Font.Code,TextSize=10,
        TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top},panel)
    local scroll=make("ScrollingFrame",{Size=UDim2.new(1,-8,1,-120),Position=UDim2.fromOffset(4,116),
        BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=4,AutomaticCanvasSize=Enum.AutomaticSize.Y,
        CanvasSize=UDim2.new(),ScrollingDirection=Enum.ScrollingDirection.Y},panel)
    make("UIListLayout",{Padding=UDim.new(0,4),SortOrder=Enum.SortOrder.LayoutOrder},scroll)
    local function header(s)
        make("TextLabel",{Size=UDim2.new(1,0,0,22),BackgroundTransparency=1,Text=s,TextColor3=COLORS.accent,
            Font=Enum.Font.GothamBold,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left},scroll)
    end
    local function toggle(key,label)
        local row=make("Frame",{Size=UDim2.new(1,0,0,32),BackgroundColor3=COLORS.row},scroll); round(row)
        make("TextLabel",{Size=UDim2.new(1,-70,1,0),Position=UDim2.fromOffset(8,0),BackgroundTransparency=1,
            Text=label,TextColor3=COLORS.text,Font=Enum.Font.Gotham,TextSize=10,TextWrapped=true,
            TextXAlignment=Enum.TextXAlignment.Left},row)
        local b=make("TextButton",{Size=UDim2.fromOffset(50,23),Position=UDim2.new(1,-56,0.5,-11),
            BackgroundColor3=COLORS.off,Text="OFF",TextColor3=COLORS.text,Font=Enum.Font.GothamBold,TextSize=10},row)
        round(b,12)
        local function paint()
            b.Text=CFG[key] and "ON" or "OFF"
            b.BackgroundColor3=CFG[key] and COLORS.on or COLORS.off
        end
        b.Activated:Connect(function() MAX.SetOption(key,not CFG[key]); paint() end)
    end
    local function action(label,fn,color)
        local b=make("TextButton",{Size=UDim2.new(1,0,0,29),BackgroundColor3=color or COLORS.row,
            Text=label,TextColor3=COLORS.text,Font=Enum.Font.GothamBold,TextSize=10},scroll)
        round(b)
        b.Activated:Connect(function()
            local good,err=pcall(fn)
            if not good then problem(err) end
        end)
    end
    header("RAM + VISUAL REDUCTION")
    toggle("Culling","Hide objects beyond render distance")
    local dist=make("TextBox",{Size=UDim2.new(1,0,0,28),BackgroundColor3=COLORS.row,Text="96",
        PlaceholderText="Render distance 0-512",TextColor3=COLORS.text,Font=Enum.Font.Code,TextSize=11,
        ClearTextOnFocus=false},scroll); round(dist)
    dist.FocusLost:Connect(function() MAX.SetDistance(dist.Text); dist.Text=tostring(CFG.RenderDistance) end)
    toggle("RemoveFoliage","Hide foliage by object name")
    toggle("SimpleMaterials","Force plastic materials")
    toggle("RemoveTextures","Hide decals / textures / mesh textures")
    toggle("RemoveParticles","Disable particles, fire, smoke")
    toggle("RemoveTrails","Disable trails and beams")
    toggle("RemoveLights","Disable local lights")
    toggle("RemoveShadows","Disable cast shadows")
    toggle("RemoveReflections","Remove part reflections")
    toggle("RemovePostFX","Disable post-processing")
    toggle("RemoveEnvironment","Reduce atmosphere and clouds")
    toggle("RemoveBillboards","Hide billboard / surface GUIs")
    header("TERRAIN / LIGHTING")
    toggle("HideTerrainGrass","Disable terrain decoration")
    toggle("SimpleWater","Reduce water waves / reflections")
    toggle("CompatLighting","Compatibility lighting (experimental)")
    header("MONITORING")
    toggle("FPSMonitor","FPS counter (adds a Heartbeat hook)")
    action("PAUSE + RESTORE",function() MAX.Pause() end)
    action("RESUME",function() MAX.Resume() end)
    action("DIAGNOSTICS",function() MAX.Diagnostics() end)
    action("EMERGENCY RESTORE",function() MAX.Stop(true) end,COLORS.danger)
    log("V23 panel ready")
end

log("V23 starting. All options OFF; no world scan or worker started.")
task.spawn(function()
    local ok,err=pcall(buildUI)
    if not ok then problem("UI build: "..tostring(err)) end
end)
task.spawn(function()
    while running do
        task.wait(1)
        if statusLabel and statusLabel.Parent then
            pcall(function() statusLabel.Text=statusText() end)
        end
    end
end)

do
    local url="https://raw.githubusercontent.com/karlmarxmvasquez-ops/Keyless-MaxFPS-Universal/main/Industrialist_MAX_V23.lua"
    local q=queue_on_teleport
    if type(q)~="function" and type(syn)=="table" then q=syn.queue_on_teleport end
    if type(q)=="function" then
        pcall(q,'loadstring(game:HttpGet("'..url..'"))()')
    end
end

print("==========================================")
print(" INDUSTRIALIST MAX V23 RUNNING")
print(" All options OFF. No startup world scan.")
print(" Status: _G.INDUSTRIALIST_MAX.Status()")
print(" Diagnostics: _G.INDUSTRIALIST_MAX.Diagnostics()")
print(" Restore: _G.INDUSTRIALIST_MAX.Stop(true)")
print("==========================================")
