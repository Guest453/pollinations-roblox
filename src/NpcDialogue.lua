--[[
	NpcDialogue.lua — give an NPC a persona and a memory, talk to it in one call.

	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Pollinations = require(ReplicatedStorage.Pollinations)
	local NpcDialogue = require(ReplicatedStorage.NpcDialogue)

	local beekeeper = NpcDialogue.new(Pollinations, {
		Name = "Bella the Beekeeper",     -- used in logs/errors
		Persona = "You are Bella, a friendly bee-keeper NPC in a cozy farming game. Keep replies under 2 sentences.",
		Greeting = "Buzz by for some honey?", -- optional, pure sugar for your UI
		Model = "openai/gpt-5.4-nano",   -- optional override
		MaxHistory = 12,                 -- max kept user/assistant turns (system prompt never trimmed)
		ApiKey = someSecret,             -- optional override (Pollinations.Configure is usually enough)
	})

	local result = beekeeper:Say("what do you sell?")
	if result.ok then
		print(beekeeper.Name .. " says: " .. result.content)
	end

	Per-NPC conversation history is kept automatically: every Say() sends the
	persona + the last MaxHistory turns so the NPC remembers the conversation.
	History is per NPC object — create one per NPC (not per player; see README
	for a per-player pattern).

	Like Pollinations.chat, Say() never throws: it returns
		{ ok = true,  content = "...", ... }        (all chat() success fields)
		{ ok = false, kind = "...", error = "..." }

	SERVER ONLY (HttpService is server-side). Surface replies to players through
	RemoteEvents / chat bubbles — see the demo scripts in /demo.
]]

local NpcDialogue = {}

export type Npc = {
	Name: string,
	Greeting: string?,
	Say: (self: Npc, playerMessage: string, opts: {[string]: any}?) -> {[string]: any},
	SayAsync: (self: Npc, playerMessage: string, callback: (result: {[string]: any}) -> nil?) -> (),
	GetHistory: (self: Npc) -> {{role: string, content: string}},
	ClearHistory: (self: Npc) -> (),
	Reset: (self: Npc) -> (),
}

local DEFAULT_MAX_HISTORY = 12

local function cloneHistory(history: {[number]: {role: string, content: string}}): {{role: string, content: string}}
	local out = {}
	for index = 1, #history do
		out[index] = { role = history[index].role, content = history[index].content }
	end
	return out
end

--- Build a chat-ready message list: system persona + trimmed history + the new player message.
--- (Pure — unit-tested in /tests/test_npc_logic.luau.)
local function buildMessages(persona: string?, history: {[number]: {role: string, content: string}}, playerMessage: string, maxHistory: number): {any}
	local systemPrompt = persona
		or "You are a friendly NPC in a Roblox game. Stay in character, keep replies short and fun."

	local historyLimit = math.max(0, maxHistory) * 2 -- turns = user + assistant pairs
	local startIndex = math.max(1, #history - historyLimit + 1)

	local messages: {any} = {}
	table.insert(messages, { role = "system", content = systemPrompt })
	for index = startIndex, #history do
		table.insert(messages, { role = history[index].role, content = history[index].content })
	end
	table.insert(messages, { role = "user", content = playerMessage })
	return messages
end

NpcDialogue.buildMessages = buildMessages -- exposed for tests

--- Create an NPC. `pollinations` is the required Pollinations module (injected so
--- this helper stays testable and dependency-free).
function NpcDialogue.new(pollinations: any, config: {[string]: any}?): Npc
	assert(type(pollinations) == "table", "NpcDialogue.new requires the Pollinations module as the first argument")
	assert(config == nil or type(config) == "table", "config must be a table")

	local options: {[string]: any} = config or {}
	assert(type(options.Persona) == "string" or options.Persona == nil, "Persona must be a string")
	assert(type(options.MaxHistory) == "number" or options.MaxHistory == nil, "MaxHistory must be a number")

	local self: any = {
		Pollinations = pollinations,
		Name = tostring(options.Name or "NPC"),
		Greeting = options.Greeting,
		Persona = options.Persona,
		Model = options.Model, -- nil -> Pollinations default
		MaxHistory = options.MaxHistory or DEFAULT_MAX_HISTORY,
		ApiKey = options.ApiKey,
		Extra = options.Extra, -- extra body params forwarded to chat()
		_history = {}, -- { { role = "user"|"assistant", content = string }, ... }
	}

	function self:Say(playerMessage: string, opts: {[string]: any}?): {[string]: any}
		if type(playerMessage) ~= "string" or playerMessage == "" then
			return { ok = false, kind = "bad_request", error = "playerMessage must be a non-empty string" }
		end

		local callOpts: {[string]: any} = {
			ApiKey = self.ApiKey,
			Extra = self.Extra,
		}
		if type(opts) == "table" then
			for key, value in pairs(opts) do
				callOpts[key] = value
			end
		end

		local messages = buildMessages(self.Persona, self._history, playerMessage, self.MaxHistory)
		-- fall back to the Pollinations module default when the NPC has no model
		local model = self.Model or self.Pollinations.DefaultModel
		local result = self.Pollinations.chat(model, messages, callOpts)

		if result.ok then
			table.insert(self._history, { role = "user", content = playerMessage })
			table.insert(self._history, { role = "assistant", content = result.content })
			result.npc = self.Name
		end
		return result
	end

	--- Fire-and-forget variant: runs Say() in its own thread, calls callback(result).
	function self:SayAsync(playerMessage: string, callback: ((result: {[string]: any}) -> nil)?)
		local spawnTask: any = task
		local spawnFn = (type(spawnTask) == "table" and spawnTask.spawn) or function(fn, ...)
			fn(...) -- standalone Luau fallback (tests); in Roblox task.spawn is always available
		end
		spawnFn(function()
			local result = self:Say(playerMessage)
			if type(callback) == "function" then
				callback(result)
			end
		end)
	end

	function self:GetHistory()
		return cloneHistory(self._history)
	end

	function self:ClearHistory()
		self._history = {}
	end

	self.Reset = self.ClearHistory

	return self
end

NpcDialogue.DefaultMaxHistory = DEFAULT_MAX_HISTORY

return NpcDialogue
