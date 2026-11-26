-- INDUSTRIALIST BLUEPRINT v1.2
-- Lightweight capture/export/import/preview utility for Delta.
-- IMPORTANT: server placement signature and catalog lookup are game-version dependent.
-- This version captures and transfers transforms; paste is guarded and may need adaptation.

if _G.INDUSTRIALIST_BLUEPRINT then
    pcall(function() _G.INDUSTRIALIST_BLUEPRINT:Destroy() end)
end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Http = game:GetService("HttpService")
local UIS = game:GetService("UserInputService")
local player = Players.LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local root = char:WaitForChild("HumanoidRootPart")

local API = {Blueprint=nil, Markers={}, Busy=false}
_G.INDUSTRIALIST_BLUEPRINT = API

local function say(s)
    print("[Industrialist Blueprint] "..s)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title="Industrialist Blueprint", Text=s, Duration=4
        })
    end)
end

local function clear()
    for _,v in ipairs(API.Markers) do pcall(function() v:Destroy() end) end
    table.clear(API.Markers)
end

local function scan(radius)
    local out, seen = {}, {}
    for _,v in ipairs(workspace:GetDescendants()) do
        if v:IsA("Model") and v ~= char and not seen[v] then
            local ok, cf = pcall(function() return v:GetPivot() end)
            if ok and (cf.Position-root.Position).Magnitude <= radius then
                seen[v] = true
                table.insert(out, v)
            end
        end
    end
    return out
end

function API:Capture()
    local list = scan(180)
    if #list == 0 then say("No nearby models found."); return end
    local origin, entries = root.CFrame, {}
    for _,m in ipairs(list) do
        local ok, cf = pcall(function() return m:GetPivot() end)
        if ok then
            local rel = origin:ToObjectSpace(cf)
            local x,y,z = rel:ToOrientation()
            table.insert(entries, {name=m.Name, x=rel.X, y=rel.Y, z=rel.Z, rx=x, ry=y, rz=z})
        end
    end
    self.Blueprint = {format="INDUSTRIALIST_BLUEPRINT", version=1, entries=entries}
    say("Captured "..#entries.." models. Export the JSON.")
end

function API:Export()
    if not self.Blueprint then say("Capture a build first."); return end
    local data = Http:JSONEncode(self.Blueprint)
    if typeof(setclipboard) == "function" then
        setclipboard(data); say("Blueprint copied to clipboard.")
    else
        print(data); say("Clipboard unavailable; JSON printed to console.")
    end
end

function API:Import()
    if typeof(getclipboard) ~= "function" then say("Clipboard read unavailable."); return end
    local ok, data = pcall(function() return Http:JSONDecode(getclipboard()) end)
    if not ok or type(data) ~= "table" or data.format ~= "INDUSTRIALIST_BLUEPRINT"
        or type(data.entries) ~= "table" or #data.entries > 1200 then
        say("Invalid blueprint or over 1200 objects."); return
    end
    self.Blueprint = data
    say("Imported "..#data.entries.." objects.")
end

function API:Preview()
    if not self.Blueprint then say("Capture or import first."); return end
    clear()
    local base = root.CFrame * CFrame.new(0,0,-18)
    for i,e in ipairs(self.Blueprint.entries) do
        local p = Instance.new("Part")
        p.Name, p.Size = "BlueprintPreview", Vector3.new(2.5,2.5,2.5)
        p.Anchored, p.CanCollide, p.Transparency = true, false, 0.5
        p.Material = Enum.Material.ForceField
        p.CFrame = base * CFrame.new(e.x,e.y,e.z) * CFrame.fromOrientation(e.rx or 0,e.ry or 0,e.rz or 0)
        p.Parent = workspace
        table.insert(self.Markers,p)
        if i % 100 == 0 then task.wait() end
    end
    say("Preview markers: "..#self.Markers..". These are not placed machines.")
end

function API:Paste()
    if self.Busy or not self.Blueprint then say("Busy, or no blueprint loaded."); return end
    local ps = RS:FindFirstChild("PlacementSystem")
    local remote = ps and ps:FindFirstChild("PlaceBind")
    if not remote or not remote:IsA("RemoteFunction") then say("PlaceBind RemoteFunction not found."); return end
    say("Paste is disabled until the game's live catalog model and remote arguments are verified. Use preview/export safely.")
end

function API:Destroy()
    clear()
    if self.Gui then self.Gui:Destroy() end
    _G.INDUSTRIALIST_BLUEPRINT = nil
end

local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn = "IndustrialistBlueprint", false
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end
API.Gui = gui

local frame = Instance.new("Frame")
frame.Size, frame.Position = UDim2.fromOffset(225,260), UDim2.new(0,16,0.35,0)
frame.BackgroundColor3, frame.BorderSizePixel = Color3.fromRGB(25,29,38), 0
frame.Parent = gui
Instance.new("UICorner",frame).CornerRadius = UDim.new(0,9)

local head = Instance.new("TextButton")
head.Size, head.Text = UDim2.new(1,0,0,36), "INDUSTRIALIST BLUEPRINT  [-]"
head.BackgroundColor3, head.TextColor3 = Color3.fromRGB(43,52,68), Color3.new(1,1,1)
head.Font, head.TextSize, head.Parent = Enum.Font.GothamBold, 11, frame
Instance.new("UICorner",head).CornerRadius = UDim.new(0,9)

local body = Instance.new("Frame")
body.Position, body.Size = UDim2.fromOffset(8,43), UDim2.new(1,-16,1,-51)
body.BackgroundTransparency, body.Parent = 1, frame
local layout = Instance.new("UIListLayout",body)
layout.Padding = UDim.new(0,6)

local function button(label,fn)
    local b = Instance.new("TextButton")
    b.Size, b.Text = UDim2.new(1,0,0,30), label
    b.BackgroundColor3, b.TextColor3 = Color3.fromRGB(53,65,84), Color3.new(1,1,1)
    b.Font, b.TextSize, b.Parent = Enum.Font.GothamMedium, 12, body
    Instance.new("UICorner",b).CornerRadius = UDim.new(0,6)
    b.Activated:Connect(function() task.spawn(fn) end)
end

button("Capture nearby build",function() API:Capture() end)
button("Export blueprint",function() API:Export() end)
button("Import from clipboard",function() API:Import() end)
button("Preview positions",function() API:Preview() end)
button("Paste build (currently guarded)",function() API:Paste() end)
button("Clear preview",function() clear(); say("Preview cleared.") end)
button("Close",function() API:Destroy() end)

local collapsed, dragging, dragPos, startPos = false, false
head.Activated:Connect(function()
    collapsed = not collapsed
    body.Visible = not collapsed
    frame.Size = collapsed and UDim2.fromOffset(225,36) or UDim2.fromOffset(225,260)
    head.Text = collapsed and "INDUSTRIALIST BLUEPRINT  [+]" or "INDUSTRIALIST BLUEPRINT  [-]"
end)
head.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging, dragPos, startPos = true, input.Position, frame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
UIS.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement) then
        local d = input.Position-dragPos
        frame.Position = UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y)
    end
end)

say("Loaded. Capture a small test area first. Placement is intentionally guarded.")
