-- Minimal pure-Luau JSON encoder/decoder for test harnesses that run outside
-- Roblox and outside lune (plain `luau` CLI has no json builtin).
-- Only used by tests; production code uses HttpService:JSONEncode/Decode
-- or lune's @lune/json.

local Json = {}

local NULL = setmetatable({}, {
	__tostring = function()
		return "JSON null"
	end,
})

-- === encode =================================================================

local function encodeString(s: string): string
	local out = s:gsub('[%z\1-\31\\"]', function(ch)
		if ch == '"' then
			return '\\"'
		elseif ch == "\\" then
			return "\\\\"
		elseif ch == "\n" then
			return "\\n"
		elseif ch == "\t" then
			return "\\t"
		elseif ch == "\r" then
			return "\\r"
		else
			return string.format("\\u%04x", ch:byte())
		end
	end)
	return '"' .. out .. '"'
end

local function encodeValue(value: any): string
	local vtype = type(value)
	if value == nil then
		return "null"
	elseif vtype == "boolean" then
		return tostring(value)
	elseif vtype == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			return string.format("%d", value)
		end
		return tostring(value)
	elseif vtype == "string" then
		return encodeString(value)
	elseif vtype == "table" then
		local count = 0
		for _ in pairs(value) do
			count += 1
		end
		local isArray = count == #value
		if isArray then
			local parts = {}
			for i = 1, #value do
				parts[i] = encodeValue(value[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		else
			local keys = {}
			for key in pairs(value) do
				if type(key) == "string" then
					table.insert(keys, key)
				end
			end
			table.sort(keys)
			local parts = {}
			for _, key in ipairs(keys) do
				table.insert(parts, encodeString(key) .. ":" .. encodeValue(value[key]))
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
	else
		error("cannot encode value of type " .. vtype, 2)
	end
end

function Json.encode(value: any): string
	return encodeValue(value)
end

-- === decode =================================================================

local function skipSpace(text: string, pos: number): number
	local _, nextPos = text:find("^[ \t\r\n]*", pos)
	return nextPos + 1
end

local parseValue: (string, number) -> (any, number)

local function parseString(text: string, pos: number): (string, number)
	-- assumes text:sub(pos,pos) == '"'
	local index = pos + 1
	local buffer = {}
	while index <= #text do
		local ch = text:sub(index, index)
		if ch == '"' then
			return table.concat(buffer), index + 1
		elseif ch == "\\" then
			local esc = text:sub(index + 1, index + 1)
			if esc == "u" then
				local hex = text:sub(index + 2, index + 5)
				buffer[#buffer + 1] = utf8.char(tonumber(hex, 16) or 0)
				index += 6
			else
				local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", ["b"] = "\b", ["f"] = "\f", ["n"] = "\n", ["r"] = "\r", ["t"] = "\t" }
				buffer[#buffer + 1] = map[esc] or esc
				index += 2
			end
		else
			buffer[#buffer + 1] = ch
			index += 1
		end
	end
	error("unterminated string", 0)
end

local function parseNumber(text: string, pos: number): (number, number)
	local _, endPos = text:find("^%-?%d+%.?%d*[eE]?[+-]?%d*", pos)
	local numText = text:sub(pos, endPos)
	local value = tonumber(numText)
	if value == nil then
		error(("bad number at %d: %s"):format(pos, numText), 0)
	end
	return value, endPos + 1
end

local function parseLiteral(text: string, pos: number, literal: string, value: any): (any, number)
	if text:sub(pos, pos + #literal - 1) == literal then
		return value, pos + #literal
	end
	error(("bad literal at %d, expected %s"):format(pos, literal), 0)
end

parseValue = function(text: string, pos: number): (any, number)
	pos = skipSpace(text, pos)
	local ch = text:sub(pos, pos)
	if ch == '{' then
		local obj = {}
		pos = skipSpace(text, pos + 1)
		if text:sub(pos, pos) == "}" then
			return obj, pos + 1
		end
		while true do
			pos = skipSpace(text, pos)
			local key
			key, pos = parseString(text, pos)
			pos = skipSpace(text, pos)
			assert(text:sub(pos, pos) == ":", "expected : at " .. pos)
			local value
			value, pos = parseValue(text, pos + 1)
			obj[key] = value
			pos = skipSpace(text, pos)
			local sep = text:sub(pos, pos)
			if sep == "," then
				pos += 1
			elseif sep == "}" then
				return obj, pos + 1
			else
				error("expected , or } at " .. pos, 0)
			end
		end
	elseif ch == "[" then
		local arr = {}
		pos = skipSpace(text, pos + 1)
		if text:sub(pos, pos) == "]" then
			return arr, pos + 1
		end
		while true do
			local value
			value, pos = parseValue(text, pos)
			arr[#arr + 1] = value
			pos = skipSpace(text, pos)
			local sep = text:sub(pos, pos)
			if sep == "," then
				pos += 1
			elseif sep == "]" then
				return arr, pos + 1
			else
				error("expected , or ] at " .. pos, 0)
			end
		end
	elseif ch == '"' then
		return parseString(text, pos)
	elseif ch == "-" or (ch >= "0" and ch <= "9") then
		return parseNumber(text, pos)
	elseif text:sub(pos, pos + 3) == "true" then
		return parseLiteral(text, pos, "true", true)
	elseif text:sub(pos, pos + 4) == "false" then
		return parseLiteral(text, pos, "false", false)
	elseif text:sub(pos, pos + 3) == "null" then
		return parseLiteral(text, pos, "null", NULL)
	else
		error("unexpected character at " .. pos .. ": " .. ch, 0)
	end
end

function Json.decode(text: string): any
	local value, pos = parseValue(text, 1)
	pos = skipSpace(text, pos)
	if pos <= #text then
		error("trailing garbage at position " .. pos, 0)
	end
	return value
end

--- Test helper: JSON null decodes to Json.NULL (a unique sentinel), not Lua nil.
Json.NULL = NULL -- JSON null decodes to this sentinel (not Lua nil)

return Json
