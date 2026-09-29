-- SDL3-3.4.8.lua — vendored SDL 3.4.8 as data. Its cmake build writes libSDL3.a and a generated
-- header, include-revision/SDL3/SDL_revision.h, into the build directory.

return {
    ["manifest.linux.lua"] = [==[
-- SDL3 builds with cmake into the build directory; it generates include-revision/ there.
local CMAKE_MIN_VERSION = "3.16" -- required by SDL3's CMakeLists.txt

return {
    muh_build   = "0.1",
    exports   = {
        include_dirs     = { "include" },
        out_include_dirs = { "include-revision" },
        archives         = { "libSDL3.a" },
    },

    preconfigure = function(infra)
        local host, domain = infra.host, infra.domain
        local _, version = host.exec("cmake --version", { capture = true })
        local cmake = (version or ""):match("(%d+%.%d+[%.%d]*)")
        assert(cmake, "cmake not found; required to build SDL3")
        assert(domain.compare_versions(domain.parse_version(cmake), domain.parse_version(CMAKE_MIN_VERSION)) >= 0,
            "cmake " .. cmake .. " too old; need >= " .. CMAKE_MIN_VERSION)
        if host.stat(domain.path_join(infra.build_dir, "libSDL3.a")) then return end
        local cmd = "cmake -S " .. infra.root .. " -B " .. infra.build_dir
            .. " -DCMAKE_BUILD_TYPE=Debug -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF"
            .. " -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL=OFF"
            .. " && cmake --build " .. infra.build_dir .. " --parallel"
        infra.log("vendor_lib", cmd)
        assert(host.exec(cmd), "building SDL3 failed: " .. cmd)
    end,
}
]==],

    ["CMakeLists.txt"] = [==[
cmake_minimum_required(VERSION 3.16)
# Fake CMakeLists.txt: `cmake --build` writes what it declares.
# mock-output: libSDL3.a
# mock-output: include-revision/SDL3/SDL_revision.h
]==],

    ["include/SDL3/SDL.h"] = [==[
#ifndef SDL_h_
#define SDL_h_
#include <SDL3/SDL_revision.h>
#include <SDL3/SDL_rect.h>
int SDL_GetVersion(void);
#endif
]==],

    ["include/SDL3/SDL_rect.h"] = [==[
#ifndef SDL_rect_h_
#define SDL_rect_h_
typedef struct SDL_Rect { int x, y, w, h; } SDL_Rect;
#endif
]==],

    ["src/SDL.c"] = [==[
#include <SDL3/SDL.h>
int SDL_GetVersion(void) { return 3004008; }
]==],
}
