--[[
	testez_spec.luau — the same suite as a TestEZ spec (for Roblox Studio's test runner).

	Setup in Studio (one-time):
		1. Install TestEZ into ReplicatedStorage.Packages.TestEZ
		   (https://github.com/roblox/testez — `TestEZ` folder from the repo).
		2. Put this file and Pollinations.lua / NpcDialogue.lua / json.luau into
		   ReplicatedStorage (e.g. via Rojo with the provided default.project.json).
		3. Run this from the command bar:

		   local TestEZ = require(game.ReplicatedStorage.Packages.TestEZ)
		   local results = TestEZ.runBootstrap(game.ReplicatedStorage.tests)
		   print(results)

	The suite is runner-agnostic: `describe/it/expect` below are thin shims over
	the harness in test_pollinations.luau's core, so the SAME assertions run under
	plain `luau`, `lune`, and TestEZ.
]]

return function(TestEZ: any)
	local Json = require("./json")
	local Root = require("../src/Pollinations")
	local NpcDialogue = require("../src/NpcDialogue")

	local function makeFakeHttp(responses)
		local fake = { Requests = {}, Responses = responses or {} }
		function fake:RequestAsync(options)
			table.insert(self.Requests, options)
			local nextResponse = table.remove(self.Responses, 1)
			if nextResponse == nil then
				return { Success = true, StatusCode = 200, Body = '{"choices":[{"message":{"content":"fallback"}}]}' }
			end
			return { Success = true, StatusCode = nextResponse.status, Body = nextResponse.body }
		end
		function fake:JSONEncode(value)
			return Json.encode(value)
		end
		function fake:JSONDecode(text)
			return Json.decode(text)
		end
		return fake
	end

	return TestEZ.describe("Pollinations", function()
		beforeEach(function()
			Root.Configure({ Retries = 0 })
		end)

		it("validates messages purely", function()
			expect(Root.validateMessages({})).to.equal("messages must contain at least one message")
			expect(Root.validateMessages({ { role = "user", content = "hi" } })).to.equal(nil)
		end)

		it("builds a request with fake HttpService", function()
			local fake = makeFakeHttp({ { status = 200, body = '{"choices":[{"message":{"content":"hi player"}}]}' } })
			Root.Configure({ Http = fake })
			local result = Root.chat("openai/gpt-5.4-nano", { { role = "user", content = "hello" } })
			expect(result.ok).to.equal(true)
			expect(result.content).to.equal("hi player")
			expect(fake.Requests[1].Url).to.equal("https://gen.pollinations.ai/v1/chat/completions")
		end)

		it("keeps per-NPC history", function()
			local fake = makeFakeHttp({ { status = 200, body = '{"choices":[{"message":{"content":"I sell honey!"}}]}' } })
			Root.Configure({ Http = fake })
			local npc = NpcDialogue.new(Root, { Name = "Bella", Persona = "You are Bella." })
			local result = npc:Say("what do you sell?")
			expect(result.ok).to.equal(true)
			expect(#npc:GetHistory()).to.equal(2)
		end)
	end)
end
