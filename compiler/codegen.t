local Codegen = {}
package.loaded["compiler.codegen"] = Codegen

local ast = require "compiler.ast"

local C = terralib.require 'compiler.c'
local L = terralib.require 'compiler.lisztlib'

local thread_id
local block_id
local aadd_fl

if terralib.cudacompile then
  thread_id = cudalib.nvvm_read_ptx_sreg_tid_x
  block_id  = cudalib.nvvm_read_ptx_sreg_ctaid_x
  aadd_fl   = terralib.intrinsic("llvm.nvvm.atomic.load.add.f32.p0f32", {&float,float} -> {float})
end


----------------------------------------------------------------------------

local Context = {}
Context.__index = Context

function Context.new(env, bran)
    local ctxt = setmetatable({
        env     = env,
        bran    = bran,
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

function Context:onGPU()
  return self.bran.location == L.GPU
end

function Context:FieldPtr(field)
  return self.bran:getRuntimeFieldPtr(field)
end
function Context:GlobalPtr(global)
  return self.bran:getRuntimeGlobalPtr(global)
end
function Context:runtimeGerm()
  return self.bran.runtime_germ:ptr()
end
function Context:cpuGerm()
  return self.bran.cpu_germ:ptr()
end
function Context:isLiveCheck(param_var)
  local ptr = self:FieldPtr(self.bran.relation._is_live_mask)
  return `ptr[param_var]
end
function Context:deleteSizeVar()
  local dd = self.bran.delete_data
  if dd then
    return `@[self:GlobalPtr(dd.updated_size)]
  end
end
function Context:getInsertIndex()
  return `[self:runtimeGerm()].insert_write
end
function Context:incrementInsertIndex()
  local insert_index = self:getInsertIndex()
  local counter = self:GlobalPtr(self.bran.insert_data.n_inserted)

  return quote
    insert_index = insert_index + 1
    @counter = @counter + 1
  end
end

----------------------------------------------------------------------------

local function cpu_codegen (kernel_ast, ctxt)
  ctxt:enterblock()
    -- declare the symbol for iteration
    local param = symbol(L.row(ctxt.bran.relation):terraType())
    ctxt:localenv()[kernel_ast.name] = param

    -- insert a check for the live row mask
    local body  = quote
      if [ctxt:isLiveCheck(param)] then
        [kernel_ast.body:codegen(ctxt)]
      end
    end

    -- by default on CPU just iterate over all the possible rows
    local kernel_body = quote
      for [param] = 0, [ctxt:runtimeGerm()].n_rows do
        [body]
      end
    end

    -- special iteration logic for subset-mapped kernels
    if ctxt.bran.subset then
      kernel_body = quote
        if [ctxt:runtimeGerm()].use_boolmask then
          var boolmask = [ctxt:runtimeGerm()].boolmask
          for [param] = 0, [ctxt:runtimeGerm()].n_rows do
            if boolmask[param] then -- subset guard
              [body]
            end
          end
        else
          var index = [ctxt:runtimeGerm()].index
          var size = [ctxt:runtimeGerm()].index_size
          for itr = 0,size do
            var [param] = index[itr]
            [body]
          end
        end
      end
    end
  ctxt:leaveblock()

  local r = terra ()
    [kernel_body]
  end
  return r
end

local function gpu_codegen (kernel_ast, ctxt)
  local BLOCK_SIZE = 32

  ctxt:enterblock()
    -- declare the symbol for iteration
    local param = symbol(L.row(ctxt.bran.relation):terraType())
    ctxt:localenv()[kernel_ast.name] = param

    local body  = quote
      if [ctxt:isLiveCheck(param)] then
        [kernel_ast.body:codegen(ctxt)]
      end
    end

    local kernel_body = quote
      var id : uint64 = block_id() * BLOCK_SIZE + thread_id()
      var [param] = id
      if [param] < [ctxt:runtimeGerm()].n_rows then
        [body]
      end
    end

    if ctxt.bran.subset then
      kernel_body = quote
        var id : uint64 = block_id() * BLOCK_SIZE + thread_id()
        if [ctxt:runtimeGerm()].use_boolmask then
          var [param] = id
          if [param] < [ctxt:runtimeGerm()].n_rows and
             [ctxt:runtimeGerm()].boolmask[param]
          then
            [body]
          end
        else
          if id < [ctxt:runtimeGerm()].index_size then
            var [param] = [ctxt:runtimeGerm()].index[id]
            [body]
          end
        end
      end
    end
  ctxt:leaveblock()

  local cuda_kernel = terra ()
    [kernel_body]
  end
  local M = terralib.cudacompile { cuda_kernel = cuda_kernel }
  -- germ type will have a use_boolmask field only if it
  -- was generated for a subset kernel
  if ctxt.bran.subset then
    local launcher = terra ()
      var n_blocks = uint(C.ceil(
        [ctxt:cpuGerm()].n_rows / float(BLOCK_SIZE)))
      var params = terralib.CUDAParams {
        n_blocks, 1, 1,
        BLOCK_SIZE, 1, 1,
        0, nil
      }

      if not [ctxt:cpuGerm()].use_boolmask then
        var n_blocks = uint(C.ceil(
          [ctxt:cpuGerm()].index_size / float(BLOCK_SIZE)))
        params = terralib.CUDAParams {
          n_blocks, 1, 1,
          BLOCK_SIZE, 1, 1,
          0, nil
        }
      end
      M.cuda_kernel(&params)
    end
    return launcher

  else
    local launcher = terra ()
      var n_blocks = uint(C.ceil(
        [ctxt:cpuGerm()].n_rows / float(BLOCK_SIZE)))
      var params = terralib.CUDAParams {
        n_blocks, 1, 1,
        BLOCK_SIZE, 1, 1,
        0, nil
      }
      M.cuda_kernel(&params)
    end
    return launcher
  end
end

function Codegen.codegen (kernel_ast, bran)
  local env  = terralib.newenvironment(nil)
  local ctxt = Context.new(env, bran)

  if ctxt:onGPU() then
    return gpu_codegen(kernel_ast, ctxt)
  else
    return cpu_codegen(kernel_ast, ctxt)
  end

end


----------------------------------------------------------------------------

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

-- DON'T CODEGEN THE KERNEL THIS WAY; HANDLE IN Codegen.codegen()
--function ast.LisztKernel:codegen (ctxt)
--end

function ast.Block:codegen (ctxt)
  -- start with an empty ast node, or we'll get an error when appending new quotes below
  local code = quote end
  for i = 1, #self.statements do
    local stmt = self.statements[i]:codegen(ctxt)
    code = quote code stmt end
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
    return quote for [itersym] = [minexp], [maxexp], [stepexp] do [body] end end
  end

  return quote for [itersym] = [minexp], [maxexp] do [body] end end
end

function ast.Break:codegen(ctxt)
  return quote break end
end

function ast.Name:codegen(ctxt)
  local s = ctxt:localenv()[self.name]
  assert(terralib.issymbol(s))
  return `[s]
end

local function min(lhe, rhe)
  return quote
    var a = [lhe]
    var b = [rhe]
    var min = a
    if b < a then
      min = b
    end
    in
    min
  end
end

local function max(lhe, rhe)
  return quote
    var a = [lhe]
    var b = [rhe]
    var max = a
    if b > a then
      max = b
    end
    in
    max
  end
end

local function bin_exp (op, lhe, rhe)
  if     op == '+'   then return `[lhe] +   [rhe]
  elseif op == '-'   then return `[lhe] -   [rhe]
  elseif op == '/'   then return `[lhe] /   [rhe]
  elseif op == '*'   then return `[lhe] *   [rhe]
  elseif op == '%'   then return `[lhe] %   [rhe]
  elseif op == '^'   then return `[lhe] ^   [rhe]
  elseif op == 'or'  then return `[lhe] or  [rhe]
  elseif op == 'and' then return `[lhe] and [rhe]
  elseif op == '<'   then return `[lhe] <   [rhe]
  elseif op == '>'   then return `[lhe] >   [rhe]
  elseif op == '<='  then return `[lhe] <=  [rhe]
  elseif op == '>='  then return `[lhe] >=  [rhe]
  elseif op == '=='  then return `[lhe] ==  [rhe]
  elseif op == '~='  then return `[lhe] ~=  [rhe]
  elseif op == 'max' then return max(lhe, rhe)
  elseif op == 'min' then return min(lhe, rhe)
  end
end

local gpu_reductions_for_type = {
  [L.float] = {
      ['+'] = true,
      ['-'] = true,
    },
  [L.double] = {}, -- unsupported types
  [L.int]    = {},
  [L.uint64] = {},
  [L.bool]   = {},
}

local function red_exp (op, typ, lvalptr, update)
  local internal_error = 'unsupported reduction, internal error; '..
                         'this should be guaraded against in the typechecker'
  if typ == L.float then
    if     op == '+' then return `aadd_fl(lvalptr, update)
    elseif op == '-' then return `aadd_fl(lvalptr, -update)
    end
    error(internal_error)
    return nil
  elseif typ == L.int then
    error(internal_error)
    return nil
  end
  error(internal_error)
end

function let_vec_binding(typ, N, exp)
  local val = symbol(typ:terraType())
  local let_binding = quote var [val] = [exp] end

  local coords = {}
  if typ:isVector() then
    for i=1, N do coords[i] = `val.d[i-1] end
  else
    for i=1, N do coords[i] = `val end
  end

  return let_binding, coords
end

function vec_bin_exp(op, result_typ, lhe, rhe, lhtyp, rhtyp)
  -- ALL non-vector ops are handled here
  if not lhtyp:isVector() and not rhtyp:isVector() then
    return bin_exp(op, lhe, rhe)
  end

  -- the result type is misleading if we're doing a vector comparison...
  if op == '==' or op == '~=' then
    -- assert(lhtyp:isVector() and rhtyp:isVector())
    result_typ = lhtyp
    if lhtyp:isCoercableTo(rhtyp) then
      result_typ = rhtyp
    end
  end

  local N = result_typ.N

  local lhbind, lhcoords = let_vec_binding(lhtyp, N, lhe)
  local rhbind, rhcoords = let_vec_binding(rhtyp, N, rhe)

  -- Assemble the resulting vector by mashing up the coords
  local coords = {}
  for i=1, N do
    coords[i] = bin_exp(op, lhcoords[i], rhcoords[i])
  end
  local result = `[result_typ:terraType()]({ array( [coords] ) })

  -- special case handling of vector comparisons
  if op == '==' then -- AND results
    result = `true
    for i = 1, N do result = `result and [ coords[i] ] end
  elseif op == '~=' then -- OR results
    result = `false
    for i = 1, N do result = `result or [ coords[i] ] end
  end

  local q = quote
    [lhbind]
    [rhbind]
  in
    [result]
  end
  return q
end

function vec_red_exp(op, result_typ, lval, rhe, rhtyp)
  if not result_typ:isVector() then
    return red_exp(op, result_typ, `&lval, rhe)
  end

  local N = result_typ.N
  local rhbind, rhcoords = let_vec_binding(rhtyp, N, rhe)

  local v = symbol() -- pointer to vector location of reduction result

  local result = quote end
  for i = 0, N-1 do
    result = quote
      [result]
      [red_exp(op, result_typ:baseType(), `v+i, rhcoords[i+1])]
    end
  end
  return quote
      var [v] : &result_typ:terraBaseType() = [&result_typ:terraBaseType()](&[lval])
      [rhbind]
    in
      [result]
    end
end

function ast.Assignment:codegen (ctxt)
  local lhs   = self.lvalue:codegen(ctxt)
  local rhs   = self.exp:codegen(ctxt)

  local ltype, rtype = self.lvalue.node_type, self.exp.node_type

  if self.reduceop then
    rhs = vec_bin_exp(self.reduceop, ltype, lhs, rhs, ltype, rtype)
  end
  return quote [lhs] = rhs end
end

function ast.GlobalReduce:codegen(ctxt)
  -- GPU impl:
  if ctxt:onGPU() then
    local lval = self.global:codegen(ctxt)
    local rexp = self.exp:codegen(ctxt)
    return vec_red_exp(self.reduceop, self.global.node_type, lval, rexp, self.exp.node_type)
  end

  -- CPU impl forwards to assignment codegen
  local assign = ast.Assignment:DeriveFrom(self)
  assign.lvalue = self.global
  assign.exp    = self.exp
  assign.reduceop = self.reduceop

  return assign:codegen(ctxt)
end


function ast.FieldWrite:codegen (ctxt)
  if ctxt:onGPU() and self.reduceop then
    local lval = self.fieldaccess:codegen(ctxt)
    local rexp = self.exp:codegen(ctxt)
    return vec_red_exp(self.reduceop, self.fieldaccess.node_type, lval, rexp, self.exp.node_type)
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
  local index = self.row:codegen(ctxt)
  local dataptr = ctxt:FieldPtr(self.field)
  return `@(dataptr + [index])
end

function ast.Cast:codegen(ctxt)
  local typ = self.node_type
  local valuecode = self.value:codegen(ctxt)

  if not typ:isVector() then
    return `[typ:terraType()](valuecode)
  else
    local vec = symbol(self.value.node_type:terraType())
    local bt  = typ:terraBaseType()

    local coords = {}
    for i= 1, typ.N do coords[i] = `[bt](vec.d[i-1]) end

    return quote
      var [vec] = valuecode
    in
      [typ:terraType()]({ arrayof(bt, [coords]) })
    end
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

function ast.VectorLiteral:codegen (ctxt)
  local typ = self.node_type

  -- type everything explicitly
  local elems = {}
  for i = 1, #self.elems do
    elems[i] = self.elems[i]:codegen(ctxt)
  end

  -- we allocate vectors as a struct with a single array member
  return `[typ:terraType()]({ array( [elems] ) })
end

function ast.Global:codegen (ctxt)
  local dataptr = ctxt:GlobalPtr(self.global)
  return `@dataptr
end

function ast.VectorIndex:codegen (ctxt)
  local vector = self.vector:codegen(ctxt)
  local index  = self.index:codegen(ctxt)

  return `vector.d[index]
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

  if not typ:isVector() then
    if (self.op == '-') then return `-[expr]
    else                     return `not [expr]
    end
  else -- Unary op applied to a vector...
    local binding, coords = let_vec_binding(typ, typ.N, expr)

    -- apply the operation
    if (self.op == '-') then
      for i = 1, typ.N do coords[i] = `-[ coords[i] ] end
    else
      for i = 1, typ.N do coords[i] = `not [ coords[i] ] end
    end

    return quote
      [binding]
    in
      [typ:terraType()]({ array([coords]) })
    end
  end
end

function ast.BinaryOp:codegen (ctxt)
  local lhe = self.lhs:codegen(ctxt)
  local rhe = self.rhs:codegen(ctxt)

  -- handle case of two primitives
  return vec_bin_exp(self.op, self.node_type,
      lhe, rhe, self.lhs.node_type, self.rhs.node_type)
end

function ast.LuaObject:codegen (ctxt)
    return `{}
end
function ast.Where:codegen(ctxt)
    local key   = self.key:codegen(ctxt)
    local sType = self.node_type:terraType()
    local indexdata = self.relation._grouping.index:DataPtr()
    local v = quote
        var k   = [key]
        var idx = [indexdata]
    in 
        sType { idx[k], idx[k+1] }
    end
    return v
end

local function doProjection(obj,field,ctxt)
    assert(L.is_field(field))
    local dataptr = ctxt:FieldPtr(field)
    return `dataptr[obj]
end

function ast.GenericFor:codegen (ctxt)
    local set       = self.set:codegen(ctxt)
    local iter      = symbol("iter")
    local rel       = self.set.node_type.relation
    local projected = iter

    for i,p in ipairs(self.set.node_type.projections) do
        local field = rel[p]
        projected   = doProjection(projected,field,ctxt)
        rel         = field.type.relation
        assert(rel)
    end
    local sym = symbol(L.row(rel):terraType())
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


----------------------------------------------------------------------------

function ast.DeleteStatement:codegen (ctxt)
  local relation  = self.row.node_type.relation

  local row       = self.row:codegen(ctxt)
  local live_mask = ctxt:FieldPtr(relation._is_live_mask)
  local set_mask_stmt = quote live_mask[row] = false end

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


