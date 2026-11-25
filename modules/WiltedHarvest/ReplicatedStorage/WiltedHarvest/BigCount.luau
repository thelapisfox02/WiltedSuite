--!strict
--[[
	=== WiltedHarvest.BigCount =================================================

	Totals that may grow past what a plain number can hold exactly.

	SAVED FORM (JSON-safe, and the same shape many big-number libraries use):
	    a plain number          while |value| < 1e15 (whole numbers stay exact)
	    { mantissa, exponent }   from 1e15 up, 1 <= |mantissa| < 10
	                             value = mantissa x 10^exponent
	Above 1e15 a value keeps about 15 significant digits. There is no upper
	limit: the exponent is a plain number, so 1e400 or 1e100000 are fine.

	Accepted INPUT (BigCount.parts): a number, a { mantissa, exponent }
	array, or any table with numeric fields `first` / `second` (the shape
	of common big-number objects). Anything else -> nil.

	Pure, no state, no yields. Exposed as Harvest.BigCount so a game can
	read big counters back:
	    local total = summary.Extensions.Counters["myGame.gold"]
	    print(Harvest.BigCount.format(total))   --> "1.2345e+42"
]]

local BigCount = {}

export type Value = number | { number }

local EXACT = 1e15
BigCount.EXACT = EXACT

local function finite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- (mantissa, exponent) with 1 <= |m| < 10, or (0, 0).
local function normalise(m: number, e: number): (number, number)
	if m == 0 then
		return 0, 0
	end
	local k = math.floor(math.log10(math.abs(m)))
	if k ~= 0 then
		m = m / 10 ^ k
		e += k
	end
	if math.abs(m) >= 10 then
		m /= 10
		e += 1
	elseif math.abs(m) < 1 then
		m *= 10
		e -= 1
	end
	return m, e
end

--[[ Any accepted input -> (mantissa, exponent) normalised, or nil. ]]
function BigCount.parts(value: any): (number?, number?)
	if type(value) == "number" then
		if not finite(value) then
			return nil, nil
		end
		return normalise(value, 0)
	elseif type(value) == "table" then
		local m, e = value[1], value[2]
		if m == nil and e == nil then
			m, e = (value :: any).first, (value :: any).second
		end
		if not finite(m) or not finite(e) or e % 1 ~= 0 then
			return nil, nil
		end
		return normalise(m, e)
	end
	return nil, nil
end

--[[ (mantissa, exponent) -> saved form. ]]
function BigCount.fromParts(m: number, e: number): Value
	m, e = normalise(m, e)
	if e < 15 then
		local v = m * 10 ^ e
		if e >= 0 then
			-- m x 10^e of a whole number is off by float noise (1234.0000000002).
			local r = math.round(v)
			if math.abs(v - r) <= 1e-6 * math.max(1, math.abs(v)) then
				v = r
			end
		end
		return v
	end
	return { m, e }
end

--[[ Any accepted input -> saved form, or nil when the input is invalid. ]]
function BigCount.from(value: any): Value?
	if type(value) == "number" then
		if not finite(value) then
			return nil
		end
		if math.abs(value) < EXACT then
			return value
		end
	end
	local m, e = BigCount.parts(value)
	if m == nil or e == nil then
		return nil
	end
	return BigCount.fromParts(m, e)
end

--[[ a + b (any accepted inputs). Invalid inputs count as 0. ]]
function BigCount.add(a: any, b: any): Value
	if type(a) == "number" and type(b) == "number" and finite(a) and finite(b) then
		local s = a + b
		if math.abs(s) < EXACT then
			return s -- exact fast path
		end
	end
	local ma, ea = BigCount.parts(a)
	local mb, eb = BigCount.parts(b)
	if ma == nil or ea == nil or ma == 0 then
		return BigCount.from(b) or 0
	end
	if mb == nil or eb == nil or mb == 0 then
		return BigCount.from(a) or 0
	end
	if ea < eb then
		ma, ea, mb, eb = mb, eb, ma, ea
	end
	local gap = ea - eb
	local m = if gap > 20 then ma else ma + mb / 10 ^ gap
	return BigCount.fromParts(m, ea)
end

-- -1, 0 or 1 (invalid -> 0).
function BigCount.sign(value: any): number
	local m = BigCount.parts(value)
	if m == nil or m == 0 then
		return 0
	end
	return if m > 0 then 1 else -1
end

--[[ Plain number, or nil when it does not fit in one (|value| >= ~1.8e308). ]]
function BigCount.toNumber(value: any): number?
	local m, e = BigCount.parts(value)
	if m == nil or e == nil then
		return nil
	end
	local v = m * 10 ^ e
	return if finite(v) then v else nil
end

-- "12345" below 1e15, otherwise "1.2345e+42" (5 significant digits).
function BigCount.format(value: any): string
	local m, e = BigCount.parts(value)
	if m == nil or e == nil then
		return "invalid"
	end
	if e < 15 then
		local v = BigCount.fromParts(m, e) :: number
		return if v % 1 == 0 then string.format("%d", v) else tostring(v)
	end
	return string.format("%.4fe+%d", m, e)
end

return BigCount
