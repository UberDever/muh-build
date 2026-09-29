# Experiment 2026-09-27: flat per-project build scripts over today's muh-build

Workspace: repos K, L1, L2, L3 (libraries) and P1, P2 (apps), real git repos with revisions, built in a scratch
directory. Each scenario is one flat Lua script; `ws.lua` gives `checkout` (git worktree or symlink to the
working tree) and `build` (runs the muh-build CLI with `-m` and `-p`, returns a record: include roots, archives,
defines). Checkouts and outputs go to `<ws>/build/<project>/<repo>@<rev>-<fnv hash of the canonical term>/`.
The term reaches each manifest through the `MUH_TERM` environment variable; `manifest.template.lua` is the
manifest every repo carries; `K_extra.lua` is K's generation step and export.

Scenarios: `p1.lua` (A: dev+ASan, K pinned, L1 dirty working tree, L3 define passed on), `p1_abi.lua`
(B: define withheld), `p2.lua` (C: release, K with generated header, L2 pinned), `p2_diamond.lua` (D: two K
revisions in one link), `mix_main.c` (D: member-level mixing), rerun of `p1.lua` (E), `f_shared.lua` (F: two
consumers of one working tree). Results: in the ledger, section "Experiment".
