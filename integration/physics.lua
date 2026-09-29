-- physics.lua — a physics library built on mathx: its sources include mathx's public headers,
-- so whoever builds it passes mathx's record.
local fx = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixture.lua")

return {
    ["manifest.linux.lua"] = fx.manifest { packages = '{ "body" }' },

    ["public/body/api.h"] = [==[
#ifndef PHYSICS_BODY_API_H
#define PHYSICS_BODY_API_H
#include "mathx/public/vec/api.h"
typedef struct ph_body { mx_vec3 pos, vel; } ph_body;
void ph_step(ph_body *b, mx_real dt);
#endif
]==],
    ["public/body/body.c"] = [==[
#include "physics/public/body/api.h"
void ph_step(ph_body *b, mx_real dt) {
    mx_vec3 d = { b->vel.x * dt, b->vel.y * dt, b->vel.z * dt };
    b->pos = mx_add(b->pos, d);
}
]==],
}
