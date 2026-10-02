-- host.linux.lua — the host on Linux, with stock Lua: files through io/os, everything else through
-- POSIX commands (find with -printf, as GNU findutils and bfs provide; GNU stat).
--
-- The host interface (integration/mock_host.lua implements the same one in memory):
--   name                     "linux"; manifests are manifest.<name>.lua
--   cwd()                    the absolute current directory
--   read_file(p)             contents, or nil and an error
--   write_file(p, s)         creates the parent directories
--   remove(p)                a file; true when it was removed
--   mkdir_p(p), rmdir_rf(p)  directories; rmdir_rf is true when something was removed
--   scan(dir)                every path under dir as {path -> {mode, mtime}}, in one process; {} if missing
--   stat(p)                  {mode, mtime} or nil, in one process: for one-off checks
--   exec(cmd, opts)          cmd: a string for the shell as written, or a list of arguments, which the
--                            host quotes. opts.capture: also return the output; opts.quiet: hide errors.
-- Paths are "/"-separated. mode is "file", "directory" or "other"; mtime is a number comparable within
-- one host, of unspecified resolution. Symlinks are followed. Paths holding a tab or a newline are
-- not supported.

local M = {}

--- A string quoted for the POSIX shell.
local function quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function mode_of(kind)
    if kind == "directory" or kind == "d" then return "directory" end
    if kind == "f" or kind:match("file$") then return "file" end
    return "other"
end

---@param opts {domain: table}
function M.new(opts)
    local domain = assert(opts.domain, "host.linux: domain is required")
    local h = { name = "linux" }
    local made = {} -- directories this host made, so mkdir_p runs once per directory in a run

    ---@param cmd string|string[]
    ---@param o {capture: boolean?, quiet: boolean?}?
    function h.exec(cmd, o)
        o = o or {}
        if type(cmd) == "table" then
            local parts = {}
            for i, a in ipairs(cmd) do parts[i] = quote(a) end
            cmd = table.concat(parts, " ")
        end
        if o.quiet then cmd = cmd .. " 2>/dev/null" end
        if not o.capture then return os.execute(cmd) == true end
        local p = io.popen(cmd)
        if not p then return false, nil end
        local out = p:read("a")
        local ok = p:close() == true
        return ok, ok and out or nil
    end

    local cwd = assert(select(2, h.exec({ "pwd" }, { capture = true })), "host.linux: pwd failed"):gsub("\n$", "")
    function h.cwd() return cwd end

    function h.read_file(path)
        local f, err = io.open(path, "rb")
        if not f then return nil, err end
        local data = f:read("a")
        f:close()
        return data
    end

    --- Opens first and makes the parent directory only when that fails, so directories removed by
    --- other programs never leave it believing they still exist.
    function h.write_file(path, data)
        local f = io.open(path, "wb")
        if not f then
            local dir = domain.parent_dir(path)
            made[dir] = nil
            h.mkdir_p(dir)
            f = assert(io.open(path, "wb"))
        end
        f:write(data)
        f:close()
    end

    function h.remove(path)
        return os.remove(path) ~= nil
    end

    function h.mkdir_p(path)
        if not path or path == "" or made[path] then return end
        assert(h.exec({ "mkdir", "-p", path }), "cannot create directory " .. path)
        made[path] = true
    end

    function h.rmdir_rf(path)
        if not h.stat(path) then return false end
        assert(h.exec({ "rm", "-rf", path }), "cannot remove " .. path)
        for dir in pairs(made) do
            if domain.is_within(dir, path) then made[dir] = nil end
        end
        return true
    end

    function h.scan(dir)
        local found = {}
        local ok, out = h.exec({ "find", "-L", dir, "-mindepth", "1", "-printf", "%y\t%T@\t%p\n" },
            { capture = true, quiet = true })
        if not ok or not out then return found end
        for kind, mtime, path in out:gmatch("([^\t\n]*)\t([^\t\n]*)\t([^\n]*)\n") do
            found[path] = { mode = mode_of(kind), mtime = tonumber(mtime) }
        end
        return found
    end

    function h.stat(path)
        local ok, out = h.exec({ "stat", "-L", "--printf", "%.9Y %F\n", "--", path }, { capture = true, quiet = true })
        if not ok or not out then return nil end
        local mtime, kind = out:match("^(%S+) ([^\n]+)")
        return { mode = mode_of(kind), mtime = tonumber(mtime) }
    end

    return h
end

return M
