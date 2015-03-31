local Codegen = {}
package.loaded["compiler.codegen_single"] = Codegen

local use_legion = not not rawget(_G, '_legion_env')
local use_single = not use_legion

local ast = require "compiler.ast"
local T   = require "compiler.types"

local C   = require 'compiler.c'
local L   = require 'compiler.lisztlib'
local G   = require 'compiler.gpu_util'
local Support = require 'compiler.codegen_support'

local LW
if use_legion then
  LW = require "compiler.legionwrap"
end

L._INTERNAL_DEV_OUTPUT_PTX = false



--[[--------------------------------------------------------------------]]--
--[[                 Context Object for Compiler Pass                   ]]--
--[[--------------------------------------------------------------------]]--

local Context = {}
Context.__index = Context

function Context.New(env, bran)
    local ctxt = setmetatable({
        env  = env,
        bran = bran,
    }, Context)
    return ctxt
end

function Context:localenv()
  return self.env:localenv()
end
function Context:enterblock()
  self.env:enterblock()
end
function Context:leaveblock()
  self.env:leaveblock()
end

-- -- -- -- -- -- -- -- -- -- -- -- -- --
-- Info about the relation mapped over

function Context:dims()
  if not self._dims_val then self._dims_val = self.bran.relation:Dims() end
  return self._dims_val
end

function Context:argKeyTerraType()
  return L.key(self.bran.relation):terraType()
end

-- This one is the odd one out, generates some code
function Context:isLiveCheck(param_var)
  assert(self:isOverElastic())
  local ptr = self:FieldPtr(self.bran.relation._is_live_mask)
  -- Assuming 1D address is ok, b/c elastic relations must be 1D
  return `ptr[param_var.a[0]]
end

-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
-- Argument Struct related context functions

function Context:argsType()
  return self.bran:argsType()
end

function Context:argsym()
  if not self.arg_symbol then
    self.arg_symbol = symbol(self:argsType())
  end
  return self.arg_symbol
end

-- -- -- -- -- -- -- -- -- -- -- --
-- Modal Data

function Context:onGPU()
  return self.bran:isOnGPU()
end
function Context:hasGPUReduce()
  return self.bran:UsesGPUReduce()
end
function Context:isOverElastic() -- meaning the relation mapped over
  return self.bran:overElasticRelation()
end
function Context:isOverSubset() -- meaning a subset of the relation mapped over
  return self.bran:isOverSubset()
end

-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
-- Generic Field / Global context functions

function Context:hasExclusivePhase(field)
  return self.bran.kernel.field_use[field]:isCentered()
end

function Context:FieldPtr(field)
  return self.bran:getTerraFieldPtr(self:argsym(), field)
end

function Context:GlobalPtr(global)
  return self.bran:getTerraGlobalPtr(self:argsym(), global)
end

-- -- -- -- -- -- -- -- -- -- -- --
-- GPU related context functions

function Context:gpuBlockSize()
  return self.bran:getBlockSize()
end
function Context:gpuSharedMemBytes()
  return self.bran:nBytesSharedMem()
end

function Context:tid()
  if not self._tid then self._tid = symbol(uint32) end
  return self._tid
end

function Context:bid()
  if not self._bid then self._bid = symbol(uint32) end
  return self._bid
end

-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
-- GPU reduction related context functions

function Context:gpuReduceSharedMemPtr(globl)
  local tid = self:tid()
  local shared_ptr = self.bran:getTerraReduceSharedMemPtr(globl)
  return `[shared_ptr][tid]
end

-- Two odd functions to ask the bran to generate a bit of code
-- TODO: Should we refactor the actual codegen functions in the Bran
-- into a "codegen support" file, also containing the arithmetic
-- expression dispatching.
--    RULE FOR REFACTOR: take all codegen that does not depend on
--      The AST structure, and factor that into one file apart
--      from this AST driven codegeneration file
function Context:codegenSharedMemInit()
  return self.bran:GenerateSharedMemInitialization(self:tid())
end
function Context:codegenSharedMemTreeReduction()
  return self.bran:GenerateSharedMemReduceTree(self:argsym(),
                                               self:tid(),
                                               self:bid())
end

-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
-- Insertion / Deletion related context functions

function Context:deleteSizeVar()
  local dd = self.bran.delete_data
  if dd then
    return `@[self:GlobalPtr(dd.updated_size)]
  end
end

function Context:getInsertIndex()
  return `[self:argsym()].insert_write
end

function Context:incrementInsertIndex()
  local insert_index = self:getInsertIndex()
  local counter = self:GlobalPtr(self.bran.insert_data.n_inserted)

  return quote
    insert_index = insert_index + 1
    @counter = @counter + 1
  end
end





--[[--------------------------------------------------------------------]]--
--[[                          LEGION CODE DUMP                          ]]--
--[[--------------------------------------------------------------------]]--

local LegionRect = {}
local LegionGetRectFromDom = {}
local LegionRawPtrFromAcc = {}

local legion_codegen
local IndexToOffset

if use_legion then

LegionRect[1] = LW.legion_rect_1d_t
LegionRect[2] = LW.legion_rect_2d_t
LegionRect[3] = LW.legion_rect_3d_t

LegionGetRectFromDom[1] = LW.legion_domain_get_rect_1d
LegionGetRectFromDom[2] = LW.legion_domain_get_rect_2d
LegionGetRectFromDom[3] = LW.legion_domain_get_rect_3d

LegionRawPtrFromAcc[1] = LW.legion_accessor_generic_raw_rect_ptr_1d
LegionRawPtrFromAcc[2] = LW.legion_accessor_generic_raw_rect_ptr_2d
LegionRawPtrFromAcc[3] = LW.legion_accessor_generic_raw_rect_ptr_3d











function Context:Regions()
  return self.bran.arg_layout:Regions()
end

function Context:Fields(reg)
  return reg:Fields()
end

function Context:Globals()
  return self.bran.arg_layout:Globals()
end

function Context:GlobalToReduce()
  return self.bran.arg_layout:GlobalToReduce()
end





function Context:FieldPtr(field)
  --return self.bran:getTerraFieldPtr(self:argsym(), field)
end

function Context:GlobalPtr(global)
  --return self.bran:getTerraGlobalPtr(self:argsym(), global)
end



function Context:FieldData(field)
  local fidx   = self.bran.arg_layout:FieldIdx(field)
  local rdim   = field:Relation():nDims()
  local fd     = self:localenv()['_field_ptrs_'..tostring(rdim)]
  assert(terralib.issymbol(fd))
  return `([fd][ fidx - 1 ])
end

function Context:GlobalData(global)
  local gidx   = self.bran.arg_layout:GlobalIdx(global)
  local gd     = self:localenv()['_global_ptrs']
  assert(terralib.issymbol(gd))
  return `([&global.type:terraType()](([gd][ gidx - 1 ]).value))
end

function Context:RegIdx(reg)
  return self.bran.arg_layout:RegIdx(reg)
end

function Context:FieldIdx(field, reg)
  return self.bran.arg_layout:FieldIdx(field, reg)
end

--function Context:GlobalIdx(global)
--  return self.bran.arg_layout:GlobalIdx(global)
--end






-- Creates a task launcher with task region requirements.
-- Implementation details:
-- * Creates a separate region requirement for every region in arg_layout. 
-- * Adds futures corresponding to globals to launcher.
-- * NOTE: This is not combined with SetUpArgLayout because of a needed codegen
--   phase in between : codegen can happen only after SetUpArgLayout, and the
--   launcher can be created only after executable from codegen is available.
function legion_CreateTaskLauncher(ctxt, arg_layout)

  -- NOTE USED TO BE A BRAN MEMBER FUNCTION


  local legion_task_type
  if arg_layout.global_red then legion_task_type = LW.TaskTypes.future
                           else legion_task_type = LW.TaskTypes.simple end

  local args = self.kernel_launcher:PackToTaskArg()

  local task_launcher
  -- Simple task that does not return any values
  if legion_task_type == LW.TaskTypes.simple then
    task_launcher = LW.legion_task_launcher_create(
                       LW.TID_SIMPLE, args,
                       LW.legion_predicate_true(), 0, 0)
  -- Tasks with futures, for handling global reductions
  else
    task_launcher = LW.legion_task_launcher_create(
                       LW.TID_FUTURE, args,
                       LW.legion_predicate_true(), 0, 0)
  end

  local arg_layout = self.arg_layout

  -- region requirements
  local regions = arg_layout:Regions()
  for _, region in ipairs(regions) do
    local r = arg_layout:RegIdx(region)
    local rel = region:Relation()
    -- Just use READ_WRITE and EXCLUSIVE for now.
    -- Will need to update this when doing partitions.
    local reg_req =
      LW.legion_task_launcher_add_region_requirement_logical_region(
        task_launcher, rel._logical_region_wrapper.handle,
        LW.READ_WRITE, LW.EXCLUSIVE,
        rel._logical_region_wrapper.handle, 0, false )
    -- add all fields that should belong to this region req (computed in
    -- SetupArgLayout)
    for _, field in ipairs(region:Fields()) do
      local rel = field:Relation()
      LW.legion_task_launcher_add_field(
        task_launcher, reg_req, field.fid, true )
    end
  end

  -- futures
  local globals = arg_layout:Globals()
  for _, global in ipairs(globals) do
    LW.legion_task_launcher_add_future(task_launcher, global.data)
  end

  --self.task_launcher = task_launcher
  return task_launcher
end

-- Launches Legion task and returns.
function legion_CreateLauncher(ctxt, arg_layout)
  local task_launcher = legion_CreateTaskLauncher(ctxt, arg_layout)

  local legion_task_type
  if arg_layout.global_red then legion_task_type = LW.TaskTypes.future
                           else legion_task_type = LW.TaskTypes.simple end

  return function(leg_args)
    if legion_task_type == LW.TaskTypes.simple then
      LW.legion_task_launcher_execute(leg_args.runtime, leg_args.ctx,
                                      task_launcher)
    else
      local global = arg_layout:GlobalToReduce()
      local future = LW.legion_task_launcher_execute(leg_args.runtime,
                                                     leg_args.ctx,
                                                     task_launcher)
      local res = LW.legion_future_get_result(future)
      -- Wait till value is available. We can remove this once apply and
      -- fold operations are implemented using legion API, and we figure out
      -- how to safely delete old future : Is it safe to call DestroyFuture
      -- immediately after launching the tasks that use the future?
      -- TODO: We must apply this return value to old value - necessary for
      -- multiple partitions. Work around right now applies reduction in the
      -- task (Liszt kernel) itself, so we can simply replace the old future.
      global.data = LW.legion_future_from_buffer(leg_args.runtime,
                                                 res.value, res.value_size)
      LW.legion_task_result_destroy(res)
    end
  end
end








function IndexToOffset(ctxt, index, strides)
  local ndims = #ctxt:dims()
  if ndims == 1 then
    return `([index].a[0] * [strides][0].offset)
  elseif ndims == 2 then
    return  `(
      [index].a[0] * [strides][0].offset +
      [index].a[1] * [strides][1].offset
    )
  else
    return `(
      [index].a[0] * [strides][0].offset +
      [index].a[1] * [strides][1].offset +
      [index].a[2] * [strides][2].offset
    )
  end
end


-- NOTE: the entries in dims may be symbols,
--       allowing the loop bounds to be dynamically driven
local function terraIterNd(dims, func)
  local atyp = L.addr_terra_types[#dims]
  local addr = symbol(atyp)
  local iters = {}
  for d=1,#dims do iters[d] = symbol(uint64) end
  local loop = quote
    var [addr] = [atyp]({ a = array( iters ) })
    [func(addr)]
  end
  for drev=1,#dims do
    local d = #dims-drev + 1 -- flip loop order of dimensions
    loop = quote for [iters[d]] = [dims[d].lo], [dims[d].hi] do [loop] end end
  end
  return loop
end


-- Here we translate the Legion task arguments into our
-- custom argument layout structure.  This allows us to write
-- the body of generated code in a way that's agnostic to whether
-- the code is being executed in a Legion task or not.
local function generate_unpack_legion_task_args (argsym, task_args, ctxt)
  -- temporary collection of symbols from unpacking the regions
  local region_temporaries = {}

  local code = quote
    -- UNPACK REGIONS
    escape for reg_wrapper, ri in pairs(ctxt.bran.region_nums) do
      local reg_dim       = reg_wrapper.dimensions
      local physical_reg  = symbol(LW.legion_physical_region_t)
      local rect          = symbol(LegionRect[reg_dim])

      region_temporaries[ri] = {
        physical_reg  = physical_reg,
        reg_dim       = reg_dim,
        rect          = rect
      }

      emit quote
        var [physical_reg]  = [LgTaskArgs].regions[ri]
        var index_space     =
          LW.legion_physical_region_get_logical_region(
                                           physical_reg).index_space
        var domain          =
          LW.legion_index_space_get_domain([LgTaskArgs].lg_runtime,
                                           [LgTaskArgs].lg_ctx,
                                           index_space)
        var [rect]          = 
          [ LegionGetRectFromDom[reg_dim] ](domain)
      end
    end end

    -- UNPACK PRIMARY REGION BOUNDS RECTANGLE
    escape
      local ri    = ctxt.bran:getPrimaryRegionNum()
      local rect  = region_temporaries[ri].rect
      local ndims = region_temporaries[ri].reg_dim
      for i=1,ndims do emit quote
        [argsym].bounds[i-1].lo = rect.lo.x[d-1]
        [argsym].bounds[i-1].hi = rect.hi.x[d-1]
      end end 
    end
    
    -- UNPACK FIELDS
    escape for field, farg_name in pairs(ctxt.bran.field_ids) do
      local rtemp = region_temporaries[ctxt.bran:getRegionNum(field)]
      local physical_reg = rtemp.physical_reg
      local reg_dim      = rtemp.reg_dim
      local rect         = rtemp.rect

      emit quote
        var field_accessor =
          LW.legion_physical_region_get_field_accessor_generic(
                                              physical_reg, [field.fid])
        var subrect : LegionRect[reg_dim]
        var strides : LW.legion_byte_offset_t[reg_dim]
        var base = [&uint8](
          [ LegionRawPtrFromAcc[reg_dim] ](
                              field_accessor, rect, &subrect, strides))
        [argsym].[farg_name] = LW.FieldAccessor[reg_dim] { base, strides }
      end
    end end
  end

    -- Read in global data from futures: assumption that the caller gets
    -- ownership of returned legion_result_t. Need to do a deep-copy (copy
    -- value from result) otherwise.
--    local global_init = quote
--      var [global_ptrs]
--    end
--    for _, global in ipairs(ctxt:Globals()) do
--      local g = ctxt:GlobalIdx(global)
--      global_init = quote
--        [global_init]
--        do
--          var fut = LW.legion_task_get_future([Largs].task, g-1)
--          [global_ptrs][g-1] = LW.legion_future_get_result(fut)
--        end
--      end
--    end

    -- Return reduced task result and destroy other task results
    -- (corresponding to futures)
--    local cleanup_and_ret = quote end
--    local global_to_reduce = ctxt:GlobalToReduce()
--    for _, global in ipairs(ctxt:Globals()) do
--      if global ~= global_to_reduce then
--        local g = ctxt:GlobalIdx(global)
--        cleanup_and_ret = quote
--          [cleanup_and_ret]
--          do
--            LW.legion_task_result_destroy([global_ptrs][g-1])
--          end
--        end
--      end
--    end
--    local gred = ctxt:GlobalIdx(global_to_reduce)
--    if gred then
--      cleanup_and_ret = quote
--        [cleanup_and_ret]
--        return [global_ptrs][ gred-1 ]
--      end
--    end

  return code
end

function legion_codegen (kernel_ast, ctxt)
  if ctxt:onGPU() then
    error('INTERNAL ERROR: Unimplemented GPU codegen with Legion runtime')
  end

  -- HACK HACK HACK
  if ctxt.bran.n_global_ids > 0 then
    error("LEGION GLOBALS TODO")
  end

  ctxt:enterblock()
    -- declare the symbol for the parameter key
    local param = symbol(ctxt:argKeyTerraType())
    ctxt:localenv()[kernel_ast.name] = param

    local dims                  = ctxt:dims()
    if use_legion then
      local bounds              = `[ctxt:argsym()].bounds
      for d=1,#dims do
        dims[d] = { lo = `bounds[d-1].lo, hi = `bounds[d-1].hi }
      end
    end


    local body = kernel_ast.body:codegen(ctxt)

    if ctxt:isOverSubset() then
      error("LEGION SUBSETS TODO")
    else
      body = terraIterNd(dims, function(iter) return quote
        var [param] = iter
        [body]
      end end)
    end

  ctxt:leaveblock()

  -- BUILD THE LAUNCHER
  if use_legion then

    local k = terra (task_args : LW.TaskArgs)
      var [ctxt:argsym()]
      [ generate_unpack_legion_task_args(ctxt:argsym(), task_args, ctxt) ]

      [body]
    end
    k:setname(kernel_ast.id)

    return legion_CreateLauncher(k, arg_layout, ctxt)
  end
end







end














--[[--------------------------------------------------------------------]]--
--[[            Iteration / Dimension Abstraction Helpers               ]]--
--[[--------------------------------------------------------------------]]--

-- NOTE: the entries in dims may be symbols,
--       allowing the loop bounds to be dynamically driven
local function terraIterNd(dims, func)
  local atyp = L.addr_terra_types[#dims]
  local addr = symbol(atyp)
  local iters = {}
  for d=1,#dims do iters[d] = symbol(uint64) end
  local loop = quote
    var [addr] = [atyp]({ a = array( iters ) })
    [func(addr)]
  end
  for drev=1,#dims do
    local d = #dims-drev + 1 -- flip loop order of dimensions
    local lo = 0
    local hi = dims[d]
    if type(dims[d]) == 'table' and dims[d].lo then
      lo = dims[d].lo
      hi = dims[d].hi
    end
    loop = quote for [iters[d]] = lo, hi do [loop] end end
  end
  return loop
end

local function terraGPUId_to_Nd(dims, size, id, func)
  local atyp = L.addr_terra_types[#dims]
  local addr = symbol(atyp)
  local translate
  if #dims == 1 then
    translate = quote var [addr] = [atyp]({ a = array(id) }) end
  elseif #dims == 2 then
    translate = quote
      var xid : uint64 = id % [dims[1]]
      var yid : uint64 = id / [dims[1]]
      var [addr] = [atyp]({ a = array(xid,yid) })
    end
  elseif #dims == 3 then
    translate = quote
      var xid : uint64 = id % [dims[1]]
      var yid : uint64 = (id / [dims[1]]) % [dims[2]]
      var zid : uint64 = id / [dims[1]*dims[2]]
      var [addr] = [atyp]({ a = array(xid,yid,zid) })
    end
  else
    error('INTERNAL: #dims > 3')
  end

  return quote
    if id < size then
      [translate]
      [func(addr)]
    end
  end
end


--[[--------------------------------------------------------------------]]--
--[[                        Codegen Entrypoint                          ]]--
--[[--------------------------------------------------------------------]]--

function Codegen.codegen (kernel_ast, bran)
  local env  = terralib.newenvironment(nil)
  local ctxt = Context.New(env, bran)

  -- BRANCH TO SEPARATE LEGION CODE HERE
  if use_legion then return legion_codegen(kernel_ast, ctxt) end

  ctxt:enterblock()
    -- declare the symbol for the parameter key
    local param = symbol(ctxt:argKeyTerraType())
    ctxt:localenv()[kernel_ast.name] = param

    local dims                  = ctxt:dims()
    local nrow_sym              = `[ctxt:argsym()].n_rows
    if #dims == 1 then dims = { nrow_sym } end
    local linid
    if ctxt:onGPU() then linid  = symbol(uint64) end

    local body = kernel_ast.body:codegen(ctxt)

    -- Handle Masking of dead rows when mapping
    -- Over an Elastic Relation
    if ctxt:isOverElastic() then
      if use_legion then
        error('INTERNAL: ELASTIC ON LEGION CURRENTLY UNSUPPORTED') end
      if ctxt:onGPU() then
        error("INTERNAL: ELASTIC ON GPU CURRENTLY UNSUPPORTED")
      else
        body = quote
          if [ctxt:isLiveCheck(param)] then [body] end
        end
      end
    end

    -- GENERATE FOR SUBSETS
    if ctxt:isOverSubset() then

      -- GPU SUBSET VERSION
      if ctxt:onGPU() then
        body = terraGPUId_to_Nd(dims, nrow_sym, linid, function(addr)
          return quote
            -- set param
            var [param]
            var use_index = not [ctxt:argsym()].use_boolmask
            if use_index then
              param = [ctxt:argsym()].index[linid]
            else -- use_boolmask
              param = addr
            end

            -- conditionally execute
            if use_index or [ctxt:argsym()].boolmask[linid] then
              [body]
            end
          end
        end)

      -- CPU SUBSET VERSION
      else
        body = quote
          if [ctxt:argsym()].use_boolmask then
          -- BOOLMASK SUBSET BRANCH
            [terraIterNd(dims, function(iter) return quote
              if [ctxt:argsym()].boolmask[ [T.linAddrTerraGen(dims)](iter) ]
              then
                var [param] = iter
                [body]
              end
            end end)]
          else
          -- INDEX SUBSET BRANCH
            -- ONLY GENERATE FOR NON-GRID RELATIONS
            escape if #ctxt:dims() > 1 then emit quote
              [terraIterNd({ nrow_sym }, function(iter) return quote
                var [param] = [ctxt:argsym()].index[iter.a[0]]
                [body]
              end end)]
            end end end
          end
        end
      end

    -- GENERATE FOR FULL RELATION
    else

      -- GPU FULL RELATION VERSION
      if ctxt:onGPU() then
        body = terraGPUId_to_Nd(dims, nrow_sym, linid, function(addr)
          return quote
            var [param] = [addr]
            [body]
          end
        end)

      -- CPU FULL RELATION VERSION
      else
        body = terraIterNd(dims, function(iter) return quote
          var [param] = iter
          [body]
        end end)
      end

    end

    -- Extra GPU wrapper
    if ctxt:onGPU() then

      -- Extra GPU Reduction setup/post-process
      if ctxt:hasGPUReduce() then
        body = quote
          [ctxt:codegenSharedMemInit()]
          G.barrier()
          [body]
          G.barrier()
          [ctxt:codegenSharedMemTreeReduction()]
        end
      end

      body = quote
        var [ctxt:tid()] = G.thread_id()
        var [ctxt:bid()] = G.block_id()
        var [linid]      = [ctxt:bid()] * [ctxt:gpuBlockSize()] + [ctxt:tid()]

        [body]
      end
    end

  ctxt:leaveblock()

  -- BUILD GPU LAUNCHER
  if ctxt:onGPU() then
    local cuda_kernel = terra([ctxt:argsym()]) [body] end
    cuda_kernel:setname(kernel_ast.id .. '_cudakernel')
    cuda_kernel = G.kernelwrap(cuda_kernel, L._INTERNAL_DEV_OUTPUT_PTX,
                               { {"maxntidx",64}, {"minctasm",6} })

    local MAX_GRID_DIM = 65536
    local launcher = terra (n_blocks : uint, args_ptr : &ctxt:argsType())
      var grid_x : uint,    grid_y : uint,    grid_z : uint   =
          G.get_grid_dimensions(n_blocks, MAX_GRID_DIM)
      var params = terralib.CUDAParams {
        grid_x, grid_y, grid_z,
        [ctxt:gpuBlockSize()], 1, 1,
        [ctxt:gpuSharedMemBytes()], nil
      }
      cuda_kernel(&params, @args_ptr)
      G.sync() -- flush print streams
      -- TODO: Does this sync cause any performance problems?
    end
    launcher:setname(kernel_ast.id)
    return launcher

  -- BUILD CPU LAUNCHER
  else
    local k = terra (args_ptr : &ctxt:argsType())
      var [ctxt:argsym()] = @args_ptr
      [body]
    end
    k:setname(kernel_ast.id)
    return k
  end
end



--[[--------------------------------------------------------------------]]--
--[[                       Codegen Pass Cases                           ]]--
--[[--------------------------------------------------------------------]]--

function ast.AST:codegen (ctxt)
  error("Codegen not implemented for AST node " .. self.kind)
end

function ast.ExprStatement:codegen (ctxt)
  return self.exp:codegen(ctxt)
end

-- complete no-op
function ast.Quote:codegen (ctxt)
  return self.code:codegen(ctxt)
end

function ast.LetExpr:codegen (ctxt)
  ctxt:enterblock()
  local block = self.block:codegen(ctxt)
  local exp   = self.exp:codegen(ctxt)
  ctxt:leaveblock()

  return quote [block] in [exp] end
end

-- DON'T CODEGEN A KERNEL DIRECTLY; HANDLE IN Codegen.codegen()
--function ast.LisztKernel:codegen (ctxt)
--end

function ast.Block:codegen (ctxt)
  -- start with an empty ast node, or we'll get an error when appending new quotes below
  local code = quote end
  for i = 1, #self.statements do
    local stmt = self.statements[i]:codegen(ctxt)
    code = quote
      [code]
      [stmt]
    end
  end
  return code
end

function ast.CondBlock:codegen(ctxt, cond_blocks, else_block, index)
  index = index or 1

  local cond  = self.cond:codegen(ctxt)
  ctxt:enterblock()
  local body = self.body:codegen(ctxt)
  ctxt:leaveblock()

  if index == #cond_blocks then
    if else_block then
      return quote if [cond] then [body] else [else_block:codegen(ctxt)] end end
    else
      return quote if [cond] then [body] end end
    end
  else
    ctxt:enterblock()
    local nested = cond_blocks[index + 1]:codegen(ctxt, cond_blocks, else_block, index + 1)
    ctxt:leaveblock()
    return quote if [cond] then [body] else [nested] end end
  end
end

function ast.IfStatement:codegen (ctxt)
  return self.if_blocks[1]:codegen(ctxt, self.if_blocks, self.else_block)
end

function ast.WhileStatement:codegen (ctxt)
  local cond = self.cond:codegen(ctxt)
  ctxt:enterblock()
  local body = self.body:codegen(ctxt)
  ctxt:leaveblock()
  return quote while [cond] do [body] end end
end

function ast.DoStatement:codegen (ctxt)
  ctxt:enterblock()
  local body = self.body:codegen(ctxt)
  ctxt:leaveblock()
  return quote do [body] end end
end

function ast.RepeatStatement:codegen (ctxt)
  ctxt:enterblock()
  local body = self.body:codegen(ctxt)
  local cond = self.cond:codegen(ctxt)
  ctxt:leaveblock()

  return quote repeat [body] until [cond] end
end

function ast.NumericFor:codegen (ctxt)
  -- min and max expression should be evaluated in current scope,
  -- iter expression should be in a nested scope, and for block
  -- should be nested again -- that way the loop var is reset every
  -- time the loop runs.
  local minexp  = self.lower:codegen(ctxt)
  local maxexp  = self.upper:codegen(ctxt)
  local stepexp = self.step and self.step:codegen(ctxt) or nil

  ctxt:enterblock()
  local iterstr = self.name
  local itersym = symbol()
  ctxt:localenv()[iterstr] = itersym

  ctxt:enterblock()
  local body = self.body:codegen(ctxt)
  ctxt:leaveblock()
  ctxt:leaveblock()

  if stepexp then
    return quote for [itersym] = [minexp], [maxexp], [stepexp] do
      [body]
    end end
  else
    return quote for [itersym] = [minexp], [maxexp] do [body] end end
  end
end

function ast.Break:codegen(ctxt)
  return quote break end
end

function ast.Name:codegen(ctxt)
  local s = ctxt:localenv()[self.name]
  assert(terralib.issymbol(s))
  return `[s]
end

function ast.Cast:codegen(ctxt)
  local typ = self.node_type
  local bt  = typ:terraBaseType()
  local valuecode = self.value:codegen(ctxt)

  if typ:isPrimitive() then
    return `[typ:terraType()](valuecode)

  elseif typ:isVector() then
    local vec = symbol(self.value.node_type:terraType())
    return quote var [vec] = valuecode in
      [ Support.vec_mapgen(typ, function(i)
          return `[bt](vec.d[i])
      end) ] end

  elseif typ:isMatrix() then
    local mat = symbol(self.value.node_type:terraType())
    return quote var [mat] = valuecode in
      [ Support.mat_mapgen(typ, function(i,j)
          return `[bt](mat.d[i][j])
      end) ] end

  else
    error("Internal Error: Type unrecognized "..typ:toString())
  end
end

-- By the time we make it to codegen, Call nodes are only used to represent builtin function calls.
function ast.Call:codegen (ctxt)
    return self.func.codegen(self, ctxt)
end


function ast.DeclStatement:codegen (ctxt)
  local varname = self.name
  local tp      = self.node_type:terraType()
  local varsym  = symbol(tp)

  if self.initializer then
    local exp = self.initializer:codegen(ctxt)
    ctxt:localenv()[varname] = varsym -- MUST happen after init codegen
    return quote 
      var [varsym] = [exp]
    end
  else
    ctxt:localenv()[varname] = varsym -- MUST happen after init codegen
    return quote var [varsym] end
  end
end

function ast.MatrixLiteral:codegen (ctxt)
  local typ = self.node_type

  return Support.mat_mapgen(typ, function(i,j)
    return self.elems[i*self.m + j + 1]:codegen(ctxt)
  end)
end

function ast.VectorLiteral:codegen (ctxt)
  local typ = self.node_type

  return Support.vec_mapgen(typ, function(i)
    return self.elems[i+1]:codegen(ctxt)
  end)
end

function ast.SquareIndex:codegen (ctxt)
  local base  = self.base:codegen(ctxt)
  local index = self.index:codegen(ctxt)

  -- Vector case
  if self.index2 == nil then
    return `base.d[index]
  -- Matrix case
  else
    local index2 = self.index2:codegen(ctxt)

    return `base.d[index][index2]
  end
end

function ast.Number:codegen (ctxt)
  return `[self.value]
end

function ast.Bool:codegen (ctxt)
  if self.value == true then
    return `true
  else 
    return `false
  end
end


function ast.UnaryOp:codegen (ctxt)
  local expr = self.exp:codegen(ctxt)
  local typ  = self.node_type

  return Support.unary_exp(self.op, typ, expr)
end

function ast.BinaryOp:codegen (ctxt)
  local lhe = self.lhs:codegen(ctxt)
  local rhe = self.rhs:codegen(ctxt)

  return Support.bin_exp(self.op, self.node_type,
      lhe, rhe, self.lhs.node_type, self.rhs.node_type)
end

function ast.LuaObject:codegen (ctxt)
    return `{}
end

function ast.GenericFor:codegen (ctxt)
    local set       = self.set:codegen(ctxt)
    local iter      = symbol("iter")
    local rel       = self.set.node_type.relation
    -- the key being used to drive the where query should
    -- come from a grouped relation, which is necessarily 1d
    local projected = `[L.addr_terra_types[1]]({array([iter])})

    for i,p in ipairs(self.set.node_type.projections) do
        local field = rel[p]
        projected   = doProjection(projected,field,ctxt)
        rel         = field.type.relation
        assert(rel)
    end
    local sym = symbol(L.key(rel):terraType())
    ctxt:enterblock()
        ctxt:localenv()[self.name] = sym
        local body = self.body:codegen(ctxt)
    ctxt:leaveblock()
    local code = quote
        var s = [set]
        for [iter] = s.start,s.finish do
            var [sym] = [projected]
            [body]
        end
    end
    return code
end

function ast.Assignment:codegen (ctxt)
  local lhs   = self.lvalue:codegen(ctxt)
  local rhs   = self.exp:codegen(ctxt)

  local ltype, rtype = self.lvalue.node_type, self.exp.node_type

  if self.reduceop then
    rhs = Support.bin_exp(self.reduceop, ltype, lhs, rhs, ltype, rtype)
  end
  return quote [lhs] = rhs end
end



--[[--------------------------------------------------------------------]]--
--[[          Codegen Pass Cases involving data access                  ]]--
--[[--------------------------------------------------------------------]]--


function ast.Global:codegen (ctxt)
  local dataptr = ctxt:GlobalPtr(self.global)
  return `@dataptr
end

function ast.Where:codegen(ctxt)
  if use_legion then error("LEGION UNSUPPORTED TODO") end
  local key         = self.key:codegen(ctxt)
  local sType       = self.node_type:terraType()
  local keydims     = self.key.node_type.relation:Dims()
  local indexarith  = T.linAddrTerraGen(keydims)

  local dstrel  = self.relation
  local offptr  = ctxt:FieldPtr(dstrel:_INTERNAL_GroupedOffset())
  local lenptr  = ctxt:FieldPtr(dstrel:_INTERNAL_GroupedLength())
  --local indexdata = self.relation._grouping.index:DataPtr()
  local v = quote
    var k   = [key]
    var off = offptr[ indexarith(k) ]
    var len = lenptr[ indexarith(k) ]
    --var idx = [indexdata]
  in 
    sType { off, off+len }
    --sType { idx[k.a[0]].a[0], idx[k.a[0]+1].a[0] }
  end
  return v
end

local function doProjection(key,field,ctxt)
  assert(L.is_field(field))
  local dataptr     = ctxt:FieldPtr(field)
  local keydims     = field:Relation():Dims()
  local indexarith  = T.linAddrTerraGen(keydims)
  return `dataptr[ indexarith(key) ]
end


function ast.GlobalReduce:codegen(ctxt)
  -- GPU impl:
  if ctxt:onGPU() then
    if use_legion then error("LEGION UNSUPPORTED TODO") end
    local lval = ctxt:gpuReduceSharedMemPtr(self.global.global)
    local rexp = self.exp:codegen(ctxt)
    local rhs  = Support.bin_exp(self.reduceop, self.global.node_type,
                                 lval, rexp,
                                 self.global.node_type, self.exp.node_type)
    return quote [lval] = [rhs] end

  -- CPU impl: forwards to assignment codegen
  else
    local assign = ast.Assignment:DeriveFrom(self)
    assign.lvalue = self.global
    assign.exp    = self.exp
    assign.reduceop = self.reduceop

    return assign:codegen(ctxt)
  end
end


function ast.FieldWrite:codegen (ctxt)
  if ctxt:onGPU() and use_legion then error("LEGION UNSUPPORTED TODO") end
  -- If this is a field-reduction on the GPU
  if ctxt:onGPU() and
     self.reduceop and
     not ctxt:hasExclusivePhase(self.fieldaccess.field)
  then
    local lval = self.fieldaccess:codegen(ctxt)
    local rexp = self.exp:codegen(ctxt)
    return Support.gpu_atomic_exp(self.reduceop,
                                  self.fieldaccess.node_type,
                                  lval, rexp, self.exp.node_type)
  else
    -- just re-direct to an assignment statement otherwise
    local assign = ast.Assignment:DeriveFrom(self)
    assign.lvalue = self.fieldaccess
    assign.exp    = self.exp
    if self.reduceop then assign.reduceop = self.reduceop end

    return assign:codegen(ctxt)
  end
end

function ast.FieldAccess:codegen (ctxt)
  if use_legion then
    local key     = self.key:codegen(ctxt)
    local fdata   = ctxt:FieldData(self.field)
    local fttype  = self.field:Type().terratype
    local access = quote
      var strides = [fdata].strides
      var ptr = [&fttype]([fdata].ptr + [IndexToOffset(ctxt, key, strides)] )
    in
      @ptr
    end
    return access
  end
  local key         = self.key:codegen(ctxt)
  local dataptr     = ctxt:FieldPtr(self.field)
  local keydims     = self.field:Relation():Dims()
  local indexarith  = T.linAddrTerraGen(keydims)
  return `dataptr[ indexarith(key) ]
end


--[[--------------------------------------------------------------------]]--
--[[                          INSERT/ DELETE                            ]]--
--[[--------------------------------------------------------------------]]--


function ast.DeleteStatement:codegen (ctxt)
  local relation  = self.key.node_type.relation

  local key       = self.key:codegen(ctxt)
  local live_mask = ctxt:FieldPtr(relation._is_live_mask)
  local set_mask_stmt = quote live_mask[key.a[0]] = false end

  local updated_size     = ctxt:deleteSizeVar()
  local size_update_stmt = quote [updated_size] = [updated_size]-1 end

  return quote set_mask_stmt size_update_stmt end
end

function ast.InsertStatement:codegen (ctxt)
  local relation = self.relation.node_type.value -- to insert into

  -- index to write to
  local index = ctxt:getInsertIndex()

  -- start with writing the live mask
  local live_mask  = ctxt:FieldPtr(relation._is_live_mask)
  local write_code = quote live_mask[index] = true end

  -- the rest of the fields should be assigned values based on the
  -- record literal specified as an argument to the insert statement
  for field,i in pairs(self.fieldindex) do
    local exp_code = self.record.exprs[i]:codegen(ctxt)
    local fieldptr = ctxt:FieldPtr(field)

    write_code = quote
      write_code
      fieldptr[index] = exp_code
    end
  end

  local inc_stmt = ctxt:incrementInsertIndex()

  return quote
    write_code
    inc_stmt
  end
end



