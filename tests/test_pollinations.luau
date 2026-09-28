-- Pure-Luau test harness (no external deps). Works under plain `luau`, luajit-free,
-- and under lune via tests/run_lune.luau.
-- Run:  tools/luau tests/test_pollinations.luau

type TestResult = {
	name: string,
	passed: boolean,
	detail: string?,
}

local Results: {TestResult} = {}

local CurrentFailed: string? = nil

local function run(name: string, fn: () -> ())
	CurrentFailed = nil
	local ok, err = pcall(fn)
	if not ok then
		CurrentFailed = tostring(err)
	end
	table.insert(Results, {
		name = name,
		passed = CurrentFailed == nil,
		detail = CurrentFailed,
	})
	CurrentFailed = nil
end

--- assert helpers: record failure and abort the current test via error()
local function fail(message: string)
	error(message, 0)
end

local function expectEqual(actual: any, expected: any, label: string?)
	if actual ~= expected then
		fail(("%s: expected %q, got %q"):format(label or "value", tostring(expected), tostring(actual)))
	end
end

local Json = require("./json")
local Root = require("../src/Pollinations")
local NpcDialogue = require("../src/NpcDialogue")

-- === shared fake HttpService ================================================

--- Build an HttpService stand-in that records requests and returns queued responses.
local function makeFakeHttp(responses: {{status: number, body: string}}?)
	local fake: any = {}
	fake.Requests = {}
	fake.Responses = responses or {}
	fake.EncodeCalls = 0
	fake.DecodeCalls = 0

	function fake:RequestAsync(options)
		table.insert(self.Requests, options)
		local nextResponse = table.remove(self.Responses, 1)
		if nextResponse == nil then
			return {
				Success = true,
				StatusCode = 200,
				Body = '{"choices":[{"message":{"role":"assistant","content":"fallback reply"},"finish_reason":"stop"}],"usage":{"total_tokens":7},"model":"fallback-model"}',
			}
		end
		return { Success = true, StatusCode = nextResponse.status, Body = nextResponse.body }
	end

	function fake:JSONEncode(value)
		self.EncodeCalls += 1
		return Json.encode(value)
	end

	function fake:JSONDecode(text)
		self.DecodeCalls += 1
		return Json.decode(text)
	end

	return fake
end

-- === json.luau sanity =======================================================

run("json encode basic", function()
	expectEqual(Json.encode({ a = "hi", n = 3, arr = { 1, 2 } }), '{"a":"hi","arr":[1,2],"n":3}', "encode")
end)

run("json encode escapes", function()
	expectEqual(Json.encode('he said "hi"\n'), '"he said \\"hi\\"\\n"', "escape")
end)

run("json decode object", function()
	local value = Json.decode('{"x": [1, 2.5, null, true], "y": {"z": "w"}}')
	expectEqual(value.x[1], 1, "x[1]")
	expectEqual(value.x[2], 2.5, "x[2]")
	if value.x[3] == Json.NULL then
		-- correct: JSON null -> sentinel
	else
		fail("x[3] should decode to Json.NULL, got: " .. tostring(value.x[3]))
	end
	expectEqual(value.x[4], true, "x[4]")
	expectEqual(value.y.z, "w", "y.z")
end)

run("json decode real pollinations success body", function()
	-- Captured live from POST https://gen.pollinations.ai/v1/chat/completions (2026-09-27)
	local body = '{"choices":[{"content_filter_results":{},"finish_reason":"stop","index":0,"logprobs":null,"message":{"annotations":[],"content":"Hello, how are you?","refusal":null,"role":"assistant"}}],"created":1790254962,"id":"chatcmpl-x","model":"gpt-5.4-nano-2026-03-17","object":"chat.completion","usage":{"completion_tokens":9,"prompt_tokens":21,"total_tokens":30}}'
	local decoded = Json.decode(body)
	expectEqual(decoded.choices[1].message.content, "Hello, how are you?", "content")
	expectEqual(decoded.choices[1].finish_reason, "stop", "finish_reason")
	expectEqual(decoded.usage.total_tokens, 30, "usage")
end)

run("json decode real pollinations 401 error body", function()
	-- Captured live (2026-09-27): {"success":false,"error":{"message":"A valid API key is required. Get one at https://enter.pollinations.ai/keys","code":"UNAUTHORIZED"},"status":401}
	local body = '{"success":false,"error":{"message":"A valid API key is required. Get one at https://enter.pollinations.ai/keys","code":"UNAUTHORIZED"},"status":401}'
	local decoded = Json.decode(body)
	expectEqual(decoded.error.code, "UNAUTHORIZED", "error.code")
	expectEqual(decoded.status, 401, "status")
end)

-- === pure helpers ===========================================================

run("encodeUriComponent", function()
	expectEqual(Root.encodeUriComponent("hello world"), "hello%20world", "space")
	expectEqual(Root.encodeUriComponent("a/b?c&d=e"), "a%2Fb%3Fc%26d%3De", "specials")
	expectEqual(Root.encodeUriComponent("héllo"), "h%C3%A9llo", "utf8")
	expectEqual(Root.encodeUriComponent("safe-._~"), "safe-._~", "unreserved")
end)

run("backoffMs", function()
	expectEqual(Root.backoffMs(1), 500, "attempt1")
	expectEqual(Root.backoffMs(2), 1000, "attempt2")
	expectEqual(Root.backoffMs(3), 2000, "attempt3")
	expectEqual(Root.backoffMs(10), 8000, "capped")
end)

run("classifyStatus", function()
	expectEqual(Root.classifyStatus(401), "auth", "401")
	expectEqual(Root.classifyStatus(403), "auth", "403")
	expectEqual(Root.classifyStatus(429), "rate_limit", "429")
	expectEqual(Root.classifyStatus(500), "server", "500")
	expectEqual(Root.classifyStatus(404), "http", "404")
end)

run("validateMessages", function()
	expectEqual(Root.validateMessages({ { role = "user", content = "hi" } }), nil, "valid")
	expectEqual(Root.validateMessages({}), "messages must contain at least one message", "empty")
	expectEqual(Root.validateMessages("nope"), "messages must be an array of { role = string, content = string }", "not array")
	expectEqual(Root.validateMessages({ { role = "user" } }), "messages[1] must be { role = string, content = string }", "missing content")
end)

-- === chat() with fake Http ==================================================

run("chat happy path", function()
	local fake = makeFakeHttp({ { status = 200, body = '{"choices":[{"message":{"content":"hi player"},"finish_reason":"stop"}],"model":"test-model","usage":{"total_tokens":5}}' } })
	Root.Configure({ Http = fake, Retries = 0 })
	local result = Root.chat("openai/gpt-5.4-nano", { { role = "user", content = "hello" } })

	expectEqual(result.ok, true, "ok")
	expectEqual(result.content, "hi player", "content")
	expectEqual(result.model, "test-model", "model")
	expectEqual(result.attempts, 1, "attempts")
	expectEqual(#fake.Requests, 1, "request count")

	local req = fake.Requests[1]
	expectEqual(req.Url, "https://gen.pollinations.ai/v1/chat/completions", "url")
	expectEqual(req.Method, "POST", "method")
	expectEqual(req.Headers["Content-Type"], "application/json", "content-type header")
	local body = Json.decode(req.Body)
	expectEqual(body.model, "openai/gpt-5.4-nano", "body.model")
	expectEqual(body.messages[1].role, "user", "body.messages[1].role")
	expectEqual(body.messages[1].content, "hello", "body.messages[1].content")
end)

run("chat sends Authorization header when ApiKey set", function()
	local fake = makeFakeHttp()
	Root.Configure({ Http = fake, Retries = 0, ApiKey = "pk_test_123" })
	local result = Root.chat("m", { { role = "user", content = "x" } })
	expectEqual(result.ok, true, "ok")
	expectEqual(fake.Requests[1].Headers["Authorization"], "Bearer pk_test_123", "auth header")
	Root.Configure({ ApiKey = nil })
end)

run("chat 401 -> auth failure, no retry", function()
	local fake = makeFakeHttp({ { status = 401, body = '{"success":false,"error":{"message":"A valid API key is required. Get one at https://enter.pollinations.ai/keys","code":"UNAUTHORIZED"},"status":401}' } })
	Root.Configure({ Http = fake, Retries = 2 })
	local result = Root.chat("m", { { role = "user", content = "x" } })
	expectEqual(result.ok, false, "ok")
	expectEqual(result.kind, "auth", "kind")
	expectEqual(#fake.Requests, 1, "no retry on 401")
	if result.error and result.error:find("enter.pollinations.ai/keys", 1, true) then
		-- hint present, good
	else
		fail("auth error should include key hint, got: " .. tostring(result.error))
	end
end)

run("chat 429 -> retries with backoff then fails", function()
	local fake = makeFakeHttp({
		{ status = 429, body = '{"error":{"message":"slow down"}}' },
		{ status = 429, body = '{"error":{"message":"slow down"}}' },
		{ status = 429, body = '{"error":{"message":"slow down"}}' },
	})
	local sleeps = {}
	Root.Configure({ Http = fake, Retries = 2, Sleep = function(s) table.insert(sleeps, s) end })
	local result = Root.chat("m", { { role = "user", content = "x" } })
	expectEqual(result.ok, false, "ok")
	expectEqual(result.kind, "rate_limit", "kind")
	expectEqual(#fake.Requests, 3, "1 + 2 retries")
	expectEqual(#sleeps, 2, "sleeps between retries")
	expectEqual(sleeps[1], 0.5, "first backoff seconds")
	expectEqual(sleeps[2], 1, "second backoff seconds")
end)

run("chat 429 then 200 -> recovers", function()
	local fake = makeFakeHttp({
		{ status = 429, body = "slow down" },
		{ status = 200, body = '{"choices":[{"message":{"content":"recovered"}}]}' },
	})
	Root.Configure({ Http = fake, Retries = 2, Sleep = function() end })
	local result = Root.chat("m", { { role = "user", content = "x" } })
	expectEqual(result.ok, true, "ok")
	expectEqual(result.content, "recovered", "content")
	expectEqual(result.attempts, 2, "attempts")
end)

run("chat 500 -> server kind", function()
	local fake = makeFakeHttp({ { status = 500, body = "boom" } })
	Root.Configure({ Http = fake, Retries = 0 })
	local result = Root.chat("m", { { role = "user", content = "x" } })
	expectEqual(result.kind, "server", "kind")
	expectEqual(result.status, 500, "status")
end)

run("chat malformed 200 body -> parse kind", function()
	local fake = makeFakeHttp({ { status = 200, body = 'not json {' } })
	Root.Configure({ Http = fake, Retries = 0 })
	local result = Root.chat("m", { { role = "user", content = "x" } })
	expectEqual(result.kind, "parse", "kind")
end)

run("chat 200 without choices -> parse kind", function()
	local fake = makeFakeHttp({ { status = 200, body = '{"object":"chat.completion"}' } })
	Root.Configure({ Http = fake, Retries = 0 })
	local result = Root.chat("m", { { role = "user", content = "x" } })
	expectEqual(result.kind, "parse", "kind")
end)

run("chat invalid args -> bad_request without any HTTP call", function()
	local fake = makeFakeHttp()
	Root.Configure({ Http = fake, Retries = 0 })
	local r1 = Root.chat(nil, { { role = "user", content = "x" } })
	local r2 = Root.chat("m", "not-a-table")
	local r3 = Root.chat("m", {})
	expectEqual(r1.kind, "bad_request", "nil model")
	expectEqual(r2.kind, "bad_request", "messages not table")
	expectEqual(r3.kind, "bad_request", "empty messages")
	expectEqual(#fake.Requests, 0, "no http calls")
end)

run("chat opts override config", function()
	local fake = makeFakeHttp({ { status = 200, body = '{"choices":[{"message":{"content":"ok"}}]}' } })
	Root.Configure({ Http = fake, Retries = 5, ApiKey = "pk_config" })
	local result = Root.chat("m", { { role = "user", content = "x" } }, { Retries = 0, ApiKey = "pk_opt" })
	expectEqual(result.ok, true, "ok")
	expectEqual(#fake.Requests, 1, "opts Retries=0 prevents retries")
	expectEqual(fake.Requests[1].Headers["Authorization"], "Bearer pk_opt", "opts ApiKey wins")
	Root.Configure({ ApiKey = nil })
end)

run("chat Temperature/MaxTokens/Extra reach the body", function()
	local fake = makeFakeHttp({ { status = 200, body = '{"choices":[{"message":{"content":"ok"}}]}' } })
	Root.Configure({ Http = fake, Retries = 0 })
	Root.chat("m", { { role = "user", content = "x" } }, { Temperature = 0.7, MaxTokens = 120, Extra = { stop = "STOP" } })
	local body = Json.decode(fake.Requests[1].Body)
	expectEqual(body.temperature, 0.7, "temperature")
	expectEqual(body.max_tokens, 120, "max_tokens")
	expectEqual(body.stop, "STOP", "extra stop")
end)

-- === ask() ==================================================================

run("ask GET one-shot", function()
	local fake = makeFakeHttp({ { status = 200, body = "a tiny poem" } })
	Root.Configure({ Http = fake, Retries = 0 })
	local result = Root.ask("write a haiku about bees", { Model = "openai/gpt-5.4-nano" })
	expectEqual(result.ok, true, "ok")
	expectEqual(result.content, "a tiny poem", "content")
	local req = fake.Requests[1]
	expectEqual(req.Method, "GET", "method")
	expectEqual(req.Url, "https://gen.pollinations.ai/text/write%20a%20haiku%20about%20bees?model=openai%2Fgpt-5.4-nano", "url")
end)

run("ask empty prompt -> bad_request", function()
	local fake = makeFakeHttp()
	Root.Configure({ Http = fake, Retries = 0 })
	expectEqual(Root.ask("", {}).kind, "bad_request", "kind")
	expectEqual(#fake.Requests, 0, "no http call")
end)

-- === listModels() ===========================================================

run("listModels decodes live-format list", function()
	local fake = makeFakeHttp({ { status = 200, body = '[{"name":"openai/gpt-5.4-nano","category":"text","health":{"status":"healthy"}}]' } })
	Root.Configure({ Http = fake, Retries = 0 })
	local result = Root.listModels({})
	expectEqual(result.ok, true, "ok")
	expectEqual(result.models[1].name, "openai/gpt-5.4-nano", "models[1].name")
	expectEqual(fake.Requests[1].Url, "https://gen.pollinations.ai/text/models", "url")
end)

-- === NpcDialogue ============================================================

run("npc builds persona + history + new message", function()
	local messages = NpcDialogue.buildMessages(
		"You are Bella.",
		{
			{ role = "user", content = "hi" },
			{ role = "assistant", content = "hello!" },
		},
		"what do you sell?",
		12
	)
	expectEqual(#messages, 4, "system + 2 history + new")
	expectEqual(messages[1].role, "system", "system first")
	expectEqual(messages[1].content, "You are Bella.", "persona")
	expectEqual(messages[2].content, "hi", "history[1]")
	expectEqual(messages[4].content, "what do you sell?", "new message last")
end)

run("npc default persona when none given", function()
	local messages = NpcDialogue.buildMessages(nil, {}, "hey", 12)
	expectEqual(messages[1].role, "system", "system role")
	if messages[1].content:find("NPC", 1, true) then
		-- ok
	else
		fail("default persona should mention NPC, got: " .. tostring(messages[1].content))
	end
end)

run("npc trims history to MaxHistory turns", function()
	local history = {}
	for i = 1, 30 do
		table.insert(history, { role = (i % 2 == 1) and "user" or "assistant", content = "turn" .. i })
	end
	-- MaxHistory = 3 turns -> last 6 messages + system + new = 8
	local messages = NpcDialogue.buildMessages("p", history, "new", 3)
	expectEqual(#messages, 8, "system + 6 history + new")
	expectEqual(messages[2].content, "turn25", "first kept turn")
	expectEqual(messages[7].content, "turn30", "last kept turn")
end)

run("npc full conversation flow with fake http", function()
	local fake = makeFakeHttp({
		{ status = 200, body = '{"choices":[{"message":{"content":"I sell honey!"}}]}' },
		{ status = 200, body = '{"choices":[{"message":{"content":"Five coins per jar."}}]}' },
	})
	Root.Configure({ Http = fake, Retries = 0 })
	local npc = NpcDialogue.new(Root, { Name = "Bella", Persona = "You are Bella, a beekeeper.", Model = "openai/gpt-5.4-nano" })

	local r1 = npc:Say("what do you sell?")
	expectEqual(r1.ok, true, "r1 ok")
	expectEqual(r1.content, "I sell honey!", "r1 content")
	expectEqual(r1.npc, "Bella", "r1 npc name")

	local r2 = npc:Say("how much?")
	expectEqual(r2.ok, true, "r2 ok")

	-- second call must include turn 1 in history
	local body2 = Json.decode(fake.Requests[2].Body)
	expectEqual(#body2.messages, 4, "system + u1 + a1 + new user")
	expectEqual(body2.messages[2].content, "what do you sell?", "remembered user turn")
	expectEqual(body2.messages[3].content, "I sell honey!", "remembered assistant turn")

	local history = npc:GetHistory()
	expectEqual(#history, 4, "2 exchanges = 4 entries")
	npc:ClearHistory()
	expectEqual(#npc:GetHistory(), 0, "cleared")
end)

run("npc failed call does not pollute history", function()
	local fake = makeFakeHttp({
		{ status = 500, body = "boom" },
		{ status = 200, body = '{"choices":[{"message":{"content":"ok"}}]}' },
	})
	Root.Configure({ Http = fake, Retries = 0 })
	local npc = NpcDialogue.new(Root, {})
	expectEqual(npc:Say("hello").ok, false, "first call fails")
	expectEqual(#npc:GetHistory(), 0, "history untouched after failure")
	expectEqual(npc:Say("hello again").ok, true, "second call works")
	expectEqual(#npc:GetHistory(), 2, "one exchange remembered")
end)

run("npc per-instance isolation", function()
	local fake = makeFakeHttp({ { status = 200, body = '{"choices":[{"message":{"content":"ok"}}]}' } })
	Root.Configure({ Http = fake, Retries = 0 })
	local a = NpcDialogue.new(Root, { Name = "A" })
	local b = NpcDialogue.new(Root, { Name = "B" })
	a:Say("hi")
	expectEqual(#a:GetHistory(), 2, "a history")
	expectEqual(#b:GetHistory(), 0, "b history untouched")
end)

run("npc rejects empty message without http call", function()
	local fake = makeFakeHttp()
	Root.Configure({ Http = fake, Retries = 0 })
	local npc = NpcDialogue.new(Root, {})
	local result = npc:Say("")
	expectEqual(result.ok, false, "ok")
	expectEqual(result.kind, "bad_request", "kind")
	expectEqual(#fake.Requests, 0, "no http call")
end)

-- === report =================================================================

local passed = 0
local failed = 0
print("\n=== pollinations-roblox test suite ===")
for _, result in ipairs(Results) do
	if result.passed then
		passed += 1
		print(("  PASS  %s"):format(result.name))
	else
		failed += 1
		print(("  FAIL  %s"):format(result.name))
		print(("        %s"):format(tostring(result.detail)))
	end
end
print(("=== %d passed, %d failed ==="):format(passed, failed))

if failed > 0 then
	error(("%d test(s) failed"):format(failed), 0)
end
