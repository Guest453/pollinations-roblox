-- Live smoke test against the real Pollinations API (no key = best-effort).
-- Run: luau tests/live_smoke.luau
-- This file is NOT part of the unit suite (network + flaky anonymous tier).

local Http = {}

-- minimal standalone implementations so this runs anywhere
local function jsonEncode(value)  -- only what this script needs
	local t = type(value)
	if t == "string" then
		return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
			if c == '"' or c == "\\" then
				return "\\" .. c
			elseif c == "\n" then
				return "\\n"
			end
			return string.format("\\u%04x", c:byte())
		end) .. '"'
	elseif t == "table" then
		local isArray = #value > 0
		local parts = {}
		if isArray then
			for _, v in ipairs(value) do
				table.insert(parts, jsonEncode(v))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, v in pairs(value) do
			table.insert(parts, jsonEncode(k) .. ":" .. jsonEncode(v))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	else
		return tostring(value)
	end
end

local function jsonDecode(text)
	local pos = 1
	local function skip() while text:sub(pos, pos):match("[%s]") do pos += 1 end end
	local function value()
		skip()
		local c = text:sub(pos, pos)
		if c == '{' then
			pos += 1
			local obj = {}
			skip()
			if text:sub(pos, pos) == '}' then pos += 1 return obj end
			while true do
				skip()
				local key = value()
				skip()
				pos += 1 -- :
				obj[key] = value()
				skip()
				local sep = text:sub(pos, pos)
				pos += 1
				if sep == '}' then return obj end
			end
		elseif c == '[' then
			pos += 1
			local arr = {}
			skip()
			if text:sub(pos, pos) == ']' then pos += 1 return arr end
			while true do
				table.insert(arr, value())
				skip()
				local sep = text:sub(pos, pos)
				pos += 1
				if sep == ']' then return arr end
			end
		elseif c == '"' then
			pos += 1
			local buffer = {}
			while true do
				local ch = text:sub(pos, pos)
				if ch == '\\' then
					buffer[#buffer+1] = text:sub(pos+1, pos+1)
					pos += 2
				elseif ch == '"' then
					pos += 1
					return table.concat(buffer)
				else
					buffer[#buffer+1] = ch
					pos += 1
				end
			end
		else
			local literal = text:match('^[%-%d%.a-z]+', pos)
			pos += #literal + 1
			if literal == "true" then return true end
			if literal == "false" then return false end
			if literal == "null" then return nil end
			return tonumber(literal)
		end
	end
	return value()
end

-- curl-based Http (the sandbox has curl; Roblox uses HttpService).
-- NOTE: plain `luau` has no io.popen — run this with `luau-php`-style hosts,
-- lune (lune/run), or replace runCommand with your own host. Kept simple:
local function runCommand(command): string?
	local ok, ioPopen = pcall(function()
		return io.popen
	end)
	if not ok or ioPopen == nil then
		return nil
	end
	local handle = ioPopen(command)
	local output = handle:read("*a")
	handle:close()
	return output
end

function Http:RequestAsync(opts)
	local headers = {}
	for key, value in pairs(opts.Headers or {}) do
		table.insert(headers, ("-H %q"):format(key .. ": " .. value))
	end
	local command
	if opts.Method == "POST" then
		command = ("curl -s --max-time 45 -X POST %s -d %q %q -w '\\n___STATUS:%d'"):format(
			table.concat(headers, " "), opts.Body, opts.Url, 0)
		command = command:gsub("___STATUS:0", "___STATUS:%%{http_code}")
	else
		command = ("curl -s --max-time 45 %s %q -w '\\n___STATUS:%%{http_code}'"):format(
			table.concat(headers, " "), opts.Url)
	end
	local output = runCommand(command)
	if output == nil then
		return { Success = false, StatusCode = 0, Body = "no io.popen in this Luau host — use the luau CLI build with stdlib or run via curl manually" }
	end
	local status = tonumber(output:match("___STATUS:(%d+)$")) or 0
	local body = output:gsub("\n___STATUS:%d+$", "")
	return { Success = true, StatusCode = status, Body = body }
end

function Http:JSONEncode(value)
	return jsonEncode(value)
end

function Http:JSONDecode(text)
	return jsonDecode(text)
end

local Root = require("../src/Pollinations")
Root.Configure({ Http = Http, Retries = 1, Sleep = function(s) os.execute(("sleep %f"):format(s)) end })

print("== live smoke: listModels ==")
local modelsResult = Root.listModels({})
print(("ok=%s, models=%s"):format(tostring(modelsResult.ok), modelsResult.models and #modelsResult.models or modelsResult.error))
if modelsResult.ok then
	local first = modelsResult.models[1]
	print(("first model: %s (%s)"):format(first.name, first.description or ""))
end

print("\n== live smoke: chat (anonymous, may 401/429) ==")
local result = Root.chat("openai/gpt-5.4-nano", {
	{ role = "system", content = "You are Bella, a friendly bee-keeper NPC. Keep it to one short sentence." },
	{ role = "user", content = "what do you sell?" },
}, { MaxTokens = 60 })
print(("ok=%s latency=%sms attempts=%s"):format(tostring(result.ok), tostring(result.latencyMs), tostring(result.attempts)))
if result.ok then
	print("Bella says: " .. result.content)
	print(("model=%s finish=%s"):format(tostring(result.model), tostring(result.finishReason)))
else
	print(("kind=%s status=%s"):format(tostring(result.kind), tostring(result.status)))
	print("error: " .. tostring(result.error))
end
