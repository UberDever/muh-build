-- muh-game.lua — the muh-game project as data: path (relative to the project root) -> contents.
-- Its recipe builds the vendored SDL3, Lua and stb_ds, each by its own manifest, then the game.

return {
    ["cmd/game/main.c"] = [==[
#include "muh-game/internal/ecs/api.h"
#include "muh-game/internal/game/api.h"

int main(void) { return game_sdl_version() > 0 ? ecs_component_count() : 1; }
]==],

    ["internal/ecs/api.h"] = [==[
#ifndef ECS_API_H
#define ECS_API_H

int ecs_component_count(void);

#endif
]==],

    ["internal/ecs/component.c"] = [==[
#include "muh-game/internal/ecs/api.h"

int ecs_component_count(void) { return 0; }
]==],

    ["internal/functional/functional_test.c"] = [==[
#include "muh-game/internal/ecs/api.h"

int main(void) { return ecs_component_count(); }
]==],

    ["internal/game/api.h"] = [==[
#ifndef GAME_API_H
#define GAME_API_H

int game_sdl_version(void);

#endif
]==],

    ["internal/game/game.c"] = [==[
#include "muh-game/internal/game/impl.h"

int game_sdl_version(void) { return SDL_GetVersion(); }
]==],

    ["internal/game/game_test.c"] = [==[
#include "muh-game/internal/game/impl.h"

int main(void) { return game_sdl_version() > 0 ? 0 : 1; }
]==],

    ["internal/game/impl.h"] = [==[
#ifndef GAME_IMPL_H
#define GAME_IMPL_H

#include "muh-game/internal/game/api.h"
#include <SDL3/SDL.h>

#endif
]==],

    ["internal/headeronly/stb_ds.c"] = [==[
#define STB_DS_IMPLEMENTATION
#include "stb_ds.h"
]==],

    ["internal/scripting/api.h"] = [==[
#ifndef SCRIPTING_API_H
#define SCRIPTING_API_H

void scripting_run(void);

#endif
]==],

    ["internal/scripting/scripting.c"] = [==[
#include "muh-game/internal/scripting/api.h"
#include "lua.h"
#include "lauxlib.h"

void scripting_run(void) { lua_close(luaL_newstate()); }
]==],

    ["manifest.linux.lua"] = [==[
local CC      = "clang"
local AR      = "ar"
local ARFLAGS = "rcs"

local MODES   = {
    dev = {
        cflags = { "-O0", "-g3", "-fsanitize=address,undefined", "-std=c99", "-Wall", "-Wextra", "-Werror" },
        ldflags = { "-fsanitize=address,undefined" },
    },
    release = {
        cflags = { "-O2", "-DNDEBUG", "-std=c99" },
        ldflags = {},
    },
}

---@type Manifest
return {
    muh_build     = "0.1",
    packages    = { "ecs", "game", "headeronly", "scripting", "functional" },
    mode        = "dev",
    system_libs = { "-lm", "-ldl", "-lpthread" },

    compile_cmd = function(out, src, extra_args, m)
        local parts = { CC, table.unpack(MODES[m.mode].cflags) }
        for _, a in ipairs(extra_args or {}) do parts[#parts + 1] = a end
        for _, a in ipairs { "-MMD", "-MF", out .. ".d", "-MT", out, "-c", src, "-o", out } do
            parts[#parts + 1] = a
        end
        return table.concat(parts, " ")
    end,

    link_cmd = function(out, ins, extra_args, m)
        local parts = { CC, table.unpack(MODES[m.mode].ldflags) }
        for _, i in ipairs(ins) do parts[#parts + 1] = i end
        parts[#parts + 1] = "-o"
        parts[#parts + 1] = out
        for _, a in ipairs(extra_args or {}) do parts[#parts + 1] = a end
        return table.concat(parts, " ")
    end,

    archive_cmd = function(out, ins)
        return AR .. " " .. ARFLAGS .. " " .. out .. " " .. table.concat(ins, " ")
    end,
}
]==],

    ["recipe.lua"] = [==[
return {
    muh_build = "0.1",
    requires = {
        { repo = "SDL3-3.4.8",  as = "sdl",    rev = "working" },
        { repo = "lua-5.5.0",   as = "lua",    rev = "working" },
        { repo = "stb_ds-0.67", as = "stb_ds", rev = "working" },
    },

    run = function(repo)
        local sdl    = repo.build "sdl"
        local lua    = repo.build "lua"
        local stb_ds = repo.build "stb_ds"
        local game   = repo.project { deps = { lua, sdl, stb_ds } }
        repo.install(game, "build/install")
        return game
    end,
}
]==],
}
