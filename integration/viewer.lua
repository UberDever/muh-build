-- viewer.lua — an app requiring mathx exactly as sandbox does (working, no params):
-- the two share one mathx build.
local fx = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixture.lua")

return {
    ["manifest.linux.lua"] = fx.manifest {},

    ["cmd/view/main.c"] = [==[
#include "mathx/public/vec/api.h"
int main(void) { mx_vec3 a = { 1, 0, 0 }; return mx_dot(a, a) == 1 ? 0 : 1; }
]==],

    ["recipe.lua"] = fx.recipe(
        '        { repo = "mathx", as = "mathx", rev = "working" },\n', [[
        local mathx = repo.build "mathx"
        return repo.project { deps = { mathx } }
]]),
}
