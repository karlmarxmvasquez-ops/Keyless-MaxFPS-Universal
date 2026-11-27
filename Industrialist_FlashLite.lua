--[[
    INDUSTRIALIST FLASH-LITE
    Independent lightweight blueprint toolkit.
    Version: 1.1.1
    Target: Roblox / Delta-compatible Luau environments

    Implemented:
      - Compact draggable/minimizable mobile UI
      - Bounded anchored-model capture with character/tool filtering
      - Relative-CFrame blueprint serialization (JSON)
      - Clipboard export/import with validation
      - Lightweight preview markers, rotate, clear
      - Blueprint inventory and bounds summary
      - Adjustable 3D selection volume; only catalog machines inside are copied
      - Machine paste through PlacementSystem.PlaceBind(template, CFrame)
      - Existing blueprint JSON import/export compatibility
      - Local A* grid route planner core (planning only)

    Still not implemented:
      - Pipe/cable/wire reconstruction, deletion, replacement, and world restore.
      - Paste has not yet been tested in a live Industrialist session; the server
        remains authoritative and may reject unavailable or unowned machines.
]]

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer
local VERSION = "1.0.0"
local CONFIG = {
    CaptureRadius = 120,
    MaxModels = 450,
    MaxPartsPerModel = 250,
    PreviewLimit = 180,
    Grid = 2,
    MarkerTransparency = 0.68,
    PreviewColor = Color3.fromRGB(74, 180, 255),
}

local State = {
    Blueprint = nil,
    Preview = {},
    Rotation = 0,
    Busy = false,
    Page = "BLUEPRINT",
    CaptureCount = 0,
}

local function notify(title, message, duration)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title, Text = message, Duration = duration or 3
        })
    end)
end

local function getRoot()
    local char = Player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function isCharacterModel(model)
    if not model:IsA("Model") then return true end
    if model:FindFirstChildOfClass("Humanoid") then return true end
    local parent = model.Parent
    while parent and parent ~= Workspace do
        if parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid") then
            return true
        end
        parent = parent.Parent
    end
    return false
end

local function countParts(model)
    local n = 0
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            n += 1
            if n > CONFIG.MaxPartsPerModel then break end
        end
    end
    return n
end

local function isBuildCandidate(model, origin)
    if not model:IsA("Model") or isCharacterModel(model) then return false end
    if model == Player.Character or model:FindFirstAncestorOfClass("Tool") then return false end
    local ok, pivot = pcall(function() return model:GetPivot() end)
    if not ok then return false end
    if (pivot.Position - origin).Magnitude > CONFIG.CaptureRadius then return false end
    local parts = countParts(model)
    if parts < 1 or parts > CONFIG.MaxPartsPerModel then return false end
    local anchored = false
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") and d.Anchored then anchored = true break end
    end
    return anchored, pivot, parts
end

local function cframeToArray(cf)
    return {cf:GetComponents()}
end

local function arrayToCFrame(a)
    if type(a) ~= "table" or #a ~= 12 then return nil end
    for i = 1, 12 do
        if type(a[i]) ~= "number" then return nil end
    end
    return CFrame.new(table.unpack(a))
end

local function captureBlueprint()
    if State.Busy then return end
    local root = getRoot()
    if not root then notify("Flash-Lite", "Character not ready") return end
    State.Busy = true

    local entries = {}
    local seen = {}
    local processed = 0
    local origin = root.CFrame
    local descendants = Workspace:GetDescendants()

    for i = 1, #descendants do
        local obj = descendants[i]
        if obj:IsA("Model") and not seen[obj] then
            seen[obj] = true
            local ok, pivot, parts = isBuildCandidate(obj, origin.Position)
            if ok then
                local relative = origin:ToObjectSpace(pivot)
                entries[#entries + 1] = {
                    n = obj.Name,
                    c = cframeToArray(relative),
                    p = parts,
                }
                processed += 1
                if processed >= CONFIG.MaxModels then break end
            end
        end
        if i % 450 == 0 then task.wait() end
    end

    State.Blueprint = {
        format = "FLASHLITE_IND",
        version = 1,
        created = os.time(),
        grid = CONFIG.Grid,
        count = #entries,
        entries = entries,
    }
    State.CaptureCount = #entries
    State.Busy = false
    notify("Blueprint captured", tostring(#entries) .. " anchored models scanned")
end

local function validateBlueprint(data)
    if type(data) ~= "table" or data.format ~= "FLASHLITE_IND" then
        return false, "Unrecognized blueprint format"
    end
    if type(data.entries) ~= "table" or #data.entries > CONFIG.MaxModels then
        return false, "Invalid or oversized entry list"
    end
    for i, entry in ipairs(data.entries) do
        if type(entry) ~= "table" or type(entry.n) ~= "string" or #entry.n > 120 then
            return false, "Invalid model entry at " .. i
        end
        if not arrayToCFrame(entry.c) then return false, "Invalid transform at " .. i end
    end
    return true
end

local function exportBlueprint()
    if not State.Blueprint then notify("Export", "Capture or import a blueprint first") return end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(State.Blueprint) end)
    if not ok then notify("Export failed", tostring(encoded)) return end
    if typeof(setclipboard) == "function" then
        local copied = pcall(setclipboard, encoded)
        if copied then notify("Exported", "Blueprint JSON copied to clipboard") return end
    end
    print("FLASHLITE_BLUEPRINT_BEGIN")
    print(encoded)
    print("FLASHLITE_BLUEPRINT_END")
    notify("Exported", "JSON printed to executor console")
end

local function importBlueprint(raw)
    if type(raw) ~= "string" or #raw < 10 then
        notify("Import", "Paste blueprint JSON into the import box")
        return
    end
    local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok then notify("Import failed", "JSON could not be decoded") return end
    local valid, reason = validateBlueprint(decoded)
    if not valid then notify("Import failed", reason) return end
    State.Blueprint = decoded
    State.CaptureCount = #decoded.entries
    State.Rotation = 0
    notify("Imported", tostring(#decoded.entries) .. " blueprint entries")
end

local function clearPreview()
    for i = #State.Preview, 1, -1 do
        local obj = State.Preview[i]
        if obj and obj.Parent then obj:Destroy() end
        State.Preview[i] = nil
    end
end

local function makePreview()
    if State.Busy then return end
    if not State.Blueprint then notify("Preview", "No blueprint loaded") return end
    local root = getRoot()
    if not root then notify("Preview", "Character not ready") return end
    clearPreview()
    State.Busy = true

    local folder = Instance.new("Folder")
    folder.Name = "FlashLitePreview"
    folder.Parent = Workspace
    local base = root.CFrame * CFrame.Angles(0, math.rad(State.Rotation), 0)
    local entries = State.Blueprint.entries
    local limit = math.min(#entries, CONFIG.PreviewLimit)

    for i = 1, limit do
        local entry = entries[i]
        local rel = arrayToCFrame(entry.c)
        if rel then
            local world = base * rel
            local marker = Instance.new("Part")
            marker.Name = "Preview_" .. i
            marker.Size = Vector3.new(2, 0.25, 2)
            marker.CFrame = CFrame.new(world.Position) * CFrame.Angles(0, math.rad(State.Rotation), 0)
            marker.Anchored = true
            marker.CanCollide = false
            marker.CanTouch = false
            marker.CanQuery = false
            marker.CastShadow = false
            marker.Material = Enum.Material.ForceField
            marker.Color = CONFIG.PreviewColor
            marker.Transparency = CONFIG.MarkerTransparency
            marker.Parent = folder
            State.Preview[#State.Preview + 1] = marker
        end
        if i % 40 == 0 then task.wait() end
    end
    State.Busy = false
    notify("Preview ready", tostring(limit) .. " / " .. #entries .. " markers shown")
end

local function rotateBlueprint()
    State.Rotation = (State.Rotation + 90) % 360
    notify("Rotation", tostring(State.Rotation) .. " degrees")
    if #State.Preview > 0 then makePreview() end
end

-- A* planner core. This computes a 2D grid path only; it does not place pipes.
local function planGridPath(startX, startZ, goalX, goalZ, blocked, maxNodes)
    local function key(x, z) return tostring(x) .. ":" .. tostring(z) end
    local function heuristic(x, z) return math.abs(goalX - x) + math.abs(goalZ - z) end
    local open = {{x=startX, z=startZ, g=0, f=heuristic(startX,startZ)}}
    local came, gScore, closed = {}, {[key(startX,startZ)] = 0}, {}
    local dirs = {{1,0},{-1,0},{0,1},{0,-1}}
    local visited = 0
    while #open > 0 and visited < (maxNodes or 3000) do
        table.sort(open, function(a,b) return a.f < b.f end)
        local current = table.remove(open, 1)
        local ck = key(current.x,current.z)
        if current.x == goalX and current.z == goalZ then
            local path = {{x=goalX,z=goalZ}}
            while came[ck] do
                local prev = came[ck]
                path[#path+1] = {x=prev.x,z=prev.z}
                ck = key(prev.x,prev.z)
            end
            local reversed = {}
            for i=#path,1,-1 do reversed[#reversed+1]=path[i] end
            return reversed, visited
        end
        if not closed[ck] then
            closed[ck] = true
            visited += 1
            for _,d in ipairs(dirs) do
                local nx,nz = current.x+d[1], current.z+d[2]
                local nk = key(nx,nz)
                local isBlocked = blocked and blocked(nx,nz)
                local tentative = current.g + 1
                if not isBlocked and not closed[nk] and (gScore[nk] == nil or tentative < gScore[nk]) then
                    came[nk] = {x=current.x,z=current.z}
                    gScore[nk] = tentative
                    open[#open+1] = {x=nx,z=nz,g=tentative,f=tentative+heuristic(nx,nz)}
                end
            end
        end
    end
    return nil, visited
end

local function getSummary()
    local bp = State.Blueprint
    if not bp then return "No blueprint loaded" end
    local totalParts = 0
    for _, e in ipairs(bp.entries) do totalParts += tonumber(e.p) or 0 end
    return string.format("%d models  |  ~%d parts  |  rotate %d°", #bp.entries, totalParts, State.Rotation)
end

-- Compact UI
local old = Player:WaitForChild("PlayerGui"):FindFirstChild("FlashLiteUI")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "FlashLiteUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = Player:WaitForChild("PlayerGui")

local main = Instance.new("Frame")
main.Name = "Panel"
main.Size = UDim2.fromOffset(286, 294)
main.Position = UDim2.new(0, 14, 0.32, 0)
main.BackgroundColor3 = Color3.fromRGB(19, 22, 29)
main.BorderSizePixel = 0
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", main)
stroke.Color = Color3.fromRGB(55, 65, 80)
stroke.Thickness = 1

local top = Instance.new("Frame")
top.Size = UDim2.new(1,0,0,36)
top.BackgroundColor3 = Color3.fromRGB(27,31,40)
top.BorderSizePixel = 0
top.Parent = main
Instance.new("UICorner", top).CornerRadius = UDim.new(0,10)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(11,0)
title.Size = UDim2.new(1,-84,1,0)
title.Font = Enum.Font.GothamSemibold
title.Text = "FLASH-LITE  /  IND"
title.TextSize = 12
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(230,237,247)
title.Parent = top

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.fromOffset(30,26)
minBtn.Position = UDim2.new(1,-36,0,5)
minBtn.BackgroundColor3 = Color3.fromRGB(48,57,71)
minBtn.Text = "_"
minBtn.TextColor3 = Color3.new(1,1,1)
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 15
minBtn.Parent = top
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0,6)

local body = Instance.new("Frame")
body.Position = UDim2.fromOffset(9,43)
body.Size = UDim2.new(1,-18,1,-52)
body.BackgroundTransparency = 1
body.Parent = main

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1,0,0,28)
status.BackgroundColor3 = Color3.fromRGB(28,34,44)
status.TextColor3 = Color3.fromRGB(171,190,211)
status.Font = Enum.Font.Gotham
status.TextSize = 10
status.Text = "Ready  |  " .. VERSION
status.Parent = body
Instance.new("UICorner", status).CornerRadius = UDim.new(0,6)

local function button(text, y, callback, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1,0,0,30)
    b.Position = UDim2.fromOffset(0,y)
    b.BackgroundColor3 = color or Color3.fromRGB(39,48,62)
    b.TextColor3 = Color3.fromRGB(235,241,248)
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 11
    b.Text = text
    b.AutoButtonColor = true
    b.Parent = body
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,6)
    b.Activated:Connect(callback)
    return b
end

local summary = Instance.new("TextLabel")
summary.Position = UDim2.fromOffset(2,34)
summary.Size = UDim2.new(1,-4,0,24)
summary.BackgroundTransparency = 1
summary.TextColor3 = Color3.fromRGB(143,161,183)
summary.Font = Enum.Font.Gotham
summary.TextSize = 9
summary.Text = "No blueprint loaded"
summary.TextTruncate = Enum.TextTruncate.AtEnd
summary.Parent = body

local function refresh()
    summary.Text = getSummary()
    status.Text = State.Busy and "Working..." or ("Ready  |  " .. VERSION)
end

button("CAPTURE NEARBY BUILD", 62, function()
    captureBlueprint()
    refresh()
end, Color3.fromRGB(35,83,119))

button("EXPORT BLUEPRINT JSON", 98, function()
    exportBlueprint()
end)

button("PREVIEW  /  REFRESH", 134, function()
    makePreview()
    refresh()
end)

button("ROTATE 90°", 170, function()
    rotateBlueprint()
    refresh()
end)

button("CLEAR PREVIEW", 206, function()
    clearPreview()
    refresh()
end)

local importBox = Instance.new("TextBox")
importBox.Position = UDim2.fromOffset(0,242)
importBox.Size = UDim2.new(1,-74,0,28)
importBox.BackgroundColor3 = Color3.fromRGB(28,34,44)
importBox.TextColor3 = Color3.fromRGB(235,241,248)
importBox.PlaceholderColor3 = Color3.fromRGB(120,137,158)
importBox.PlaceholderText = "Paste blueprint JSON..."
importBox.Text = ""
importBox.ClearTextOnFocus = false
importBox.Font = Enum.Font.Gotham
importBox.TextSize = 10
importBox.Parent = body
Instance.new("UICorner", importBox).CornerRadius = UDim.new(0,6)

local importBtn = Instance.new("TextButton")
importBtn.Position = UDim2.new(1,-68,0,242)
importBtn.Size = UDim2.fromOffset(68,28)
importBtn.BackgroundColor3 = Color3.fromRGB(42,91,72)
importBtn.TextColor3 = Color3.new(1,1,1)
importBtn.Text = "IMPORT"
importBtn.Font = Enum.Font.GothamBold
importBtn.TextSize = 10
importBtn.Parent = body
Instance.new("UICorner", importBtn).CornerRadius = UDim.new(0,6)
importBtn.Activated:Connect(function()
    importBlueprint(importBox.Text)
    importBox.Text = ""
    refresh()
end)

local minimized = false
minBtn.Activated:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    main.Size = minimized and UDim2.fromOffset(286,36) or UDim2.fromOffset(286,294)
    minBtn.Text = minimized and "+" or "_"
end)

-- Touch/mouse dragging; only the title strip is draggable.
local dragging, dragStart, startPos
top.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = main.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

gui.Destroying:Connect(function()
    clearPreview()
end)

refresh()
notify("Flash-Lite loaded", "Lightweight blueprint tools ready", 4)

-- Exposed internal planner for future verified pipe-routing integration.
_G.FlashLitePlanGridPath = planGridPath



-- ============================================================
-- FLASH-LITE v1.1 BOX SELECT + MACHINE PASTE
-- The box is a selection volume only. It never scales machines.
-- Uses the game's PlacementSystem.PlaceBind(template, CFrame).
-- No automatic buying and no speculative alternate remote calls.
-- ============================================================

local BOX = {
    size = Vector3.new(48, 24, 48),
    yaw = 0,
    center = nil,
    blueprint = nil,
    busy = false,
    pasteDelay = 0.12,
    maxEntries = 300,
}
local placementFolder = ReplicatedStorage:FindFirstChild("PlacementSystem")
local placementRemote = placementFolder and placementFolder:FindFirstChild("PlaceBind")
local buildingCatalog = placementFolder and placementFolder:FindFirstChild("Buildings")

local function boxRoot()
    local r = getRoot()
    if not r then return nil end
    return r
end

local function findMachineTemplate(name)
    if not buildingCatalog then return nil end
    for _, category in ipairs(buildingCatalog:GetChildren()) do
        local found = category:FindFirstChild(name)
        if found and found:IsA("Model") then return found end
    end
    return nil
end

local function boxCFrame()
    if BOX.center then
        return CFrame.new(BOX.center) * CFrame.Angles(0, math.rad(BOX.yaw), 0)
    end
    local r = boxRoot()
    if not r then return CFrame.new() end
    return r.CFrame * CFrame.new(0, BOX.size.Y / 2, -18)
end

local volume = Instance.new("Part")
volume.Name = "FlashLiteSelectionVolume"
volume.Anchored = true
volume.Transparency = 1
volume.Size = BOX.size
volume.CanCollide = false
volume.CanTouch = false
volume.CanQuery = false
volume.CastShadow = false
volume.Parent = Workspace

local outline = Instance.new("SelectionBox")
outline.Name = "FlashLiteSelectionOutline"
outline.Adornee = volume
outline.LineThickness = 0.045
outline.Color3 = Color3.fromRGB(65, 190, 255)
outline.SurfaceTransparency = 1
outline.Parent = volume

local function updateBox()
    volume.Size = BOX.size
    volume.CFrame = boxCFrame()
end
updateBox()

local function aimPoint()
    local camera = Workspace.CurrentCamera
    if not camera then return nil end
    local viewport = camera.ViewportSize
    local ray = camera:ViewportPointToRay(viewport.X * 0.5, viewport.Y * 0.5)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local exclude = {volume}
    if Player.Character then table.insert(exclude, Player.Character) end
    params.FilterDescendantsInstances = exclude
    params.IgnoreWater = true
    local result = Workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
    return result and result.Position or nil
end

local function setBoxAtAim()
    local point = aimPoint()
    if not point then
        notify("Selection box", "Aim at the ground or a surface first")
        return
    end
    BOX.center = Vector3.new(point.X, point.Y + BOX.size.Y / 2, point.Z)
    local r = boxRoot()
    if r then
        local _, y = r.CFrame:ToOrientation()
        BOX.yaw = math.deg(y)
    end
    updateBox()
    notify("Selection box", "Moved to your aim point")
end

local function insideSelection(worldPosition)
    local localPosition = volume.CFrame:PointToObjectSpace(worldPosition)
    local half = BOX.size * 0.5
    return math.abs(localPosition.X) <= half.X
        and math.abs(localPosition.Y) <= half.Y
        and math.abs(localPosition.Z) <= half.Z
end

local function copyInsideBox()
    if BOX.busy then return end
    if not buildingCatalog then
        notify("Copy failed", "PlacementSystem.Buildings catalog not found")
        return
    end
    BOX.busy = true
    local origin = volume.CFrame
    local entries, seen = {}, {}
    local descendants = Workspace:GetDescendants()

    for i, obj in ipairs(descendants) do
        if obj:IsA("Model") and not seen[obj] and not obj:FindFirstAncestorOfClass("Tool") then
            seen[obj] = true
            -- Only top-level machine models whose exact name exists in the game's catalog.
            local parentIsModel = obj.Parent and obj.Parent:IsA("Model")
            if not parentIsModel and not (obj:FindFirstChildOfClass("Humanoid")) then
                local template = findMachineTemplate(obj.Name)
                if template then
                    local ok, pivot = pcall(function() return obj:GetPivot() end)
                    if ok and insideSelection(pivot.Position) then
                        entries[#entries + 1] = {
                            n = obj.Name,
                            c = cframeToArray(origin:ToObjectSpace(pivot)),
                        }
                        if #entries >= BOX.maxEntries then break end
                    end
                end
            end
        end
        if i % 500 == 0 then task.wait() end
    end

    BOX.busy = false
    if #entries == 0 then
        notify("Copy inside box", "No catalog machines found inside the box")
        return
    end
    BOX.blueprint = {
        format = "FLASHLITE_IND",
        version = 1,
        count = #entries,
        size = {BOX.size.X, BOX.size.Y, BOX.size.Z},
        entries = entries,
    }
    State.Blueprint = BOX.blueprint
    State.CaptureCount = #entries
    notify("Copied", tostring(#entries) .. " machines inside the box")
end

local function pasteBoxBlueprint()
    if BOX.busy then return end
    local bp = BOX.blueprint or State.Blueprint
    if not bp or type(bp.entries) ~= "table" or #bp.entries == 0 then
        notify("Paste", "Copy a selection first")
        return
    end
    if not placementFolder or not placementRemote or not placementRemote:IsA("RemoteFunction") then
        notify("Paste unavailable", "PlacementSystem.PlaceBind RemoteFunction not found")
        return
    end
    if not buildingCatalog then
        notify("Paste unavailable", "Building catalog not found")
        return
    end

    BOX.busy = true
    local target = volume.CFrame
    local placed, missing, failed = 0, 0, 0
    for i, entry in ipairs(bp.entries) do
        local template = findMachineTemplate(entry.n)
        local relative = arrayToCFrame(entry.c)
        if not template or not relative then
            missing += 1
        else
            local targetCF = target * relative
            local ok, result = pcall(function()
                return placementRemote:InvokeServer(template, targetCF)
            end)
            local rejected = result == false
            if type(result) == "string" then
                local lower = result:lower()
                rejected = lower:find("fail", 1, true) ~= nil
                    or lower:find("not enough", 1, true) ~= nil
                    or lower:find("error", 1, true) ~= nil
            end
            if ok and not rejected then
                placed += 1
            else
                failed += 1
                if failed <= 3 then
                    warn("[Flash-Lite] PlaceBind rejected " .. tostring(entry.n) .. ": " .. tostring(result))
                end
            end
        end
        if i % 4 == 0 then
            notify("Pasting", string.format("%d/%d | placed %d | missing %d | failed %d", i, #bp.entries, placed, missing, failed))
            task.wait(BOX.pasteDelay)
        else
            task.wait(0.04)
        end
    end
    BOX.busy = false
    notify("Paste finished", string.format("%d requested | %d missing | %d failed. Check the world.", placed, missing, failed), 6)
end

-- Dedicated compact controls for the 3D selection volume.
local boxGui = Instance.new("ScreenGui")
boxGui.Name = "FlashLiteBoxControls"
boxGui.ResetOnSpawn = false
boxGui.IgnoreGuiInset = true
boxGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
boxGui.Parent = Player:WaitForChild("PlayerGui")

local boxPanel = Instance.new("Frame")
boxPanel.Name = "BoxPanel"
boxPanel.Size = UDim2.fromOffset(248, 252)
boxPanel.Position = UDim2.new(1, -260, 0.30, 0)
boxPanel.BackgroundColor3 = Color3.fromRGB(17, 23, 32)
boxPanel.BorderSizePixel = 0
boxPanel.Parent = boxGui
Instance.new("UICorner", boxPanel).CornerRadius = UDim.new(0, 10)
local boxStroke = Instance.new("UIStroke", boxPanel)
boxStroke.Color = Color3.fromRGB(57, 100, 133)
boxStroke.Thickness = 1

local boxHeader = Instance.new("TextLabel")
boxHeader.Size = UDim2.new(1, -12, 0, 30)
boxHeader.Position = UDim2.fromOffset(8, 0)
boxHeader.BackgroundTransparency = 1
boxHeader.Text = "3D MACHINE SELECTOR"
boxHeader.Active = true
boxHeader.TextColor3 = Color3.fromRGB(220, 239, 255)
boxHeader.Font = Enum.Font.GothamBold
boxHeader.TextSize = 11
boxHeader.TextXAlignment = Enum.TextXAlignment.Left
boxHeader.Parent = boxPanel

local function boxButton(label, y, callback, color)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -16, 0, 29)
    b.Position = UDim2.fromOffset(8, y)
    b.BackgroundColor3 = color or Color3.fromRGB(37, 52, 69)
    b.TextColor3 = Color3.fromRGB(239, 246, 252)
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = 10
    b.Text = label
    b.Parent = boxPanel
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.Activated:Connect(callback)
    return b
end

local function dimensionField(label, x, value, axis)
    local wrap = Instance.new("Frame")
    wrap.Size = UDim2.fromOffset(72, 42)
    wrap.Position = UDim2.fromOffset(x, 34)
    wrap.BackgroundTransparency = 1
    wrap.Parent = boxPanel

    local caption = Instance.new("TextLabel")
    caption.Size = UDim2.new(1, 0, 0, 14)
    caption.BackgroundTransparency = 1
    caption.Text = label
    caption.TextColor3 = Color3.fromRGB(150, 177, 198)
    caption.Font = Enum.Font.Gotham
    caption.TextSize = 9
    caption.Parent = wrap

    local field = Instance.new("TextBox")
    field.Size = UDim2.new(1, 0, 0, 25)
    field.Position = UDim2.fromOffset(0, 15)
    field.BackgroundColor3 = Color3.fromRGB(31, 41, 54)
    field.TextColor3 = Color3.new(1, 1, 1)
    field.PlaceholderColor3 = Color3.fromRGB(130, 150, 170)
    field.Text = tostring(value)
    field.ClearTextOnFocus = false
    field.Font = Enum.Font.GothamMedium
    field.TextSize = 10
    field.Parent = wrap
    Instance.new("UICorner", field).CornerRadius = UDim.new(0, 5)

    field.FocusLost:Connect(function()
        local n = tonumber(field.Text)
        if not n then
            field.Text = tostring(BOX.size[axis])
            return
        end
        n = math.clamp(math.floor(n), 4, 300)
        BOX.size = Vector3.new(
            axis == "X" and n or BOX.size.X,
            axis == "Y" and n or BOX.size.Y,
            axis == "Z" and n or BOX.size.Z
        )
        field.Text = tostring(n)
        updateBox()
    end)
end

dimensionField("LENGTH (X)", 8, BOX.size.X, "X")
dimensionField("HEIGHT (Y)", 88, BOX.size.Y, "Y")
dimensionField("WIDTH (Z)", 168, BOX.size.Z, "Z")

boxButton("MOVE BOX TO AIM POINT", 82, setBoxAtAim, Color3.fromRGB(39, 76, 101))
boxButton("COPY MACHINES INSIDE BOX", 116, copyInsideBox, Color3.fromRGB(34, 91, 123))
boxButton("PASTE COPIED MACHINES", 150, pasteBoxBlueprint, Color3.fromRGB(38, 104, 75))
boxButton("ROTATE BOX 90°", 184, function()
    BOX.yaw = (BOX.yaw + 90) % 360
    updateBox()
end)
boxButton("HIDE BOX", 218, function()
    volume.Transparency = volume.Transparency == 1 and 1 or 1
    outline.Visible = not outline.Visible
end, Color3.fromRGB(61, 61, 69))

-- Drag the selector panel by its title area.
local boxDragging, boxDragStart, boxStartPos = false, nil, nil
boxHeader.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        boxDragging = true
        boxDragStart = input.Position
        boxStartPos = boxPanel.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if boxDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - boxDragStart
        boxPanel.Position = UDim2.new(boxStartPos.X.Scale, boxStartPos.X.Offset + delta.X,
            boxStartPos.Y.Scale, boxStartPos.Y.Offset + delta.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        boxDragging = false
    end
end)

gui.Destroying:Connect(function()
    pcall(function() boxGui:Destroy() end)
    pcall(function() volume:Destroy() end)
end)

notify("Flash-Lite 1.1", "3D box selector and PlaceBind paste controls loaded", 4)
