import "compiler/liszt"
mesh = L.initMeshRelationsFromFile("examples/mesh.lmesh")

local vk = liszt_kernel(v in mesh.vertices)
    var v = { }
end
vk()
