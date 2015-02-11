local T = {}
package.loaded["compiler.legion_tasks"] = T

local C = require "compiler.c"

-- Legion library
require "legionlib"
local Lc = terralib.includecstring([[
#include "legion_c.h"
]])

local Ld = require "compiler.legion_data"
local Tt = require "compiler.legion_task_types"


-------------------------------------------------------------------------------
--[[                       Kernel Launcher Template                        ]]--
-------------------------------------------------------------------------------

local KernelLauncherTemplate = Tt.KernelLauncherTemplate
local KernelLauncherSize     = Tt.KernelLauncherSize


-------------------------------------------------------------------------------
--[[                Argument layout (known during codegen)                 ]]--
-------------------------------------------------------------------------------

-- information about fields in a region, privileges etc
local ArgRegion = {}
ArgRegion.__index = ArgRegion
local function NewArgRegion(rel)
  local reg = {
    relation   = rel,
    -- fields in this region
    fields     = {},
    -- number of fields this region contains
    num_fields = 0,
  }
  setmetatable(reg, ArgRegion)
  return reg
end
T.NewArgRegion = NewArgRegion

function ArgRegion:Relation()
  return self.relation
end

function ArgRegion:Fields()
  return self.fields
end

function ArgRegion:NumFields()
  return self.num_fields
end

function ArgRegion:AddField(field, idx)
  self.num_fields = self.num_fields + 1
  self.fields[field] = idx
end

-- information about regions passed by Legion, number of fields etc
local ArgLayout = {}
ArgLayout.__index = ArgLayout
T.ArgLayout = ArgLayout
local function NewArgLayout()
  local arg = {
    -- number of regions
    num_regions = 0,
    -- list of regions for a Legion task
    regions     = {},
    -- total number of fields over all regions
    num_fields  = 0,
    -- fields with idx for codegen
    fields      = {}
  }
  setmetatable(arg, ArgLayout)
  return arg
end
T.NewArgLayout = NewArgLayout

function ArgLayout:NumRegions()
  return self.num_regions
end

function ArgLayout:Regions()
  return self.regions
end

function ArgLayout:NumFields()
  return self.num_fields
end

function ArgLayout:AddRegion(reg)
  self.num_regions = self.num_regions + 1
  self.regions[reg] = self.num_regions
end

function ArgLayout:AddFieldToRegion(field, reg)
  self.num_fields = self.num_fields + 1
  self.fields[field] = self.num_fields
  reg:AddField(field, self.num_fields)
end

function ArgLayout:RegIdx(reg)
  return self.regions[reg]
end

function ArgLayout:FieldIdx(field)
  return self.fields[field]
end


-------------------------------------------------------------------------------
--[[                         Legion task launcher                          ]]--
-------------------------------------------------------------------------------


-- Creates a map of region requirements, to be used when creating region
-- requirements for task launcher, and when codegen-ing task executable.
function T.SetUpArgLayout(params)

  local field_use = params.bran.kernel.field_use

  -- arg layout
  params.bran.arg_layout = NewArgLayout()
  local arg_layout = params.bran.arg_layout

  -- only one region for now
  local region = NewArgRegion(params.bran.relset)
  arg_layout:AddRegion(region)

  -- add all fields to this region
  for field, access in pairs(field_use) do
    arg_layout:AddFieldToRegion(field, region)
  end

end


-- Creates a task launcher with task region requirements.
-- Implementation details:
--  * This creates a separate region requirement for each accessed field. We
--  can group multiple fields into one region requirement, based on stencil
--  and access privileges.
--  * A region requirement with no fields is created as region req 0. This is
--  for iterating over the index space. We can instead do book-keeping about
--  which region can be used for performing iteration, or something else?
function T.CreateTaskLauncher(params)
  local args = params.bran.kernel_launcher:PackToTaskArg()
  -- Simple task that does not return any values
  if params.task_type == Tt.TaskTypes.simple then
    -- task launcher
    local task_launcher = Lc.legion_task_launcher_create(
                             Tt.TID_SIMPLE, args,
                             Lc.legion_predicate_true(), 0, 0)

    local field_use = params.bran.kernel.field_use
    local relset = params.bran.relset
    local arg_layout = params.bran.arg_layout

    local regions = arg_layout:Regions()
    local num_regions = params.bran.arg_layout:NumRegions()
    local reg_req = {}

    for region, _ in pairs(regions) do
      local r = arg_layout:RegIdx(region)
      local rel = region:Relation()
      reg_req[r] =
        Lc.legion_task_launcher_add_region_requirement_logical_region(
          task_launcher, rel._logical_region_wrapper.handle,
          Lc.READ_WRITE, Lc.EXCLUSIVE,
          rel._logical_region_wrapper.handle, 0, false )
      for field, _ in pairs(region:Fields()) do
        local f = arg_layout:FieldIdx(field, region)
        local access = field_use[field]
        local rel = field.owner
        print("In create task launcher, adding field " .. field.fid .. " to region req " .. r)
        Lc.legion_task_launcher_add_field(
          task_launcher, reg_req[r], field.fid, true )
      end
    end
    return task_launcher
  elseif params.task_type == Tt.TaskTypes.fut then
    error("INTERNAL ERROR: Liszt does not handle tasks with future values yet")
  else
    error("INTERNAL ERROR: Unknown task type")
  end
end

-- Launches Legion task and returns.
function T.LaunchTask(p, leg_args)
  print("Launching legion task")
   Lc.legion_task_launcher_execute(leg_args.runtime, leg_args.ctx,
                                   p.task_launcher)
  print("Launched task")
end
