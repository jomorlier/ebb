test = {}

function test.eq(a,b)
	if a ~= b then
		error(tostring(a) .. " ~= "  .. tostring(b),2)
	end
end
function test.neq(a,b)
	if a == b then
		error(tostring(a) .. " == "  .. tostring(b),2)
	end
end

function test.seteq(a,b)
	for id,_ in pairs(a) do
		if not b[id] then
			error('Element ' .. tostring(id) .. ' of the left-set was not found '..
				 		'in the right-set', 2)
		end
	end
	for id,_ in pairs(b) do
		if not a[id] then
			error('Element ' .. tostring(id) .. ' of the right-set was not found '..
				 		'in the left-set', 2)
		end
	end
end

function test.aeq(a, b)
	if #a ~= #b then error("Arrays are not of equal length", 2) end
	for i = 1, #a do
		if a[i] ~= b[i] then error("Element " .. tostring(i) .. " of arrays do not match (" .. tostring(a[i]) .. ", " .. tostring(b[i]) .. ")", 2) end
	end
end

function test.rec_aeq(a, b, idxstr)
	idxstr = idxstr or ''
	if type(a) ~= 'table' or type(b) ~= 'table' then
		if a ~= b then error("Element (index"..idxstr.." ) "..
												 "of arrays does not match "..
												 "( "..tostring(a).." vs. "..tostring(b).." )",
												 2) end
	else
		if #a ~= #b then error("(Sub-)arrays (index "..idxstr.." ) "..
													 "do not have matching length "..
													 "( "..tostring(#a).." vs. "..tostring(#b).." )",
													 2) end
		-- recurse
		for i=1,#a do
			test.rec_aeq(a[i],b[i], idxstr..' '..tostring(i))
		end
	end
end

local zero_diff = .0000005
function test.fuzzy_aeq (a, b)
	if #a ~= #b then error("Arrays are not of equal length", 2) end
	for i = 1, #a do
		local d = a[i] - b[i]
		if d < 0 then d = -d end
		if d > zero_diff then error("Element " .. tostring(i) .. " of arrays do not match (" .. tostring(a[i]) .. ", " .. tostring(b[i]) .. ")", 2) end
	end
end
function test.fuzzy_eq (a, b)
	local d = a - b
	if d < 0 then d = -d end
	if d > zero_diff then error(tostring(a) .. " ~= " .. tostring(b),2) end
end

function test.meq(a,...)
	local lst = {...}
	if #lst ~= #a then
		error("size mismatch",2)
	end
	for i,e in ipairs(a) do
		if e ~= lst[i] then
			error(tostring(i) .. ": "..tostring(e) .. " ~= " .. tostring(lst[i]),2)
		end
	end
end

function test.time(fn)
    local s = terralib.currenttimeinseconds()
    fn()
    local e = terralib.currenttimeinseconds()
    return e - s
end

-- This code is based off tests/coverage.t from the terra project
function test.fail_function(fn, match)
	local msg = ''
	local function handler ( errobj )
		msg = tostring(errobj) .. '\n' .. debug.traceback()
	end
	local success = xpcall(fn, handler)
	if success then
		error("Expected function to fail, but it succeeded.", 2)
	elseif not string.match(msg,match) then
		error("Function did not produce the expected error: " .. msg, 2)
	end
end



-- And this function is based off of a similar fn found in tests/twolang.t in the terra project
function test.fail_parse(str,match)
	local r,msg = terralib.loadstring(str)
	if r then
		error("Erroneous syntax did not produce error.", 2)
	elseif not msg:match(match) then
		error("Erroneous syntax did not produce the expected error: " .. msg, 2)
	end
end

return test
