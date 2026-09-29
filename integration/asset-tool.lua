-- asset-tool.lua — a command-line tool that stays on mathx v1 (before rng; manifest version 1).
local fx = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixture.lua")

return {
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
