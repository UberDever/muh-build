-- lua-5.5.0.lua — vendored Lua 5.5.0 as data. onelua.c compiles all of Lua as one unit;
-- with MAKE_LIB it is the library only.

return {
    ["manifest.linux.lua"] = [==[
-- Lua has no packages: its build is one external step, compiling onelua.c into the build directory.
return {
    muh_build   = "0.1",
    exports   = { include_dirs = { "." }, archives = { "liblua.a" } },

    preconfigure = function(infra)
        local host, domain = infra.host, infra.domain
        local lib = domain.path_join(infra.build_dir, "liblua.a")
        if host.stat(lib) then return end
        local obj = domain.path_join(infra.build_dir, "onelua.o")
        local cmd = "cc -O2 -std=c99 -DMAKE_LIB -c " .. domain.path_join(infra.root, "onelua.c") .. " -o " .. obj
            .. " && ar rcs " .. lib .. " " .. obj
        host.mkdir_p(infra.build_dir)
        infra.log("vendor_lib", cmd)
        assert(host.exec(cmd), "building lua failed: " .. cmd)
    end,
}
]==],

    ["onelua.c"] = [==[
#include "lapi.c"
]==],

    ["luaconf.h"] = [==[
#ifndef luaconf_h
#define luaconf_h
#define LUA_API extern
#endif
]==],

    ["lua.h"] = [==[
#ifndef lua_h
#define lua_h
#include "luaconf.h"
typedef struct lua_State lua_State;
LUA_API void lua_close(lua_State *L);
#endif
]==],

    ["lauxlib.h"] = [==[
#ifndef lauxlib_h
#define lauxlib_h
#include "lua.h"
LUA_API lua_State *luaL_newstate(void);
#endif
]==],

    ["lualib.h"] = [==[
#ifndef lualib_h
#define lualib_h
#include "lua.h"
LUA_API void luaL_openlibs(lua_State *L);
#endif
]==],

    ["lapi.c"] = [==[
#include "lua.h"
void lua_close(lua_State *L) { (void)L; }
]==],
}
