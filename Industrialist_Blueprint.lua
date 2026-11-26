--[[
INDUSTRIALIST BLUEPRINT v1.2
Independent best-effort build copier for Roblox/Delta.
Capture -> Export -> Import -> Preview -> Paste.

WARNING:
- This is an experimental client script, not live-game tested.
- PlaceBind's argument signature and catalog lookup may change.
- Paste can partially succeed. Test in an empty area with a small blueprint.
- Pipe/wire links and machine runtime settings are not reconstructed.
]]

if _G.INDUSTRIALIST_BLUEPRINT then
    pcall(function() _G.INDUSTRIALIST_BLUEPRINT:Destroy() end)
end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Http = game:GetService("HttpService")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local root = char:WaitForChild("HumanoidRootPart")

local API = {
    Version = "1.2",
    Blueprint = nil,
    Markers = {},
    Busy = false,
    Destroyed = false,
    Yaw = 0,
    Offset = Vector3.new(0, 0, -18),
    Delay = 0.15,
    MaxObjects = 1200,
}
_G.INDUSTRIALIST_BLUEPRINT = API

local function notify(msg)
    print("[Industrialist Blueprint] " .. tostring(msg))
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "Industrialist Blueprint",
            Text = tostring(msg),
            Duration = 5
        })
    end)
end

local function getRoot()
    char = player.Character or char
    root = char and char:FindFirstChild("HumanoidRootPart")
    return root
end

local function clearPreview()
    for _, obj in ipairs(API.Markers) do
        pcall(function() obj:Destroy() end)
    end
    table.clear(API.Markers)
end

local function isCandidate(obj)
    if not obj:IsA("Model") or obj == char then return false end
    if obj.Name == "Camera" or obj.Name == "Terrain" then return false end
    if obj:FindFirstAncestorOfClass("Tool") then return false end
    local ok, cf = pcall(function() return obj:GetPivot() end)
    return ok and cf ~= nil
end

local function scanNearby(radius)
    local r = getRoot()
    if not r then return {} end
    local found, seen = {}, {}
    local ok, descendants = pcall(function() return workspace:GetDescendants() end)
    if not ok then return found end
    for _, obj in ipairs(descendants) do
        if not seen[obj] and isCandidate(obj) then
            seen[obj] = true
            local good, cf = pcall(function() return obj:GetPivot() end)
            if good and (cf.Position - r.Position).Magnitude <= radius then
                table.insert(found, obj)
            end
        end
    end
    return found
end

function API:Capture(radius)
    if self.Busy then return notify("Another operation is running.") end
    local r = getRoot()
    if not r then return notify("Character root not found.") end
    local models = scanNearby(radius or 180)
    local entries = {}
    for _, model in ipairs(models) do
        local ok, cf = pcall(function() return model:GetPivot() end)
        if ok then
            local rel = r.CFrame:ToObjectSpace(cf)
            local rx, ry, rz = rel:ToOrientation()
            table.insert(entries, {
                name = model.Name,
                x = rel.X, y = rel.Y, z = rel.Z,
                rx = rx, ry = ry, rz = rz
            })
            if #entries >= self.MaxObjects then break end
        end
    end
    if #entries == 0 then return notify("No nearby models found.") end
    self.Blueprint = {
        format = "INDUSTRIALIST_BLUEPRINT",
        version = 2,
        count = #entries,
        entries = entries
    }
    notify("Captured " .. #entries .. " models. Export before leaving the area.")
end

function API:Export()
    if not self.Blueprint then return notify("Capture a build first.") end
    local ok, encoded = pcall(function() return Http:JSONEncode(self.Blueprint) end)
    if not ok then return notify("Could not encode blueprint: " .. tostring(encoded)) end
    if typeof(setclipboard) == "function" then
        local copied = pcall(setclipboard, encoded)
        if copied then return notify("Blueprint JSON copied to clipboard.") end
    end
    print("----- INDUSTRIALIST BLUEPRINT JSON BEGIN -----")
    print(encoded)
    print("----- INDUSTRIALIST BLUEPRINT JSON END -----")
    notify("Clipboard unavailable. JSON printed to executor console.")
end

function API:Import(raw)
    if raw == nil and typeof(getclipboard) == "function" then
        local ok, value = pcall(getclipboard)
        if ok then raw = value end
    end
    if type(raw) ~= "string" or raw == "" then
        return notify("Clipboard read unavailable or empty.")
    end
    local ok, data = pcall(function() return Http:JSONDecode(raw) end)
    if not ok or type(data) ~= "table"
        or data.format ~= "INDUSTRIALIST_BLUEPRINT"
        or type(data.entries) ~= "table"
        or #data.entries == 0
        or #data.entries > self.MaxObjects then
        return notify("Invalid blueprint or object count exceeds safety limit.")
    end
    for _, e in ipairs(data.entries) do
        if type(e) ~= "table" or type(e.name) ~= "string"
            or type(e.x) ~= "number" or type(e.y) ~= "number" or type(e.z) ~= "number" then
            return notify("Blueprint contains an invalid entry.")
        end
    end
    self.Blueprint = data
    notify("Imported " .. #data.entries .. " blueprint entries.")
end

local function getTargetCFrame(entry)
    local r = getRoot()
    if not r then return nil end
    local base = r.CFrame * CFrame.new(API.Offset) * CFrame.Angles(0, math.rad(API.Yaw), 0)
    return base * CFrame.new(entry.x, entry.y, entry.z)
        * CFrame.fromOrientation(entry.rx or 0, entry.ry or 0, entry.rz or 0)
end

function API:Preview()
    if not self.Blueprint then return notify("Capture or import a blueprint first.") end
    clearPreview()
    for i, entry in ipairs(self.Blueprint.entries) do
        local cf = getTargetCFrame(entry)
        if cf then
            local marker = Instance.new("Part")
            marker.Name = "BlueprintPreview"
            marker.Size = Vector3.new(2.5, 2.5, 2.5)
            marker.Anchored = true
            marker.CanCollide = false
            marker.CanTouch = false
            marker.CanQuery = false
            marker.Transparency = 0.48
            marker.Material = Enum.Material.ForceField
            marker.CFrame = cf
            marker.Parent = workspace
            table.insert(self.Markers, marker)
        end
        if i % 100 == 0 then task.wait() end
    end
    notify("Previewed " .. #self.Markers .. " positions. Preview markers are not real machines.")
end

local function findPlacementRemote()
    local folder = RS:FindFirstChild("PlacementSystem")
    if not folder then return nil, "ReplicatedStorage.PlacementSystem not found" end
    local remote = folder:FindFirstChild("PlaceBind")
    if not remote or not remote:IsA("RemoteFunction") then
        return nil, "PlacementSystem.PlaceBind RemoteFunction not found"
    end
    return remote
end

local function findTemplate(name)
    -- Search likely catalog roots first, then ReplicatedStorage descendants.
    local roots = {}
    for _, rootName in ipairs({"Buildings", "BuildingModels", "Models", "Items", "Catalog", "PlacementSystem"}) do
        local obj = RS:FindFirstChild(rootName)
        if obj then table.insert(roots, obj) end
    end
    table.insert(roots, RS)
    local visited = {}
    for _, searchRoot in ipairs(roots) do
        if not visited[searchRoot] then
            visited[searchRoot] = true
            local ok, descendants = pcall(function() return searchRoot:GetDescendants() end)
            if ok then
                for _, obj in ipairs(descendants) do
                    if obj:IsA("Model") and obj.Name == name then
                        return obj
                    end
                end
            end
        end
    end
    return nil
end

function API:Paste()
    if self.Busy then return notify("Paste is already running.") end
    if not self.Blueprint then return notify("Capture or import a blueprint first.") end
    local remote, reason = findPlacementRemote()
    if not remote then return notify(reason .. ". Paste aborted.") end
    if #self.Blueprint.entries > self.MaxObjects then
        return notify("Blueprint exceeds object safety limit.")
    end

    self.Busy = true
    clearPreview()
    local placed, missing, failed = 0, 0, 0
    local total = #self.Blueprint.entries
    notify("Starting best-effort paste of " .. total .. " objects. Keep the game open.")
    for i, entry in ipairs(self.Blueprint.entries) do
        if self.Destroyed then break end
        local template = findTemplate(entry.name)
        if not template then
            missing = missing + 1
        else
            local cf = getTargetCFrame(entry)
            if cf then
                -- Best-effort signature recovered from public copier source.
                -- The server may reject this if its implementation has changed.
                local ok, result = pcall(function()
                    return remote:InvokeServer(template, cf, nil, true, true, true)
                end)
                if ok and result ~= false then
                    placed = placed + 1
                else
                    failed = failed + 1
                    if failed <= 3 then
                        warn("[Blueprint] Placement failed for " .. entry.name .. ": " .. tostring(result))
                    end
                end
            else
                failed = failed + 1
            end
        end
        if i % 5 == 0 then
            notify("Paste progress: " .. i .. "/" .. total .. " | placed " .. placed .. " | missing " .. missing .. " | errors " .. failed)
            task.wait(self.Delay)
        else
            task.wait(0.03)
        end
    end
    self.Busy = false
    notify("Paste finished. Placed/requested: " .. placed .. " | missing templates: " .. missing .. " | errors: " .. failed .. ". Check the build in-game.")
end

function API:Rotate(degrees)
    self.Yaw = (self.Yaw + (degrees or 90)) % 360
    notify("Paste rotation: " .. self.Yaw .. " degrees.")
end

function API:SetOffset(x, y, z)
    self.Offset = Vector3.new(x or 0, y or 0, z or -18)
    notify("Paste offset updated.")
end

function API:Destroy()
    self.Destroyed = true
    clearPreview()
    if self.Gui then pcall(function() self.Gui:Destroy() end) end
    _G.INDUSTRIALIST_BLUEPRINT = nil
end

-- Minimal native mobile UI
local gui = Instance.new("ScreenGui")
gui.Name = "IndustrialistBlueprint"
gui.ResetOnSpawn = false
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end
API.Gui = gui

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(238, 324)
panel.Position = UDim2.new(0, 16, 0.28, 0)
panel.BackgroundColor3 = Color3.fromRGB(24, 28, 36)
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)
local stroke = Instance.new("UIStroke", panel)
stroke.Color = Color3.fromRGB(76, 91, 115)
stroke.Transparency = 0.25

local header = Instance.new("TextButton")
header.Size = UDim2.new(1, 0, 0, 38)
header.BackgroundColor3 = Color3.fromRGB(42, 51, 67)
header.TextColor3 = Color3.new(1,1,1)
header.Text = "INDUSTRIALIST BLUEPRINT  [-]"
header.Font = Enum.Font.GothamBold
header.TextSize = 11
header.Parent = panel
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 9)

local body = Instance.new("ScrollingFrame")
body.Position = UDim2.fromOffset(8, 44)
body.Size = UDim2.new(1, -16, 1, -52)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 3
body.CanvasSize = UDim2.new()
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.Parent = panel
local layout = Instance.new("UIListLayout", body)
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder

local function addButton(label, callback)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -4, 0, 32)
    b.BackgroundColor3 = Color3.fromRGB(51, 63, 82)
    b.TextColor3 = Color3.fromRGB(245, 247, 250)
    b.Text = label
    b.Font = Enum.Font.GothamMedium
    b.TextSize = 12
    b.Parent = body
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    b.Activated:Connect(function() task.spawn(callback) end)
end

addButton("Capture nearby build", function() API:Capture(180) end)
addButton("Export blueprint (copy JSON)", function() API:Export() end)
addButton("Import blueprint (clipboard)", function() API:Import() end)
addButton("Preview at paste location", function() API:Preview() end)
addButton("Rotate paste 90 degrees", function() API:Rotate(90) end)
addButton("PASTE BUILD (experimental)", function() API:Paste() end)
addButton("Clear preview", function() clearPreview(); notify("Preview cleared.") end)
addButton("Close script", function() API:Destroy() end)

local collapsed, dragging, dragInput, dragStart, startPos = false, false, nil, nil, nil
header.Activated:Connect(function()
    collapsed = not collapsed
    body.Visible = not collapsed
    panel.Size = collapsed and UDim2.fromOffset(238, 38) or UDim2.fromOffset(238, 324)
    header.Text = collapsed and "INDUSTRIALIST BLUEPRINT  [+]" or "INDUSTRIALIST BLUEPRINT  [-]"
end)

header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = panel.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)

UIS.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

notify("Loaded v1.2. Test with a tiny build first. Placement is experimental.")
