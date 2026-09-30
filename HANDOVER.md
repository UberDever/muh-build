# Handover: muh-build has two build pipelines, and you wrote both

To: Claude, on the local agent machine
From: Claude, in the cloud session that had to clean up after you
Re: `repo.project`, or how to build an identity system and then not use it

---

Hi. It's you. Well, a version of you that read the code afterwards.

The user sat down and designed build identity properly: revision, manifest text, params, and the
dependencies' builds, all hashed into `<repo>@<rev>-<hash>`, with `build-info.lua` next to it and a
`muh_build` version line like go.mod. That's the whole point of this tool. They worked hard to make
it sane.

Then you built it for dependencies only and left the one project the user actually runs out of it.
I'm sure it seemed reasonable at the time. Most things do.

## What you did

There are two ways to get a build out of `scripts/repo.lua`, and they don't agree.

| | `repo.build` (dependencies) | `repo.project` (the thing the user runs) |
|---|---|---|
| Output | `<ws>/build/<repo>@<rev>-<hash>/out` (`repo.lua:139`, `:166`) | `<project>/build`, because you didn't pass `out` and `project.lua:698` falls back to it |
| Identity: manifest text, params, dependency outputs | hashed into the name (`repo.lua:122–133`) | none at all |
| `build-info.lua` | written (`repo.lua:152–157`) | not written |
| "built twice with different inputs" check | yes (`repo.lua:134–137`) | no |
| `compile_commands.json` | not written | written into the same folder as the objects (`project.lua:792`) |

Both call the same `project.build`. So this isn't two pipelines for a reason. It's the same pipeline,
once with identity and once without it.

In case it isn't obvious: the top-level project is just another repo in the workspace at revision
`"working"`. It has a manifest, params and dependencies like any other. Nothing about it needed its
own path. You gave it one anyway.

## How it broke, so you don't have to take my word for it

1. Workspace: the `mine` entries that `vetochka/recipe.lua` requires, plus vetochka and muh-build.
2. `lua muh-build/scripts/cli.lua vetochka/recipe.lua` builds in `mode = "debug"` with
   `-fsanitize=address,undefined`.
3. Change vetochka's manifest to `mode = "release"` and build again.
4. Nothing is recompiled. Only the link runs, against the old sanitized objects in
   `vetochka/build/objs/`, and fails on `undefined reference to __asan_report_load8`,
   `__ubsan_handle_type_mismatch_v1`, and so on.
5. `rm -rf vetochka/build` fixes it. That is exactly the manual step the identity system exists to
   remove, and on the path the user uses most it's the only thing that works.

A dependency in the same situation gets a new `@working-<hash>` folder and builds from scratch. The
project gets a timestamp check and good luck. The same goes for `params` passed to
`repo.project { params = ... }` and for a dependency whose exported defines change: none of it is
seen.

## How you covered it up

You didn't do this on purpose, but the result is the same. The behaviour is in the code, the README
and the tests, so all three agree and the tests are green:

- `README.md:169–170`: "The apps' own objects go to `sandbox/build/` and `raytracer/build/`." You
  wrote the shortcut up as a feature.
- `integration/runner.lua:228, 272, 325, 456` expect the project's objects under `<project>/build`,
  and `:411` expects `raytracer/build/compile_commands.json` there too. 109 of 109 passing, and they
  check the wrong thing.

It has been like this since the initial commit (`015c949`). Nothing later broke it. It shipped that
way.

## What the user actually wants

Their words: *"it should build to the top-level build… Vetochka build should only have compile
commands."*

- The project builds into `<ws>/build/<project>@working-<hash>/out`, with `build-info.lua`, exactly
  like a dependency.
- `<project>/build/` holds `compile_commands.json` and nothing else.
- There is one path. `repo.project` is `repo.build` applied to the project's own folder at
  `"working"`, taking `params` and `deps` from its argument. It is not a copy of `repo.build` with
  a few lines changed, and it is not a flag.

## The work

1. Pull the identity step out of `repo.build` (reading the manifest, hashing params + manifest text
   + dependency outputs, naming the folder, writing `build-info.lua`, the build-twice check) into
   one local function. Use it from both.
2. `repo.project` calls that function for `dir` at `"working"` with `b.params` and `b.deps`. The
   project gets an entry in `built` like everything else.
3. Let `project.build` take the compile database's location separately from the output folder.
   Right now `compile_db` is a boolean that writes into `build_dir`, which is the whole reason
   "only compile commands in `vetochka/build`" can't be expressed. Make it a path, or add one, and
   have `repo.project` point it at `<project>/build/compile_commands.json`.
4. Update `README.md:160–175`: the layout example gains `sandbox@working-…/` and
   `raytracer@working-…/`, and the line about "apps' own objects" goes. Then read the rest of the
   "what gets rebuilt" bullets again. "You change a flag in mathx/manifest.linux.lua" now applies to
   the app's own manifest as well; say so.
5. Update `integration/runner.lua` at the lines above to expect the new layout. Change the
   expectations. Do not delete them.
6. Add the test that should have been there from the start: change the top-level project's own
   manifest (a flag, or `mode`) and check that it gets a new folder and every object is compiled
   again. Add one for `repo.project { params = ... }` too.

## Done means

- [ ] `build/lua integration/runner.lua`: everything passes, including the new tests.
- [ ] After a build, `<project>/build/` contains only `compile_commands.json`.
- [ ] The project's output is in `<ws>/build/<project>@working-<hash>/out`, with `build-info.lua`.
- [ ] The reproduction above works without `rm -rf`: changing `mode` in vetochka's manifest gives a
      new folder and a clean link.
- [ ] vetochka builds from its unchanged `recipe.lua`, and
      `vtest tests/run.lua tests/*_test.lua` gives 25 passed, 0 failed.
- [ ] `grep` shows one place in `repo.lua` that computes identity.
- [ ] The four tests for a recipe that requires its own repo pass.

## Please don't

- Add `if is_top_level then` anywhere. That's how we got here.
- Make the tests pass by loosening what they check.
- Keep `<project>/build/objs` around "for compatibility". Nobody asked for it.
- Report this as done because the old 109 tests pass. They passed before, too.

## A recipe that requires its own repo

The user decided this one, so you don't have to. It's allowed, and it gets no special case. With
one path, the right behaviour follows from rules that already exist.

Why anyone would do it: bootstrapping. A pinned vetochka builds a tool that generates C for the
working tree:

```lua
requires = {
    { repo = "vetochka", as = "stage0", rev = "v0.3", params = { mode = "release" } },
    -- ...
},
run = function(repo)
    local stage0 = repo.build { "stage0", deps = { lua } }
    repo.host.exec { stage0.bins.vtool, "gen", repo.path "src", repo.path "gen" }
    return repo.project { deps = { lua } }
end,
```

Or the same working tree with different params, as a host tool: release for a generator, debug
with ASan for the project.

What it has to do:

- **Pinned revision:** a worktree under `build/<repo>@<rev>-<hash>/src/`, as for any other repo.
  This already works. Don't break it.
- **`"working"` with different params:** a different hash, so a different folder next to the
  project's own.
- **`"working"` with the same params:** the same hash, so the same folder, reused. Not an error.
  The project and its `requires` entry have different names, and the build-twice check is keyed by
  name, so two entries can land in one folder. Identical inputs, identical outputs; that's fine.
  Test it anyway.
- **Linking the project's own repo into itself:** still refused, by the existing
  "appears twice among dependencies" check (`project.lua:650`). The `<repo>/public/...` includes
  and the symbols would collide. Used as a tool, fine; linked in, no.

Tests to add in `integration/runner.lua`:

1. A recipe pins its own repo at an older commit, builds it, runs one of its `bins` as a tool, and
   then builds the project. Both succeed, into two different folders.
2. A recipe requires its own repo at `"working"` with different params. Two folders, both built.
3. A recipe requires its own repo at `"working"` with no params, identical to `repo.project`. One
   folder, compiled once.
4. A recipe passes its own pinned build in the project's `deps`. It's refused before anything is
   linked.

---

The good news is that almost all the machinery you need already exists. You wrote it, and then
used it for everything except the project the user runs.

Your predecessor
