-- asset-tool.lua — a command-line tool that stays on mathx v1 (before rng; manifest version 1).
-- Its commit v1 is its own sources as they are; the recipe_self_*.lua recipes require asset-tool itself.
local fx = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixture.lua")

local files = {
    ["manifest.linux.lua"] = fx.manifest {},

    ["cmd/pack/main.c"] = [==[
#include "mathx/public/vec/api.h"
int main(void) { mx_vec3 a = { 1, 2, 3 }; return mx_dot(a, a) > 0 ? 0 : 1; }
]==],

    ["recipe.lua"] = fx.recipe(
        '        { repo = "mathx", as = "mathx", rev = "v1" },\n', [[
        local mathx = repo.build "mathx"
        return repo.project { deps = { mathx } }
]]),
}

local REQ_MATHX = '        { repo = "mathx", as = "mathx", rev = "v1" },\n'

-- the tool at v1 builds packs for the working tree; both are asset-tool
files["recipe_self_tool.lua"] = fx.recipe(REQ_MATHX
    .. '        { repo = "asset-tool", as = "packer", rev = "v1" },\n', [[
        local mathx  = repo.build "mathx"
        local packer = repo.build { "packer", deps = { mathx } }
        local _, said = repo.host.exec({ packer.bins.pack, "packed" }, { capture = true })
        repo.project { deps = { mathx } }
        return { packer = packer, said = said }
]])
-- itself as on disk, in release mode, next to the project build
files["recipe_self_release.lua"] = fx.recipe(REQ_MATHX
    .. '        { repo = "asset-tool", as = "self", rev = "working", params = { mode = "release" } },\n', [[
        local mathx = repo.build "mathx"
        repo.build { "self", deps = { mathx } }
        return repo.project { deps = { mathx } }
]])
-- itself as on disk with no params: the project build is that build
files["recipe_self_same.lua"] = fx.recipe(REQ_MATHX
    .. '        { repo = "asset-tool", as = "self", rev = "working" },\n', [[
        local mathx = repo.build "mathx"
        repo.build { "self", deps = { mathx } }
        return repo.project { deps = { mathx } }
]])
-- a mistake: linking a build of itself into itself
files["recipe_self_dep.lua"] = fx.recipe(REQ_MATHX
    .. '        { repo = "asset-tool", as = "packer", rev = "v1" },\n', [[
        local mathx  = repo.build "mathx"
        local packer = repo.build { "packer", deps = { mathx } }
        return repo.project { deps = { packer, mathx } }
]])

local v1 = {}
for path, text in pairs(files) do v1[path] = text end

return { files = files, revisions = { v1 = v1 } }
