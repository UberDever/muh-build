# muh-build

A small build system for C projects, written in Lua. It needs only a C compiler to bootstrap.

Concepts:

- manifest.<host>.lua: a set of declarations that ultimately tells `project.lua` which options and commands to use to build the project;
it is not responsible for project's dependencies on other projects/libraries
- host.<host>.lua: the platform adapter: files, directories, scans and commands, all through stock Lua and the platform's tools; manifests get it as `infra.host`, and its interface is documented at the top of `scripts/host.linux.lua`
- project.lua: the main logic behind the single-project build and the primary user of a manifest
- repo.lua: facilities to write a build script for a particular project being part of a multiproject monorepo
- recipe.lua: primary user of `repo.lua` that imperatively
lists how to build a particular project and its dependencies
- cli.lua: a runner for the whole build system
- build-info.lua: a lua term that describes how this particular project was built, look for it in the project's build directory

## Use

muh-build runs on stock Lua. Use the system's `lua`, or build the vendored Lua 5.5.1 release, unmodified:

```sh
mkdir -p build && cc -std=c99 -O2 -DLUA_USE_LINUX -o build/lua vendor/lua-5.5.1/*.c -lm -ldl   # Linux rn
```

Lua 5.5 is the target; 5.4 passes the tests too; older versions are untested and up to you.

Platforms: Linux. macOS and Windows are planned; `cli.lua` refuses them until their hosts exist.
The Linux host needs `find` with `-printf` (GNU findutils or bfs) and GNU `stat`.

Then run a project's recipe:

```sh
build/lua scripts/cli.lua path/to/project/recipe.lua [--log color|plain|quiet]
```

Tests: `build/lua integration/runner.lua` builds a whole workspace on an in-memory host with fake
tools; `build/lua integration/show.lua <project>` prints what a recipe runs and writes.

## Writing a manifest

Every repo has a manifest at its root, named after the platform: `manifest.linux.lua`. It says how to
build that repo's own files, and nothing about other repos. It is a Lua file returning a table.

Put your code in packages. A package is a directory: `public/<name>/` if other repos may include it,
`internal/<name>/` if only this repo may. Every `.c` in it goes into one archive, `lib<name>.a`;
files ending in `_test.c` become a test program instead. Programs live in `cmd/<name>/main.c`.

Yes, it's all go-style packaging.

Includes always start with the repo's name, even inside the repo itself:

```c
#include "mathx/public/vec/api.h"
```

Then write the manifest. Here is mathx's:

```lua
return {
    muh_build = "0.1",                       -- the muh-build this is written for, at least
    mode     = "dev",                        -- your own field; recipes may override it
    packages = { "vec", "simd", "rng" },     -- what to build, in link order: vec uses simd, so vec first

    exports = {                              -- what users of mathx need besides public/
        out_include_dirs = { "gen" },        -- headers generated into the build directory
        defines = {},                        -- defines that change public headers: users get them too
    },

    -- one object from one source; extra_args carries the include flags and defines
    compile_cmd = function(out, src, extra_args, m)
        local flags = m.mode == "release" and "-O2" or "-O0 -g"
        return "clang " .. flags .. " " .. table.concat(extra_args, " ")
            .. " -MMD -MF " .. out .. ".d -c " .. src .. " -o " .. out
    end,
    archive_cmd = function(out, ins) return "ar rcs " .. out .. " " .. table.concat(ins, " ") end,
    link_cmd = function(out, ins, extra_args)
        return "clang " .. table.concat(ins, " ") .. " -o " .. out .. " " .. table.concat(extra_args, " ")
    end,

    -- runs before anything is compiled: generate files, or build something external
    preconfigure = function(infra)
        local header = infra.domain.path_join(infra.build_dir, "gen", "mathx", "mathx_config.h")
        if not infra.host.stat(header) then infra.host.write_file(header, "#define MATHX_SIMD_WIDTH 4\n") end
    end,
}
```

The commands get the manifest as their last argument (`m`), already merged with whatever the recipe
overrides, so read settings from it rather than from local variables. Keep `-MMD -MF <out>.d`: the
depfile is how muh-build knows which headers an object used.

A vendored library gets a manifest too. Header-only is one line:

```lua
return { muh_build = "0.1", exports = { include_dirs = { "." } } }
```

A library with its own build system (cmake, say) runs it from `preconfigure` into `infra.build_dir`,
skips it when the result already exists, and exports the result:

```lua
exports = { include_dirs = { "include" }, archives = { "libSDL3.a" } },
```

## Writing a recipe

A project you build and run (an app, a tool) has `recipe.lua` next to its manifest. It says which
other repos to build, at which revision, with which settings, in which order.  Basically it is used to
build a project with other project dependencies: vendored or not.

`requires` lists what the recipe uses. Each entry is a repo in the workspace, the name you will call
it by, a revision (`"working"` for the repo as it is on disk, or a commit or tag), and optionally
params: values that replace the repo's manifest entries for this build.

`run` does the building, step by step, with `repo`:

```lua
return {
    muh_build = "0.1",
    requires = {
        { repo = "mathx",   as = "mathx",   rev = "working", params = { mode = "release" } },
        { repo = "physics", as = "physics", rev = "working" },
        { repo = "stb_ds",  as = "stb_ds",  rev = "working" },
    },

    run = function(repo)
        local mathx   = repo.build "mathx"                          -- build a required repo
        local physics = repo.build { "physics", deps = { mathx } }  -- physics includes mathx: give it mathx
        local stb_ds  = repo.build "stb_ds"

        local app = repo.project { deps = { physics, mathx, stb_ds } }  -- then this project itself
        repo.install(app, "build/install")                              -- optional: bin/, lib/, include/
        return app
    end,
}
```

A few things to know:

- `muh_build`, in recipes and manifests alike, is the muh-build version the file is written for. It
  works like the `go` line in go.mod: an older muh-build refuses the file, a newer one keeps building
  it the way it was meant. So an old commit of a library still builds after you upgrade muh-build.
  Write the version you are using now (`build/lua -e 'print(dofile("scripts/domain.lua").VERSION)'`).
- Pass every library a build uses in `deps`, in link order: users before what they use. Nothing is
  passed along for you. If physics needs mathx, you give mathx to physics, and to the app as well.
- Each build gives back a record: its include directories, defines, archives and programs
  (`app.bins.sandbox`). That record is what you pass as a dependency.
- Mistakes are refused before anything is built: a repo or revision that does not exist, one repo
  required twice, a param the manifest does not have, a manifest or recipe written for a newer
  muh-build than yours.
  Building a name you did not require is refused when the recipe gets to it.
- Relative paths in a recipe start at the project's root. `repo.host` is there for anything else:
  `repo.host.exec`, `repo.host.write_file`, and so on.

## What gets rebuilt, by example

Say `~/dev/c` holds a math library `mathx`, a `physics` library that uses it, and two apps:
`sandbox` (uses physics and mathx) and `raytracer` (uses mathx in release mode, with doubles).

Building sandbox, then raytracer, leaves this in the shared `build/`:

```
~/dev/c/build/
  mathx@working-3f2a91c0/      mathx as sandbox asked for it: no params
  physics@working-8b10d4e2/    physics built on that mathx
  mathx@working-c7e05a19/      mathx as raytracer asked for it: mode = "release", MATHX_DOUBLE
```

Each directory has a `build-info.lua` saying how it was made. The apps' own objects go to
`sandbox/build/` and `raytracer/build/`.

Now some things happen:

- **You build sandbox again.** Nothing runs.
- **A third app asks for mathx exactly as sandbox does.** It gets `mathx@working-3f2a91c0` as it is,
  and compiles only its own sources.
- **You edit `mathx/public/vec/api.h`, then build raytracer.** Its mathx build recompiles the files
  that include the header, and raytracer recompiles its own includers, directly or through another
  header; the archives and the program containing them are redone. Sandbox's mathx catches up the
  next time sandbox is built. Directory names stay the same: an edit is not a new build.
- **You change a flag in `mathx/manifest.linux.lua`.** Each working-tree mathx build gets a new name
  and is built from scratch, and so is physics on top of it. The old directories stay until you
  remove them.
- **raytracer's recipe drops its params for mathx.** It now asks for mathx exactly as sandbox does, and
  uses `mathx@working-3f2a91c0`. (Params are compared as written: `{ mode = "dev" }` is a different
  build from no params, even where dev is the default.)
- **A tool pins mathx at commit `v1`.** It gets `mathx@v1-…/`, with v1's sources checked out inside,
  and the working tree of mathx does not matter to it.
- **You upgrade your compiler.** Nothing notices: remove `build/` yourself. The same goes for anything a
  manifest might read from the environment, which is why manifests must not.

A manifest also lists its packages in link order: mathx has `packages = { "vec", "simd", "rng" }`
because vec calls simd. Directories it does not list are not built.

# License

Copyright (C) 2026 uberdever

- Code: [GPL-3.0-or-later](LICENSE).
- Manifests, recipes and build outputs of the projects muh-build builds are not covered by the project license.
- `vendor/lua-5.5.1/` is Lua, under the MIT license stated at the end of its `lua.h`.
