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


-- Simplify includes

local gl = {}
package.loaded["ebb.gl.gl"] = gl

local ffi = require 'ffi'
local C   = require 'ebb.src.c'


-- declare preprocessor constants we want to retreive
local enum_list = {
    'COLOR_BUFFER_BIT',
    'DEPTH_BUFFER_BIT',
    'TRIANGLES',
    'DEPTH_TEST',
    'CULL_FACE',
    'MULTISAMPLE',
    'ARRAY_BUFFER',
    'ELEMENT_ARRAY_BUFFER',
    'STATIC_DRAW',
    'FLOAT',
    'DOUBLE',
    'UNSIGNED_INT',
    'VERTEX_SHADER',
    'FRAGMENT_SHADER',
    'INFO_LOG_LENGTH',
    'VALIDATE_STATUS',
    'LINK_STATUS',
    'FALSE',
    'TRUE',
}
local enum_c_patch = "void get_gl_enum_constants(GLenum * output) {\n"
for i, name in ipairs(enum_list) do
    enum_c_patch = enum_c_patch ..
                   '    output['..tostring(i-1)..'] = GL_'..name..';\n'
end
enum_c_patch = enum_c_patch .. '}\n'



local c_inc = terralib.includecstring([[
//#define GLFW_INCLUDE_GLU
#define GLFW_INCLUDE_GLCOREARB
#include <GLFW/glfw3.h>

int GLFW_KEY_ESCAPE_val     () { return GLFW_KEY_ESCAPE     ; }
int GLFW_PRESS_val          () { return GLFW_PRESS          ; }

void requestCoreContext() {
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
    glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
}

void loadId(GLint location) {
    float id[] = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };
    glUniformMatrix4fv(location, 1, GL_FALSE, id);
}

#ifdef __APPLE__
    char *CURRENT_PLATFORM_STR() { return "apple"; }
#else
    char *CURRENT_PLATFORM_STR() { return ""; }
#endif

]]..
enum_c_patch)


-- copy over everything but the patch from the C stuff
for key, val in pairs(c_inc) do
    if key ~= 'get_gl_enum_constants' and
       key ~= 'CURRENT_PLATFORM_STR' then
        gl[key] = val
    end
end

-- now handle the enum constants

do
    local enum_values = terralib.cast(&c_inc.GLenum,
        C.malloc(#enum_list * terralib.sizeof(c_inc.GLenum)))

    c_inc.get_gl_enum_constants(enum_values)
    for i=1,#enum_list do
        gl[enum_list[i]] = enum_values[i-1]
    end

    C.free(enum_values)
end

-- get the platform string
local platform = ffi.string(c_inc.CURRENT_PLATFORM_STR());




-- do platform specific library location and linking
if platform == 'apple' then
    local glfw_path = nil
    for line in io.popen('mdfind -name libglfw'):lines() do
        local version = string.match(line, 'libglfw(.-)%.dylib')
        if version then
            glfw_path = line
        end
    end
    print('auto-located glfw:')
    print(glfw_path)

    --if not glfw_path then error('could not find glfw*.*.*.dylib', 2) end

    terralib.linklibrary(glfw_path)
else
    error('did not recognize platform')
end


return gl

