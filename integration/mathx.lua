-- mathx.lua — a math library: public vec (layout depends on MATHX_DOUBLE) and rng, internal simd,
-- and a generated mathx_config.h. Commit v1 predates rng and has manifest version 1.
local fx = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixture.lua")

local GENERATE_CONFIG = [==[function(infra)
        local host, domain = infra.host, infra.domain
        local header = domain.path_join(infra.build_dir, "gen", "mathx", "mathx_config.h")
        if not host.stat(header) then host.write_file(header, "#define MATHX_SIMD_WIDTH 4\n") end
    end]==]

local files = {
    -- vec calls simd, so vec links first
    ["manifest.linux.lua"] = fx.manifest {
        packages = '{ "vec", "simd", "rng" }',
        exports = '{ out_include_dirs = { "gen" } }', preconfigure = GENERATE_CONFIG,
    },

    ["public/vec/api.h"] = [==[
#ifndef MATHX_VEC_API_H
#define MATHX_VEC_API_H
#include "mathx/mathx_config.h"
#ifdef MATHX_DOUBLE
typedef double mx_real;
#else
typedef float mx_real;
#endif
typedef struct mx_vec3 { mx_real x, y, z; } mx_vec3;
mx_vec3 mx_add(mx_vec3 a, mx_vec3 b);
mx_real mx_dot(mx_vec3 a, mx_vec3 b);
#endif
]==],
    ["public/vec/vec.c"] = [==[
#include "mathx/public/vec/api.h"
#include "mathx/internal/simd/api.h"
mx_vec3 mx_add(mx_vec3 a, mx_vec3 b) { mx_vec3 r = { a.x + b.x, a.y + b.y, a.z + b.z }; return r; }
mx_real mx_dot(mx_vec3 a, mx_vec3 b) { return mx_simd_sum3(a.x * b.x, a.y * b.y, a.z * b.z); }
]==],

    ["public/rng/api.h"] = [==[
#ifndef MATHX_RNG_API_H
#define MATHX_RNG_API_H
unsigned mx_rng_next(unsigned *state);
#endif
]==],
    ["public/rng/rng.c"] = [==[
#include "mathx/public/rng/api.h"
unsigned mx_rng_next(unsigned *state) { *state = *state * 1664525u + 1013904223u; return *state; }
]==],

    ["internal/simd/api.h"] = [==[
#ifndef MATHX_SIMD_API_H
#define MATHX_SIMD_API_H
#include "mathx/public/vec/api.h"
mx_real mx_simd_sum3(mx_real a, mx_real b, mx_real c);
#endif
]==],
    ["internal/simd/simd.c"] = [==[
#include "mathx/internal/simd/api.h"
mx_real mx_simd_sum3(mx_real a, mx_real b, mx_real c) { return a + b + c; }
]==],
    ["internal/simd/simd_test.c"] = [==[
#include "mathx/internal/simd/api.h"
int main(void) { return mx_simd_sum3(1, 2, 3) == 6 ? 0 : 1; }
]==],
}

-- v1: before rng existed, when the manifest was at version 1
local v1 = {}
for path, text in pairs(files) do
    if not path:match("^public/rng/") then v1[path] = text end
end
v1["manifest.linux.lua"] = fx.manifest {
    packages = '{ "vec", "simd" }',
    exports = '{ out_include_dirs = { "gen" } }', preconfigure = GENERATE_CONFIG,
}

return { files = files, revisions = { v1 = v1 } }
