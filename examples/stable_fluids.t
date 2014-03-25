import "compiler.liszt"

local Grid  = terralib.require 'compiler.grid'
local cmath = terralib.includecstring [[
#include <math.h>
#include <stdlib.h>
#include <time.h>



float rand_float()
{
      float r = (float)rand() / (float)RAND_MAX;
      return r;
}
]]
cmath.srand(cmath.time(nil));
local vdb   = terralib.require 'compiler.vdb'

local N = 150
local grid = Grid.New2dUniformGrid(N, N, {-N/2.0, -1.0}, N, N)

local viscosity     = 0.08
local dt            = L.NewGlobal(L.float, 0.01)


grid.cells:NewField('velocity', L.vec2f)
grid.cells.velocity:LoadConstant(L.NewVector(L.float, {0,0}))

grid.cells:NewField('velocity_prev', L.vec2f)
grid.cells.velocity_prev:LoadConstant(L.NewVector(L.float, {0,0}))





-----------------------------------------------------------------------------
--[[                             UPDATES                                 ]]--
-----------------------------------------------------------------------------

local velocity_zero = liszt_kernel(c : grid.cells)
    c.velocity = {0,0}
end

local velocity_swap = liszt_kernel(c : grid.cells)
    c.velocity_prev = c.velocity
end


local velocity_update_bnd = liszt kernel (c : grid.cells)
    var v = c.velocity_prev
    if c.is_bnd then
        if c.is_left_bnd then
            v = c.right.velocity_prev
            v[0] = -v[0]
        elseif c.is_right_bnd then
            v = c.left.velocity_prev
            v[0] = -v[0]
        elseif c.is_up_bnd then
            v = c.down.velocity_prev
            v[1] = -v[1]
        elseif c.is_down_bnd then
            v = c.up.velocity_prev
            v[1] = -v[1]
        end
    end
    c.velocity = v
end

-----------------------------------------------------------------------------
--[[                             VELSTEP                                 ]]--
-----------------------------------------------------------------------------

-----------------------------------------------------------------------------
--[[                             DIFFUSE                                 ]]--
-----------------------------------------------------------------------------

local diffuse_diagonal = L.NewGlobal(L.float, 0.0)
local diffuse_edge     = L.NewGlobal(L.float, 0.0)
grid.cells:NewField('diffuse_temp', L.vec2f):Load(L.NewVector(L.float, {0,0}))

-- One Jacobi-Iteration
local diffuse_lin_solve_jacobi_init = liszt kernel (c : grid.cells)
    if c.is_bnd then
    else
        c.diffuse_temp = c.velocity
    end
end
local diffuse_lin_solve_jacobi_step = liszt kernel (c : grid.cells)
    if c.is_bnd then
        c.diffuse_temp = {0,0}
    else
        var edge_sum = diffuse_edge * (
            c.left.velocity + c.right.velocity +
            c.up.velocity + c.down.velocity
        )
        c.diffuse_temp = (c.velocity_prev - edge_sum) / diffuse_diagonal
    end
end
local diffuse_lin_solve_jacobi_commit = liszt kernel (c : grid.cells)
    c.velocity = c.diffuse_temp
end

-- Should be called with velocity and velocity_prev both set to
-- the previous velocity field value...
local function diffuse_lin_solve(edge, diagonal)
    diffuse_diagonal:setTo(diagonal)
    diffuse_edge:setTo(edge)

    -- do 20 Jacobi iterations
    for i=1,20 do
        diffuse_lin_solve_jacobi_step(grid.cells)
        diffuse_lin_solve_jacobi_commit(grid.cells)
        -- set boundary conditions
        velocity_swap(grid.cells)
        velocity_update_bnd(grid.cells)
    end
end

local function diffuse_velocity(grid)
    -- Why the N*N term?  I don't get that...
    local laplacian_weight  = dt:value() * viscosity * N * N
    local diagonal          = 1.0 + 4.0 * laplacian_weight
    local edge              = -laplacian_weight

    velocity_swap(grid.cells)
    diffuse_lin_solve(edge, diagonal)

    velocity_swap(grid.cells)
    velocity_update_bnd(grid.cells)
end

-----------------------------------------------------------------------------
--[[                             ADVECT                                  ]]--
-----------------------------------------------------------------------------

local cell_w = grid:cellWidth()
local cell_h = grid:cellHeight()

local advect_dt = L.NewGlobal(L.float, 0.0)
grid.cells:NewField('lookup_pos', L.vec2f):Load(L.NewVector(L.float, {0,0}))
grid.cells:NewField('lookup_from', grid.dual_cells):Load(0)

local advect_where_from = liszt_kernel(c : grid.cells)
    var offset      = - c.velocity_prev
    -- Make sure all our lookups are appropriately confined
    c.lookup_pos    = grid.snap_to_grid(c.center + advect_dt * offset)
end

local advect_point_locate = liszt_kernel(c : grid.cells)
    c.lookup_from   = grid.dual_locate(c.lookup_pos)
end

local advect_interpolate_velocity = liszt_kernel(c : grid.cells)
    if not c.is_bnd then
        var dc      = c.lookup_from
        var frac    = c.lookup_pos - dc.center
        -- figure out fractional position in the dual cell in range [0.0, 1.0]
        var xfrac   = frac[0] / cell_w + 0.5 
        var yfrac   = frac[1] / cell_h + 0.5

        -- interpolation constants
        var x1      = L.float(xfrac)
        var y1      = L.float(yfrac)
        var x0      = L.float(1.0 - xfrac)
        var y0      = L.float(1.0 - yfrac)

        c.velocity  = x0 * y0 * dc.upleft.velocity_prev
                    + x1 * y0 * dc.upright.velocity_prev
                    + x0 * y1 * dc.downleft.velocity_prev
                    + x1 * y1 * dc.downright.velocity_prev
    end
end

local function advect_velocity(grid)
    -- Why N?
    advect_dt:setTo(dt:value() * N)

    -- switch the velocity field into the previous velocity field
    velocity_swap(grid.cells)

    advect_where_from(grid.cells)
    advect_point_locate(grid.cells)
    advect_interpolate_velocity(grid.cells)

    velocity_swap(grid.cells)
    velocity_update_bnd(grid.cells)
end

-----------------------------------------------------------------------------
--[[                             PROJECT                                 ]]--
-----------------------------------------------------------------------------

local project_diagonal = L.NewGlobal(L.float, 0.0)
local project_edge     = L.NewGlobal(L.float, 0.0)
grid.cells:NewField('divergence', L.float):Load(0)
grid.cells:NewField('p', L.float):Load(0)
grid.cells:NewField('p_temp', L.float):Load(0)

local init_p = liszt kernel (c : grid.cells)
    c.p_temp = c.divergence
    c.p      = c.divergence
end
local project_lin_solve_jacobi_step = liszt kernel (c : grid.cells)
    if c.is_bnd then
        c.p_temp = 0
    else
        var edge_sum = project_edge * ( c.left.p + c.right.p +
                                        c.up.p + c.down.p )
        c.p_temp = (c.divergence - edge_sum) / project_diagonal
    end
end
local project_lin_solve_jacobi_commit = liszt kernel (c : grid.cells)
    c.p = c.p_temp
end
-- Neumann condition
local project_lin_solve_bnd_condition = liszt kernel (c : grid.cells)
    if c.is_bnd then
        if c.is_left_bnd then
            c.p_temp = c.right.p
        elseif c.is_right_bnd then
            c.p_temp = c.left.p
        elseif c.is_up_bnd then
            c.p_temp = c.down.p
        elseif c.is_down_bnd then
            c.p_temp = c.up.p
        end
    end
end
-- Give the divergence a Neumann condition
local set_initial_div_bnd_condition = liszt kernel (c : grid.cells)
    if c.is_bnd then
        c.divergence = c.p_temp
    end
end

-- Should be called with velocity and velocity_prev both set to
-- the previous velocity field value...
local function project_lin_solve(edge, diagonal)
    project_diagonal:setTo(diagonal)
    project_edge:setTo(edge)

    -- do 20 Jacobi iterations
    for i=1,20 do
        project_lin_solve_jacobi_step(grid.cells)
        project_lin_solve_bnd_condition(grid.cells)
        project_lin_solve_jacobi_commit(grid.cells)
    end
end

local compute_divergence = liszt kernel (c : grid.cells)
    if c.is_bnd then
        c.divergence = 0
    else
        -- why the factor of N?
        var vx_dx = c.right.velocity[0] - c.left.velocity[0]
        var vy_dy = c.up.velocity[1]   - c.down.velocity[1]
        c.divergence = L.float(-(0.5/N)*(vx_dx + vy_dy))
    end
end

local compute_projection = liszt kernel (c : grid.cells)
    if not c.is_bnd then
        var grad = L.vec2f(0.5 * N * { c.right.p - c.left.p,
                                       c.up.p   - c.down.p })
        c.velocity = c.velocity_prev - grad
    end
end

local function project_velocity(grid)
    -- Why the N*N term?  I don't get that...
    --local laplacian_weight  = dt:value() * viscosity * N * N
    local diagonal          =  4.0
    local edge              = -1.0

    compute_divergence(grid.cells)

    init_p(grid.cells)
    project_lin_solve_bnd_condition(grid.cells)
    project_lin_solve_jacobi_commit(grid.cells)
    set_initial_div_bnd_condition(grid.cells)

    project_lin_solve(edge, diagonal)

    velocity_swap(grid.cells)
    compute_projection(grid.cells)

    velocity_swap(grid.cells)
    velocity_update_bnd(grid.cells)
end



local N_particles = (N-1)*(N-1)
local particles = L.NewRelation(N_particles, 'particles')

particles:NewField('dual_cell', grid.dual_cells)
    :Load(function(i) return i end)

particles:NewField('next_pos', L.vec2f):Load(L.NewVector(L.float, {0,0}))
particles:NewField('pos', L.vec2f):Load(L.NewVector(L.float, {0,0}))
(liszt kernel (p : particles) -- init...
    p.pos = p.dual_cell.center
end)(particles)

local locate_particles = liszt kernel (p : particles)
    p.dual_cell = grid.dual_locate(p.pos)
end

local compute_particle_velocity = liszt kernel (p : particles)
    var dc      = p.dual_cell
    var frac    = p.pos - dc.center
    -- figure out fractional position in the dual cell in range [0.0, 1.0]
    var xfrac   = frac[0] / cell_w + 0.5 
    var yfrac   = frac[1] / cell_h + 0.5

    -- interpolation constants
    var x1      = L.float(xfrac)
    var y1      = L.float(yfrac)
    var x0      = L.float(1.0 - xfrac)
    var y0      = L.float(1.0 - yfrac)

    p.next_pos  = p.pos + N *
        ( x0 * y0 * dc.upleft.velocity
        + x1 * y0 * dc.upright.velocity
        + x0 * y1 * dc.downleft.velocity
        + x1 * y1 * dc.downright.velocity )
end

local update_particle_pos = liszt kernel (p : particles)
    var r = L.vec2f({ cmath.rand_float() - 0.5, cmath.rand_float() - 0.5 })
    var pos = p.next_pos + dt * r
    p.pos = grid.snap_to_grid(pos)
end


-----------------------------------------------------------------------------
--[[                             MAIN LOOP                               ]]--
-----------------------------------------------------------------------------

--grid.cells:print()

local source_strength = 100.0
local source_velocity = liszt kernel (c : grid.cells)
    if cmath.fabs(c.center[0]) < 1.75 and
       cmath.fabs(c.center[1]) < 1.75 and
       not c.is_bnd
    then
        c.velocity += dt * source_strength * { 0.0, 1.0 }
    end
end

local draw_grid = liszt kernel (c : grid.cells)
    var color = {1.0, 1.0, 1.0}
    vdb.color(color)
    var p : L.vec3f = { c.center[0],   c.center[1],   0.0 }
    var vel = c.velocity
    var v = L.vec3f({ vel[0], vel[1], 0.0 })
    --if not c.is_bnd then
    vdb.line(p, p+v*N)
end

local draw_particles = liszt kernel (p : particles)
    var color = {1.0,1.0,0.0}
    vdb.color(color)
    var pos : L.vec3f = { p.pos[0], p.pos[1], 0.0 }
    vdb.point(pos)
end

for i = 1, 1000 do
    if math.floor(i / 70) % 2 == 0 then
        source_velocity(grid.cells)
        velocity_swap(grid.cells)
        velocity_update_bnd(grid.cells)
    end

    diffuse_velocity(grid)
    project_velocity(grid)
    --grid.cells:print()
    --io.read()

    advect_velocity(grid)
    project_velocity(grid)

    compute_particle_velocity(particles)
    update_particle_pos(particles)
    locate_particles(particles)

    vdb.vbegin()
        vdb.frame()
        draw_grid(grid.cells)
        draw_particles(particles)
    vdb.vend()

end

--grid.cells:print()

