
local debugger_stackInfo = nil
local coro_debugger = nil
local debugger_require = require
local debugger_exeLuaString = nil
local loadstring = loadstring
local getinfo = debug.getinfo
local function createSocket()
	local base = _G
	local string = require("string")
	local math = require("math")
	local socket = require("socket.core")
	
	local _M = socket
	
	-----------------------------------------------------------------------------
	-- Exported auxiliar functions
	-----------------------------------------------------------------------------
	function _M.connect4(address, port, laddress, lport)
		return socket.connect(address, port, laddress, lport, "inet")
	end
	
	function _M.connect6(address, port, laddress, lport)
		return socket.connect(address, port, laddress, lport, "inet6")
	end
	
	function _M.bind(host, port, backlog)
		if host == "*" then host = "0.0.0.0" end
		local addrinfo, err = socket.dns.getaddrinfo(host) ;
		if not addrinfo then return nil, err end
		local sock, res
		err = "no info on address"
		for i, alt in base.ipairs(addrinfo) do
			if alt.family == "inet" then
				sock, err = socket.tcp4()
			else
				sock, err = socket.tcp6()
			end
			if not sock then return nil, err end
			sock:setoption("reuseaddr", true)
			res, err = sock:bind(alt.addr, port)
			if not res then
				sock:close()
			else
				res, err = sock:listen(backlog)
				if not res then
					sock:close()
				else
					return sock
				end
			end
		end
		return nil, err
	end
	
	_M.try = _M.newtry()
	
	function _M.choose(table)
		return function(name, opt1, opt2)
			if base.type(name) ~= "string" then
				name, opt1, opt2 = "default", name, opt1
			end
			local f = table[name or "nil"]
			if not f then base.error("unknown key (" .. base.tostring(name) .. ")", 3)
			else return f(opt1, opt2) end
		end
	end
	
	-----------------------------------------------------------------------------
	-- Socket sources and sinks, conforming to LTN12
	-----------------------------------------------------------------------------
	-- create namespaces inside LuaSocket namespace
	local sourcet, sinkt = {}, {}
	_M.sourcet = sourcet
	_M.sinkt = sinkt
	
	_M.BLOCKSIZE = 2048
	
	sinkt["close-when-done"] = function(sock)
		return base.setmetatable({
			getfd = function() return sock:getfd() end,
			dirty = function() return sock:dirty() end
		}, {
			__call = function(self, chunk, err)
				if not chunk then
					sock:close()
					return 1
				else return sock:send(chunk) end
			end
		})
	end
	
	sinkt["keep-open"] = function(sock)
		return base.setmetatable({
			getfd = function() return sock:getfd() end,
			dirty = function() return sock:dirty() end
		}, {
			__call = function(self, chunk, err)
				if chunk then return sock:send(chunk)
				else return 1 end
			end
		})
	end
	
	sinkt["default"] = sinkt["keep-open"]
	
	_M.sink = _M.choose(sinkt)
	
	sourcet["by-length"] = function(sock, length)
		return base.setmetatable({
			getfd = function() return sock:getfd() end,
			dirty = function() return sock:dirty() end
		}, {
			__call = function()
				if length <= 0 then return nil end
				local size = math.min(socket.BLOCKSIZE, length)
				local chunk, err = sock:receive(size)
				if err then return nil, err end
				length = length - string.len(chunk)
				return chunk
			end
		})
	end
	
	sourcet["until-closed"] = function(sock)
		local done
		return base.setmetatable({
			getfd = function() return sock:getfd() end,
			dirty = function() return sock:dirty() end
		}, {
			__call = function()
				if done then return nil end
				local chunk, err, partial = sock:receive(socket.BLOCKSIZE)
				if not err then return chunk
				elseif err == "closed" then
					sock:close()
					done = 1
					return partial
				else return nil, err end
			end
		})
	end
	
	
	sourcet["default"] = sourcet["until-closed"]
	
	_M.source = _M.choose(sourcet)
	
	return _M
end

local function createJson()
	local math = require('math')
	local string = require("string")
	local table = require("table")
	local object = nil
	-----------------------------------------------------------------------------
	-- Module declaration
	-----------------------------------------------------------------------------
	local json = {}              -- Public namespace
	local json_private = {}     -- Private namespace
	
	-- Public constants                                                            
	json.EMPTY_ARRAY = {}
	json.EMPTY_OBJECT = {}
	-- Public functions

	-- Private functions
	local decode_scanArray
	local decode_scanComment
	local decode_scanConstant
	local decode_scanNumber
	local decode_scanObject
	local decode_scanString
	local decode_scanWhitespace
	local encodeString
	local isArray
	local isEncodable
	
	-----------------------------------------------------------------------------
	-- PUBLIC FUNCTIONS
	-----------------------------------------------------------------------------
	--- Encodes an arbitrary Lua object / variable.
	-- @param v The Lua object / variable to be JSON encoded.
	-- @return String containing the JSON encoding in internal Lua string format (i.e. not unicode)
	function json.encode(v)
		-- Handle nil values
		if v == nil then
			return "null"
		end
		
		local vtype = type(v)
		
		-- Handle strings
		if vtype == 'string' then
			return "\"" .. json_private.encodeString(v) .. "\"" 	    -- Need to handle encoding in string
		end
		
		-- Handle booleans
		if vtype == 'number' or vtype == 'boolean' then
			return tostring(v)
		end
		
		-- Handle tables
		if vtype == 'table' then
			local rval = {}
			-- Consider arrays separately
			local bArray, maxCount = isArray(v)
			if bArray then
				for i = 1, maxCount do
					table.insert(rval, json.encode(v[i]))
				end
			else	-- An object, not an array
				for i, j in pairs(v) do
					if isEncodable(i) and isEncodable(j) then
						table.insert(rval, "\"" .. json_private.encodeString(i) .. '":' .. json.encode(j))
					end
				end
			end
			if bArray then
				return '[' .. table.concat(rval, ',') .. ']'
			else
				return '{' .. table.concat(rval, ',') .. '}'
			end
		end
		
		-- Handle null values
		if vtype == 'function' and v == json.null then
			return 'null'
		end
		
		assert(false, 'encode attempt to encode unsupported type ' .. vtype .. ':' .. tostring(v))
	end
	
	
	--- Decodes a JSON string and returns the decoded value as a Lua data structure / value.
	-- @param s The string to scan.
	-- @param [startPos] Optional starting position where the JSON string is located. Defaults to 1.
	-- @param Lua object, number The object that was scanned, as a Lua table / string / number / boolean or nil,
	-- and the position of the first character after
	-- the scanned JSON object.
	function json.decode(s, startPos)
		startPos = startPos and startPos or 1
		startPos = decode_scanWhitespace(s, startPos)
		assert(startPos <= string.len(s), 'Unterminated JSON encoded object found at position in [' .. s .. ']')
		local curChar = string.sub(s, startPos, startPos)
		-- Object
		if curChar == '{' then
			return decode_scanObject(s, startPos)
		end
		-- Array
		if curChar == '[' then
			return decode_scanArray(s, startPos)
		end
		-- Number
		if string.find("+-0123456789.e", curChar, 1, true) then
			return decode_scanNumber(s, startPos)
		end
		-- String
		if curChar == "\"" or curChar == [[']] then
			return decode_scanString(s, startPos)
		end
		if string.sub(s, startPos, startPos + 1) == '/*' then
			return json.decode(s, decode_scanComment(s, startPos))
		end
		-- Otherwise, it must be a constant
		return decode_scanConstant(s, startPos)
	end
	
	--- The null function allows one to specify a null value in an associative array (which is otherwise
	-- discarded if you set the value with 'nil' in Lua. Simply set t = { first=json.null }
	function json.null()
		return json.null  -- so json.null() will also return null ;-)
	end
	-----------------------------------------------------------------------------
	-- Internal, PRIVATE functions.
	-- Following a Python-like convention, I have prefixed all these 'PRIVATE'
	-- functions with an underscore.
	-----------------------------------------------------------------------------

	--- Scans an array from JSON into a Lua object
	-- startPos begins at the start of the array.
	-- Returns the array and the next starting position
	-- @param s The string being scanned.
	-- @param startPos The starting position for the scan.
	-- @return table, int The scanned array as a table, and the position of the next character to scan.
	function decode_scanArray(s, startPos)
		local array = {} 	-- The return value
		local stringLen = string.len(s)
		assert(string.sub(s, startPos, startPos) == '[', 'decode_scanArray called but array does not start at position ' .. startPos .. ' in string:\n' .. s)
		startPos = startPos + 1
		-- Infinite loop for array elements
			repeat
			startPos = decode_scanWhitespace(s, startPos)
			assert(startPos <= stringLen, 'JSON String ended unexpectedly scanning array.')
			local curChar = string.sub(s, startPos, startPos)
			if(curChar == ']') then
				return array, startPos + 1
			end
			if(curChar == ',') then
				startPos = decode_scanWhitespace(s, startPos + 1)
			end
			assert(startPos <= stringLen, 'JSON String ended unexpectedly scanning array.')
			object, startPos = json.decode(s, startPos)
			table.insert(array, object)
		until false
	end
	
	--- Scans a comment and discards the comment.
	-- Returns the position of the next character following the comment.
	-- @param string s The JSON string to scan.
	-- @param int startPos The starting position of the comment
	function decode_scanComment(s, startPos)
		assert(string.sub(s, startPos, startPos + 1) == '/*', "decode_scanComment called but comment does not start at position " .. startPos)
		local endPos = string.find(s, '*/', startPos + 2)
		assert(endPos ~= nil, "Unterminated comment in string at " .. startPos)
		return endPos + 2
	end
	
	--- Scans for given constants: true, false or null
	-- Returns the appropriate Lua type, and the position of the next character to read.
	-- @param s The string being scanned.
	-- @param startPos The position in the string at which to start scanning.
	-- @return object, int The object (true, false or nil) and the position at which the next character should be 
	-- scanned.
	function decode_scanConstant(s, startPos)
		local consts = {["true"] = true, ["false"] = false, ["null"] = nil}
		local constNames = {"true", "false", "null"}
		
		for i, k in pairs(constNames) do
			if string.sub(s, startPos, startPos + string.len(k) - 1) == k then
				return consts[k], startPos + string.len(k)
			end
		end
		assert(nil, 'Failed to scan constant from string ' .. s .. ' at starting position ' .. startPos)
	end
	
	--- Scans a number from the JSON encoded string.
	-- (in fact, also is able to scan numeric +- eqns, which is not
	-- in the JSON spec.)
	-- Returns the number, and the position of the next character
	-- after the number.
	-- @param s The string being scanned.
	-- @param startPos The position at which to start scanning.
	-- @return number, int The extracted number and the position of the next character to scan.
	function decode_scanNumber(s, startPos)
		local endPos = startPos + 1
		local stringLen = string.len(s)
		local acceptableChars = "+-0123456789.e"
		while(string.find(acceptableChars, string.sub(s, endPos, endPos), 1, true)
		and endPos <= stringLen
		) do
			endPos = endPos + 1
		end
		local stringValue = 'return ' .. string.sub(s, startPos, endPos - 1)
		local stringEval = loadstring(stringValue)
		assert(stringEval, 'Failed to scan number [ ' .. stringValue .. '] in JSON string at position ' .. startPos .. ' : ' .. endPos)
		return stringEval(), endPos
	end
	
	--- Scans a JSON object into a Lua object.
	-- startPos begins at the start of the object.
	-- Returns the object and the next starting position.
	-- @param s The string being scanned.
	-- @param startPos The starting position of the scan.
	-- @return table, int The scanned object as a table and the position of the next character to scan.
	function decode_scanObject(s, startPos)
		local object = {}
		local stringLen = string.len(s)
		local key, value
		assert(string.sub(s, startPos, startPos) == '{', 'decode_scanObject called but object does not start at position ' .. startPos .. ' in string:\n' .. s)
		startPos = startPos + 1
		repeat
			startPos = decode_scanWhitespace(s, startPos)
			assert(startPos <= stringLen, 'JSON string ended unexpectedly while scanning object.')
			local curChar = string.sub(s, startPos, startPos)
			if(curChar == '}') then
				return object, startPos + 1
			end
			if(curChar == ',') then
				startPos = decode_scanWhitespace(s, startPos + 1)
			end
			assert(startPos <= stringLen, 'JSON string ended unexpectedly scanning object.')
			-- Scan the key
			key, startPos = json.decode(s, startPos)
			assert(startPos <= stringLen, 'JSON string ended unexpectedly searching for value of key ' .. key)
			startPos = decode_scanWhitespace(s, startPos)
			assert(startPos <= stringLen, 'JSON string ended unexpectedly searching for value of key ' .. key)
			assert(string.sub(s, startPos, startPos) == ':', 'JSON object key-value assignment mal-formed at ' .. startPos)
			startPos = decode_scanWhitespace(s, startPos + 1)
			assert(startPos <= stringLen, 'JSON string ended unexpectedly searching for value of key ' .. key)
			value, startPos = json.decode(s, startPos)
			object[key] = value
		until false 	-- infinite loop while key-value pairs are found
	end
	
	-- START SoniEx2
	-- Initialize some things used by decode_scanString
	-- You know, for efficiency
	local escapeSequences = {
		["\\t"] = "\t",
		["\\f"] = "\f",
		["\\r"] = "\r",
		["\\n"] = "\n",
		["\\b"] = ""
	}
	setmetatable(escapeSequences, {__index = function(t, k)
		-- skip "\" aka strip escape
		return string.sub(k, 2)
	end})
	-- END SoniEx2

	--- Scans a JSON string from the opening inverted comma or single quote to the
	-- end of the string.
	-- Returns the string extracted as a Lua string,
	-- and the position of the next non-string character
	-- (after the closing inverted comma or single quote).
	-- @param s The string being scanned.
	-- @param startPos The starting position of the scan.
	-- @return string, int The extracted string as a Lua string, and the next character to parse.
	function decode_scanString(s, startPos)
		assert(startPos, 'decode_scanString(..) called without start position')
		local startChar = string.sub(s, startPos, startPos)
		-- START SoniEx2
		-- PS: I don't think single quotes are valid JSON
		assert(startChar == "\"" or startChar == [[']], 'decode_scanString called for a non-string')
		--assert(startPos, "String decoding failed: missing closing " .. startChar .. " for string at position " .. oldStart)
		local t = {}
		local i, j = startPos, startPos
		while string.find(s, startChar, j + 1) ~= j + 1 do
			local oldj = j
			i, j = string.find(s, "\\.", j + 1)
			local x, y = string.find(s, startChar, oldj + 1)
			if not i or x < i then
				i, j = x, y - 1
			end
			table.insert(t, string.sub(s, oldj + 1, i - 1))
			if string.sub(s, i, j) == "\\u" then
				local a = string.sub(s, j + 1, j + 4)
				j = j + 4
				local n = tonumber(a, 16)
				assert(n, "String decoding failed: bad Unicode escape " .. a .. " at position " .. i .. " : " .. j)
				-- math.floor(x/2^y) == lazy right shift
				-- a % 2^b == bitwise_and(a, (2^b)-1)
				-- 64 = 2^6
				-- 4096 = 2^12 (or 2^6 * 2^6)
				local x
				if n < 128 then
					x = string.char(n % 128)
				elseif n < 2048 then
					-- [110x xxxx] [10xx xxxx]
					x = string.char(192 +(math.floor(n / 64) % 32), 128 +(n % 64))
				else
					-- [1110 xxxx] [10xx xxxx] [10xx xxxx]
					x = string.char(224 +(math.floor(n / 4096) % 16), 128 +(math.floor(n / 64) % 64), 128 +(n % 64))
				end
				table.insert(t, x)
			else
				table.insert(t, escapeSequences[string.sub(s, i, j)])
			end
		end
		table.insert(t, string.sub(j, j + 1))
		assert(string.find(s, startChar, j + 1), "String decoding failed: missing closing " .. startChar .. " at position " .. j .. "(for string at position " .. startPos .. ")")
		return table.concat(t, ""), j + 2
	-- END SoniEx2
	end
	
	--- Scans a JSON string skipping all whitespace from the current start position.
	-- Returns the position of the first non-whitespace character, or nil if the whole end of string is reached.
	-- @param s The string being scanned
	-- @param startPos The starting position where we should begin removing whitespace.
	-- @return int The first position where non-whitespace was encountered, or string.len(s)+1 if the end of string
	-- was reached.
	function decode_scanWhitespace(s, startPos)
		local whitespace = " \n\r\t"
		local stringLen = string.len(s)
		while(string.find(whitespace, string.sub(s, startPos, startPos), 1, true) and startPos <= stringLen) do
			startPos = startPos + 1
		end
		return startPos
	end
	
	--- Encodes a string to be JSON-compatible.
	-- This just involves back-quoting inverted commas, back-quotes and newlines, I think ;-)
	-- @param s The string to return as a JSON encoded (i.e. backquoted string)
	-- @return The string appropriately escaped.

	local escapeList = {
		["\""] = '\\"',
		['\\'] = '\\\\',
		['/'] = '\\/',
		[''] = '\\b',
		['\f'] = '\\f',
		['\n'] = '\\n',
		['\r'] = '\\r',
		['\t'] = '\\t'
	}
	
	function json_private.encodeString(s)
		local s = tostring(s)
		return s:gsub(".", function(c) return escapeList[c] end)  -- SoniEx2: 5.0 compat
	end
	
	-- Determines whether the given Lua type is an array or a table / dictionary.
	-- We consider any table an array if it has indexes 1..n for its n items, and no
	-- other data in the table.
	-- I think this method is currently a little 'flaky', but can't think of a good way around it yet...
	-- @param t The table to evaluate as an array
	-- @return boolean, number True if the table can be represented as an array, false otherwise. If true,
	-- the second returned value is the maximum
	-- number of indexed elements in the array. 
	function isArray(t)
		-- Next we count all the elements, ensuring that any non-indexed elements are not-encodable 
		-- (with the possible exception of 'n')
		if(t == json.EMPTY_ARRAY) then return true, 0 end
		if(t == json.EMPTY_OBJECT) then return false end
		
		local maxIndex = 0
		for k, v in pairs(t) do
			if(type(k) == 'number' and math.floor(k) == k and 1 <= k) then	-- k,v is an indexed pair
				if(not isEncodable(v)) then return false end	-- All array elements must be encodable
				maxIndex = math.max(maxIndex, k)
			else
				if(k == 'n') then
					if v ~=(t.n or # t) then return false end  -- False if n does not hold the number of elements
					
					
					
					
					
					
					
					
					
					
					
					
					
				else -- Else of (k=='n')
					if isEncodable(v) then return false end
				end  -- End of (k~='n')
			end  -- End of k,v not an indexed pair
		end   -- End of loop across all pairs
		return true, maxIndex
	end
	
	--- Determines whether the given Lua object / table / variable can be JSON encoded. The only
	-- types that are JSON encodable are: string, boolean, number, nil, table and json.null.
	-- In this implementation, all other types are ignored.
	-- @param o The object to examine.
	-- @return boolean True if the object should be JSON encoded, false if it should be ignored.
	function isEncodable(o)
		local t = type(o)
		return(t == 'string' or t == 'boolean' or t == 'number' or t == 'nil' or t == 'table') or
		(t == 'function' and o == json.null)
	end
	
	return json
end


local debugger_print = print
local debug_server = nil
local breakInfoSocket = nil
local json = createJson()
local LuaDebugger = {
	fileMaps = {},
	isStepIn = false,
	isStepOut = false,
	isStepOutReturn = false,
	stepInfo = nil,
	Run = true,  --表示正常运行只检测断点
	breakInfos = {},
	runTimeType = nil,
	isHook = true,
	clientPaths = {},
	pathCachePaths = {},
	isProntToConsole = 1,
	isDebugPrint = true,
	hookType = "lrc"
}
LuaDebugger.event = {
	S2C_SetBreakPoints = 1,
	C2S_SetBreakPoints = 2,
	S2C_RUN = 3,
	C2S_HITBreakPoint = 4,
	S2C_ReqVar = 5,
	C2S_ReqVar = 6,
	--单步跳过请求
	S2C_NextRequest = 7,
	--单步跳过反馈
	C2S_NextResponse = 8,
	-- 单步跳过 结束 没有下一步
	C2S_NextResponseOver = 9,
	--单步跳入
	S2C_StepInRequest = 10,
	C2S_StepInResponse = 11,
	--单步跳出
	S2C_StepOutRequest = 12,
	--单步跳出返回
	C2S_StepOutResponse = 13,
	--打印
	C2S_LuaPrint = 14,
	
	S2C_LoadLuaScript = 16,
	C2S_SetSocketName = 17,
	C2S_LoadLuaScript = 18,
	S2C_SetLuaClientPaths = 19,
	C2S_DebugXpCall = 20,
	
}

function print(...)
	if(LuaDebugger.isProntToConsole == 1 or LuaDebugger.isProntToConsole == 3) then
		debugger_print(...)
	end
	if(LuaDebugger.isProntToConsole == 1 or LuaDebugger.isProntToConsole == 2) then
		if(debug_server ) then
			local arg = {...}    --这里的...和{}符号中间需要有空格号，否则会出错  
			local str = ""
			for k, v in pairs(arg) do
				str = str .. tostring(v) .. "\t"
			end
			local sendMsg = {
				event = LuaDebugger.event.C2S_LuaPrint,
				data = {msg = str}
			}
			local sendStr = json.encode(sendMsg)
			debug_server:send(sendStr .. "__debugger_k0204__")
		end
	end
end


-- function require(path)
-- -- print("加载lua:"..path)
-- 	-- return debugger_require(path)
-- 	-- print("-------------------------------------------------------------------------")
	
-- 	local r1,r2,r3,r4,r5,r6,r7,r8,r8,r10,r11,r12,r13,r14,r15,r16,r17,r18,r18,r20 = debugger_require(path)
-- 	local returnTable = {r1,r2,r3,r4,r5,r6,r7,r8,r8,r10,r11,r12,r13,r14,r15,r16,r17,r18,r18,r20}
-- 	for i,v in ipairs(returnTable) do
-- 		if(type(v) == "table") then
-- 			if(v["new"]) then
				
-- 			end
-- 		end
-- 	end


-- 	return r1,r2,r3,r4,r5,r6,r7,r8,r8,r10,r11,r12,r13,r14,r15,r16,r17,r18,r18,r20
-- end


----=============================工具方法=============================================
local  debug_hook = nil
local function debugger_strSplit(input, delimiter)
	input = tostring(input)
	delimiter = tostring(delimiter)
	if(delimiter == '') then return false end
	local pos, arr = 0, {}
	-- for each divider found
	for st, sp in function() return string.find(input, delimiter, pos, true) end do
		table.insert(arr, string.sub(input, pos, st - 1))
		pos = sp + 1
	end
	table.insert(arr, string.sub(input, pos))
	return arr
end
local function debugger_strTrim(input)
	input = string.gsub(input, "^[ \t\n\r]+", "")
	return string.gsub(input, "[ \t\n\r]+$", "")
end

local function debugger_dump(value, desciption, nesting)
	
	if type(nesting) ~= "number" then nesting = 3 end
	local lookupTable = {}
	local result = {}
	local function _v(v)
		if type(v) == "string" then
			v = "\"" .. v .. "\""
		end
		return tostring(v)
	end
	local traceback = debugger_strSplit(debug.traceback("", 2), "\n")
	print("dump from: " .. debugger_strTrim(traceback[3]))
	
	local function _dump(value, desciption, indent, nest, keylen)
		desciption = desciption or "<var>"
		spc = ""
		if type(keylen) == "number" then
			spc = string.rep(" ", keylen - string.len(_v(desciption)))
		end
		if type(value) ~= "table" then
			result[# result + 1] = string.format("%s%s%s = %s", indent, _v(desciption), spc, _v(value))
		elseif lookupTable[value] then
			result[# result + 1] = string.format("%s%s%s = *REF*", indent, desciption, spc)
		else
			lookupTable[value] = true
			if nest > nesting then
				result[# result + 1] = string.format("%s%s = *MAX NESTING*", indent, desciption)
			else
				result[# result + 1] = string.format("%s%s = {", indent, _v(desciption))
				local indent2 = indent .. "    "
				local keys = {}
				local keylen = 0
				local values = {}
				for k, v in pairs(value) do
					keys[# keys + 1] = k
					local vk = _v(k)
					local vkl = string.len(vk)
					if vkl > keylen then keylen = vkl end
					values[k] = v
				end
				table.sort(keys, function(a, b)
					if type(a) == "number" and type(b) == "number" then
						return a < b
					else
						return tostring(a) < tostring(b)
					end
				end)
				for i, k in ipairs(keys) do
					_dump(values[k], k, indent2, nest + 1, keylen)
				end
				result[# result + 1] = string.format("%s}", indent)
			end
		end
	end
	_dump(value, desciption, "- ", 1)
	
	for i, line in ipairs(result) do
		print(line)
	end
end


local function ToBase64(source_str)
    local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local s64 = ''
    local str = source_str

    while #str > 0 do
        local bytes_num = 0
        local buf = 0

        for byte_cnt=1,3 do
            buf = (buf * 256)
            if #str > 0 then
                buf = buf + string.byte(str, 1, 1)
                str = string.sub(str, 2)
                bytes_num = bytes_num + 1
            end
        end

        for group_cnt=1,(bytes_num+1) do
          local  b64char = math.fmod(math.floor(buf/262144), 64) + 1
            s64 = s64 .. string.sub(b64chars, b64char, b64char)
            buf = buf * 64
        end

        for fill_cnt=1,(3-bytes_num) do
            s64 = s64 .. '='
        end
    end

    return s64
end

local function debugger_setVarInfo(name, value)

	local vt = type(value)
	local valueStr = ""
	if(vt ~= "table") then
		valueStr =  tostring(value)
		valueStr = ToBase64(valueStr)
	else
		-- valueStr =  topointer(value)
	end
	local valueInfo = {
		name = name,
		valueType = vt,
		valueStr =valueStr
	}
	return valueInfo ;
end

local function debugger_getvalue(f)
	local i = 1
	local locals = {}
	-- get locals
	while true do
		local name, value = debug.getlocal(f, i)
		if not name then break end
		if(name ~= "(*temporary)") then
			locals[name] = value
			
		end
		
		i = i + 1
	end
	local func = getinfo(f, "f").func
	i = 1
	local ups = {}
	while func do -- check for func as it may be nil for tail calls
		local name, value = debug.getupvalue(func, i)
		if not name then break end
		ups[name] = value
		
		i = i + 1
	end
	return {locals = locals, ups = ups}
end

--获取堆栈
 debugger_stackInfo = function (ignoreCount)
	local datas = {}
	local stack = {}
	local varInfos = {}
	local funcs = {}
	local index = 0 ;
	for i = ignoreCount, 100 do
		local source = getinfo(i)
		if not source then
			break ;
		end
		
		local file = source.source
		local info =
		{
			src = file,
			scoreName = source.name,
			currentline = source.currentline,
			linedefined = source.linedefined,
			what = source.what,
			nameWhat = source.namewhat
		}
		index = i
		local vars = debugger_getvalue(i + 1)
		table.insert(stack, info)
		table.insert(varInfos, vars)
		table.insert(funcs,source.func)
		if source.what == 'main' then break end
	end
	return {stack = stack, vars = varInfos,funcs=funcs}
end


--==============================工具方法 end======================================================

--===========================点断信息==================================================

--根据不同的游戏引擎进行定时获取断点信息

--CCDirector:sharedDirector():getScheduler()
local debugger_setBreak = nil
local function debugger_receiveDebugBreakInfo()
	if(breakInfoSocket) then
	local msg, status = breakInfoSocket:receive()
	if(msg) then
	
		local netData =  json.decode(msg)
		if netData.event == LuaDebugger.event.S2C_SetBreakPoints then
			debugger_setBreak(netData.data)
		elseif netData.event == LuaDebugger.event.S2C_LoadLuaScript then
			print("获取数据")
			debugger_exeLuaString(netData.data,false)
		end
	end
	end
end

debugger_setBreak = function(data)
		
		local breakInfos = LuaDebugger.breakInfos
		for i, breakInfo in ipairs(data) do
		
			local fileNames =  breakInfo.paths
			local breakLines = breakInfo.lines
			if(breakLines and #breakLines>0) then
				local lines = {}
				for i, v in ipairs(breakInfo.lines) do
					lines[v] = true
				end
				for i,v in ipairs(fileNames) do
					breakInfos[v] = lines ;
				end
			else 
				for i,v in ipairs(fileNames) do
					breakInfos[v] = nil
				end
			end
		end
	
		--检查是否需要断点
		local isHook = false
		
		for k,v in pairs(breakInfos) do
			isHook = true
			break
		end
		-- debugger_dump(breakInfos,"breakList")
		--这样做的原因是为了最大限度的使手机调试更加流畅 注意这里会连续的进行n次
		if(isHook) then
			if(not LuaDebugger.isHook) then
				
				debug.sethook(debug_hook, "lrc")
			end
			LuaDebugger.isHook = true
			-- print("isHook=>true")
		else
			-- print("isHook=>false")
			if( LuaDebugger.isHook) then
				
				debug.sethook()
			end
			LuaDebugger.isHook = false
		end
		
end
local function debugger_checkFileIsBreak(fileName)
	return LuaDebugger.breakInfos[fileName]
end
local function debugger_checkIsBreak(fileName, line)
	
	local lines = LuaDebugger.breakInfos[fileName]
	
	if(lines) then
		return lines[line]
	end
	return false
end
--=====================================断点信息 end ----------------------------------------------



local controller_host = "192.168.1.102"
local controller_port = 7003

local function debugger_sendMsg(serverSocket, eventName, data)
	
	local sendMsg = {
		event = eventName,
		data = data
	}
	
	
	local sendStr = json.encode(sendMsg)
	
	serverSocket:send(sendStr .. "__debugger_k0204__")
end
--执行lua字符串
debugger_exeLuaString = function(data,isBreakPoint)
	
	local function loadScript()
	
		local luastr = data.luastr
		if(isBreakPoint) then
		

			local currentTabble = {_G = _G}
			
			local frameId = data.frameId
			frameId = frameId + 1
			local func = LuaDebugger.currentDebuggerData.funcs[frameId];
			local vars = LuaDebugger.currentDebuggerData.vars[frameId]
			local locals = vars.locals;
			local ups = vars.ups
			
			for k,v in pairs(ups) do
				currentTabble[k] = v
			end
			for k,v in pairs(locals) do
				currentTabble[k] = v
			end
			
			
			setmetatable(currentTabble, {__index = _G})
			local fun = loadstring(luastr)
			setfenv(fun,currentTabble)
			fun()
		else

			local fun = loadstring(luastr)
			
			fun()
		end
		
	end
	
	local status, msg = xpcall(loadScript, function(error)
		print(error)
	end)
	if(status) then
		debugger_sendMsg(debug_server,LuaDebugger.event.C2S_LoadLuaScript, {msg ="执行代码成功"})
		if(isBreakPoint) then
		debugger_sendMsg(debug_server,LuaDebugger.event.C2S_HITBreakPoint, LuaDebugger.currentDebuggerData.stack)
		end
	else
		debugger_sendMsg(debug_server,LuaDebugger.event.C2S_LoadLuaScript, {msg ="加载代码失败"})
	end
	
end






local function getSource(source)
	
	if(LuaDebugger.pathCachePaths[source]) then
		print("cunzai",LuaDebugger.pathCachePaths[source])
		return LuaDebugger.pathCachePaths[source]
	end
	local file = source
	file = file:gsub("\\", "/")
	
	if file:find("/./") then
		file = file:gsub("/./", "/")
	end
	if file:find("./") == 1 then
		file = file:sub(3);

	end
	if file:find("@") == 1 then
		file = file:sub(2);

	end
	
	local tempFile = string.lower(file)
	local paths = LuaDebugger.clientPaths
	if(tempFile:find('-')) then
		tempFile =   tempFile:gsub("-", "_")
		
	end
	if(paths) then

		for i,clientPath in ipairs(paths) do
			if tempFile:find(clientPath) then
				
				file = file:sub(string.len(clientPath)+1)
				
				break;
			end
		end
	end
	
	LuaDebugger.pathCachePaths[source] = file
	
	return file ;
end

local function debugger_initDebugStepInfo()
	--单步跳过
	LuaDebugger.stepInfo = {isStep = false, isReturn = false}
	--是否为单步跳入
	LuaDebugger.isStepIn = false
	LuaDebugger.isStepIn = false
	LuaDebugger.isStepOut = false
	LuaDebugger.isStepOutReturn = false
	LuaDebugger.Run = true
end

--设置单步跳入的信息
local function debugger_setStepInfo(stepInfo,iscall)
	
	local file = getSource(stepInfo.source)
	local line =  stepInfo.currentline
	if(iscall) then
		line = stepInfo.linedefined
	end
	LuaDebugger.stepInfo =
	{
		file = file,
		line = line,
		func = stepInfo.func,
		lastlinedefined = stepInfo.lastlinedefined,
		linedefined= stepInfo.linedefined,
		isStep = false,
		isReturn = false
	} ;
	
	
end

--获取lua 变量的方法
local function debugger_getBreakVar(body, server)
	local function exe()
		
		local variablesReference = body.variablesReference
		local debugSpeedIndex = body.debugSpeedIndex
		local frameId = body.frameId ;
		local type_ = body.type ;
		local keys = body.keys ;
		
		--找到对应的var
		local vars = nil
	
		if(type_ == 1) then
			vars = LuaDebugger.currentDebuggerData.vars[frameId + 1]
			vars = vars.locals
		elseif(type_ == 2) then
			vars = LuaDebugger.currentDebuggerData.vars[frameId + 1]
			vars = vars.ups
		elseif(type_ == 3) then
			vars = _G
		end
		
		--特殊处理下
		for i, v in ipairs(keys) do
			vars = vars[v]
			if(type(vars) == "userdata") then
				vars = tolua.getpeer(vars)
			end

			if(vars == nil) then
				break ;
			end
		end
		local vinfos = {}
		-- local varinfos ={}
		local count = 0 ;
		if(vars ~= nil) then
			for k, v in pairs(vars) do
				local vinfo = debugger_setVarInfo(k, v)
				table.insert(vinfos, vinfo)
				if(# vinfos >10) then
					debugger_sendMsg(server,
					LuaDebugger.event.C2S_ReqVar,
					{
						variablesReference = variablesReference,
						debugSpeedIndex = debugSpeedIndex,
						vars = vinfos,
						isComplete = 0
						
					})
					vinfos = {}
				end
			end
		end
		
		debugger_sendMsg(server, LuaDebugger.event.C2S_ReqVar, {
			variablesReference = variablesReference,
			debugSpeedIndex = debugSpeedIndex,
			vars = vinfos,
			isComplete = 1
			
		})
	end
	xpcall(exe, function(error)
	print("获取变量错误 错误消息-----------------")
	print(error)
	print(debug.traceback("", 2))
end)
end

local function debugger_loop(server)
	server = debug_server
	--命令
	local command
	local eval_env = {}
	local arg
	while true do
		local line, status = server:receive()
		
		if(line) then
			
			local netData = json.decode(line)
			
			local event = netData.event ;
			
			local body = netData.data ;
			
			if event == LuaDebugger.event.S2C_SetBreakPoints then
				--设置断点信息
				local function setB()
				debugger_setBreak(body)
				end
				
				xpcall(setB, function(error)
		
					print(error)
				end)
				
				
			elseif event == LuaDebugger.event.S2C_RUN then
				
				--重置调试信息
				debugger_initDebugStepInfo() ;
				LuaDebugger.runTimeType = body.runTimeType
				LuaDebugger.Run = true
				LuaDebugger.currentFileName =nil
				
				local data = coroutine.yield()
				
				LuaDebugger.currentDebuggerData = data ;
				debugger_sendMsg(server, data.event, {
					stack = data.stack,
					eventType = data.eventType

				})
			elseif event == LuaDebugger.event.S2C_ReqVar then
				--请求数据信息
				
				-- if(LuaDebugger.hookType ~= "lrc") then
				-- 	LuaDebugger.hookType = "lrc"
				-- 	if(LuaDebugger.isHook) then
				-- 		debug.sethook(debug_hook, LuaDebugger.hookType)
				-- 	end
				-- end
				debugger_getBreakVar(body, server)
			elseif event == LuaDebugger.event.S2C_NextRequest then
				LuaDebugger.Run = false
				LuaDebugger.stepInfo.isStep = true
				-- if(LuaDebugger.hookType ~= "lrc") then
				-- 	LuaDebugger.hookType = "lrc"
				-- 	if(LuaDebugger.isHook) then
				-- 	debug.sethook(debug_hook, LuaDebugger.hookType)
				-- 	end
				-- end
				--设置当前文件名和当前行数
				local data = coroutine.yield()
				--重置调试信息
				
				LuaDebugger.currentDebuggerData = data ;
				
				debugger_sendMsg(server, data.event, {
					stack = data.stack,
					eventType = data.eventType

				})
			elseif(event == LuaDebugger.event.S2C_StepInRequest) then
				--单步跳入
				LuaDebugger.isStepIn = true
				LuaDebugger.Run = false
				local data = coroutine.yield()
				--重置调试信息
				LuaDebugger.currentDebuggerData = data ;
				
				debugger_sendMsg(server, data.event, {
					stack = data.stack,
					eventType = data.eventType

				})
			elseif(event == LuaDebugger.event.S2C_StepOutRequest) then
				--单步跳出
				LuaDebugger.Run = false
				LuaDebugger.isStepOut = true
				local data = coroutine.yield()
				--重置调试信息
				LuaDebugger.currentDebuggerData = data ;
				
				debugger_sendMsg(server, data.event, {
					stack = data.stack,
					eventType = data.eventType

				})
			
			elseif event == LuaDebugger.event.S2C_LoadLuaScript then
				debugger_exeLuaString(body,true)
			elseif event == LuaDebugger.event.S2C_SetLuaClientPaths then
				LuaDebugger.clientPaths = body.paths
				local paths = {}
				for i,path in ipairs(LuaDebugger.clientPaths) do
					path =   path:gsub("-", "_")
					table.insert(paths,path)
				end
				LuaDebugger.clientPaths = paths
				
				LuaDebugger.isProntToConsole = body.isProntToConsole
				-- debugger_dump(LuaDebugger.clientPaths,"LuaDebugger.clientPaths")
			else
			
			end
		end
	end
end
 coro_debugger = coroutine.create(debugger_loop)




local function debugger_checkNextRequest(file, line)
	
	if(LuaDebugger.stepInfo.isStep) then
		if(file == LuaDebugger.stepInfo.file) then
			
			local lastlinedefined = LuaDebugger.stepInfo.lastlinedefined
			local linedefined = LuaDebugger.stepInfo.linedefined
			
			
			if(lastlinedefined == 0 and linedefined == 0)then
				LuaDebugger.stepInfo.isStep = false
				
				return true
			else
				if(line >= linedefined and line <= lastlinedefined) then
					LuaDebugger.stepInfo.isStep = false
					
					return true
				end
			end
			-- lastlinedefined linedefined
			-- if(line >= LuaDebugger.stepInfo.line and(LuaDebugger.stepInfo.lastlinedefined == 0 or line <= LuaDebugger.stepInfo.lastlinedefined)) then
			
				
			-- end
		end
	end
	return false
end







 debug_hook = function(event, line)

	if(not LuaDebugger.isHook) then
		return
	end
	-- print(event,line)
	local file = nil
	
	-- 如果为运行模式 先做一次筛选不再断点范围内的直接跳过
	if(LuaDebugger.Run  ) then
		if( event == "call") then
			return
		elseif(event == "return") then
		else
			local isCheck = false
			for i,breakInfo in pairs(LuaDebugger.breakInfos) do
				if(breakInfo[line]) then
					isCheck = true
					break
				end
			end
			if(not isCheck) then
				return
			end
		end
	end

	--下一步
	if( event == "line" and LuaDebugger.stepInfo.isStep and LuaDebugger.stepInfo.isReturn == false) then
		
		local isCheck = false
		--如果没有在断点的行
		for i,breakInfo in pairs(LuaDebugger.breakInfos) do
			if(breakInfo[line]) then
				isCheck = true
				break
			end
		end
		
		local lastlinedefined = LuaDebugger.stepInfo.lastlinedefined
		local linedefined = LuaDebugger.stepInfo.linedefined
		if(isCheck or ((lastlinedefined == 0 and linedefined == 0) or (line >= linedefined and line <= lastlinedefined)))then	
			--如果有断点的行 或者在 调试的方法的方位内 就进行下一次检查 不然就返回
			-- print("通过--------------")
			-- print("event",event)
		else
			return
		end		
	end

	
	if(event == "call") then
		local stepInfo = getinfo(2)
		local source = stepInfo.source
		if(source == "=[C]" or source:find("LuaDebug"))then return end
		file = getSource(source);
		--检查是否是方法进入时的断点
		if(debugger_checkIsBreak(file,stepInfo.linedefined)) then
			local stackInfo = debugger_stackInfo(3)
			local data = {
				stack = stackInfo.stack,
				vars = stackInfo.vars,
				funcs = stackInfo.funcs,
				event = LuaDebugger.event.C2S_NextResponse,
				eventType = event
			}
			--设置下一步的调试信息
			local stepInfo = getinfo(2)
			debugger_setStepInfo(stepInfo,true)
			LuaDebugger.isStepIn = false
			LuaDebugger.isStepOut = false
			LuaDebugger.isStepOutReturn = false
			--挂起等待调试器作出反应
			coroutine.resume(coro_debugger, data)
		end
		LuaDebugger.currentFileName = file
	elseif event == "return" or event == "tail return" then
		if(LuaDebugger.stepInfo.isStep or LuaDebugger.isStepOut) then
			if(LuaDebugger.stepInfo.file == file) then
				local currentInfo = getinfo(2)
				local fun = currentInfo.func
				if(LuaDebugger.stepInfo.func == fun) then
					--如果当前方法返回那么就需要再 line 接受新的
					--判断堆栈是为1  如果为1 并且 返回的话 就直接结束本次调试
					if(# LuaDebugger.currentDebuggerData.stack == 1) then
						--发送消息直接返回
						local data = {
							event = LuaDebugger.event.C2S_NextResponseOver
						}
						local stepInfo = currentInfo
						debugger_setStepInfo(stepInfo) ;
						LuaDebugger.isStepIn = false
						LuaDebugger.isStepOut = false
						LuaDebugger.isStepOutReturn = false
						coroutine.resume(coro_debugger, data)
					else
						if(LuaDebugger.isStepOut) then
							LuaDebugger.isStepOutReturn = true
						elseif(LuaDebugger.stepInfo.isStep) then
							LuaDebugger.stepInfo.isReturn = true
						end
					end
				end
			end
		end
		LuaDebugger.currentFileName = nil
	else
		if(not LuaDebugger.currentFileName) then
			local source = getinfo(2, "S").source
			if(source == "=[C]" or source:find("LuaDebug"))then return end
			file = getSource(source);
			LuaDebugger.currentFileName = file
			print(file)
		end
		file = LuaDebugger.currentFileName 
		
		local isHit = false
		local sevent = nil
		if(LuaDebugger.isStepIn) then
			isHit = true
			sevent = LuaDebugger.event.C2S_StepInResponse
		end
		--返回后执行的第一个句代码 将这一句代码设置为下一步
		if(isHit == false and LuaDebugger.stepInfo.isReturn) then
			local stepInfo = getinfo(2)
			--重新定义stepInfo
			debugger_setStepInfo(stepInfo)
			LuaDebugger.stepInfo.isReturn = false
			LuaDebugger.stepInfo.isStep = true
		end
		
		--下一步判断
		if(isHit == false and debugger_checkNextRequest(file, line)) then
			
			isHit = true
			sevent = LuaDebugger.event.C2S_NextResponse
		end
		
		--单步跳出
		if(isHit == false and LuaDebugger.isStepOut == true and LuaDebugger.isStepOutReturn == true) then
			isHit = true
			sevent = LuaDebugger.event.C2S_StepOutResponse
		end
		
		
		--断点判断
		if(isHit == false and debugger_checkIsBreak(file, line)) then
			
			isHit = true
			sevent = LuaDebugger.event.C2S_HITBreakPoint
		end
		
		--命中断点
		if(isHit) then
			
			--调用 coro_debugger 并传入 参数
			local stackInfo = debugger_stackInfo(3)
			
			local data = {
				stack = stackInfo.stack,
				vars = stackInfo.vars,
				funcs = stackInfo.funcs,
				event = sevent,
				eventType = event
			}
		
			--设置下一步的调试信息
			local stepInfo = getinfo(2)
			
			debugger_setStepInfo(stepInfo)
			LuaDebugger.isStepIn = false
			LuaDebugger.isStepOut = false
			LuaDebugger.isStepOutReturn = false
			--挂起等待调试器作出反应
			
			coroutine.resume(coro_debugger, data)
		end
		
	end
end

local function debugger_xpcall()
	--调用 coro_debugger 并传入 参数
	local stackInfo = debugger_stackInfo(4)
	local data = {
		stack = stackInfo.stack,
		vars = stackInfo.vars,
		funcs = stackInfo.funcs,
		event = LuaDebugger.event.C2S_HITBreakPoint
	}
	--设置下一步的调试信息
	local stepInfo = getinfo(2)
	
	debugger_setStepInfo(stepInfo)
	LuaDebugger.isStepIn = false
	LuaDebugger.isStepOut = false
	LuaDebugger.isStepOutReturn = false
	--挂起等待调试器作出反应
	
	coroutine.resume(coro_debugger, data)
end

--调试开始
local function start()
	
	local socket = createSocket()
	
	print(controller_host)
	print(controller_port)

	local server = socket.connect(controller_host, controller_port)
	
	debug_server = server;
	if server then
		--创建breakInfo socket
		socket = createSocket()
		breakInfoSocket = socket.connect(controller_host, controller_port)
		if(breakInfoSocket) then
			breakInfoSocket:settimeout(0)
			debugger_sendMsg(breakInfoSocket, LuaDebugger.event.C2S_SetSocketName, {
				name = "breakPointSocket"
			})
			debugger_sendMsg(server, LuaDebugger.event.C2S_SetSocketName, {
				name = "mainSocket",
				rootPath =package.path
			})
			debugger_initDebugStepInfo() ;
			debug.sethook(debug_hook, "lrc")
			coroutine.resume(coro_debugger, server)
		end
	end
end
function StartDebug(host,port) 
	print("-=----------------------------")
	if(not host) then
		print("error host nil")
	end
	if(not port) then
		print("error prot nil")
	end
	if(type(host) ~= "string") then
		print("error host not string")
	end
	if(type(port) ~= "number") then
		print("error host not number")
	end
	

	controller_host = host
	controller_port = 7003
	xpcall(start,function(error )
		-- body
		print(error)
	end)
	
	
	return debugger_receiveDebugBreakInfo,debugger_xpcall

end
return StartDebug