-- repo.lua — runs a project's build script (recipe.lua) in a multiproject workspace.
--
-- A recipe declares what it requires and then builds, step by step:
--
--   return {
--       muh_build = "0.1",  -- the muh-build version this recipe is written for (a minimum)
--       requires = {        -- (repo, name, revision, params)
--           { repo = "lua-5.5.0", as = "lua", rev = "working" },
--           { repo = "L",         as = "l",   rev = "a1b2c3d4", params = { mode = "release" } },
--       },
--       run = function(repo)
--           local lua = repo.build "lua"
--           local l = repo.build { "l", deps = { lua } }
--           return repo.project { deps = { l, lua } }
--       end,
--   }
--
-- The declaration states essential inputs only and is checked before anything runs: every repo
-- exists in the workspace, every pinned revision exists, names are unique, and a repo is required
-- at most once. While running, the body may only build what it declared. Outputs are unchecked.
--
-- The workspace is the directory holding the project. A required repo builds into
-- <workspace>/build/<repo>@<rev>-<hash>/: `out/` for its build, and `src/<repo>/` for a checkout
-- at a pinned revision ("working" builds the repo in place). Relative paths in a recipe resolve
-- against the project root.
--
-- What makes a build (its identity): the revision, the manifest, the params, and the builds of its
-- dependencies. The hash covers the params, the names of the dependencies' builds, and, for
-- "working", the manifest's text (a pinned revision fixes its manifest). Equal names are equal builds,
-- so any recipe asking for the same thing reuses the same directory. Inside a directory, a target is
-- stale when an input (source, header, object, archive) is newer than it. Nothing else counts: not the
-- environment, not the toolchain binaries, not muh-build itself. Manifests must not read the
-- environment.
--
-- Each such directory holds build-info.lua, a Lua term saying how it was built: its name, repo,
-- revision, the manifest (and, for "working", the hash of its text), the params and
-- the names of the dependency builds. A project's own compile_commands.json holds its entries and
-- those of the builds it was given as dependencies; dependency builds write none.

local M = {}

---@class Requirement
---@field repo string     Directory name of the repo in the workspace
---@field as string       The name the recipe uses for it
---@field rev string      A commit, or "working" for the repo as it is on disk
---@field params table?   Overrides of the repo's manifest entries for this build (e.g. mode)

---@class RunArgs
---@field host table     The host every file access and command goes through
---@field domain table   Pure helpers: paths, logging, parsing
---@field project table  The single-project build (project.lua)
---@field recipe string  Path to the recipe
---@field log (string|fun(spec: string|{tag: string, level: string}, text: string))?

--- The requirements, checked before anything runs; returns them by name.
---@return table<string, Requirement>
local function check_requires(host, domain, ws, requires)
    assert(type(requires) == "table", "recipe: requires must be a list")
    local by_name, by_repo = {}, {}
    for i, r in ipairs(requires) do
        local where = "requires[" .. i .. "]"
        assert(type(r.repo) == "string", where .. ": repo must be a string")
        assert(type(r.as) == "string" and r.as:match("^[%a_][%w_]*$"), where .. ": as must be a name (letters, digits, _)")
        assert(type(r.rev) == "string", where .. ": rev must be a string")
        assert(r.params == nil or type(r.params) == "table", where .. ": params must be a table")
        if by_name[r.as] then error("recipe requires the name " .. r.as .. " twice", 0) end
        if by_repo[r.repo] then
            error(string.format("recipe requires repo %s twice (as %s and %s)", r.repo, by_repo[r.repo].as, r.as), 0)
        end
        local dir = domain.path_join(ws, r.repo)
        local attr = host.stat(dir)
        if not attr or attr.mode ~= "directory" then
            error("required repo " .. r.repo .. " is not in the workspace " .. ws, 0)
        end
        if r.rev ~= "working"
            and not host.exec({ "git", "-C", dir, "cat-file", "-e", r.rev .. "^{commit}" }, { quiet = true }) then
            error("revision " .. r.rev .. " of " .. r.repo .. " does not exist", 0)
        end
        by_name[r.as], by_repo[r.repo] = r, r
    end
    return by_name
end

---@param args RunArgs
---@return any  whatever the recipe's run returns
function M.run(args)
    local host = assert(args.host, "run: host is required")
    local domain = assert(args.domain, "run: domain is required")
    local project = assert(args.project, "run: project is required")
    local path = domain.path_normalize(domain.resolve_path(host.cwd(), assert(args.recipe, "run: recipe is required")))
    local dir = domain.parent_dir(path)
    local ws = domain.parent_dir(dir)
    local manifest_name = "manifest." .. assert(host.name, "run: host.name is required") .. ".lua"

    local text, err = host.read_file(path)
    assert(text, "cannot read recipe " .. path .. ": " .. tostring(err))
    local recipe = assert(load(text, "@" .. path, "t"))()
    assert(type(recipe) == "table" and type(recipe.run) == "function",
        "recipe " .. path .. " must return a table with a run function")
    domain.require_muh_build(recipe.muh_build, "recipe " .. path)
    local requires = check_requires(host, domain, ws, recipe.requires or {})

    local log = type(args.log) == "function" and args.log or domain.make_log_printer(args.log or "color")
    local repo = { host = host, domain = domain, dir = dir }
    local built = {} -- name -> {key, record}

    --- A path relative to the project root, made absolute.
    ---@param rel string
    ---@return string
    function repo.path(rel)
        return domain.path_normalize(domain.resolve_path(dir, rel))
    end

    --- One build of a repo. Everything that decides it (the revision, the params, the manifest's text
    --- for "working", the dependency builds) names its folder <ws>/build/<repo>@<rev>-<hash>/, which
    --- holds build-info.lua, out/, and src/<repo> for a pinned revision. Every build comes here: the
    --- required repos' and the project's own.
    ---@param name string  its key in `built`: a required name, or "(project)"
    ---@param r {repo: string, rev: string, params: table?}
    ---@param b {deps: BuildRecord[]?, target: string?}
    ---@param compile_db string?  where to write the compile database, if anywhere
    ---@return BuildRecord
    local function build_repo(name, r, b, compile_db)
        local deps = b.deps or {}
        local dep_outs = {}
        for _, d in ipairs(deps) do dep_outs[#dep_outs + 1] = d.out end
        local identity = { params = r.params or {}, deps = dep_outs }
        local manifest_hash
        if r.rev == "working" then
            local mtext, merr = host.read_file(domain.path_join(ws, r.repo, manifest_name))
            if not mtext then error("cannot read the manifest of " .. r.repo .. ": " .. tostring(merr), 0) end
            identity.manifest = mtext
            manifest_hash = domain.hash(mtext)
        end
        local key = domain.hash(domain.serialize(identity))
        if built[name] then
            if built[name].key ~= key then error(name .. " is built twice with different inputs", 0) end
            return built[name].record
        end

        local base = domain.path_join(ws, "build", r.repo .. "@" .. r.rev .. "-" .. key)
        local root = domain.path_join(ws, r.repo)
        if r.rev ~= "working" then
            root = domain.path_join(base, "src", r.repo)
            if not host.stat(root) then
                host.mkdir_p(domain.parent_dir(root))
                local cmd = { "git", "-C", domain.path_join(ws, r.repo), "worktree", "add", "--quiet", "--detach", root, r.rev }
                log("checkout", table.concat(cmd, " "))
                if not host.exec(cmd) then error("checkout failed: " .. table.concat(cmd, " "), 0) end
            end
        end

        local dep_names = {}
        for _, d in ipairs(deps) do dep_names[#dep_names + 1] = d.out:match("([^/]+)/out$") or d.out end
        host.write_file(domain.path_join(base, "build-info.lua"), "return " .. domain.serialize {
            name = r.repo .. "@" .. r.rev .. "-" .. key,
            repo = r.repo, rev = r.rev, manifest = manifest_name,
            manifest_hash = manifest_hash, params = r.params or {}, deps = dep_names,
        } .. "\n")

        local record = project.build {
            host = host,
            domain = domain,
            manifest = domain.path_join(root, manifest_name),
            params = r.params,
            deps = deps,
            out = domain.path_join(base, "out"),
            compile_db = compile_db,
            target = b.target,
            log = args.log,
        }
        built[name] = { key = key, record = record }
        return record
    end

    --- Build a required repo at its declared revision, with its declared params.
    ---@param b string|{[1]: string, deps: BuildRecord[]?, target: string?}
    ---@return BuildRecord
    function repo.build(b)
        if type(b) == "string" then b = { b } end
        local r = requires[b[1]]
        if not r then error(tostring(b[1]) .. " is not required by this recipe", 0) end
        return build_repo(b[1], r, b)
    end

    --- Build the project itself: its own repo, as it is on disk, like any other. Its compile database
    --- goes to <project>/build/compile_commands.json, where editors look.
    ---@param b {deps: BuildRecord[]?, params: table?, target: string?}?
    ---@return BuildRecord
    function repo.project(b)
        b = b or {}
        local own = { repo = dir:match("([^/\\]+)$"), rev = "working", params = b.params }
        return build_repo("(project)", own, b, domain.path_join(dir, "build", "compile_commands.json"))
    end

    --- Copy a build's products under `prefix`: executables to bin/, archives to lib/,
    --- public headers to include/<repo>/public/, so "<repo>/public/<pkg>/api.h" still resolves.
    ---@param record BuildRecord
    ---@param prefix string  relative to the project root
    ---@return string[]  the installed paths
    function repo.install(record, prefix)
        prefix = repo.path(prefix)
        local installed = {}
        local function copy(src, dest)
            local data, cerr = host.read_file(src)
            if not data then error("install failed: " .. tostring(cerr), 0) end
            host.write_file(dest, data)
            log("install", src .. " -> " .. dest)
            installed[#installed + 1] = dest
        end
        for _, name in ipairs(domain.sorted_keys(record.bins)) do
            copy(record.bins[name], domain.path_join(prefix, "bin", name))
        end
        for _, a in ipairs(record.archives) do
            copy(a, domain.path_join(prefix, "lib", a:match("([^/\\]+)$")))
        end
        local public = domain.path_join(record.root, "public")
        local found = host.scan(public)
        for _, path in ipairs(domain.sorted_keys(found)) do
            if found[path].mode == "file" and path:match("%.h$") then
                copy(path, domain.path_join(prefix, "include", record.repo, "public", path:sub(#public + 2)))
            end
        end
        return installed
    end

    return recipe.run(repo)
end

return M
