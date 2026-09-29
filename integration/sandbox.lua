-- sandbox.lua — an app using physics and mathx. Its recipe builds mathx, then physics against it,
-- then itself. The other recipes are realistic mistakes, each refused.
local fx = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixture.lua")

local MATHX   = '        { repo = "mathx",   as = "mathx",   rev = "working" },\n'
local PHYSICS = '        { repo = "physics", as = "physics", rev = "working" },\n'

return {
    ["manifest.linux.lua"] = fx.manifest {},

    ["cmd/sandbox/main.c"] = [==[
#include "physics/public/body/api.h"
int main(void) { ph_body b = { { 0, 0, 0 }, { 1, 0, 0 } }; ph_step(&b, 1); return b.pos.x == 1 ? 0 : 1; }
]==],

    ["recipe.lua"] = fx.recipe(MATHX .. PHYSICS, [[
        local mathx   = repo.build "mathx"
        local physics = repo.build { "physics", deps = { mathx } }
        return repo.project { deps = { physics, mathx } }
]]),

    -- builds physics without declaring it
    ["recipe_forgot_physics.lua"] = fx.recipe(MATHX, [[
        local mathx = repo.build "mathx"
        return repo.build { "physics", deps = { mathx } }
]]),

    -- wants the current mathx for itself and the old one for physics: two versions in one link
    ["recipe_two_mathx.lua"] = fx.recipe(MATHX .. PHYSICS
        .. '        { repo = "mathx", as = "mathx_v1", rev = "v1" },\n', "        return nil\n"),

    -- written for a muh-build newer than this one
    ["recipe_new_muh_build.lua"] = fx.recipe(MATHX, "        return nil\n"):gsub('muh_build = "0.1"', 'muh_build = "9.0"'),

    -- a revision that was never made
    ["recipe_future_rev.lua"] = fx.recipe(
        '        { repo = "mathx", as = "mathx", rev = "v3" },\n', "        return nil\n"),

    -- a repo that is not in the workspace
    ["recipe_missing_repo.lua"] = fx.recipe(MATHX
        .. '        { repo = "audio", as = "audio", rev = "working" },\n', "        return nil\n"),

    -- a misspelt param
    ["recipe_bad_param.lua"] = fx.recipe(
        '        { repo = "mathx", as = "mathx", rev = "working", params = { mdoe = "release" } },\n', [[
        return repo.build "mathx"
]]),

    -- a param that would change which muh-build the manifest is written for
    ["recipe_param_muh_build.lua"] = fx.recipe(
        '        { repo = "mathx", as = "mathx", rev = "working", params = { muh_build = "0.0" } },\n', [[
        return repo.build "mathx"
]]),

    -- mathx without its rng package: sandbox needs only vec
    ["recipe_no_rng.lua"] = fx.recipe(
        '        { repo = "mathx",   as = "mathx",   rev = "working", params = { packages = { "vec", "simd" } } },\n'
        .. PHYSICS, [[
        local mathx   = repo.build "mathx"
        local physics = repo.build { "physics", deps = { mathx } }
        return repo.project { deps = { physics, mathx } }
]]),

    -- builds mathx twice with different inputs
    ["recipe_mathx_twice.lua"] = fx.recipe(MATHX .. PHYSICS, [[
        local mathx   = repo.build "mathx"
        local physics = repo.build { "physics", deps = { mathx } }
        return repo.build { "mathx", deps = { physics } }
]]),
}
