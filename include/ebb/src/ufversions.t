-- The MIT License (MIT)
-- 
-- Copyright (c) 2015 Stanford University.
-- All rights reserved.
-- 
-- Permission is hereby granted, free of charge, to any person obtaining a
-- copy of this software and associated documentation files (the "Software"),
-- to deal in the Software without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense,
-- and/or sell copies of the Software, and to permit persons to whom the
-- Software is furnished to do so, subject to the following conditions:
-- 
-- The above copyright notice and this permission notice shall be included
-- in all copies or substantial portions of the Software.
-- 
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING 
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.

local UF   = {}
package.loaded["ebb.src.ufversions"] = UF

local use_legion = not not rawget(_G, '_legion_env')
local use_single = not use_legion

local Pre   = require "ebb.src.prelude"
local C     = require "ebb.src.c"
local G     = require "ebb.src.gpu_util"
local T     = require "ebb.src.types"
local Util  = require 'ebb.src.util'

local CPU       = Pre.CPU
local GPU       = Pre.GPU
local uint64T   = T.uint64
local keyT      = T.key

local EbbGlobal = Pre.Global

local codegen         = require "ebb.src.codegen"
local codesupport     = require "ebb.src.codegen_support"
local LE, legion_env, LW, run_config
if use_legion then
  LE = rawget(_G, '_legion_env')
  legion_env = LE.legion_env[0]
  LW = require 'ebb.src.legionwrap'
  run_config = rawget(_G, '_run_config')
end
local use_partitioning = use_legion and run_config.use_partitioning
local DataArray       = require('ebb.src.rawdata').DataArray

local R         = require 'ebb.src.relations'
local F         = require 'ebb.src.functions'
local UFunc     = F.Function
local UFVersion = F.UFVersion
local _INTERNAL_DEV_OUTPUT_PTX = F._INTERNAL_DEV_OUTPUT_PTX
local Phase     = require 'ebb.src.phase'
local PhaseType = Phase.PhaseType

local VERBOSE = rawget(_G, 'EBB_LOG_EBB')


local function shallowcopy_table(tbl)
  local x = {}
  for k,v in pairs(tbl) do x[k] = v end
  return x
end

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Terra Signature                                                       ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

local struct bounds_struct { lo : uint64, hi : uint64 }

--[[
args = {
  relation,     -- relation being executed over
  use_subset,   -- boolean
  name,         -- name for struct
  fields,       -- list of fields
  globals,      -- list of globals
  global_reductions,  -- list of globals to reduce
}
--]]
local function BuildTerraSignature(args)
  local arg_keyT        = keyT(args.relation):terratype()
  local n_dims          = #args.relation:Dims()

  local name = (args.name or '') .. '_terra_signature'
  local terrasig = terralib.types.newstruct(name)
  local _field_num,             f_count = {}, 0
  local _global_num,            g_count = {}, 0
  local _global_reduction_num,  r_count = {}, 0
  local field_names             = {}
  local global_names            = {}
  local global_reduction_names  = {}

  -- add counter
  terrasig.entries:insert{field='bounds', type=(bounds_struct[n_dims])}
  -- add subset data
  if args.use_subset then -- make sure it's available
    terrasig.entries:insert{field='index',      type=&arg_keyT}
    terrasig.entries:insert{field='index_size', type=uint64}
  end
  -- add fields
  for i,f in ipairs(args.fields) do
    _field_num[f] = i
    local name = 'field_'..i..'_'..string.gsub(f:FullName(),'%W','_')
    field_names[f] = name
    if use_single then
      terrasig.entries:insert{ field=name, type=&( f:Type():terratype() ) }
    elseif use_legion then
      local f_dims = #f:Relation():Dims()
      terrasig.entries:insert{ field=name, type=LW.FieldAccessor[f_dims] }
    end
  end
  -- add globals
  for i,g in ipairs(args.globals) do
    _global_num[g] = i
    local name = 'global_'..i..'_'..
                 string.gsub(tostring(g:Type()),'%W','_')
    global_names[g] = name
    terrasig.entries:insert{ field=name, type=&( g:Type():terratype() ) }
  end
  -- add global reductions (possibly secondary location)
  for i,gr in ipairs(args.global_reductions) do
    _global_reduction_num[gr] = i
    local name = 'reduce_global_'..i..'_'..
                 string.gsub(tostring(gr:Type()),'%W','_')
    global_reduction_names[gr] = name
    terrasig.entries:insert{ field=name, type=&( gr:Type():terratype() ) }
  end

  terrasig:complete()
  terrasig._field_num             = _field_num
  terrasig._global_num            = _global_num
  terrasig._global_reduction_num  = _global_reduction_num

  function terrasig.luaget(sig, fg)
    if        R.is_field(fg) then return sig[field_names[fg]]
    elseif Pre.is_global(fg) then return sig[global_names[fg]]
    else error('luaget() expects a field or global') end
  end
  function terrasig.luaget_reduction(sig, g)
    return sig[global_reduction_names[g]]
  end
  function terrasig.luaset(sig, fg, val)
    if        R.is_field(fg) then sig[field_names[fg]] = val
    elseif Pre.is_global(fg) then sig[global_names[fg]] = val
    else error('luaset() expects a field or global') end
  end
  function terrasig.luaset_reduction(sig, g, val)
    sig[global_reduction_names[g]] = val
  end
  function terrasig.terraptr(sig, fg)
    if        R.is_field(fg) then
      local name = field_names[fg]
      return `sig.[name]
    elseif Pre.is_global(fg) then
      local name = global_names[fg]
      return `sig.[name]
    else
      error('terraptr() expects a field or global')
    end
  end
  function terrasig.terraptr_reduction(sig, g)
    local name = global_reduction_names[g]
    return `sig.[name]
  end

  return terrasig
end



-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ UFVersion                                                             ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

function UFVersion:Execute()
  if not self:isCompiled() then
    self:Compile()
  end

  UFVersion._total_function_launch_count:increment()

  self._exec_timer:start()

  -- Next, we partition the primary relation and other relations that are
  -- referenced from UFunc.
  self:_PartitionData()

  -- Regardless of the caching, we need to make sure
  -- that the current state of the system and relevant data safely allows
  -- us to launch the UFunc.  This might include checks to make sure that
  -- all of the relevant data does in fact exist, and that any invariants
  -- we assumed when the UFunc was compiled and cached are still true.
  self:_DynamicChecks()

  -- Next, we bind all the necessary data into the version.
  -- This involves looking up appropriate pointers, argument values,
  -- data location, Legion or CUDA parameters, and packing
  -- appropriate structures
  self:_BindData()

  --local prelaunch = terralib.currenttimeinseconds()
  -- Then, once all the data is bound and marshalled, we
  -- can actually launch the computation.  Oddly enough, this
  -- may require some amount of further marshalling and binding
  -- of data depending on what runtime this version is being launched on.
  self:_Launch()
  --LAUNCH_TIMER = LAUNCH_TIMER + (terralib.currenttimeinseconds() - prelaunch)

  -- Finally, some features may require some post-processing after the
  -- launch of the UFunc.  This hook provides a place for
  -- any such computations.
  self:_PostLaunchCleanup()

  self._exec_timer:stop()
end

-- Define ways of inspecting high-level UFVersion state/modes
function UFVersion:isCompiled()
  return nil ~= self._executable
end
function UFVersion:UsesInsert()
  return nil ~= self._insert_data
end
function UFVersion:UsesDelete()
  return nil ~= self._delete_data
end
function UFVersion:UsesGlobalReduce()
  return next(self._global_reductions) ~= nil
end
function UFVersion:onGPU()
  return self._proc == GPU
end
function UFVersion:overElasticRelation()
  return self._is_elastic
end
function UFVersion:isOverSubset()
  return nil ~= self._subset
end
function UFVersion:isBoolMaskSubset()
  return nil ~= self._subset._boolmask
end
function UFVersion:isIndexSubset()
  return nil ~= self._subset._index
end

function UFVersion:_TESTING_GetFieldAccesses()
  return self._field_accesses -- these have the stencils in them
end


--                  ---------------------------------------                  --
--[[ UF Compilation                                                        ]]--
--                  ---------------------------------------                  --


function UFVersion:Compile()
  self._compile_timer:start()

  local typed_ast   = self._typed_ast
  local phase_data  = self._phase_data
  -- shallow copy so that we can add entries
  self._field_use   = shallowcopy_table(phase_data.field_use)
  self._global_use  = shallowcopy_table(phase_data.global_use)

  -- Build Signatures defining interface boundaries for
  -- constructing various kinds of task wrappers
  self:_CompileTerraSignature()
  if use_legion then self:_CompileLegionSignature() end

  -- handle GPU specific compilation
  if self:onGPU() and self:UsesGlobalReduce() then
    self._sharedmem_size = 0
    self:_CompileGPUReduction()
  end

  if use_single then
    -- allocate memory for the arguments struct on the CPU.  It will be used
    -- to hold the parameter values that will be passed to the Ebb function.
    self._args = DataArray.New{
      size = 1,
      type = self._terra_signature,
      processor = CPU, -- DON'T MOVE
    }
    
    -- compile an executable
    self._executable = codegen.codegen(typed_ast, self)

  elseif use_legion then
    self:_CompileLegionAndGetLauncher(typed_ast)
  else
    error("INTERNAL: IMPOSSIBLE BRANCH")
  end

  self._compile_timer:stop()
end

function UFVersion:_CompileTerraSignature()
  local fields, globals   = terralib.newlist(), terralib.newlist()
  local global_reductions = terralib.newlist()
  self._global_reductions = {}

  if self:overElasticRelation() then
    if use_legion then error("LEGION UNSUPPORTED ELASTIC") end
    local use_deletes = not not self._phase_data.deletes
    self._field_use[self._relation._is_live_mask] = PhaseType.New {
      centered  = true,
      read      = true,
      write     = use_deletes,
    }
  end
  if self:isOverSubset() and self._subset._boolmask then
    self._compiled_with_boolmask = true
    self._field_use[self._subset._boolmask] = PhaseType.New {
      centered  = true,
      read      = true,
    }
  end

  -- INSERTS
  if self._phase_data.inserts then
    -- max 1 insert allowed right now
    local insert_rel, ast_nodes = next(self._phase_data.inserts)
    self._insert_data = {
      relation    = insert_rel,
      record_type = ast_nodes[1].record_type,
      write_idx   = EbbGlobal(uint64T, 0),
    }
    -- also need to support reductions?
    self._global_use[self._insert_data.write_idx] = PhaseType.New {
      reduceop    = '+',
    }

    for _,f in ipairs(insert_rel._fields) do
      assert(self._field_use[f] == nil, 'trying to add duplicate field')
      fields:insert(f) -- might this be a duplicate?  No?
      self._field_use[f] = PhaseType.New {
        centered = false,
        write    = true,
      }
    end
    self._field_use[insert_rel._is_live_mask] = PhaseType.New {
      centered = false,
      write    = true,
    }
  end
  -- DELETES
  if self._phase_data.deletes then
    -- max 1 delete allowed right now
    local del_rel = next(self._phase_data.deletes)
    self._delete_data = {
      relation  = del_rel,
      n_deleted = EbbGlobal(uint64T, 0)
    }
    -- also need to support reductions?
    self._global_use[self._delete_data.n_deleted] = PhaseType.New {
      reduceop    = '+',
    }
  end


  for f, use in pairs(self._field_use) do  fields:insert(f) end
  for g, phase in pairs(self._global_use) do
    globals:insert(g)
    if phase.reduceop then
      global_reductions:insert(g)
      self._uses_global_reduce  = true

      self._global_reductions[g] = {
        phase = phase,
      }
    end
  end

  self._terra_signature = BuildTerraSignature{
    relation          = self._relation,
    use_subset        = self:isOverSubset(),
    name              = self._name,
    fields            = fields,
    globals           = globals,
    global_reductions = global_reductions,
  }
end

--                  ---------------------------------------                  --
--[[ UFVersion Interface for Codegen / Compilation                         ]]--
--                  ---------------------------------------                  --

function UFVersion:_argsType ()
  return self._terra_signature
end

function UFVersion:_getReduceData(global)
  local data = self._global_reductions[global]
  return assert(self._global_reductions[global],
                'reduction was not predeclared')
end

function UFVersion:_setFieldPtr(field)
  if use_legion then
    error('INTERNAL: Do not call setFieldPtr() when using Legion') end
  self._terra_signature.luaset(self._args:_raw_ptr(),
                               field,
                               field:_Raw_DataPtr())
end
function UFVersion:_setGlobalPtr(global)
  if use_legion then
    error('INTERNAL: Do not call setGlobalPtr() when using Legion') end
  self._terra_signature.luaset(self._args:_raw_ptr(),
                               global,
                               global:_Raw_DataPtr())
end

function UFVersion:_getLegionGlobalTempSymbol(global)
  local id = self:_getGlobalId(global)
  if not self._legion_global_temps then self._legion_global_temps = {} end
  local sym = self._legion_global_temps[id]
  if not sym then
    local ttype = global._type:terratype()
    sym = symbol(&ttype)
    self._legion_global_temps[id] = sym
  end
  return sym
end
function UFVersion:_getTerraField(args_sym, field)
  return self._terra_signature.terraptr(args_sym, field)
end
function UFVersion:_getTerraGlobalPtr(args_sym, global)
  return self._terra_signature.terraptr(args_sym, global)
end
function UFVersion:_getTerraGreductionPtr(args_sym, global)
  return self._terra_signature.terraptr_reduction(args_sym, global)
end


--                  ---------------------------------------                  --
--[[ UFVersion Dynamic Checks                                              ]]--
--                  ---------------------------------------                  --

function UFVersion:_DynamicChecks()
  if use_single then
    -- Check that the fields are resident on the correct processor
    local underscore_field_fail = nil
    for field, _ in pairs(self._field_use) do
      if field._array:location() ~= self._proc then
        if field:Name():sub(1,1) == '_' then
          underscore_field_fail = field
        else
          error("cannot execute function because field "..field:FullName()..
                " is not currently located on "..tostring(self._proc), 3)
        end
      end
    end
    if underscore_field_fail then
      error("cannot execute function because hidden field "..
            underscore_field_fail:FullName()..
            " is not currently located on "..tostring(self._proc), 3)
    end
  end

  if self:isOverSubset() then
    if self._compiled_with_boolmask and not self:isBoolMaskSubset() then
      error('INTERNAL: Should not try to run a function compiled for '..
            'boolmask subsets over an index subset')
    elseif not self._compiled_with_boolmask and not self:isIndexSubset() then
      error('INTERNAL: Should not try to run a function compiled for '..
            'index subsets over a boolmask subset')
    end
  end

  if self:UsesInsert()  then  self:_DynamicInsertChecks()  end
  if self:UsesDelete()  then  self:_DynamicDeleteChecks()  end
end


-------------------------------------------------------------------------------
--[[ Ufversion Data Partitioning                                           ]]--
-------------------------------------------------------------------------------

function UFVersion:_PartitionData()
  if not use_legion then return end
  self._legion_signature:PartitionRegReqs()
end


--                  ---------------------------------------                  --
--[[ UFVersion Data Binding                                                ]]--
--                  ---------------------------------------                  --

function UFVersion:_BindData()
  -- Bind inserts and deletions before anything else, because
  -- the binding may trigger computations to re-size/re-allocate
  -- data in some cases, invalidating previous data pointers
  if self:UsesInsert()  then  self:_bindInsertData()       end
  if self:UsesDelete()  then  self:_bindDeleteData()       end

  -- Bind the rest of the data
  self:_bindFieldGlobalSubsetArgs()
end

function UFVersion:_bindFieldGlobalSubsetArgs()
  -- Don't worry about binding on Legion, since we need
  -- to handle that a different way anyways
  if use_legion then return end

  local argptr    = self._args:_raw_ptr()

  -- Case 1: subset indirection index
  if self._subset and self._subset._index then
    argptr.index        = self._subset._index:_Raw_DataPtr()
    -- Spoof the number of entries in the index, which is what
    -- we actually want to iterate over
    argptr.bounds[0].lo = 0
    argptr.bounds[0].hi = self._subset._index:Size() - 1 

  -- Case 2: elastic relation
  elseif self:overElasticRelation() then
    argptr.bounds[0].lo = 0
    argptr.bounds[0].hi = self._relation:ConcreteSize() - 1

  -- Case 3: generic staticly sized relation
  else
    local dims = self._relation:Dims()
    for d=1,#dims do
      argptr.bounds[d-1].lo = 0
      argptr.bounds[d-1].hi = dims[d] - 1
    end

  end

  -- set field and global pointers
  for field, _ in pairs(self._field_use) do
    self:_setFieldPtr(field)
  end
  for globl, _ in pairs(self._global_use) do
    self:_setGlobalPtr(globl)
  end
end

--                  ---------------------------------------                  --
--[[ UFVersion Launch                                                      ]]--
--                  ---------------------------------------                  --

function UFVersion:_Launch()
  if VERBOSE then
    local data_deps = "Ebb LOG: function " .. self._ufunc._name .. " accesses"
    for field, use in pairs(self._field_use) do
      data_deps = data_deps .. " relation " .. field:Relation():Name()
      data_deps = data_deps .. " field " .. field:Name() .. " in phase "
      data_deps = data_deps .. tostring(use) .. " ,"
    end
    for global, use in pairs(self._global_use) do
      data_deps = data_deps .. " global " .. tostring(global) .. " in phase "
      data_deps = data_deps .. tostring(use) .. " ,"
    end
    print(data_deps)
  end
  if use_legion then
    self._executable({ ctx = legion_env.ctx, runtime = legion_env.runtime })
  else
    self._executable(self._args:_raw_ptr())
  end
end

--                  ---------------------------------------                  --
--[[ UFVersion Postprocess / Cleanup                                       ]]--
--                  ---------------------------------------                  --

function UFVersion:_PostLaunchCleanup()
  -- GPU Reduction finishing and cleanup
  --if self:onGPU() then
  --  if self:UsesGlobalReduce() then  self:postprocessGPUReduction()  end
  --end

  -- Handle post execution Insertion and Deletion Behaviors
  if self:UsesInsert()         then   self:_postprocessInsertions()    end
  if self:UsesDelete()         then   self:_postprocessDeletions()     end
end


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Insert / Delete Extensions                                            ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------


--                  ---------------------------------------                  --
--[[ Insert Processing ; all 4 stages (-launch)                            ]]--
--                  ---------------------------------------                  --

function UFVersion:_DynamicInsertChecks()
  if use_legion then error('INSERT unsupported on legion currently', 4) end

  local rel = self._insert_data.relation
  local unsafe_msg = rel:UnsafeToInsert(self._insert_data.record_type)
  if unsafe_msg then error(unsafe_msg, 4) end
end

function UFVersion:_bindInsertData()
  local insert_rel                    = self._insert_data.relation
  local center_size_logical           = self._relation:Size()
  local insert_size_concrete          = insert_rel:ConcreteSize()
  local insert_size_logical           = insert_rel:Size()
  --print('INSERT BIND',
  --  center_size_logical, insert_size_concrete, insert_size_logical)

  -- point the write index at the first entry after the end of the
  -- used portion of the data arrays
  self._insert_data.write_idx:set(insert_size_concrete)
  -- cache the old sizes
  self._insert_data.last_concrete_size = insert_size_concrete
  self._insert_data.last_logical_size  = insert_size_logical

  -- then make sure to reserve enough space to perform the insertion
  -- don't worry about updating logical size here
  insert_rel:_INTERNAL_Resize(insert_size_concrete + center_size_logical)
end

function UFVersion:_postprocessInsertions()
  local insert_rel        = self._insert_data.relation
  local old_concrete_size = self._insert_data.last_concrete_size
  local old_logical_size  = self._insert_data.last_logical_size

  local new_concrete_size = tonumber(self._insert_data.write_idx:get())
  local n_inserted        = new_concrete_size - old_concrete_size
  local new_logical_size  = old_logical_size + n_inserted
  --print("POST INSERT",
  --  old_concrete_size, old_logical_size, new_concrete_size,
  --  n_inserted, new_logical_size)

  -- shrink array back to fit how much we actually wrote
  insert_rel:_INTERNAL_Resize(new_concrete_size, new_logical_size)

  -- NOTE that this relation is now considered fragmented
  -- (change this?)
  insert_rel:_INTERNAL_MarkFragmented()
end

--                  ---------------------------------------                  --
--[[ Delete Processing ; all 4 stages (-launch)                            ]]--
--                  ---------------------------------------                  --

function UFVersion:_DynamicDeleteChecks()
  if use_legion then error('DELETE unsupported on legion currently', 4) end

  local unsafe_msg = self._delete_data.relation:UnsafeToDelete()
  if unsafe_msg then error(unsafe_msg, 4) end
end

function UFVersion:_bindDeleteData()
  local relsize = tonumber(self._delete_data.relation._logical_size)
  self._delete_data.n_deleted:set(0)
end

function UFVersion:_postprocessDeletions()
  -- WARNING UNSAFE CONVERSION FROM UINT64 TO DOUBLE
  local rel = self._delete_data.relation
  local n_deleted     = tonumber(self._delete_data.n_deleted:get())
  local updated_size  = rel:Size() - n_deleted
  local concrete_size = rel:ConcreteSize()
  rel:_INTERNAL_Resize(concrete_size, updated_size)
  rel:_INTERNAL_MarkFragmented()

  -- if we have too low an occupancy
  if updated_size < 0.5 * concrete_size then
    rel:Defrag()
  end
end


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ GPU Extensions     (Mainly Global Reductions)                         ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

-- The following are mainly support routines related to the GPU
-- A lot of them (identified in their names) are
-- strictly related to reductions, and may be used both
-- within the codegen compilation and the compilation of a secondary
-- CUDA Kernel (below)

function UFVersion:_numGPUBlocks(argptr)
  if self:overElasticRelation() then
    local size    = `argptr.bounds[0].hi - argptr.bounds[0].lo + 1
    local nblocks = `[uint64]( C.ceil( [double](size) /
                                       [double](self._blocksize) ))
    return nblocks
  else
    if self:isOverSubset() and self:isIndexSubset() then
      return math.ceil(self._subset._index:Size() / self._blocksize)
    else
      local size = `1
      for d = 1, #self._relation:Dims() do
          size = `((size) * (argptr.bounds[d-1].hi - argptr.bounds[d-1].lo + 1))
      end
      return `[uint64](C.ceil( [double](size) / [double](self._blocksize)))
    end
  end
end

function UFVersion:_nBytesSharedMem()
  return self._sharedmem_size or 0
end

function UFVersion:_getBlockSize()
  return self._blocksize
end

function UFVersion:_getTerraReduceGlobalMemPtr(args_sym, global)
  return self:_getTerraGreductionPtr(args_sym, global)
  --local data = self:_getReduceData(global)
  --return `[args_sym].[data.id]
end

function UFVersion:_getTerraReduceSharedMemPtr(global)
  local data = self:_getReduceData(global)

  if self._useTreeReduce then
    return data.sharedmem
  else
    return data.reduceobj:getSharedMemPtr()
  end
end

--                  ---------------------------------------                  --
--[[ GPU Reduction Compilation                                             ]]--
--                  ---------------------------------------                  --

function UFVersion:_CompileGPUReduction()
  self._useTreeReduce = true
  -- NOTE: because GPU memory is idiosyncratic, we need to handle
  --    GPU global memory and
  --    GPU shared memory differently.
  --  Specifically,
  --    * we handle the global memory in the same way we handle
  --      field and global data; by adding an entry into
  --      the argument structure, binding appropriate allocated data, etc.
  --    * we handle the shared memory via a mechanism that looks more
  --      like Terra globals.  As such, these "shared memory pointers"
  --      get inlined directly into the Terra code.  This is safe because
  --      the CUDA kernel launch, not the client CPU code, is responsible
  --      for allocating and deallocating shared memory on function launch/exit

  -- Find all the global variables in this function that are being reduced
  for globl, data in pairs(self._global_reductions) do
    local ttype             = globl._type:terratype()
    if self._useTreeReduce then
      data.sharedmem          = cudalib.sharedmemory(ttype, self._blocksize)
  
      self._sharedmem_size    = self._sharedmem_size +
                                  sizeof(ttype) * self._blocksize
    else
      local op      = data.phase.reduceop
      local lz_type = globl._type
      local reduceobj = G.ReductionObj.New {
        ttype             = ttype,
        blocksize         = self._blocksize,
        reduce_ident      = codesupport.reduction_identity(lz_type, op),
        reduce_binop      = function(lval, rhs)
          return codesupport.reduction_binop(lz_type, op, lval, rhs)
        end,
        gpu_reduce_atomic = function(lval, rhs)
          return codesupport.gpu_atomic_exp(op, lz_type, lval, rhs, lz_type)
        end,
      }
      data.reduceobj = reduceobj
      self._sharedmem_size = self._sharedmem_size + reduceobj:sharedMemSize()
    end
  end

  if self._useTreeReduce then
    self:_CompileGlobalMemReductionKernel()
  end
end

-- The following routine is also used inside the primary compile CUDA kernel
function UFVersion:_GenerateSharedMemInitialization(tid_sym)
  local code = quote end
  for globl, data in pairs(self._global_reductions) do
    local op        = data.phase.reduceop
    local lz_type   = globl._type
    local sharedmem = data.sharedmem

    if self._useTreeReduce then
      code = quote
        [code]
        [sharedmem][tid_sym] = [codesupport.reduction_identity(lz_type, op)]
      end
    else
      code = quote
        [code]
        [data.reduceobj:sharedMemInitCode(tid_sym)]
      end
    end
  end
  return code
end

-- The following routine is also used inside the primary compile CUDA kernel
function UFVersion:_GenerateSharedMemReduceTree(
  args_sym, tid_sym, bid_sym, is_final
)
  is_final = is_final or false
  local code = quote end
  for globl, data in pairs(self._global_reductions) do
    local op          = data.phase.reduceop
    local lz_type     = globl._type
    local sharedmem   = data.sharedmem
    local finalptr    = self:_getTerraGlobalPtr(args_sym, globl)
    local globalmem   = self:_getTerraReduceGlobalMemPtr(args_sym, globl)

    -- Insert an unrolled reduction tree here
    if self._useTreeReduce then
      local step = self._blocksize
      while step > 1 do
        step = step/2
        code = quote
          [code]
          if tid_sym < step then
            var exp = [codesupport.reduction_binop(
                        lz_type, op, `[sharedmem][tid_sym],
                                     `[sharedmem][tid_sym + step])]
            terralib.attrstore(&[sharedmem][tid_sym], exp, {isvolatile=true})
          end
          G.barrier()
        end
      end

      -- Finally, reduce into the actual global value
      code = quote
        [code]
        if [tid_sym] == 0 then
          if is_final then
            @[finalptr] = [codesupport.reduction_binop(lz_type, op,
                                                       `@[finalptr],
                                                       `[sharedmem][0])]
          else
            [globalmem][bid_sym] = [sharedmem][0]
          end
        end
      end
    else
      code = quote
        [code]
        [data.reduceobj:sharedMemReductionCode(tid_sym, finalptr)]
      end
    end
  end
  return code
end

-- The full secondary CUDA kernel to reduce the contents of the
-- global mem array.  See comment inside function for sketch of algorithm
function UFVersion:_CompileGlobalMemReductionKernel()
  local ufv       = self
  local fn_name   = ufv._ufunc._name .. '_globalmem_reduction'

  -- Let N be the number of rows in the original relation
  -- and B be the block size for both the primary and this (the secondary)
  --          cuda kernels
  -- Let M = CEIL(N/B) be the number of blocks launched in the primary
  --          cuda kernel
  -- Then note that there are M entries in the globalmem array that
  --  need to be reduced.  We assume that the primary cuda kernel filled
  --  in a correct value for each of these.
  -- The secondary kernel will launch exactly one block with B threads.
  --  First we'll reduce all of the M entries in the globalmem array in
  --  chunks of B values into a sharedmem buffer.  Then we'll do a local
  --  tree reduction on those B values.
  -- NOTE EDGE CASE: What if M < B?  Then we'll initialize the shared
  --  buffer to an identity value and fail to execute the loop iteration
  --  for the trailing B-M threads of the block.  (This is memory safe)
  --  We will get the correct values b/c reducing identities has no effect.
  local args      = symbol(ufv:_argsType())
  local array_len = symbol(uint64)
  local tid       = symbol(uint32)
  local bid       = symbol(uint32)

  local cuda_kernel =
  terra([array_len], [args])
    var [tid]    : uint32 = G.thread_id()
    var [bid]    : uint32 = G.block_id()
    var n_blocks : uint32 = G.num_blocks()
    var gt                = tid + [ufv._blocksize] * bid
    
    -- INITIALIZE the shared memory
    [ufv:_GenerateSharedMemInitialization(tid)]
    
    -- REDUCE the global memory into the provided shared memory
    -- count from (gt) till (array_len) by step sizes of (blocksize)
    for gi = gt, array_len, n_blocks * [ufv._blocksize] do
      escape for globl, data in pairs(ufv._global_reductions) do
        local op          = data.phase.reduceop
        local lz_type     = globl._type
        local sharedmem   = data.sharedmem
        local globalmem   = ufv:_getTerraReduceGlobalMemPtr(args, globl)

        emit quote
          [sharedmem][tid]  = [codesupport.reduction_binop(lz_type, op,
                                                           `[sharedmem][tid],
                                                           `[globalmem][gi])]
        end
      end end
    end

    G.barrier()
  
    -- REDUCE the shared memory using a tree
    [ufv:_GenerateSharedMemReduceTree(args, tid, bid, true)]
  end
  cuda_kernel:setname(fn_name)
  cuda_kernel = G.kernelwrap(cuda_kernel, _INTERNAL_DEV_OUTPUT_PTX)

  -- the globalmem array has an entry for every block in the primary kernel
  local terra launcher( argptr : &(ufv:_argsType()) )
    var globalmem_array_len = [ ufv:_numGPUBlocks(argptr) ]
    var launch_params = terralib.CUDAParams {
      1,1,1, [ufv._blocksize],1,1, [ufv._sharedmem_size], nil
    }
    cuda_kernel(&launch_params, globalmem_array_len, @argptr )
  end
  launcher:setname(fn_name..'_launcher')

  ufv._global_reduction_pass = launcher
end

--                  ---------------------------------------                  --
--[[ GPU Reduction Dynamic Checks                                          ]]--
--                  ---------------------------------------                  --

function UFVersion:_DynamicGPUReductionChecks()
  if self._proc ~= GPU then
    error("INTERNAL ERROR: Should only try to run GPUReduction on the GPU...")
  end
end


--                  ---------------------------------------                  --
--[[ GPU Reduction Data Binding                                            ]]--
--                  ---------------------------------------                  --

function UFVersion:_generateGPUReductionPreProcess(argptrsym)
  if not self._useTreeReduce then return quote end end
  if not self:UsesGlobalReduce() then return quote end end

  -- allocate GPU global memory for the reduction
  local n_blocks = symbol()
  local code = quote
    var [n_blocks] = [self:_numGPUBlocks(argptrsym)]
  end
  for globl, _ in pairs(self._global_reductions) do
    local ttype     = globl._type:terratype()
    local reduceptr = self:_getTerraGreductionPtr(argptrsym, globl)
    code = quote code
      [reduceptr] = [&ttype](G.malloc(sizeof(ttype) * n_blocks))
    end
  end
  return code
end


--                  ---------------------------------------                  --
--[[ GPU Reduction Postprocessing                                          ]]--
--                  ---------------------------------------                  --

function UFVersion:_generateGPUReductionPostProcess(argptrsym)
  if not self._useTreeReduce then return quote end end
  if not self:UsesGlobalReduce() then return quote end end
  
  -- perform inter-block reduction step (secondary kernel launch)
  local second_pass = self._global_reduction_pass
  local code = quote
    second_pass(argptrsym)
  end

  -- free GPU global memory allocated for the reduction
  for globl, _ in pairs(self._global_reductions) do
    local reduceptr = self:_getTerraGreductionPtr(argptrsym, globl)
    code = quote code
      G.free( [reduceptr] )
      [reduceptr] = nil -- just to be safe
    end
  end
  return code
end



-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Legion Signature                                                      ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

local function phase_to_legion_privilege(phase)
  assert(not phase:iserror(), 'INTERNAL: phase should not be in error')
  if phase:isReadOnly() then      return LW.READ_ONLY
  elseif phase:isCentered() then  return LW.READ_WRITE
  else                            return LW.REDUCE        end
end
local get_regreq_helper = Util.memoize_named({
  'build_data', 'relation', 'centered', 'privilege', 'reducefield',
  -- hidden phase
},
function(args)
  local reduceop  = args.phase:reductionOp()
  local fieldtype = R.is_field(args.reducefield) and args.reducefield:Type()
                                                  or nil
  local regreq = LW.NewRegionReq {
    num             = args.build_data.n_reg_req,
    relation        = args.relation,
    privilege       = args.privilege,
    coherence       = LW.EXCLUSIVE,
    reduce_op       = reduceop,
    reduce_typ      = fieldtype,       
    centered        = args.centered,
  }
  args.build_data.reg_req_list[regreq.num] = regreq
  args.build_data.n_reg_req = args.build_data.n_reg_req + 1
  return regreq
end)
local function get_regreq(build_data, field, phase)
  local privilege = phase_to_legion_privilege(phase)
  local regreq = get_regreq_helper {
    build_data      = build_data,
    relation        = field:Relation(),
    privilege       = privilege,
    reducefield     = privilege == LW.REDUCE and field,
    centered        = phase:isCentered(),
    phase           = phase,
  }
  return regreq
end
local function get_primary_regreq(build_data, relation)
  -- NOTE: Legion might be assuming right now that NO_ACCESS regions are
  -- added before other region requirements
  assert(build_data.n_reg_req == 0,
         'primary region requirement must be added first')
  build_data.n_reg_req = 1
  local regreq = LW.NewRegionReq {
    num             = 0,
    relation        = relation,
    privilege       = LW.NO_ACCESS,
    coherence       = LW.EXCLUSIVE,      
    centered        = true,
  }
  build_data.reg_req_list[0] = regreq
  return regreq
end
--[[
{
  field_use
  global_use
  relation
}
--]]
-- ONE OF THE PRIMARY RESPONSIBILITIES of the legion signature is to
-- manage the ordering of region requirements and futures in the
-- legion task launch
local function BuildLegionSignature(params)
  if use_single then error('INTERNAL: Should only call '..
    'BuildLegionSignature() when running on Legion runtime') end

  local future_seq_i      = {}  -- future -> seq_num
  local seq_globals       = {}  -- seq_num -> future
  local n_futures         = 0

  -- used as context and unique key for memoization
  local build_data        = {
    reg_req_list    = {}, -- in order by regreq_seq_i
    n_reg_req       = 0,
  }
  local field_reqs  = {} -- field -> reg_req
  local seq_fields  = {} -- regreq_seq_i -> field

  -- add primary data-less region requirement
  local prim_relation = params.relation
  local prim_reg_req  = get_primary_regreq(build_data, prim_relation)
  -- add field-driven region requirements
  for field, phase in pairs(params.field_use) do
    local reg_req             = get_regreq(build_data, field, phase)
    field_reqs[field]         = reg_req
    seq_fields[reg_req.num]   = field
  end

  -- determine order of future arguments
  for globl, _ in pairs(params.global_use) do
    future_seq_i[globl]     = n_futures
    seq_globals[n_futures]  = globl
    n_futures               = n_futures + 1
  end

  local LegionSignature = {}
  function LegionSignature:getRegSeqId(field)
    return field_reqs[field].num
  end
  function LegionSignature:getPrimaryRegionSeqId(field)
    return prim_reg_req.num
  end
  function LegionSignature:getRegionRelation(regreq_seq_i)
    if regreq_seq_i == 0 then return prim_relation end

    local field = seq_fields[regreq_seq_i]
    return field:Relation()
  end
  function LegionSignature:AddRegReqsToTaskLauncher(task_launcher)
    for i, req in self:RegionRequirementIterator() do
      local out_id = task_launcher:AddRegionReq(req)
      assert(i == out_id)
    end
  end
  function LegionSignature:PartitionRegReqs()
    for i, req in self:RegionRequirementIterator() do
      -- TODO: make default case single partition
      req:PartitionData(use_partitioning)
    end
  end
  function LegionSignature:getPrimaryRegionPartition()
    return prim_reg_req.partition
  end
  -- I DON'T LIKE THIS ITERATOR ONE BIT...
  function LegionSignature:RegionRequirementIterator()
    local i=0
    return function()
      local req = build_data.reg_req_list[i]
      i=i+1
      if not req then return nil
                 else return i-1,req end
    end
  end
  function LegionSignature:GetFutureSeqId(globl)
    return future_seq_i[globl]
  end
  function LegionSignature:GlobalFutureIterator()
    local i=0
    return function()
      local glob = seq_globals[i]
      i=i+1
      if not glob then return nil
                  else return i-1,glob end
    end
  end

  return LegionSignature
end

function UFVersion:_CompileLegionSignature()
  self._legion_signature = BuildLegionSignature {
    field_use   = self._field_use,
    global_use  = self._global_use,
    relation    = self._relation
  }
end


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Legion Extensions                                                     ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

function UFVersion:_CompileLegionAndGetLauncher(typed_ast)
  local task_function     = codegen.codegen(typed_ast, self)
  self._executable        = self:_CreateLegionLauncher(task_function)
end

function UFVersion:_WrapLegionTask(argsym, basic_launcher)
  local ufv = self

  -- generate the end-of-launch code
  local return_future_code    = quote end
  local global_red_ptr        = nil
  if ufv:UsesGlobalReduce() then
    local globl = next(ufv._global_reductions)
    local gtyp  = globl:Type():terratype()
    global_red_ptr = symbol(&gtyp, 'global_red_ptr')

    if next(ufv._global_reductions, globl) then
      error("INTERNAL: More than 1 global reduction at a time unsupported")
    end
    if ufv:onGPU() then
      return_future_code = quote
        var datum : gtyp
        G.memcpy_cpu_from_gpu(&datum, global_red_ptr, sizeof(gtyp))
        G.free(global_red_ptr)
        return LW.legion_task_result_create( &datum, sizeof(gtyp) )
      end
    else
      return_future_code = quote
        return LW.legion_task_result_create( global_red_ptr, sizeof(gtyp) )
      end
    end
  end

  -- execute the basic launcher multiple times if given a weird
  -- iteration construct induced by legion
  local function index_iterator_wrap(argsym, task_args)
    local pnum = ufv._legion_signature:getPrimaryRegionSeqId()
    return quote
      var lg_index_space = LW.legion_physical_region_get_logical_region(
          task_args.regions[pnum]
        ).index_space
      var lg_it = LW.legion_index_iterator_create(
          task_args.lg_runtime,
          task_args.lg_ctx,
          lg_index_space
        )
      while LW.legion_index_iterator_has_next(lg_it) do
        var count : C.size_t = 0
        var base =
            LW.legion_index_iterator_next_span(lg_it, &count, -1).value
        argsym.bounds[0].lo = base
        argsym.bounds[0].hi = base + count - 1

        basic_launcher(&argsym)
      end
    end
  end

  -- generate the launcher wrapper
  local argtyp = ufv:_argsType()
  local launcher = terra( task_args : LW.TaskArgs )
    var argsym : argtyp
    -- Unpack from task args into argsym
    [ ufv:_GenerateUnpackLegionTaskArgs(argsym, task_args, global_red_ptr) ]

    -- Weird wrapper if given a fragmented view of non-grid partition
    escape if not ufv._relation:isGrid() and run_config.use_partitioning then
      emit(index_iterator_wrap(argsym, task_args))
    else
      emit quote basic_launcher(&argsym) end
    end end -- end of escape

    -- destroy field accessors
    [ ufv:_CleanLegionTask(argsym) ]

    -- possibly return a future object if a global was reduced
    [ return_future_code ]
  end
  launcher:setname(ufv._name)

  return launcher
end

-- Here we translate the Legion task arguments into our
-- custom argument layout structure.  This allows us to write
-- the body of generated code in a way that's agnostic to whether
-- the code is being executed in a Legion task or not.
function UFVersion:_GenerateUnpackLegionTaskArgs(argsym, task_args, gredptr)
  local ufv = self

  -- temporary collection of symbols from unpacking the regions
  local region_temporaries = {}
  local first = symbol(bool)

  -- UNPACK REGIONS
  local unpack_regions_code = terralib.newlist()
  for ri,req in ufv._legion_signature:RegionRequirementIterator() do
    local relation      = ufv._legion_signature:getRegionRelation(ri)
    local n_reldim      = #relation:Dims()
    local physical_reg  = symbol(LW.legion_physical_region_t, 'phys_reg')
    local rect, rectFromDom
    if relation:isGrid() then
      rect          = symbol(LW.LegionRect[n_reldim])
      rectFromDom   = LW.LegionRectFromDom[n_reldim]
    end

    region_temporaries[ri] = {
      physical_reg  = physical_reg,
      rect          = rect,     -- nil for unstructured
    }

    unpack_regions_code:insert quote
      var [physical_reg]  = [task_args].regions[ri]
    end

    -- structured case
    if relation:isGrid() then unpack_regions_code:insert quote
      var index_space = LW.legion_physical_region_get_logical_region(
                                                    physical_reg).index_space
      var domain = LW.legion_index_space_get_domain([task_args].lg_runtime,
                                                    [task_args].lg_ctx,
                                                    index_space)
      var [rect] = [LW.LegionRectFromDom[n_reldim]]([domain])
    end end
  end

  -- UNPACK FIELDS
  local unpack_fields_code = terralib.newlist()
  for field, phase in pairs(ufv._field_use) do
    local rnum          = ufv._legion_signature:getRegSeqId(field)
    local rtemp         = region_temporaries[rnum]
    local physical_reg  = rtemp.physical_reg
    local relation      = field:Relation()
    local n_reldim      = #relation:Dims()
    local rect          = rtemp.rect

    local f_access = symbol(LW.legion_accessor_generic_t, 'field_accessor')
    if phase:isUncenteredReduction() then
      unpack_fields_code:insert(quote var [f_access] =
        LW.legion_physical_region_get_accessor_generic(physical_reg)
    end) else
      unpack_fields_code:insert(quote var [f_access] =
        LW.legion_physical_region_get_field_accessor_generic(physical_reg,
                                                             field._fid)
    end) end
    -- structured
    if relation:isGrid() then unpack_fields_code:insert(quote
      var subrect : LW.LegionRect[n_reldim]
      var strides : LW.legion_byte_offset_t[n_reldim]
      var base = [&uint8]([ LW.LegionRawPtrFromAcc[n_reldim] ](
                            f_access, rect, &subrect, strides))
      for d = 0, n_reldim do
        base = base - [rect].lo.x[d] * strides[d].offset
      end
      [ ufv._terra_signature.terraptr(argsym, field) ] =
        [ LW.FieldAccessor[n_reldim] ] { base, strides, f_access }
    end)
    -- unstructured
    else unpack_fields_code:insert(quote
      var stride_val : C.size_t = 0
      var strides : LW.legion_byte_offset_t[1]
      var base : &uint8 = nil
      C.assert(LW.legion_accessor_generic_get_soa_parameters(
        f_access, [&&opaque](&base), &stride_val ))
      strides[0].offset = stride_val
      [ ufv._terra_signature.terraptr(argsym, field) ] =
        [ LW.FieldAccessor[1] ] { base, strides, f_access }
    end) end  -- quote, if-else
  end  -- for


  assert(not ufv._relation:isElastic(),
         'LEGION TODO: have to change launch bound-unpack for '..
         'elastic relations')
  local code = quote
    do -- close after unpacking the fields
      [unpack_regions_code]
      [unpack_fields_code]
      
      -- UNPACK PRIMARY REGION BOUNDS RECTANGLE FOR STRUCTURED
      -- FOR UNSTRUCTURED, CORRECT INITIALIZATION IS POSTPONED TO LATER
      -- FOR UNSRRUCTURED, BOUNDS INITIALIZED TO TOTAL ROWS HERE
      escape
        local relation  = ufv._relation
        local ri        = ufv._legion_signature:getPrimaryRegionSeqId()
        local rect      = region_temporaries[ri].rect
        -- need to fix the following method of getting size when assert fails
        local rel_size  = relation:Size()
        -- structured
        if relation:isGrid() then
          local ndims = #relation:Dims()
          for i=1,ndims do emit quote
            [argsym].bounds[i-1].lo = rect.lo.x[i-1]
            [argsym].bounds[i-1].hi = rect.hi.x[i-1]
          end end
        -- unstructured
        else emit quote
          -- initialize to total relation rows here, which would work without
          -- partitions
          [argsym].bounds[0].lo = 0
          [argsym].bounds[0].hi = [rel_size-1]
        end end
      end
    end -- closing do started before unpacking the regions

    -- UNPACK FUTURES
    -- DO NOT WRAP THIS IN A LOCAL SCOPE or IN A DO BLOCK (SEE BELOW)
    -- ALSO DETERMINE IF THIS IS THE FIRST PARTITION
    escape
      for globl, _ in pairs(ufv._global_use) do
        local isreduce  = ufv._global_reductions[globl]
        -- position in the Legion task arguments
        local fut_i     = ufv._legion_signature:GetFutureSeqId(globl)
        local gtyp      = globl:Type():terratype()
        local gptr      = symbol(&gtyp, 'global_var_ptr')
        if isreduce then gptr = gredptr end
        emit quote var [gptr] end

        -- code to initialize the global pointer
        local init_gptr_code = quote
          -- process the future into a piece of data
          var fut     = LW.legion_task_get_future([task_args].task, fut_i)
          var result  = LW.legion_future_get_result(fut)
          var datum   = @[&gtyp](result.value)
          LW.legion_task_result_destroy(result)

          -- now set up the pointer to the global data
          escape emit( ufv:onGPU() and quote
            [gptr] = [&gtyp](G.malloc(sizeof(gtyp)))
            G.memcpy_gpu_from_cpu(gptr, &datum, sizeof(gtyp))
          end or quote -- onCPU
            [gptr] = &datum
          end ) end
        end

        -- SIMPLE NON-REDUCTION CASE
        emit(init_gptr_code)
        -- NOTE: THE FOLLOWING CODE IS BROKEN
        --[[
        if not isreduce then emit(init_gptr_code)
        -- REDUCTION CASE
        else emit quote
          var first = true
          do
            var task_point = LW.legion_task_get_index_point(task_args.task)
            for i = 0, task_point.dim do
              first = first and (task_point.point_data[i] == 0)
            end
          end

          if not first then escape
            local reduceid = codesupport.reduction_identity(
              globl:Type(), ufv._global_reductions[globl].phase.reduceop
            )

            -- alternate way of intializing gptr
            if ufv:onGPU() then emit quote
              var temp = [reduceid]
              [gptr] = [&gtyp](G.malloc(sizeof(gtyp)))
              G.memcpy_gpu_from_cpu(gptr, &temp, sizeof(gtyp))
            end else emit quote
              var temp = [reduceid]
              [gptr] = &temp
            end end
          end else
            [init_gptr_code]
          end
        end end
        --]]

        emit quote
          [ ufv._terra_signature.terraptr(argsym, globl) ] = gptr
        end
      end  -- for loop for globals
    end  -- escape
  end -- end quote

  return code
end

function UFVersion:_CleanLegionTask(argsym)
  local stmts = terralib.newlist()
  for field, _ in pairs(self._field_use) do
  --for field, farg_name in pairs(ufv._field_ids) do
    stmts:insert(quote LW.legion_accessor_generic_destroy(
      [ self._terra_signature.terraptr(argsym, field) ].handle
    ) end)
  end  -- escape
  return stmts
end


--                  ---------------------------------------                  --
--[[ Legion Dynamic Checks                                                 ]]--
--                  ---------------------------------------                  --

function UFVersion:_DynamicLegionChecks()
end


--                  ---------------------------------------                  --
--[[ Legion Data Binding                                                   ]]--
--                  ---------------------------------------                  --


function UFVersion:_bindLegionData()
  -- meh
end


--                  ---------------------------------------                  --
--[[ Legion Launching/ Compiling                                           ]]--
--                  ---------------------------------------                  --

local function pairs_val_sorted(tbl)
  local list = {}
  for k,v in pairs(tbl) do table.insert(list, {k,v}) end
  table.sort(list, function(p1,p2)
    return p1[2] < p2[2]
  end)

  local i = 0
  return function() -- iterator
    i = i+1
    if list[i] == nil then return nil
                      else return list[i][1], list[i][2] end
  end
end

-- Creates a task launcher with task region requirements.
function UFVersion:_CreateLegionTaskLauncher(task_func)
  local prim_partn = self._legion_signature:getPrimaryRegionPartition()

  local task_launcher = LW.NewTaskLauncher {
    taskfunc          = task_func,
    gpu               = self:onGPU(),
    use_index_launch  = use_partitioning, -- TODO: make default case single partition
    domain            = use_partitioning and prim_partn:Domain()
  }

  -- ADD EACH REGION to the launcher as a requirement
  -- WITH THE appropriate permissions set
  -- NOTE: Need to make sure to do this in the right order
  self._legion_signature:AddRegReqsToTaskLauncher(task_launcher)

  -- ADD EACH FIELD to the launcher as a requirement
  -- as part of the correct, corresponding region
  for field, _ in pairs(self._field_use) do
    task_launcher:AddField( self._legion_signature:getRegSeqId(field),
                            field._fid )
  end

  -- ADD EACH GLOBAL to the launcher as a future being passed to the task
  -- NOTE: Need to make sure to do this in the right order
  for gi, globl in self._legion_signature:GlobalFutureIterator() do
    task_launcher:AddFuture( globl._data )
  end

  -- ADD Global reduction data to the launcher
  local reduced_global = next(self._global_reductions)
  if reduced_global then
    local op  = self:_getReduceData(reduced_global).phase:reductionOp()
    local typ = reduced_global:Type()
    task_launcher:AddFutureReduction(op, typ)
  end

  return task_launcher
end

-- Launches Legion task and returns.
function UFVersion:_CreateLegionLauncher(task_func)
  local ufv = self

  -- NOTE: Instead of creating Legion task launcher every time
  -- within the returned function, why not create it once and then reuse the
  -- task launcher?
  if ufv:UsesGlobalReduce() then
    return function(leg_args)
      local task_launcher   = ufv:_CreateLegionTaskLauncher(task_func)
      local future = task_launcher:Execute(leg_args.runtime, leg_args.ctx)

      local reduced_global  = next(ufv._global_reductions)
      if reduced_global._data then
        LW.legion_future_destroy(reduced_global._data)
      end
      reduced_global._data = future

      task_launcher:Destroy()
    end
  else
    return function(leg_args)
      local task_launcher = ufv:_CreateLegionTaskLauncher(task_func)
      task_launcher:Execute(leg_args.runtime, leg_args.ctx)
      task_launcher:Destroy()
    end
  end
end

--                  ---------------------------------------                  --
--[[ Legion Postprocessing                                                 ]]--
--                  ---------------------------------------                  --

function UFVersion:_postprocessLegion()
  -- meh for now
end

