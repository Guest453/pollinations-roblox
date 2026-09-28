--[[
	DemoServer.server.lua — the entire demo: one ProximityPrompt, one NPC, done.

	Walk up to Bella, press E, the open chat window opens, type a message and
	Bella replies (Pollinations text model, per-player conversation memory).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Pollinations = require(ReplicatedStorage.Pollinations)
local NpcDialogue = require(ReplicatedStorage.NpcDialogue)

-- ============================================================================
-- API KEY (server-side only!)
-- ============================================================================
-- Recommended: Roblox secrets store. In Creator Dashboard select your
-- experience > Secrets > Create Secret:
--     name:   pollinations_key
--     secret: <your key from https://enter.pollinations.ai/keys>
--     domain: gen.pollinations.ai
-- Then uncomment:
-- local secret = game:GetService("HttpService"):GetSecret("pollinations_key")
-- Pollinations.Configure({ ApiKey = secret })
--
-- For quick local testing you can paste a key here, but NEVER commit one:
-- Pollinations.Configure({ ApiKey = "pk_..." })
--
-- Anonymous requests (no key) sometimes work for free-tier models but are
-- rate-limited and unreliable.

-- ============================================================================
-- the NPC
-- ============================================================================

local bella = NpcDialogue.new(Pollinations, {
	Name = "Bella the Beekeeper",
	Persona = "You are Bella, a friendly bee-keeper NPC in the cozy village of Pollenville "
		.. "(a Roblox game). Stay in character at all times. Keep replies under 2 short "
		.. "sentences. You sell honey, honeycombs and beeswax for coins. You love flowers, "
		.. "bad puns about bees, and you are mildly obsessed with your prize-winning hive "
		.. "named Bumbledore.",
	Greeting = "Buzz by for some honey? Press E and type away!",
	Model = "openai/gpt-5.4-nano", -- any model from Pollinations.listModels()
	MaxHistory = 10, -- remember the last 10 exchanges per player
})

-- ============================================================================
-- wiring: ProximityPrompt -> per-player conversation -> chat bubble reply
-- ============================================================================

local bellaModel = workspace:WaitForChild("PollenVillage"):WaitForChild("Bella")
local bodyPart = bellaModel:WaitForChild("Body")
local prompt = bodyPart:WaitForChild("Talk")

local conversations: {[number]: any} = {} -- [userId] = Npc object (own history per player)

local function getConversation(userId: number): any
	if conversations[userId] == nil then
		-- one Npc per player => each player gets their own conversation with Bella
		conversations[userId] = NpcDialogue.new(Pollinations, {
			Name = bella.Name,
			Persona = bella.Persona,
			Model = bella.Model,
			MaxHistory = bella.MaxHistory,
			ApiKey = bella.ApiKey,
			Extra = bella.Extra,
		})
	end
	return conversations[userId]
end

Players.PlayerRemoving:Connect(function(player)
	conversations[player.UserId] = nil -- free the memory when they leave
end)

-- Players say things in Roblox's chat (press / to open it) — every message is
-- sent to Bella while the player is near her. (A dedicated chat UI via
-- RemoteEvents is a nice upgrade; plain chat keeps the demo to one script.)

local function showBubble(part: BasePart, text: string)
	local bubble = Instance.new("BillboardGui")
	bubble.Size = UDim2.fromScale(0.5, 0.25)
	bubble.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	bubble.AlwaysOnTop = true
	bubble.MaxDistance = 40

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.35
	label.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	label.TextColor3 = Color3.fromRGB(255, 245, 200)
	label.TextScaled = true
	label.TextWrapped = true
	label.Text = text
	label.Parent = bubble

	bubble.Parent = part
	task.delay(8, function()
		bubble:Destroy()
	end)
end

prompt.Triggered:Connect(function(player: Player)
	local conversation = getConversation(player.UserId)

	-- First interaction shows the greeting; afterwards remind them how to reply.
	local history = conversation:GetHistory()
	if #history == 0 then
		showBubble(bodyPart, bella.Greeting or "Hello!")
	else
		showBubble(bodyPart, "Type in the chat — I'm listening!")
	end
end)

-- ============================================================================
-- listening for player chat aimed at Bella
-- ============================================================================

Players.PlayerAdded:Connect(function(player)
	player.Chatted:Connect(function(message: string)
		local lower = message:lower()
		local isGreetingExit = lower == "bye" or lower == "goodbye"

		local conversation = getConversation(player.UserId)
		local result = conversation:Say(message)

		if result.ok then
			showBubble(bodyPart, ("%s: %s"):format(bella.Name, result.content))
			if isGreetingExit then
				conversation:ClearHistory()
				showBubble(bodyPart, "Buzz off anytime, friend! 🐝")
			end
		else
			showBubble(bodyPart, ("(Bella is daydreaming — %s)"):format(tostring(result.error)))
			warn(("[PollinationsDemo] %s: %s"):format(bella.Name, tostring(result.error)))
		end
	end)
end)

print(("[PollinationsDemo] %s is ready to chat — walk up and press E!"):format(bella.Name))

-- ============================================================================
-- decorative sign text (created at runtime so the Rojo project stays minimal)
-- ============================================================================

local sign = workspace:WaitForChild("PollenVillage"):WaitForChild("Sign")
do
	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.CanvasSize = Vector2.new(800, 200)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 242, 179)
	label.TextScaled = true
	label.Text = "Welcome to Pollen Village — press E to talk to Bella! (AI-powered NPC)"
	label.Parent = surfaceGui

	surfaceGui.Parent = sign
end
