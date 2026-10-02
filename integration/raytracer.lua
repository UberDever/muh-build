-- raytracer.lua — an app: cmd/rt and an internal scene package, on mathx in release mode with
-- doubles, plus stb_ds. It installs itself.
local fx = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixture.lua")

return {
    ["manifest.linux.lua"] = fx.manifest { packages = '{ "scene" }' },

    ["internal/scene/api.h"] = [==[
#ifndef RT_SCENE_API_H
#define RT_SCENE_API_H
#include "mathx/public/vec/api.h"
typedef struct rt_sphere { mx_vec3 center; mx_real radius; } rt_sphere;
int rt_scene_count(void);
#endif
]==],
    ["internal/scene/scene.c"] = [==[
#include "raytracer/internal/scene/api.h"
#include "stb_ds.h"
int rt_scene_count(void) { return 1; }
]==],

    ["cmd/rt/main.c"] = [==[
#include "raytracer/internal/scene/api.h"
#include "mathx/public/rng/api.h"
int main(void) { unsigned s = 1; mx_rng_next(&s); return rt_scene_count() == 1 ? 0 : 1; }
]==],

    ["recipe.lua"] = fx.recipe([[
        { repo = "mathx",       as = "mathx",  rev = "working",
          params = { mode = "release", exports = { defines = { "MATHX_DOUBLE" } } } },
        { repo = "stb_ds-0.67", as = "stb_ds", rev = "working" },
]], [[
        local mathx  = repo.build "mathx"
        local stb_ds = repo.build "stb_ds"
        local rt     = repo.project { deps = { mathx, stb_ds } }
        repo.install(rt, "../build/install/raytracer")
        return rt
]]),
}
