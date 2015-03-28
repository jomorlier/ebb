import "compiler.liszt"
require "tests/test"

-- Need a high N to test the index-based representation as well as boolmask
local N = 40
local cells = L.NewRelation { size = N*N, name = 'cells' }

local function yidx(i) return math.floor(i/N) end

cells:NewField('value', L.double):Load(function(i)
  if yidx(i) == 0 or yidx(i) == N-1 or i%N == 0 or i%N == N-1 then
    return 0
  else
    return 1
  end
end)

cells:NewSubsetFromFunction('boundary', function(i)
  return yidx(i) == 0 or yidx(i) == N-1 or i%N == 0 or i%N == N-1
end)
cells:NewSubsetFromFunction('interior', function(i)
  return not (yidx(i) == 0 or yidx(i) == N-1 or i%N == 0 or i%N == N-1)
end)


local test_boundary = liszt ( c : cells )
  L.assert(c.value == 0)
end

local test_interior = liszt ( c : cells )
  L.assert(c.value == 1)
end

cells.boundary:map(test_boundary)
cells.interior:map(test_interior)



-- Now run the same test, but with a truly grid structured relation

local gridcells  = L.NewRelation { dims = {N,N}, name = 'gridcells' }

gridcells:NewField('value', L.double):Load(function(xi,yi)
  if xi == 0 or xi == N-1 or yi == 0 or yi == N-1 then
    return 0
  else
    return 1
  end
end)

gridcells:NewSubsetFromFunction('boundary', function(xi,yi)
  return xi == 0 or xi == N-1 or yi == 0 or yi == N-1
end)
gridcells:NewSubsetFromFunction('interior', function(xi,yi)
  return not(xi == 0 or xi == N-1 or yi == 0 or yi == N-1)
end)

local liszt grid_test_boundary ( c : gridcells )
  L.assert(c.value == 0)
end
local liszt grid_test_interior ( c : gridcells )
  L.assert(c.value == 1)
end

gridcells.boundary:map(grid_test_boundary)
gridcells.interior:map(grid_test_interior)




