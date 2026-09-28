--[[
	Pollinations.lua — Roblox/Luau client for the Pollinations text APIs.

	Gives your NPCs conversations powered by Pollinations (https://pollinations.ai)
	with a few lines of Luau:

		local Pollinations = require(game:GetService("ReplicatedStorage").Pollinations)

		local result = Pollinations.chat("openai/gpt-5.4-nano", {
			{ role = "system", content = "You are a friendly bee-keeper NPC." },
			{ role = "user", content = "hello!" },
		})
		print(result.ok, result.content)

	ENDPOINTS USED (verified 2026-09):
		POST https://gen.pollinations.ai/v1/chat/completions   { model, messages }
		GET  https://gen.pollinations.ai/text/models           live model list
		GET  https://gen.pollinations.ai/text/{prompt}         one-shot plain text

	AUTH:
		API keys are free at https://enter.pollinations.ai/keys (spends Pollen).
		Anonymous requests MAY work in trial windows but usually return 401 — configure
		a key for your game (see README).

		Recommended on Roblox: keep the key in Roblox's secrets store
		(https://create.roblox.com/docs/cloud-services/secrets), server-side only:

			local secret = game:GetService("HttpService"):GetSecret("pollinations_key")
			Pollinations.Configure({ ApiKey = secret })          -- Secret object, or...
			Pollinations.Configure({ ApiKey = "pk_..." })        -- plain string, or...
			local res = Pollinations.chat(model, messages, { ApiKey = secret })

		Secret objects are never printed/stringified by this module; they are only
		attached to the outgoing Authorization header via Secret:AddPrefix().

	IMPORTANT — SERVER ONLY:
		HttpService is server-side. Require this module from a Script in
		ServerScriptService (or a ModuleScript required by one). Never trust the
		client: expose NPC replies to players via RemoteEvents / chat bubbles, not
		by calling this module from LocalScripts.

	THIS MODULE NEVER THROWS on API failures: `chat` returns a result table:
		{ ok = true,  content = "...", model = "...", usage = {...}, ... }
		{ ok = false, kind = "auth"|"rate_limit"|"server"|"network"|"http"|"parse"|"encode"|"bad_request", error = "..." }

	Runs on Roblox (HttpService) and in plain Luau CLIs (lune/luau) when you
	inject Http/JsonEncode/JsonDecode — which is how the tests in /tests run.
]]

local Pollinations = {}

-- === configuration ==========================================================

local DEFAULT_MODEL = "openai/gpt-5.4-nano" -- free tier, healthy on the live list
local DEFAULT_BASE_URL = "https://gen.pollinations.ai"

local Config = {
	ApiKey = nil, -- string | Secret | nil
	Model = DEFAULT_MODEL,
	BaseUrl = DEFAULT_BASE_URL,
	Retries = 2, -- extra attempts for 429 / 5xx / transport errors
	Sleep = nil, -- function(seconds); inject in tests (Roblox default: task.wait)
	JsonEncode = nil, -- function(value) -> string
	JsonDecode = nil, -- function(json) -> value
	Http = nil, -- HttpService-like: { RequestAsync = function(self, opts) end }
}

--- Merge overrides into the module config. Unknown keys are ignored.
--- Values may also be passed per-call via opts (opts win over Configure).
function Pollinations.Configure(overrides: {[string]: any}?)
	if type(overrides) ~= "table" then
		return
	end
	for _, key in ipairs({ "ApiKey", "Model", "BaseUrl", "Retries", "Sleep", "JsonEncode", "JsonDecode", "Http" }) do
		if overrides[key] ~= nil then
			Config[key] = overrides[key]
		end
	end
end

-- Roblox environment detection (standalone Luau has no `game`; do not error here)
local HttpService: any = nil
do
	local ok, service = pcall(function()
		return game:GetService("HttpService") -- game only exists inside Roblox
	end)
	if ok then
		HttpService = service
	end
end

-- === pure helpers (unit-tested in /tests) ===================================

--- Percent-encode a string for use as a single URI component (RFC 3986).
function Pollinations.encodeUriComponent(value: string): string
	local out = value:gsub("[^%w%-_%.~]", function(ch)
		return string.format("%%%02X", ch:byte())
	end)
	return out
end

--- Backoff before retry `attempt` (1-based), in milliseconds: 500, 1000, 2000... capped at 8000.
function Pollinations.backoffMs(attempt: number): number
	return math.min(500 * (2 ^ (attempt - 1)), 8000)
end

--- Map an HTTP status code to a stable error `kind`.
function Pollinations.classifyStatus(statusCode: number): string
	if statusCode == 401 or statusCode == 403 then
		return "auth"
	elseif statusCode == 429 then
		return "rate_limit"
	elseif statusCode >= 500 then
		return "server"
	else
		return "http"
	end
end

local AUTH_HINT = "get a (free) API key at https://enter.pollinations.ai/keys and set it via "
	.. 'Pollinations.Configure({ ApiKey = HttpService:GetSecret("pollinations_key") }) — server-side only'

--- Validate the `messages` argument of chat(). Returns nil when valid, else a reason string.
function Pollinations.validateMessages(messages: any): string?
	if type(messages) ~= "table" then
		return "messages must be an array of { role = string, content = string }"
	end
	if #messages == 0 then
		return "messages must contain at least one message"
	end
	for i, msg in ipairs(messages) do
		if type(msg) ~= "table" or type(msg.role) ~= "string" or type(msg.content) ~= "string" then
			return string.format("messages[%d] must be { role = string, content = string }", i)
		end
	end
	return nil
end

local COPIED_CONFIG_KEYS = { "ApiKey", "Model", "BaseUrl", "Retries", "Sleep", "JsonEncode", "JsonDecode", "Http" }
local CALL_OVERRIDE_KEYS = { "ApiKey", "Retries", "Sleep", "Http", "JsonEncode", "JsonDecode" }

--- Copy module config, then apply per-call overrides on top (opts win).
local function makeCallConfig(opts: {[string]: any}, overrideKeys: {[number]: string}): {[string]: any}
	local cfg = {}
	for _, key in ipairs(COPIED_CONFIG_KEYS) do
		cfg[key] = Config[key]
	end
	for _, key in ipairs(overrideKeys) do
		if opts[key] ~= nil then
			cfg[key] = opts[key]
		end
	end
	return cfg
end

-- === internals ==============================================================

local function isSecretValue(value: any): boolean
	-- Roblox `Secret` data type: has an AddPrefix method, is not a plain string.
	-- We deliberately do not stringify it anywhere; secrets must never be printed.
	if type(value) ~= "userdata" and type(value) ~= "table" then
		return false
	end
	local ok, addPrefix = pcall(function()
		return (value :: any).AddPrefix
	end)
	return ok and type(addPrefix) == "function"
end

-- Returns the raw Bearer token value (NOT a "Header: value" string). The call
-- site sets it as the *value* of the Authorization header.
local function buildAuthToken(apiKey: any): (string?, string?)
	if apiKey == nil then
		return nil, nil
	end
	if isSecretValue(apiKey) then
		-- Secret:AddPrefix returns the secret with a prefix. Pass an empty prefix
		-- to get the raw key; the caller prepends "Bearer ". Secrets may be used
		-- in request headers, never the body.
		local ok, token = pcall(function()
			return (apiKey :: any):AddPrefix("")
		end)
		if ok and type(token) == "string" then
			return token, nil
		end
		return nil, "ApiKey looks like a Secret but Secret:AddPrefix failed"
	end
	if type(apiKey) == "string" then
		if apiKey == "" then
			return nil, "ApiKey is an empty string"
		end
		return apiKey, nil
	end
	return nil, "ApiKey must be a string or an HttpService Secret"
end

local function resolveHttp(cfg): any
	if cfg.Http ~= nil then
		return cfg.Http
	end
	if HttpService ~= nil then
		return HttpService
	end
	return nil, "no HTTP implementation: running outside Roblox? Inject Pollinations.Configure({ Http = ... })"
end

local function resolveJson(cfg, http): (any, any, string?)
	local encode = cfg.JsonEncode
	local decode = cfg.JsonDecode
	if encode == nil or decode == nil then
		-- fall back to the injected Http object's own JSON methods (it is
		-- HttpService in Roblox; in tests it is a fake with the same methods)
		if type(http) == "table" or type(http) == "userdata" then
			local httpAny = http :: any
			if encode == nil and type(httpAny.JSONEncode) == "function" then
				encode = function(value)
					return httpAny:JSONEncode(value)
				end
			end
			if decode == nil and type(httpAny.JSONDecode) == "function" then
				decode = function(text)
					return httpAny:JSONDecode(text)
				end
			end
		end
		if (encode == nil or decode == nil) and HttpService ~= nil then
			encode = encode or function(value)
				return HttpService:JSONEncode(value)
			end
			decode = decode or function(json)
				return HttpService:JSONDecode(json)
			end
		end
	end
	if encode == nil or decode == nil then
		return nil, nil,
			"no JSON implementation: running outside Roblox? Inject Pollinations.Configure({ JsonEncode = ..., JsonDecode = ... })"
	end
	return encode, decode, nil
end

local function errorBodySnippet(body: any): string
	if type(body) ~= "string" or body == "" then
		return ""
	end
	if #body > 300 then
		return body:sub(1, 300) .. "..."
	end
	return body
end

local function httpFailure(cfg, response, http): {[string]: any}
	local kind = Pollinations.classifyStatus(response.StatusCode or 0)
	local detail = errorBodySnippet(response.Body)

	-- The live API returns error bodies like:
	--   {"success":false,"error":{"message":"A valid API key is required...","code":"UNAUTHORIZED"},"status":401}
	-- Prefer the server's message when we can find it.
	local serverMessage: string? = nil
	local _, decode = resolveJson(cfg, http)
	if type(response.Body) == "string" and decode ~= nil then
		local okDecoded, decoded = pcall(decode, response.Body)
		if okDecoded and type(decoded) == "table" and type(decoded.error) == "table" then
			serverMessage = decoded.error.message
		end
	end

	local message = ("HTTP %d from Pollinations%s"):format(response.StatusCode or 0, serverMessage and (": " .. serverMessage) or (detail ~= "" and (": " .. detail) or ""))
	if kind == "auth" then
		message = message .. " — " .. AUTH_HINT
	elseif kind == "rate_limit" then
		message = message .. " — you are out of quota/credits; top up or switch model (https://gen.pollinations.ai/text/models)"
	end

	return {
		ok = false,
		kind = kind,
		status = response.StatusCode or 0,
		error = message,
	}
end

-- === public API =============================================================

--[[
	Pollinations.chat(model, messages, opts) -> result table (never throws)

	model     string  e.g. "openai/gpt-5.4-nano" — any entry from Pollinations.listModels()
	messages  array  OpenAI-style: { { role = "system"|"user"|"assistant", content = string }, ... }
	opts      table? per-call overrides:
		ApiKey       string | Secret
		Temperature  number (0..2)
		MaxTokens    number
		Retries      number  (default 2; retries only on 429/5xx/transport errors)
		Sleep        function(seconds)
		Http         HttpService-like object
		JsonEncode / JsonDecode functions
		Extra        table merged into the JSON body (tools, stop, response_format, ...)

	result.ok == true:  { ok, content, model, finishReason, usage, raw, attempts, latencyMs }
	result.ok == false: { ok, kind, status?, error }
]]
function Pollinations.chat(model: any, messages: any, opts: {[string]: any}?): {[string]: any}
	local started = os.clock()
	local options: {[string]: any} = opts or {}

	local cfg = makeCallConfig(options, CALL_OVERRIDE_KEYS)

	-- cheap pure validation first
	local invalid = Pollinations.validateMessages(messages)
	if invalid then
		return { ok = false, kind = "bad_request", error = invalid }
	end
	if type(model) ~= "string" or model == "" then
		return { ok = false, kind = "bad_request", error = 'model must be a string like "openai/gpt-5.4-nano" (see Pollinations.listModels())' }
	end

	local authToken, authError = buildAuthToken(cfg.ApiKey)
	if authError then
		return { ok = false, kind = "bad_request", error = authError }
	end

	local http, httpError = resolveHttp(cfg)
	if http == nil then
		return { ok = false, kind = "network", error = httpError }
	end

	local encode, decode, jsonError = resolveJson(cfg, http)
	if jsonError then
		return { ok = false, kind = "network", error = jsonError }
	end

	local body: {[string]: any} = {
		model = model,
		messages = messages,
	}
	if type(options.Temperature) == "number" then
		body.temperature = options.Temperature
	end
	if type(options.MaxTokens) == "number" then
		body.max_tokens = options.MaxTokens
	end
	if type(options.Extra) == "table" then
		for key, value in pairs(options.Extra) do
			body[key] = value
		end
	end

	local okEncoded, bodyJson = pcall(encode, body)
	if not okEncoded then
		return { ok = false, kind = "encode", error = "failed to JSON-encode request body: " .. tostring(bodyJson) }
	end

	local headers: {[string]: string} = {
		["Content-Type"] = "application/json",
	}
	if authToken then
		headers["Authorization"] = "Bearer " .. authToken
	end

	local attemptsAllowed = math.max(1, (tonumber(cfg.Retries) or 2) + 1)
	local lastFailure: {[string]: any}? = nil

	for attempt = 1, attemptsAllowed do
		local okRequest, response = pcall(function()
			return http:RequestAsync({
				Url = cfg.BaseUrl .. "/v1/chat/completions",
				Method = "POST",
				Headers = headers,
				Body = bodyJson,
			})
		end)

		if not okRequest then
			-- transport-level failure (DNS, offline, HttpEnabled=false, throttling)
			return {
				ok = false,
				kind = "network",
				error = "HttpService:RequestAsync failed: " .. tostring(response)
					.. " — is Game Settings > Security > Allow HTTP Requests enabled?",
			}
		end

		local statusCode = tonumber(response.StatusCode) or 0
		if response.Success == false then
			-- Roblox: Success=false means the request did not complete (transport error)
			return {
				ok = false,
				kind = "network",
				status = statusCode,
				error = "request did not complete (HttpService Success=false, status "
					.. tostring(statusCode) .. ") — check Allow HTTP Requests and your network",
			}
		end

		if statusCode == 200 then
			local okDecoded, decoded = pcall(decode, response.Body)
			if not okDecoded then
				return { ok = false, kind = "parse", status = statusCode, error = "failed to decode response JSON: " .. tostring(decoded) }
			end
			local content: any = nil
			local finishReason: any = nil
			if type(decoded) == "table" and type(decoded.choices) == "table" and type(decoded.choices[1]) == "table" then
				local choice = decoded.choices[1]
				if type(choice.message) == "table" then
					content = choice.message.content
				end
				finishReason = choice.finish_reason
			end
			if type(content) ~= "string" then
				return { ok = false, kind = "parse", status = statusCode, error = "response JSON had no choices[1].message.content: " .. errorBodySnippet(response.Body) }
			end
			return {
				ok = true,
				content = content,
				model = type(decoded) == "table" and decoded.model or nil,
				finishReason = finishReason,
				usage = type(decoded) == "table" and decoded.usage or nil,
				raw = decoded,
				attempts = attempt,
				latencyMs = math.floor((os.clock() - started) * 1000),
			}
		end

		lastFailure = httpFailure(cfg, response, http)
		local retriable = statusCode == 429 or statusCode >= 500
		if not retriable or attempt == attemptsAllowed then
			return lastFailure :: {[string]: any}
		end
		if type(cfg.Sleep) == "function" then
			cfg.Sleep(Pollinations.backoffMs(attempt) / 1000)
		end
	end

	-- unreachable (loop always returns), kept for safety
	return lastFailure or { ok = false, kind = "http", error = "unreachable retry state" }
end

--[[
	Pollinations.ask(prompt, opts) -> result table
	One-shot sugar over GET /text/{prompt}?model=... — returns { ok, content } on success.
]]
function Pollinations.ask(prompt: any, opts: {[string]: any}?): {[string]: any}
	local options: {[string]: any} = opts or {}
	local started = os.clock()

	local cfg = makeCallConfig(options, CALL_OVERRIDE_KEYS)

	if type(prompt) ~= "string" or prompt == "" then
		return { ok = false, kind = "bad_request", error = "prompt must be a non-empty string" }
	end

	local http, httpError = resolveHttp(cfg)
	if http == nil then
		return { ok = false, kind = "network", error = httpError }
	end

	local url = cfg.BaseUrl .. "/text/" .. Pollinations.encodeUriComponent(prompt)
		.. "?model=" .. Pollinations.encodeUriComponent(tostring(options.Model or cfg.Model))

	local authToken, authError = buildAuthToken(cfg.ApiKey)
	if authError then
		return { ok = false, kind = "bad_request", error = authError }
	end

	local headers: {[string]: string} = {}
	if authToken then
		headers["Authorization"] = "Bearer " .. authToken
	end

	local okRequest, response = pcall(function()
		return http:RequestAsync({
			Url = url,
			Method = "GET",
			Headers = headers,
		})
	end)
	if not okRequest then
		return { ok = false, kind = "network", error = "HttpService:RequestAsync failed: " .. tostring(response) }
	end

	local statusCode = tonumber(response.StatusCode) or 0
	if response.Success == false then
		return { ok = false, kind = "network", status = statusCode, error = "request did not complete (HttpService Success=false)" }
	end
	if statusCode ~= 200 then
		local failure = httpFailure(cfg, response, http)
		if failure.kind == "http" then
			failure.error = failure.error .. " — /text/{prompt} expects plain text; for structured replies use Pollinations.chat()"
		end
		return failure
	end

	local content = response.Body
	if type(content) ~= "string" then
		return { ok = false, kind = "parse", status = statusCode, error = "/text response was not a string" }
	end
	return { ok = true, content = content, model = options.Model or cfg.Model, latencyMs = math.floor((os.clock() - started) * 1000) }
end

--[[
	Pollinations.listModels(opts) -> { ok = true, models = {...} } | { ok = false, ... }
	Fetches the LIVE text model list from https://gen.pollinations.ai/text/models.
	Each entry has .name (pass it to chat()), .description, .pricing, .health, ...
]]
function Pollinations.listModels(opts: {[string]: any}?): {[string]: any}
	local options: {[string]: any} = opts or {}

	local cfg = makeCallConfig(options, { "ApiKey", "Http", "JsonEncode", "JsonDecode" })

	local http, httpError = resolveHttp(cfg)
	if http == nil then
		return { ok = false, kind = "network", error = httpError }
	end
	local _, decode, jsonError = resolveJson(cfg, http)
	if jsonError then
		return { ok = false, kind = "network", error = jsonError }
	end

	local authToken, authError = buildAuthToken(cfg.ApiKey)
	if authError then
		return { ok = false, kind = "bad_request", error = authError }
	end

	local headers: {[string]: string} = {}
	if authToken then
		headers["Authorization"] = "Bearer " .. authToken
	end

	local okRequest, response = pcall(function()
		return http:RequestAsync({
			Url = cfg.BaseUrl .. "/text/models",
			Method = "GET",
			Headers = headers,
		})
	end)
	if not okRequest then
		return { ok = false, kind = "network", error = "HttpService:RequestAsync failed: " .. tostring(response) }
	end
	local statusCode = tonumber(response.StatusCode) or 0
	if response.Success == false then
		return { ok = false, kind = "network", status = statusCode, error = "request did not complete (HttpService Success=false)" }
	end
	if statusCode ~= 200 then
		return httpFailure(cfg, response, http)
	end

	local okDecoded, decoded = pcall(decode, response.Body)
	if not okDecoded or type(decoded) ~= "table" then
		return { ok = false, kind = "parse", status = statusCode, error = "failed to decode model list JSON: " .. tostring(decoded) }
	end
	return { ok = true, models = decoded }
end

-- Defaults surfaced for convenience / tests
Pollinations.DefaultModel = DEFAULT_MODEL
Pollinations.DefaultBaseUrl = DEFAULT_BASE_URL
Pollinations.AuthHint = AUTH_HINT

return Pollinations
