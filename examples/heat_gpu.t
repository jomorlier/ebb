if not terralib.cudacompile then
	print("This simulation requires CUDA support; exiting...")
	return
end


--------------------------------------------------------------------------------
--[[ Grab references to CUDA API                                            ]]--
--------------------------------------------------------------------------------
terralib.includepath = terralib.includepath..";/usr/local/cuda/include"
local C = terralib.includecstring [[
#include "cuda_runtime.h"
#include <stdlib.h>
#include <stdio.h>
]]

-- Find cudasMemcpyKind enum in <cuda-include>/driver_types.h, have to
-- declare manually since terra doesn't grok enums from include files
C.cudaMemcpyHostToDevice = 1
C.cudaMemcpyDeviceToHost = 2

local tid       = cudalib.nvvm_read_ptx_sreg_tid_x -- threadId.x
local sqrt      = cudalib.nvvm_sqrt_rm_d           -- floating point sqrt, round to nearest
--local atomicAdd = cudalib.atom_add_f


--------------------------------------------------------------------------------
--[[ Read in mesh relation, initialize fields                               ]]--
--------------------------------------------------------------------------------
--[[
-- this code isn't working on derp.stanford.edu - linux problems with path module?
local PN    = terralib.require 'compiler.pathname'
local LMesh = terralib.require "compiler.lmesh"
local M     = LMesh.Load(PN.scriptdir():concat("rmesh.lmesh"):tostring())
]]--

local LMesh = terralib.require "compiler.lmesh"
local M     = LMesh.Load('/home/clemire/liszt-in-terra/examples/rmesh.lmesh')

local init_to_zero = terra (mem : &float, i : int) mem[0] = 0 end
local init_temp    = terra (mem : &float, i : int)
	if i == 0 then
		mem[0] = 1000
	else 
		mem[0] = 0
	end
end

M.vertices:NewField('flux',        L.float):LoadFromCallback(init_to_zero)
M.vertices:NewField('jacobistep',  L.float):LoadFromCallback(init_to_zero)
M.vertices:NewField('temperature', L.float):LoadFromCallback(init_temp)

M.edges:NewField('debug', L.float):LoadFromCallback(init_to_zero)


--------------------------------------------------------------------------------
--[[ Parallel kernels for GPU:                                              ]]--
--------------------------------------------------------------------------------
local terra compute_step (head : &uint64, tail : &uint64, 
	                      flux : &float,  jacobistep : &float,
	                      temp : &float,  position   : &float, debug : &float) : {}

	var edge_id : uint64 = tid()
	var head_id : uint64 = head[edge_id]
	var tail_id : uint64 = tail[edge_id]

	var dp : double[3]
	dp[0] = position[3*head_id]   - position[3*tail_id]
	dp[1] = position[3*head_id+1] - position[3*tail_id+1]
	dp[2] = position[3*head_id+2] - position[3*tail_id+2]

	var dpsq = dp[0]*dp[0] + dp[1]*dp[1] + dp[2] * dp[2]
	var len  = sqrt(dpsq)
	var step = 1.0 / len

	var dt : float = temp[head_id] - temp[tail_id]

--[[ Non-atomic (unsafe) add-reductions
	flux[head_id] = flux[head_id] - dt * step
	flux[tail_id] = flux[tail_id] + dt * step

	jacobistep[head_id] = jacobistep[head_id] + step
	jacobistep[tail_id] = jacobistep[tail_id] + step
--]]

--[-[ atomic (safe) add-reductions.  Why are these segfaulting?
	atomicAdd(&flux[head_id], -dt * step)
	atomicAdd(&flux[tail_id],  dt * step)

	atomicAdd(&jacobistep[head_id], step)
	atomicAdd(&jacobistep[tail_id], step)
--]]

end

local terra propagate_temp (temp : &float, flux : &float, jacobistep : &float, debug : &float)
	var vid = tid()
	debug[vid] = flux[vid]
	temp[vid] = temp[vid] + .01 * flux[vid] / jacobistep[vid]
end

local terra clear_temp_vars (flux : &float, jacobistep : &float, debug : &float)
	var vid = tid()
	flux[vid]       = 0.0
	jacobistep[vid] = 0.0
end

local R = terralib.cudacompile { compute_step    = compute_step,
                                 propagate_temp  = propagate_temp,
                                 clear_temp_vars = clear_temp_vars }


--------------------------------------------------------------------------------
--[[ Simulation:                                                            ]]-- 
--------------------------------------------------------------------------------
terra copy_posn_data (data : &vector(double, 3), N : int) : &float
	var ret : &float = [&float](C.malloc(sizeof(float) * N * 3))
	for i = 0, N do
		ret[3*i]   = data[i][0]
		ret[3*i+1] = data[i][1]
		ret[3*i+2] = data[i][2]
	end
	return ret
end	

local nEdges = M.edges:Size()
local nVerts = M.vertices:Size()

local terra run_simulation (iters : uint64)
	var posn_data = copy_posn_data(M.vertices.position.data, nVerts)

	-- Allocate and copy over field data to GPU device
	var head_ddata : &uint64,
	    tail_ddata : &uint64,
	    debg_ddata : &float,
	    flux_ddata : &float,
	    jaco_ddata : &float, 
	    temp_ddata : &float, 
	    posn_ddata : &float

	var tsize = sizeof(uint64) * nEdges -- size of edge topology relation
	var fsize = sizeof(float)  * nVerts -- size of fields over vertices
	var dsize = sizeof(float)  * nEdges -- size of debug field over edges

	C.cudaMalloc([&&opaque](&head_ddata),   tsize)
	C.cudaMalloc([&&opaque](&tail_ddata),   tsize)
	C.cudaMalloc([&&opaque](&debg_ddata),   dsize)
	C.cudaMalloc([&&opaque](&flux_ddata),   fsize)
	C.cudaMalloc([&&opaque](&jaco_ddata),   fsize)
	C.cudaMalloc([&&opaque](&temp_ddata),   fsize)
	C.cudaMalloc([&&opaque](&posn_ddata), 3*fsize)

	C.cudaMemcpy([&opaque](head_ddata), [&opaque](M.edges.head.data),             tsize, C.cudaMemcpyHostToDevice)
	C.cudaMemcpy([&opaque](tail_ddata), [&opaque](M.edges.tail.data),             tsize, C.cudaMemcpyHostToDevice)
	C.cudaMemcpy([&opaque](debg_ddata), [&opaque](M.edges.debug.data),            dsize, C.cudaMemcpyHostToDevice)
	C.cudaMemcpy([&opaque](flux_ddata), [&opaque](M.vertices.flux.data),          fsize, C.cudaMemcpyHostToDevice)
	C.cudaMemcpy([&opaque](jaco_ddata), [&opaque](M.vertices.jacobistep.data),    fsize, C.cudaMemcpyHostToDevice)
	C.cudaMemcpy([&opaque](temp_ddata), [&opaque](M.vertices.temperature.data),   fsize, C.cudaMemcpyHostToDevice)
	C.cudaMemcpy([&opaque](posn_ddata), [&opaque](posn_data),                   3*fsize, C.cudaMemcpyHostToDevice)

	-- Launch parameters
	var eLaunch = terralib.CUDAParams { 1, 1, 1, nEdges, 1, 1, 0, nil }
	var vLaunch = terralib.CUDAParams { 1, 1, 1, nVerts, 1, 1, 0, nil }

	-- run kernels!
	for i = 0, iters do
		R.compute_step(&eLaunch,    head_ddata, tail_ddata, flux_ddata, jaco_ddata,
		                            temp_ddata, posn_ddata, debg_ddata)
		R.propagate_temp(&vLaunch,  temp_ddata, flux_ddata, jaco_ddata, debg_ddata)
		R.clear_temp_vars(&vLaunch, flux_ddata, jaco_ddata, debg_ddata)
	end

	-- copy back results
	C.cudaMemcpy([&opaque](M.vertices.temperature.data),  [&opaque](temp_ddata),  fsize, C.cudaMemcpyDeviceToHost)
	C.cudaMemcpy([&opaque](M.edges.debug.data),           [&opaque](debg_ddata),  dsize, C.cudaMemcpyDeviceToHost)

	-- Free unused memory
	C.free(posn_data)

	C.cudaFree(head_ddata)
	C.cudaFree(tail_ddata)
	C.cudaFree(debg_ddata)
	C.cudaFree(flux_ddata)
	C.cudaFree(jaco_ddata)
	C.cudaFree(temp_ddata)
	C.cudaFree(posn_ddata)
end

local function main()
	run_simulation(1)

	-- Debug output:
	M.edges:print()
	M.vertices.temperature:print()
end

main()
