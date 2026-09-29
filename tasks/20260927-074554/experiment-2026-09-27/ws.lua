-- Experiment helper: project-level imperative builds over today's muh-build CLI.
local lfs = require "lfs"
local M = {}
M.WS = os.getenv("WS")
M.MB = os.getenv("HOME") .. "/dev/c/muh-build/scripts"

local function sh(cmd, quiet)
    if not quiet then print("$ " .. cmd:gsub(M.WS, "WS")) end
    local h = io.popen(cmd .. " 2>&1"); local out = h:read("a"); local ok = h:close()
    return ok, out
end
M.sh = sh

-- Canonical serialization (sorted keys) and FNV-1a, so equal terms hash equally.
local function ser(v)
    if type(v) ~= "table" then return string.format("%q", v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
M.ser = ser
local function fnv(s)
    local h = 0x811c9dc5
    for i = 1, #s do h = ((h ~ s:byte(i)) * 0x01000193) & 0xffffffff end
    return string.format("%08x", h)
end

-- Where a (project, repo, rev, term) build lives.
function M.key(project, repo, rev, term)
    return string.format("%s/build/%s/%s@%s-%s", M.WS, project, repo, rev, fnv(ser(term)))
end

-- Make <dir>/src/<repo>: a detached worktree at rev, or a symlink to the working tree.
function M.checkout(dir, repo, rev)
    local src = dir .. "/src/" .. repo
    if lfs.attributes(src) then return src end
    assert(sh("mkdir -p " .. dir .. "/src"))
    if rev == "working" then
        assert(sh("ln -s " .. M.WS .. "/" .. repo .. " " .. src))
    else
        local ok, out = sh("git -C " .. M.WS .. "/" .. repo .. " worktree add -q --detach " .. src .. " " .. rev)
        assert(ok, out)
    end
    return src
end

local memo = {}
-- build{project=, repo=, rev=, term=} -> record {repo, rev, dir, include_root, archives, defines}
function M.build(a)
    local term = a.term or {}
    local dir = M.key(a.project, a.repo, a.rev, term)
    if memo[dir] then print("memo hit " .. dir); return memo[dir] end
    local src = M.checkout(dir, a.repo, a.rev)
    local out = dir .. "/out"
    -- the term travels to the manifest as a file named by MUH_TERM
    local tf = io.open(dir .. "/term.lua", "w"); tf:write("return " .. ser(term)); tf:close()
    local env = "MUH_TERM=" .. dir .. "/term.lua MUH_SRC=" .. src .. " "
    local mb = env .. M.MB .. "/lua " .. M.MB .. "/build.lua "
    local margs = " --log plain -m " .. src .. "/manifest.lua -p " .. out
    -- default targets are only cmd: and test:, so build every lib: target explicitly
    local ok, list = sh(mb .. "list" .. margs, true)
    assert(ok, list)
    local targets = {}
    for t in list:gmatch("[^\n]+") do if t:match("^vendor:") or t:match("^lib:") or t:match("^cmd:") then targets[#targets + 1] = t end end
    local rank = { vendor = 1, lib = 2, cmd = 3 }
    table.sort(targets, function(x, y) return rank[x:match("^%a+")] < rank[y:match("^%a+")] end)
    for _, t in ipairs(targets) do
        local ok2, log = sh(mb .. "build -t " .. t .. margs, true)
        for line in log:gmatch("[^\n]+") do
            if not line:match("^%[wrote") then print("  " .. a.repo .. " | " .. line:gsub(M.WS, "WS")) end
        end
        assert(ok2, "build failed: " .. a.repo .. " " .. t)
    end
    local archives = {}
    if lfs.attributes(out .. "/lib") then
        for f in lfs.dir(out .. "/lib") do if f:match("%.a$") then archives[#archives + 1] = out .. "/lib/" .. f end end
    end
    table.sort(archives)
    -- the manifest reads its term from the environment, so its exports are read in a subprocess
    local okx, ex = sh(env .. M.MB .. "/lua -e 'package.path=\"" .. M.WS .. "/?.lua;\"..package.path; local w=require\"ws\"; io.write(w.ser(dofile(\"" .. src .. "/manifest.lua\").exports))'", true)
    assert(okx, ex)
    local exports = load("return " .. ex)()
    local roots = { dir .. "/src" }
    for _, d in ipairs(exports.include_dirs or {}) do roots[#roots + 1] = src .. "/" .. d end
    local rec = { repo = a.repo, rev = a.rev, dir = dir, include_roots = roots,
                  archives = archives, defines = exports.defines or {}, bin = out .. "/bin" }
    memo[dir] = rec
    return rec
end

function M.run(rec, name)
    local ok, out = sh(rec.bin .. "/" .. name)
    io.write(out)
    return ok, out
end
return M
