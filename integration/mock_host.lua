-- mock_host.lua — a host whose filesystem lives in memory and whose tools are simulated.
--
-- It implements the host interface of scripts/host.linux.lua, plus test helpers (add_revision, touch,
-- tick) and records (commands, writes, scans). Files carry a logical mtime from a clock that ticks on
-- every write; with `coarse`, it only ticks on tick(), as on a filesystem with coarse timestamps.
-- exec() and capture() record each command and run fake tools: cc/clang/gcc compile or link,
-- ar archives, cp copies, make and cmake write the outputs their build files declare.
-- A fake compile scans includes through -I directories and writes the -MF depfile.

local M = {}

---@param s string
---@return string[]
local function split(s)
    local argv = {}
    for w in s:gmatch("%S+") do argv[#argv + 1] = w end
    return argv
end

-- ── Fake tools ─────────────────────────────────────────────────────────────
-- A tool is fun(host, domain, argv) -> ok, output_or_error.

--- The includes of `path` found through `dirs`, transitively: quoted ones also search the file's own
--- directory; angle ones not found in `dirs` are system headers and are left out, as with -MMD.
local function scan_includes(h, domain, path, dirs, found, seen)
    local text = h.read_file(path)
    if not text then return end
    for open, inc in text:gmatch('#%s*include%s*([<"])([^>"]+)[>"]') do
        local search = {}
        if open == '"' then search[1] = domain.parent_dir(path) end
        for _, d in ipairs(dirs) do search[#search + 1] = d end
        for _, d in ipairs(search) do
            local cand = domain.path_normalize(domain.path_join(d, inc))
            if h.exists(cand) then
                if not seen[cand] then
                    seen[cand] = true
                    found[#found + 1] = cand
                    scan_includes(h, domain, cand, dirs, found, seen)
                end
                break
            end
        end
    end
end

-- ── Symbols ────────────────────────────────────────────────────────────────
-- A fake object records the functions its source defines and calls:
--   "object\ndefines a b\nuses c d\n". A fake archive is its members' objects, separated by "\0".

local KEYWORDS = { ["if"] = true, ["for"] = true, ["while"] = true, ["switch"] = true, ["return"] = true, ["sizeof"] = true }

--- Function definitions (a line `... name(...) {`) and calls in C source text.
local function symbols_of(text)
    local defines, uses, defined = {}, {}, {}
    for line in text:gmatch("[^\n]+") do
        local name = line:match("^[%w_][%w_%s%*]-([%a_][%w_]*)%s*%b()%s*{")
        if name and not KEYWORDS[name] and not line:match("^%s*#") then
            defined[name] = true
            defines[#defines + 1] = name
        end
    end
    local seen = {}
    for name in text:gmatch("([%a_][%w_]*)%s*%(") do
        if not defined[name] and not KEYWORDS[name] and not seen[name] then
            seen[name] = true
            uses[#uses + 1] = name
        end
    end
    return defines, uses
end

local function object_text(defines, uses)
    return "object\ndefines " .. table.concat(defines, " ") .. "\nuses " .. table.concat(uses, " ") .. "\n"
end

local function parse_object(text)
    local defines, uses = {}, {}
    for w in (text:match("defines ([^\n]*)") or ""):gmatch("%S+") do defines[#defines + 1] = w end
    for w in (text:match("uses ([^\n]*)") or ""):gmatch("%S+") do uses[#uses + 1] = w end
    return { defines = defines, uses = uses }
end

--- Resolve symbols like a static linker: inputs left to right; an object is always pulled in, an archive
--- member only when it defines a symbol still undefined at that point. Symbols defined by no input are
--- outside the workspace (libc, SDL) and ignored. Returns nil or an "undefined reference" message.
local function resolve(h, ins)
    local objects = {}   -- per input: {kind, members = {obj...}}
    local known = {}
    for _, path in ipairs(ins) do
        local text = h.read_file(path) or ""
        local entry = { members = {} }
        if text:sub(1, 7) == "archive" then
            entry.kind = "archive"
            for member in text:sub(9):gmatch("[^%z]+") do entry.members[#entry.members + 1] = parse_object(member) end
        else
            entry.kind = "object"
            entry.members[1] = parse_object(text)
        end
        for _, m in ipairs(entry.members) do for _, d in ipairs(m.defines) do known[d] = true end end
        objects[#objects + 1] = entry
    end
    local defined, undefined = {}, {}
    local function pull(m)
        for _, d in ipairs(m.defines) do defined[d] = true; undefined[d] = nil end
        for _, u in ipairs(m.uses) do if known[u] and not defined[u] then undefined[u] = true end end
    end
    for _, entry in ipairs(objects) do
        if entry.kind == "object" then
            pull(entry.members[1])
        else
            local pulled = {}
            local again = true
            while again do -- members of one archive may need each other
                again = false
                for i, m in ipairs(entry.members) do
                    if not pulled[i] then
                        for _, d in ipairs(m.defines) do
                            if undefined[d] then pulled[i] = true; pull(m); again = true; break end
                        end
                    end
                end
            end
        end
    end
    local missing = {}
    for u in pairs(undefined) do missing[#missing + 1] = u end
    table.sort(missing)
    if #missing > 0 then return "undefined reference to " .. table.concat(missing, ", ") end
end

local function fake_cc(h, domain, argv)
    local out, depfile, compile, dirs, ins = nil, nil, false, {}, {}
    local i = 2
    while i <= #argv do
        local a = argv[i]
        if a == "-o" then out = argv[i + 1]; i = i + 1
        elseif a == "-MF" or a == "-MT" then
            if a == "-MF" then depfile = argv[i + 1] end
            i = i + 1
        elseif a == "-c" then compile = true
        elseif a:match("^%-I") then dirs[#dirs + 1] = a:sub(3)
        elseif not a:match("^%-") then ins[#ins + 1] = a
        end
        i = i + 1
    end
    if not out then return false, "no -o" end
    for _, f in ipairs(ins) do
        if not h.exists(f) then return false, "missing input " .. f end
    end
    if compile then
        local src = assert(ins[1], "compile without a source")
        if depfile then
            local found = {}
            scan_includes(h, domain, src, dirs, found, {})
            h.write_file(depfile, out .. ": " .. src .. " " .. table.concat(found, " ") .. "\n")
        end
        h.write_file(out, object_text(symbols_of(h.read_file(src) or "")))
    else
        local err = resolve(h, ins)
        if err then return false, "link " .. out .. ": " .. err end
        h.write_file(out, "executable from " .. table.concat(ins, " "))
    end
    return true
end

local function fake_ar(h, _, argv)
    local out = argv[3]
    if not out then return false, "no archive" end
    local members = {}
    for i = 4, #argv do
        if not h.exists(argv[i]) then return false, "missing member " .. argv[i] end
        members[#members + 1] = h.read_file(argv[i])
    end
    h.write_file(out, "archive\n" .. table.concat(members, "\0"))
    return true
end

local function fake_cp(h, _, argv)
    local data = h.read_file(argv[2])
    if not data then return false, "cp: cannot open " .. argv[2] end
    h.write_file(argv[3], data)
    return true
end

--- The outputs a fake build file declares: lines `# mock-output: <path relative to the build dir>`.
local function declared_outputs(text)
    local outs = {}
    for rel in text:gmatch("# mock%-output: (%S+)") do outs[#outs + 1] = rel end
    return outs
end

--- make [-B] -C <dir> <target>: `all` writes the Makefile's declared outputs into <dir>, `clean` removes them.
local function fake_make(h, domain, argv)
    local dir, target = nil, "all"
    local i = 2
    while i <= #argv do
        if argv[i] == "-C" then dir = argv[i + 1]; i = i + 1
        elseif not argv[i]:match("^%-") then target = argv[i] end
        i = i + 1
    end
    if not dir then return false, "make: no -C" end
    local makefile = h.read_file(domain.path_join(dir, "Makefile"))
    if not makefile then return false, "make: no Makefile in " .. dir end
    for _, rel in ipairs(declared_outputs(makefile)) do
        local path = domain.path_join(dir, rel)
        if target == "clean" then h.remove(path) else h.write_file(path, "made by make " .. target) end
    end
    return true
end

--- cmake --version | cmake -S <src> -B <out> [-D...] | cmake --build <out> [...].
--- The build writes the declared outputs of <src>/CMakeLists.txt into <out>.
local function make_fake_cmake(version)
    return function(h, domain, argv)
        if argv[2] == "--version" then return true, "cmake version " .. version .. "\n" end
        if argv[2] == "--build" then
            local cache = h.read_file(domain.path_join(argv[3], "CMakeCache.txt"))
            if not cache then return false, "cmake: " .. argv[3] .. " is not configured" end
            local src = cache:match("src=(%S+)")
            for _, rel in ipairs(declared_outputs(h.read_file(domain.path_join(src, "CMakeLists.txt")))) do
                h.write_file(domain.path_join(argv[3], rel), "built by cmake")
            end
            return true
        end
        local src, out
        for i = 2, #argv do
            if argv[i] == "-S" then src = argv[i + 1] elseif argv[i] == "-B" then out = argv[i + 1] end
        end
        if not (src and out) then return false, "cmake: need -S and -B" end
        if not h.exists(domain.path_join(src, "CMakeLists.txt")) then return false, "cmake: no CMakeLists.txt in " .. src end
        h.write_file(domain.path_join(out, "CMakeCache.txt"), "src=" .. src .. "\n")
        return true
    end
end

M.make_fake_cmake = make_fake_cmake

--- git -C <repo> cat-file -e <rev>^{commit} | git -C <repo> worktree add [--quiet] --detach <dest> <rev>.
--- Revisions are snapshots registered with host.add_revision(repo, rev, files). Redirections are ignored.
local function fake_git(h, domain, argv)
    if argv[2] ~= "-C" then return false, "git: expected -C" end
    local repo = argv[3]
    local revs = h.revisions[repo] or {}
    local operands = {} -- after the subcommand, without flags and redirections
    for i = 6, #argv do
        if not argv[i]:match("^%-") and not argv[i]:match("^%d?>") then operands[#operands + 1] = argv[i] end
    end
    if argv[4] == "cat-file" and argv[5] == "-e" then
        return revs[(operands[1] or ""):gsub("%^{commit}$", "")] ~= nil
    end
    if argv[4] == "worktree" and argv[5] == "add" then
        local dest, rev = operands[1], operands[2]
        local files = revs[rev]
        if not files then return false, "git: unknown revision " .. tostring(rev) end
        for rel, text in pairs(files) do h.write_file(domain.path_join(dest, rel), text) end
        return true
    end
    return false, "git: unsupported " .. table.concat(argv, " ")
end

---@param overrides table?  tool name -> tool, replacing the defaults
function M.tools(overrides)
    local t = {
        cc = fake_cc, clang = fake_cc, gcc = fake_cc, ar = fake_ar, cp = fake_cp,
        make = fake_make, cmake = make_fake_cmake("3.28.3"), git = fake_git,
    }
    for k, v in pairs(overrides or {}) do t[k] = v end
    return t
end

-- ── Host ───────────────────────────────────────────────────────────────────

---@param opts {domain: table, cwd: string?, tools: table?, coarse: boolean?}
function M.new(opts)
    local domain = assert(opts.domain, "mock host: domain is required")
    local files = {}       -- path -> {data = string, mtime = integer}
    local dirs = { ["/"] = true }
    local clock = 0
    local tools = opts.tools or M.tools()

    local h = {
        name = "linux",     -- manifests are manifest.<name>.lua
        revisions = {},     -- repo dir -> rev -> {relative path -> contents}
        files = files,
        commands = {},      -- every exec'd command, in order (argument lists joined by spaces)
        writes = {},        -- every written path, in order
        scans = {},         -- every scanned directory, in order
        stats = 0,          -- how many single-path stats were asked
    }

    local function tick()
        if not opts.coarse then clock = clock + 1 end
    end

    --- Advance the clock, as the passing of time would on a coarse filesystem.
    function h.tick() clock = clock + 1 end

    function h.cwd() return opts.cwd or "/" end

    function h.mkdir_p(path)
        while path and path ~= "" and not dirs[path] do
            dirs[path] = true
            path = domain.parent_dir(path)
        end
    end

    --- Whether a path exists; for the fake tools, not counted in stats.
    function h.exists(path)
        return files[path] ~= nil or dirs[path] ~= nil
    end

    function h.stat(path)
        h.stats = h.stats + 1
        local f = files[path]
        if f then return { mode = "file", mtime = f.mtime } end
        if dirs[path] then return { mode = "directory", mtime = 0 } end
        return nil
    end

    --- Every path under `dir` (not `dir` itself), as {path -> {mode, mtime}}; empty when it is missing.
    function h.scan(dir)
        h.scans[#h.scans + 1] = dir
        local found = {}
        for p, f in pairs(files) do
            if domain.is_within(p, dir) and p ~= dir then found[p] = { mode = "file", mtime = f.mtime } end
        end
        for p in pairs(dirs) do
            if domain.is_within(p, dir) and p ~= dir then found[p] = { mode = "directory", mtime = 0 } end
        end
        return found
    end

    function h.read_file(path)
        local f = files[path]
        if not f then return nil, path .. ": no such file" end
        return f.data
    end

    function h.write_file(path, data)
        h.mkdir_p(domain.parent_dir(path))
        h.writes[#h.writes + 1] = path
        tick()
        files[path] = { data = data, mtime = clock }
    end

    --- Register a commit of a repo: its files, relative to the repo root.
    function h.add_revision(repo, rev, snapshot)
        h.revisions[repo] = h.revisions[repo] or {}
        h.revisions[repo][rev] = snapshot
    end

    --- Bump a file's mtime, as an edit would.
    function h.touch(path)
        assert(files[path], "touch: no such file " .. path)
        tick()
        files[path].mtime = clock
    end

    function h.remove(path)
        if not files[path] then return false end
        files[path] = nil
        return true
    end

    function h.rmdir_rf(path)
        local any = false
        for p in pairs(files) do
            if p == path or p:sub(1, #path + 1) == path .. "/" then files[p] = nil; any = true end
        end
        for p in pairs(dirs) do
            if p == path or p:sub(1, #path + 1) == path .. "/" then dirs[p] = nil; any = true end
        end
        return any
    end

    --- Run `cmd` (steps joined by &&, stopping at the first failure); returns ok and the last output.
    local function run(cmd)
        h.commands[#h.commands + 1] = cmd
        local output
        for step in (cmd .. " && "):gmatch("(.-)%s+&&%s+") do
            local argv = split(step)
            local tool = tools[(argv[1] or ""):match("[^/]+$")]
            if not tool then return false, "unknown tool " .. tostring(argv[1]) end
            local ok, out = tool(h, domain, argv)
            if not ok then return false, out end
            output = out
        end
        return true, output
    end

    --- Run a command: a string as written, or a list of arguments. Returns ok, and with
    --- opts.capture its output. opts.quiet (hide errors) changes nothing here.
    ---@param cmd string|string[]
    ---@param opts {capture: boolean?, quiet: boolean?}?
    function h.exec(cmd, opts)
        if type(cmd) == "table" then cmd = table.concat(cmd, " ") end
        local ok, out = run(cmd)
        if opts and opts.capture then return ok, ok and (out or "") or nil end
        return ok
    end

    return h
end

return M
