# Platform constraints for the host interface (research, 2026-09-29)

Why: the host is handed to every manifest's `preconfigure` (`infra.host`), so its interface is
user-facing and must mean the same on every platform. The user's TODO asks for stock Lua (no lfs).

## Stock Lua

- [fact] Stock Lua has no directory listing and no file times: only `io.open`, `os.remove`,
  `os.rename`, `os.tmpname`, `os.execute`, `io.popen`. Anything else goes through a process.
- [fact] `io.popen` exists on POSIX builds (`popen`) and on Windows (`_popen`); in a C89 build it
  raises "'popen' not supported" (`vendor/lua-5.5.0/liolib.c:54-79`). `os.execute` is `system()`
  (`loslib.c:133-147`). Windows builds define `LUA_USE_C89` by default (`luaconf.h:50-57`), yet
  `liolib.c` still picks `_popen` under `_WIN32` (line 63).

## Listing a tree with modification times, one process

| Platform | Tool | Sub-second mtime | Source |
|-|-|-|-|
| Linux, GNU | `find <dir> -printf '%p\t%y\t%T@\n'` | yes (ns) | GNU findutils |
| Linux, BusyBox (Alpine) | `find` has no `-printf`; `stat -c` has `%Y` (seconds) | no | https://busybox.net/downloads/BusyBox.html |
| macOS | `find` has no `-printf`; `find <dir> -exec stat -f ... {} +` batches; BSD `stat` does floating output for a, m, c fields, exact sub-second syntax unverified | unverified | https://ss64.com/mac/find.html, https://ss64.com/mac/stat.html |
| FreeBSD (current) | `find -printf` exists; `stat -f` takes many files | unverified | https://man.freebsd.org/cgi/man.cgi?query=find&sektion=1, ...query=stat |
| Windows | PowerShell `Get-ChildItem -LiteralPath <dir> -Recurse -Force` gives `LastWriteTimeUtc` | yes (100 ns on NTFS) | https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-childitem |

- (agent, general knowledge, unverified) cmd.exe's `%~t` gives minutes only; PowerShell startup costs
  a noticeable fraction of a second, so one call per tree, not per file.

## Filesystem timestamp resolution

- [fact] NTFS: 100 ns units; FAT write time: 2 s; NTFS delays last-access updates up to 1 h
  (https://learn.microsoft.com/en-us/windows/win32/sysinfo/file-times).
- (agent, general knowledge) ext4, APFS: nanoseconds; HFS+: 1 s.
- Consequence: the build cannot assume sub-second mtimes. It must stay correct when an input and an
  output share a timestamp.

## Command lines and shells

- [fact] cmd.exe: 8191 characters per command line; the documented workaround is a file of
  arguments (https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/command-line-string-limitation).
  Linux allows megabytes. So batching many paths into one command line does not scale to Windows;
  scanning a directory (one path in, a stream out) does.
- (agent) Shell syntax differs: `2>/dev/null` vs `2>NUL`, quoting, `&&`. [fact] `repo.lua` currently
  embeds `2>/dev/null` in its revision probe: core code writing shell syntax is not portable.
- (agent) Case-insensitive filesystems (macOS, Windows defaults) and `\` separators affect matching
  depfile paths against scanned paths.

## Implications for the design (agent proposal, not decided)

1. The host is a per-platform adapter over processes; its functions must be semantic (scan a tree,
   read, write, remove, make a directory, run a program), never shell strings built by the core.
2. `scan(dir)` is feasible everywhere as one process per tree; precision varies (ns to 2 s).
3. The build must not depend on precision: snapshot per project build, a "built in this run" set,
   and an input whose time equals its output's treated as stale (spurious rebuilds within one tick,
   never missed ones).
4. Running a program should take an argument list, not a shell string, where the core builds it, so
   each host quotes for its own shell; manifests, being per-host, may keep writing their own strings.

## Decisions and findings (2026-09-29)

- Decision (user): platforms Linux, macOS, Windows; the others are to be tested through GitHub Actions.
  Lua 5.5 is the target; older versions allowed, untested, the user's responsibility.
- Decision (user): the host interface proposed above: `name, cwd, read_file, write_file, remove,
  mkdir_p, rmdir_rf, scan, stat, exec(cmd, {capture, quiet})`, "/" paths, mtime of unspecified resolution.
- [fact] (agent) This machine's `find` is bfs 4.1.1, not GNU findutils; it supports `-printf`.
  GNU `stat -c` prints `\t` literally; `--printf` interprets it.
- [fact] (agent) A host that remembers the directories it made goes wrong when another program removes
  them (found with `git rm` in the real check); `write_file` now opens first and makes the parent only
  when that fails.
- Open (agent): the vendored Lua was not diffed against the release this time: lua.org timed out.
- Open (agent): hosts for macOS (find -exec stat -f) and Windows (PowerShell), and path case on
  case-insensitive filesystems.
