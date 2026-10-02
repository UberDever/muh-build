#!/usr/bin/env lua
-- runner.lua — integration tests: builds the projects of a mock workspace through their recipes.
-- It is the entry point: it loads every module and passes them down.
--
-- Usage:  lua integration/runner.lua

local HERE     = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local SCRIPTS  = HERE .. "../scripts/"

local domain   = dofile(SCRIPTS .. "domain.lua")
local project  = dofile(SCRIPTS .. "project.lua")
local repo     = dofile(SCRIPTS .. "repo.lua")
local mock     = dofile(HERE .. "mock_host.lua")

local fixtures = dofile(HERE .. "workspace.lua")
local PROJECTS = fixtures.load()

local WS = "/ws" -- the workspace inside the mock

-- ── Harness ────────────────────────────────────────────────────────────────

local PASS, FAIL = 0, 0

local function check(desc, ok, detail)
    if ok then
        PASS = PASS + 1
        print("  PASS: " .. desc)
    else
        FAIL = FAIL + 1
        print("  FAIL: " .. desc)
        if detail then print("    " .. tostring(detail)) end
    end
end

--- A fresh mock host holding every project under WS.
---@param tools table?  tool overrides
---@param coarse boolean?  a clock that moves only on host.tick()
local function workspace(tools, coarse)
    local host = mock.new { domain = domain, cwd = WS, tools = mock.tools(tools), coarse = coarse }
    fixtures.write(host, domain, WS, PROJECTS, host.add_revision)
    return host
end

--- Paths written since write number `first` that are not under the workspace's or a repo's build/.
local function written_outside_build(host, first)
    local bad = {}
    for i = first, #host.writes do
        local p = host.writes[i]
        if not (p:match("^" .. WS .. "/[^/]+/build/") or p:match("^" .. WS .. "/build/")) then bad[#bad + 1] = p end
    end
    return bad
end

--- Run a project's recipe; returns ok, the recipe's result or error, and the commands it executed.
local function run(host, name, recipe_file)
    local first = #host.commands + 1
    local ok, result = pcall(repo.run, {
        host = host,
        domain = domain,
        project = project,
        recipe = domain.path_join(WS, name, recipe_file or "recipe.lua"),
        log = function() end,
    })
    return ok, result, table.move(host.commands, first, #host.commands, 1, {})
end

--- The commands containing `text` literally.
local function containing(cmds, text)
    local found = {}
    for _, c in ipairs(cmds) do if c:find(text, 1, true) then found[#found + 1] = c end end
    return found
end

local function matching(cmds, pattern)
    local found = {}
    for _, c in ipairs(cmds) do if c:match(pattern) then found[#found + 1] = c end end
    return found
end

--- Outputs of the compile commands, sorted.
local function compiled(cmds)
    local outs = {}
    for _, c in ipairs(matching(cmds, "^clang .* %-c ")) do outs[#outs + 1] = c:match(" %-o (%S+)") end
    table.sort(outs)
    return outs
end

local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

--- The build directories of `repo` at `rev` under the workspace's build/.
local function builds_of(host, repo_name, rev)
    local found, prefix = {}, WS .. "/build/" .. repo_name .. "@" .. rev .. "-"
    for path in pairs(host.files) do
        local dir = path:sub(1, #prefix) == prefix and path:match("^(" .. WS .. "/build/[^/]+)/")
        if dir then found[dir] = true end
    end
    return domain.sorted_keys(found)
end

--- The one build directory of `repo` at `rev`, or nil when there is none or several.
local function dep_dir(host, repo_name, rev)
    local found = builds_of(host, repo_name, rev or "working")
    return #found == 1 and found[1] or nil
end

-- ── muh-game ───────────────────────────────────────────────────────────────

print("=== muh-game ===")
do
    local host = workspace()
    local OUT -- the project's own build, <ws>/build/muh-game@working-<hash>/out, once it exists
    local LUA, SDL = WS .. "/lua-5.5.0", WS .. "/SDL3-3.4.8"

    local first_write = #host.writes + 1
    local ok, rec, cmds = run(host, "muh-game")
    check("clean build succeeds", ok, rec)
    OUT = (dep_dir(host, "muh-game") or "?") .. "/out"
    -- each required repo builds under the workspace's build/<repo>@<rev>-<hash>/
    local lua_dir = dep_dir(host, "lua-5.5.0")
    check("required repos build under <workspace>/build/<repo>@working-<hash>",
        lua_dir and lua_dir:match("^" .. WS .. "/build/lua%-5%.5%.0@working%-%x%x%x%x%x%x%x%x$"), lua_dir)
    local LUA_OUT = (lua_dir or "?") .. "/out"
    local SDL_OUT = (dep_dir(host, "SDL3-3.4.8") or "?") .. "/out"
    local outside = written_outside_build(host, first_write)
    check("nothing is written outside build directories", #outside == 0, table.concat(outside, " "))
    rec = ok and rec or { bins = {}, archives = {} }
    check("record names the repo", rec.repo == "muh-game", rec.repo)
    check("record lists bin game", rec.bins.game == OUT .. "/bin/game", rec.bins.game)

    -- vendored libraries
    check("SDL3's manifest checks cmake first", cmds[1] == "cmake --version", cmds[1])
    local sdl_cmd = containing(cmds, "cmake -S " .. SDL .. " -B " .. SDL_OUT .. " ")
    check("SDL3 is configured and built by cmake into its build directory", #sdl_cmd == 1
        and sdl_cmd[1]:find("-DSDL_STATIC=ON", 1, true)
        and sdl_cmd[1]:find(" && cmake --build " .. SDL_OUT .. " --parallel", 1, true), sdl_cmd[1])
    check("lua is compiled from its sources into its build directory", #containing(cmds,
        "cc -O2 -std=c99 -DMAKE_LIB -c " .. LUA .. "/onelua.c -o " .. LUA_OUT .. "/onelua.o && ar rcs "
        .. LUA_OUT .. "/liblua.a " .. LUA_OUT .. "/onelua.o") == 1)
    check("required repos build in declaration order, before the project",
        cmds[2]:match("^cmake %-S ") and cmds[3]:match("onelua%.c"), cmds[2] .. " | " .. cmds[3])

    -- the project
    local compiles = matching(cmds, "^clang .* %-c ")
    check("7 compiles", #compiles == 7, #compiles)
    check("4 archives", #matching(cmds, "^ar rcs ") == 4)
    local links = #matching(cmds, "^clang ") - #compiles
    check("3 links", links == 3, links)
    local inc = { WS, LUA, SDL .. "/include", SDL_OUT .. "/include-revision", WS .. "/stb_ds-0.67" }
    for _, dir in ipairs(inc) do
        check("every compile gets -I" .. dir, #containing(compiles, " -I" .. dir .. " ") == 7)
    end
    check("dev mode flags", #matching(compiles, " %-fsanitize=address,undefined ") == 7)
    local game_link = containing(cmds, " -o " .. OUT .. "/bin/game ")[1] or ""
    check("game links own archives, then lua and SDL3, then system libs",
        game_link:find(OUT .. "/lib/libscripting.a " .. LUA_OUT .. "/liblua.a "
            .. SDL_OUT .. "/libSDL3.a -o " .. OUT .. "/bin/game -lm -ldl -lpthread", 1, true), game_link)
    for _, bin in ipairs { "game", "game_test", "functional_test" } do
        check("bin/" .. bin .. " exists", host.stat(OUT .. "/bin/" .. bin) ~= nil)
    end
    check("game is installed", host.stat(WS .. "/build/install/muh-game/bin/game") ~= nil)

    local dep = host.read_file(OUT .. "/objs/internal/game/game.o.d") or ""
    check("game.o depfile lists the generated SDL_revision.h",
        dep:find(SDL_OUT .. "/include-revision/SDL3/SDL_revision.h", 1, true), dep)
    dep = host.read_file(OUT .. "/objs/internal/scripting/scripting.o.d") or ""
    check("scripting.o depfile lists lua.h and luaconf.h",
        dep:find(LUA .. "/lua.h", 1, true) and dep:find(LUA .. "/luaconf.h", 1, true), dep)

    local db = host.read_file(WS .. "/muh-game/build/compile_commands.json") or ""
    local _, entries = db:gsub('"file":', "")
    check("compile_commands.json has 7 entries", entries == 7, entries)

    -- rebuilds
    _, _, cmds = run(host, "muh-game")
    check("unchanged rebuild runs only the cmake check", same(cmds, { "cmake --version" }), table.concat(cmds, "\n    "))

    host.touch(WS .. "/muh-game/internal/game/impl.h")
    _, _, cmds = run(host, "muh-game")
    check("editing impl.h recompiles game.c and game_test.c only",
        same(compiled(cmds), { OUT .. "/objs/internal/game/game.o", OUT .. "/objs/internal/game/game_test.o" }),
        table.concat(compiled(cmds), " "))

    host.touch(SDL .. "/include/SDL3/SDL_rect.h")
    _, _, cmds = run(host, "muh-game")
    check("editing an SDL3 header recompiles game.c and game_test.c only",
        same(compiled(cmds), { OUT .. "/objs/internal/game/game.o", OUT .. "/objs/internal/game/game_test.o" }),
        table.concat(compiled(cmds), " "))

    host.touch(WS .. "/muh-game/internal/ecs/api.h")
    _, _, cmds = run(host, "muh-game")
    check("editing ecs/api.h recompiles its includers", same(compiled(cmds), {
        OUT .. "/objs/cmd/game/main.o",
        OUT .. "/objs/internal/ecs/component.o",
        OUT .. "/objs/internal/functional/functional_test.o",
    }), table.concat(compiled(cmds), " "))

    host.remove(LUA_OUT .. "/liblua.a")
    _, _, cmds = run(host, "muh-game")
    check("a missing vendor sentinel rebuilds that library only",
        #matching(cmds, "onelua%.c") == 1 and #matching(cmds, "^cmake %-S ") == 0)
end

print("=== muh-game with an old cmake ===")
do
    local host = workspace { cmake = mock.make_fake_cmake("3.10.2") }
    local ok, err, cmds = run(host, "muh-game")
    check("SDL3's manifest refuses it", not ok and tostring(err):find("cmake 3.10.2 too old", 1, true), err)
    check("nothing is built", #cmds == 1, table.concat(cmds, "\n    "))
end

--- Positions (in cmds) of the compile commands whose output lies under `dir`.
local function compile_positions(cmds, dir)
    local at = {}
    for i, c in ipairs(cmds) do
        if c:match("^clang .* %-c ") and c:find(" -o " .. dir, 1, true) then at[#at + 1] = i end
    end
    return at
end

-- ── raytracer: an app on mathx in release mode with doubles ────────────────

print("=== raytracer ===")
do
    local host = workspace()
    local first_write = #host.writes + 1
    local ok, rec, cmds = run(host, "raytracer")
    check("builds", ok, rec)
    local OUT = (dep_dir(host, "raytracer") or "?") .. "/out"
    check("nothing is written outside build directories", #written_outside_build(host, first_write) == 0,
        table.concat(written_outside_build(host, first_write), " "))
    local MX = (dep_dir(host, "mathx") or "?") .. "/out"

    -- mathx: a library-only repo, all its packages built, by its own manifest with the recipe's params
    for _, obj in ipairs { "public/vec/vec", "public/rng/rng", "internal/simd/simd" } do
        check("mathx compiles " .. obj .. ".c", host.stat(MX .. "/objs/" .. obj .. ".o") ~= nil)
    end
    check("mathx builds its test too", host.stat(MX .. "/bin/simd_test") ~= nil)
    local mx = containing(cmds, " -o " .. MX .. "/objs/")
    check("params reach mathx: release mode", #mx == 4 and #matching(mx, " %-O2 ") == 4, #mx)
    check("mathx's interface define applies to its own sources", #containing(mx, " -DMATHX_DOUBLE ") == 4)

    -- raytracer: its own mode, mathx's interface, generated header and archives
    local rt = containing(cmds, " -o " .. OUT .. "/objs/")
    check("raytracer compiles in its own dev mode", #rt == 2 and #matching(rt, " %-O0 ") == 2, #rt)
    check("mathx's interface define reaches raytracer", #containing(rt, " -DMATHX_DOUBLE ") == 2)
    check("mathx's generated headers reach raytracer", #containing(rt, " -I" .. MX .. "/gen ") == 2)
    local dep = host.read_file(OUT .. "/objs/internal/scene/scene.o.d") or ""
    check("scene.c sees mathx_config.h and stb_ds.h",
        dep:find(MX .. "/gen/mathx/mathx_config.h", 1, true) and dep:find(WS .. "/stb_ds-0.67/stb_ds.h", 1, true), dep)
    local link = containing(cmds, " -o " .. OUT .. "/bin/rt")[1] or ""
    check("rt links its scene library, then mathx's archives in mathx's order",
        link:find(OUT .. "/lib/libscene.a " .. MX .. "/lib/libvec.a " .. MX .. "/lib/libsimd.a "
            .. MX .. "/lib/librng.a", 1, true), link)

    -- install: the app's executable and archives; its public headers (it has none)
    local INST = WS .. "/build/install/raytracer"
    check("rt is installed", host.stat(INST .. "/bin/rt") ~= nil)
    check("raytracer's own archive is installed", host.stat(INST .. "/lib/libscene.a") ~= nil)
    check("internal headers are not installed", host.stat(INST .. "/include") == nil)

    _, _, cmds = run(host, "raytracer")
    check("unchanged rebuild runs nothing", #cmds == 0, table.concat(cmds, "\n    "))
end

-- ── sandbox: an app on physics, which is built on mathx ────────────────────

print("=== sandbox ===")
do
    local host = workspace()
    local ok, rec, cmds = run(host, "sandbox")
    check("builds", ok, rec)
    local OUT = (dep_dir(host, "sandbox") or "?") .. "/out"
    local MX = (dep_dir(host, "mathx") or "?") .. "/out"
    local PH = (dep_dir(host, "physics") or "?") .. "/out"

    local mx_at, ph_at, sb_at = compile_positions(cmds, MX), compile_positions(cmds, PH), compile_positions(cmds, OUT .. "/objs")
    check("mathx, then physics, then sandbox, as the recipe says",
        #mx_at > 0 and #ph_at > 0 and #sb_at > 0 and mx_at[#mx_at] < ph_at[1] and ph_at[#ph_at] < sb_at[1])
    local body = containing(cmds, " -o " .. PH .. "/objs/public/body/body.o")[1] or ""
    check("physics compiles against mathx's record", body:find(" -I" .. MX .. "/gen ", 1, true), body)
    local dep = host.read_file(PH .. "/objs/public/body/body.o.d") or ""
    check("physics includes mathx's public header", dep:find(WS .. "/mathx/public/vec/api.h", 1, true), dep)
    local link = containing(cmds, " -o " .. OUT .. "/bin/sandbox")[1] or ""
    check("sandbox links physics before mathx", link:find(PH .. "/lib/libbody.a " .. MX .. "/lib/libvec.a", 1, true), link)
end

-- ── asset-tool: pinned to mathx v1 ─────────────────────────────────────────

print("=== asset-tool on mathx v1 ===")
do
    local host = workspace()
    local first_write = #host.writes + 1
    local ok, rec, cmds = run(host, "asset-tool")
    check("builds", ok, rec)
    local OUT = (dep_dir(host, "asset-tool") or "?") .. "/out"
    local base = dep_dir(host, "mathx", "v1") or "?"
    check("the build directory names the revision", base:match("/mathx@v1%-%x%x%x%x%x%x%x%x$"), base)
    check("the revision is checked before anything else", cmds[1] == "git -C " .. WS .. "/mathx cat-file -e v1^{commit}", cmds[1])
    check("mathx v1 is checked out into the build directory",
        cmds[2] == "git -C " .. WS .. "/mathx worktree add --quiet --detach " .. base .. "/src/mathx v1", cmds[2])
    check("mathx compiles from the checkout", #containing(cmds, " -c " .. base .. "/src/mathx/public/vec/vec.c ") == 1)
    check("v1 has no rng", host.stat(base .. "/out/lib/librng.a") == nil and host.stat(base .. "/out/lib/libvec.a") ~= nil)
    local dep = host.read_file(OUT .. "/objs/cmd/pack/main.o.d") or ""
    check("pack includes mathx from the checkout, not the working tree",
        dep:find(base .. "/src/mathx/public/vec/api.h", 1, true) and not dep:find(WS .. "/mathx/public/", 1, true), dep)
    check("nothing is written outside build directories", #written_outside_build(host, first_write) == 0,
        table.concat(written_outside_build(host, first_write), " "))
end

-- ── one workspace, two apps, two versions of mathx ─────────────────────────

print("=== raytracer and asset-tool side by side ===")
do
    local host = workspace()
    check("raytracer builds", (run(host, "raytracer")))
    check("asset-tool builds", (run(host, "asset-tool")))
    local rt_mx, at_mx = dep_dir(host, "mathx"), dep_dir(host, "mathx", "v1")
    check("each app has its own mathx build", rt_mx and at_mx and rt_mx ~= at_mx, tostring(rt_mx) .. " " .. tostring(at_mx))

    -- someone edits mathx's working tree
    host.touch(WS .. "/mathx/public/vec/api.h")
    local _, _, cmds = run(host, "raytracer")
    local RT = (dep_dir(host, "raytracer") or "?") .. "/out"
    -- main.c includes scene/api.h, which includes vec/api.h: it depends on the edit too
    check("raytracer rebuilds mathx's includers of vec and its own",
        same(compiled(cmds), {
            rt_mx .. "/out/objs/internal/simd/simd.o",
            rt_mx .. "/out/objs/internal/simd/simd_test.o",
            rt_mx .. "/out/objs/public/vec/vec.o",
            RT .. "/objs/cmd/rt/main.o",
            RT .. "/objs/internal/scene/scene.o",
        }), table.concat(compiled(cmds), " "))
    check("and re-archives what they changed", #containing(cmds, "ar rcs " .. rt_mx .. "/out/lib/libvec.a ") == 1
        and #containing(cmds, "ar rcs " .. RT .. "/lib/libscene.a ") == 1)
    check("and relinks rt", #containing(cmds, " -o " .. RT .. "/bin/rt") == 1)
    _, _, cmds = run(host, "asset-tool")
    check("asset-tool, pinned to v1, rebuilds nothing", #cmds == 1 and cmds[1]:match("cat%-file"), table.concat(cmds, "\n    "))
end

-- ── what makes a build: shared when equal, new when the manifest changes ──

print("=== builds are shared by identity ===")
do
    local host = workspace()
    check("sandbox builds", (run(host, "sandbox")))
    local _, _, cmds = run(host, "viewer")
    local MX = dep_dir(host, "mathx")
    check("viewer asks for mathx as sandbox did: the same build, nothing recompiled",
        MX and #compile_positions(cmds, MX .. "/") == 0, table.concat(compiled(cmds), " "))
    check("viewer links that build", #containing(cmds, " " .. (MX or "?") .. "/out/lib/libvec.a ") == 1)

    -- raytracer asks for mathx with other params: another build
    check("raytracer builds", (run(host, "raytracer")))
    check("other params make another mathx build", #builds_of(host, "mathx", "working") == 2)

    -- someone changes mathx's working manifest: every build on top of it gets a new name
    local mpath = WS .. "/mathx/manifest.linux.lua"
    local physics_before = dep_dir(host, "physics")
    host.write_file(mpath, host.read_file(mpath) .. "-- edited\n")
    _, _, cmds = run(host, "sandbox")
    check("an edited manifest makes a new mathx build",
        #builds_of(host, "mathx", "working") == 3 and #compile_positions(cmds, WS .. "/build/mathx@") > 0)
    local physics_after = builds_of(host, "physics", "working")
    check("and a new physics build, since it is built on mathx",
        #physics_after == 2 and physics_before ~= nil, table.concat(physics_after, " "))
    check("the edit invalidates nothing in place: the old builds remain", host.stat(physics_before or "?") ~= nil)
end

-- ── the project itself is a build like any other ──────────────────────────

print("=== the project builds by the same identity ===")
do
    local host = workspace()
    local ok, rec = run(host, "viewer")
    check("viewer builds", ok, rec)
    local VW = dep_dir(host, "viewer")
    check("into <ws>/build/viewer@working-<hash>", VW and VW:match("/viewer@working%-%x%x%x%x%x%x%x%x$"), VW)
    local info = load(host.read_file((VW or "?") .. "/build-info.lua") or "return nil")()
    check("with a build-info.lua like any build", info and info.repo == "viewer" and info.rev == "working"
        and info.deps[1] == (dep_dir(host, "mathx") or "?"):match("[^/]+$"), info and domain.serialize(info))
    local own, prefix = {}, WS .. "/viewer/build/"
    for path in pairs(host.files) do
        if path:sub(1, #prefix) == prefix then own[#own + 1] = path end
    end
    check("viewer/build/ holds only the compile database",
        #own == 1 and own[1] == WS .. "/viewer/build/compile_commands.json", table.concat(own, " "))

    -- someone changes viewer's own manifest: a new build, from scratch
    local mpath = WS .. "/viewer/manifest.linux.lua"
    host.write_file(mpath, host.read_file(mpath) .. "-- edited\n")
    local _, _, cmds = run(host, "viewer")
    local after = builds_of(host, "viewer", "working")
    local NEW = after[1] == VW and after[2] or after[1]
    check("an edited project manifest makes a new project build", #after == 2, table.concat(after, " "))
    check("which compiles all its sources", same(compiled(cmds), { (NEW or "?") .. "/out/objs/cmd/view/main.o" }),
        table.concat(compiled(cmds), " "))

    ok, rec = run(host, "viewer", "recipe_release.lua")
    check("repo.project takes params", ok, rec)
    local release
    for _, dir in ipairs(builds_of(host, "viewer", "working")) do
        local i = load(host.read_file(dir .. "/build-info.lua") or "return nil")()
        if i and i.params and i.params.mode == "release" then release = dir end
    end
    check("they make another project build, recorded in its build-info.lua", release ~= nil
        and #builds_of(host, "viewer", "working") == 3)
    check("and reach the manifest's commands",
        #containing(host.commands, "clang -O2 -DNDEBUG -std=c99 ") > 0
        and #containing(host.commands, " -o " .. (release or "?") .. "/out/objs/cmd/view/main.o") == 1)
end

print("=== a recipe may require its own repo ===")
do
    local host = workspace()
    local ok, rec = run(host, "asset-tool", "recipe_self_tool.lua")
    check("asset-tool builds its v1 as a tool", ok, rec)
    local PIN, OWN = dep_dir(host, "asset-tool", "v1"), dep_dir(host, "asset-tool")
    check("the pinned tool and the project are two builds", PIN and OWN and PIN ~= OWN,
        tostring(PIN) .. " " .. tostring(OWN))
    check("the tool is the pinned build's program",
        ok and rec.bins and rec.bins.pack == (PIN or "?") .. "/out/bin/pack", ok and domain.serialize(rec.bins))

    host = workspace()
    ok, rec = run(host, "asset-tool", "recipe_self_release.lua")
    check("itself as on disk with other params builds", ok, rec)
    check("next to the project build: two folders", #builds_of(host, "asset-tool", "working") == 2,
        table.concat(builds_of(host, "asset-tool", "working"), " "))

    host = workspace()
    ok, rec = run(host, "asset-tool", "recipe_self_same.lua")
    check("itself as on disk with the same params builds", ok, rec)
    check("as the project build: one folder", #builds_of(host, "asset-tool", "working") == 1,
        table.concat(builds_of(host, "asset-tool", "working"), " "))
    check("compiled once", #containing(host.commands, "/cmd/pack/main.c ") == 1)

    host = workspace()
    local err, cmds
    ok, err, cmds = run(host, "asset-tool", "recipe_self_dep.lua")
    check("linking a build of itself into the project is refused",
        not ok and tostring(err):find("repo asset-tool cannot depend on a build of itself", 1, true), err)
    check("before the project compiles anything", #containing(cmds, WS .. "/asset-tool/cmd/pack/main.c") == 0
        and #containing(cmds, "/src/asset-tool/cmd/pack/main.c") == 1, table.concat(compiled(cmds), " "))
end

-- ── params, build info, compile database ───────────────────────────────────

print("=== params can leave a package out ===")
do
    local host = workspace()
    local ok, rec = run(host, "sandbox", "recipe_no_rng.lua")
    check("sandbox builds on mathx without rng", ok, rec)
    local MX = (dep_dir(host, "mathx") or "?") .. "/out"
    check("rng is not built", host.stat(MX .. "/lib/librng.a") == nil and host.stat(MX .. "/lib/libvec.a") ~= nil)
end

print("=== every build says how it was built ===")
do
    local host = workspace()
    check("sandbox builds", (run(host, "sandbox")))
    local MX, PH = dep_dir(host, "mathx"), dep_dir(host, "physics")
    local function info(dir) return load(host.read_file(dir .. "/build-info.lua") or "return nil")() end
    local mx, ph = info(MX or "?"), info(PH or "?")
    check("build-info.lua is a Lua term", mx and ph)
    check("it names the build, its repo, revision and manifest", mx and mx.name == MX:match("[^/]+$")
        and mx.repo == "mathx" and mx.rev == "working" and mx.manifest == "manifest.linux.lua",
        mx and domain.serialize(mx))
    check("the hash of a working manifest's text", mx and mx.manifest_hash == domain.hash(host.read_file(WS .. "/mathx/manifest.linux.lua")))
    check("and the builds it depends on", ph and ph.deps[1] == MX:match("[^/]+$"), ph and domain.serialize(ph.deps))

    local ok, rec = run(host, "raytracer")
    check("raytracer builds", ok, rec)
    local rinfo = info(builds_of(host, "mathx", "working")[2] or "?")
    local any_release = false
    for _, dir in ipairs(builds_of(host, "mathx", "working")) do
        local i = info(dir)
        if i and i.params.mode == "release" then any_release = true end
    end
    check("and the params it was built with", any_release, rinfo and domain.serialize(rinfo))
end

print("=== one compile database per project ===")
do
    local host = workspace()
    check("raytracer builds", (run(host, "raytracer")))
    local db = host.read_file(WS .. "/raytracer/build/compile_commands.json") or ""
    local MX = dep_dir(host, "mathx") or "?"
    check("the project's database holds its own sources", db:find('"file": "' .. WS .. '/raytracer/cmd/rt/main.c"', 1, true))
    check("and its dependencies' sources", db:find('"file": "' .. WS .. '/mathx/public/vec/vec.c"', 1, true))
    local stray = {}
    for path in pairs(host.files) do
        if path:find(WS .. "/build/", 1, true) and path:match("compile_commands%.json$") then stray[#stray + 1] = path end
    end
    check("dependency builds write none", #stray == 0, table.concat(stray, " "))
    check("its paths are absolute", not db:find('"file": "[^/]', 1) and db:find('"directory": "' .. WS .. '/mathx"', 1, true))
end

-- ── reading the filesystem: a few scans, and no trust in timestamp precision ──

print("=== the filesystem is read by a few scans ===")
do
    local host = workspace()
    local scans, stats = #host.scans, host.stats
    check("raytracer builds", (run(host, "raytracer")))
    local n_scans, n_stats = #host.scans - scans, host.stats - stats
    -- mathx and stb_ds: their root and build (2 each); raytracer: its root, its build and each
    -- dependency's root and build (6); install: raytracer's public/ (1)
    check("three project builds and an install take 11 scans", n_scans == 11, n_scans)
    check("and 3 single stats: the declared repos, mathx's generated header", n_stats == 3, n_stats)
end

print("=== coarse timestamps: an edit is never missed ===")
do
    local host = workspace(nil, true) -- every file has the same time until the clock is moved
    check("raytracer builds", (run(host, "raytracer")))
    host.tick()
    local _, _, cmds = run(host, "raytracer")
    check("outputs as old as their inputs are rebuilt once", #compiled(cmds) > 0)
    -- objects and archives written in the same tick look equal once more: one level settles per build
    local settled = false
    for _attempt = 1, 3 do
        host.tick()
        _, _, cmds = run(host, "raytracer")
        if #cmds == 0 then settled = true; break end
    end
    check("then settles to nothing within a few builds", settled, table.concat(cmds, "\n    "))
    -- an edit in the same tick as the last build
    host.touch(WS .. "/raytracer/internal/scene/scene.c")
    _, _, cmds = run(host, "raytracer")
    check("an edit in the same tick as the build is rebuilt",
        same(compiled(cmds), { (dep_dir(host, "raytracer") or "?") .. "/out/objs/internal/scene/scene.o" }), table.concat(compiled(cmds), " "))
end

-- ── mistakes in sandbox's recipe ───────────────────────────────────────────

print("=== sandbox's mistakes are refused ===")
do
    -- the body is imperative: an undeclared build is caught when reached, after the steps before it
    local ok, err, cmds = run(workspace(), "sandbox", "recipe_forgot_physics.lua")
    check("building an undeclared repo is refused when reached",
        not ok and tostring(err):find("physics is not required by this recipe", 1, true)
        and #containing(cmds, "/physics/") == 0, err)

    local cases = {
        { "recipe_two_mathx.lua", "recipe requires repo mathx twice (as mathx and mathx_v1)", "two versions of mathx" },
        { "recipe_new_muh_build.lua", "is written for muh-build 9.0; this is muh-build " .. domain.VERSION, "a recipe for a newer muh-build" },
        { "recipe_future_rev.lua", "revision v3 of mathx does not exist", "a revision that does not exist" },
        { "recipe_missing_repo.lua", "required repo audio is not in the workspace", "a repo missing from the workspace" },
        { "recipe_bad_param.lua", "params set mdoe, which manifest " .. WS .. "/mathx/manifest.linux.lua does not declare", "a misspelt param" },
        { "recipe_param_muh_build.lua", "params cannot set muh_build", "a param overriding muh_build" },
    }
    for _, c in ipairs(cases) do
        local host = workspace()
        local ok, err, cmds = run(host, "sandbox", c[1])
        local builds = matching(cmds, "^clang ")
        check(c[3] .. " is refused before building", not ok and tostring(err):find(c[2], 1, true) and #builds == 0,
            tostring(err) .. " | " .. table.concat(cmds, "; "))
    end
    -- a manifest, not the recipe, written for a newer muh-build, or stating none
    local path = WS .. "/mathx/manifest.linux.lua"
    for _, c in ipairs {
        { '"9.0"', "is written for muh-build 9.0", "a manifest for a newer muh-build" },
        { "nil", "must state the muh-build version it is written for", "a manifest stating no muh-build version" },
    } do
        local host = workspace()
        host.write_file(path, (host.read_file(path):gsub('muh_build = "0.1"', "muh_build = " .. c[1])))
        local ok2, err2, cmds = run(host, "viewer")
        check(c[3] .. " is refused before building", not ok2 and tostring(err2):find(c[2], 1, true)
            and #matching(cmds, "^clang ") == 0, err2)
    end
    ok, err = run(workspace(), "sandbox", "recipe_mathx_twice.lua")
    check("building mathx twice with different inputs is refused",
        not ok and tostring(err):find("mathx is built twice with different inputs", 1, true), err)
end

print(string.format("\nResults: %d passed, %d failed, %d total", PASS, FAIL, PASS + FAIL))
os.exit(FAIL == 0 and 0 or 1)
