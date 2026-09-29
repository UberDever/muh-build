-- project.lua — the single-project build. Every filesystem access and command goes through a host.

---@class Manifest
---@field compile_cmd fun(out: string, src: string, extra_args: string[], m: Manifest): string  m: the manifest merged with the params
---@field link_cmd fun(out: string, ins: string[], extra_args: string[], m: Manifest): string
---@field archive_cmd fun(out: string, ins: string[], m: Manifest): string
---@field preconfigure fun(infra: Infra)?   Runs before targets are generated; external builds go here
---@field postconfigure fun(infra: Infra)?
---@field muh_build string                  The muh-build version it is written for (a minimum, see domain.VERSION)
---@field system_libs string[]?
---@field packages string[]?                The packages to build, in link order: dependents before their dependencies
---@field exports ManifestExports?            The public interface, carried by the build record

---@class ManifestExports
---@field include_dirs string[]?      Header directories in the sources, relative to the project root
---@field out_include_dirs string[]?  Generated header directories, relative to the build directory
---@field archives string[]?          Archives built outside the package graph, relative to the build directory
---@field defines string[]?           Interface defines: applied to the project's own sources and to consumers

--- Params override a manifest's entries for one build: merged deeply into the manifest, records key by
--- key, lists and other values replaced. The manifest is their schema: a params key must be a field
--- the manifest declares, or one muh-build defines for every manifest (PARAMS_FIELDS). `muh_build` is
--- not a param: it says which muh-build the manifest is written for.
---@alias Params table

---@class BuildRecord
---@field repo string
---@field root string
---@field out string
---@field include_dirs string[]
---@field defines string[]
---@field archives string[]
---@field link_flags string[]
---@field bins table<string, string>
---@field compile_commands table[]  this build's compile database entries: {directory, file, arguments, output}

--- What a manifest's pre/postconfigure hooks receive.
---@class Infra
---@field host table
---@field domain table
---@field manifest Manifest?  the manifest merged with the params
---@field root string?        project root
---@field build_dir string?   absolute build directory
---@field log fun(spec: string|{tag: string, level: string}, text: string)
local Infra   = {}
Infra.__index = Infra

---@param host table
---@param domain table
---@return Infra
function Infra.new(host, domain)
    local self = setmetatable({}, Infra)
    self.host = host
    self.domain = domain
    self.log = domain.make_log_printer("color")
    return self
end

-- ── Target ─────────────────────────────────────────────────────────────────

---@class Target
---@field name string           Output path (file or sentinel)
---@field ins string[]          Input paths (source files, object files, etc.)
---@field deps Target[]         Targets that must be built first
---@field command fun(name: string, ins: string[]): string   Returns shell command string
---@field tag string            Label for printing ("compile", "archive", etc.)
local Target = {}
Target.__index = Target

function Target.new(fields)
    local self = setmetatable({}, Target)
    self.name = assert(fields.name, "target missing 'name'")
    self.ins = fields.ins or {}
    self.deps = fields.deps or {}
    self.command = assert(fields.command, "target missing 'command'")
    self.tag = fields.tag or "build"
    return self
end

---@param host table
---@param log fun(spec: string|{tag: string, level: string}, text: string)
---@return boolean
function Target:run(host, domain, log)
    host.mkdir_p(domain.parent_dir(self.name))
    local cmd_str = self.command(self.name, self.ins)
    log(self.tag, cmd_str)
    return host.exec(cmd_str)
end

-- ── Snapshot ───────────────────────────────────────────────────────────────

--- The filesystem as it was when a project build started: a few trees, each read by one host.scan.
--- A path outside them is asked of the host by itself. The snapshot is never refreshed: what the build
--- itself produces is tracked by MuhNinja.built instead.
---@class Snapshot
local Snapshot = {}
Snapshot.__index = Snapshot

---@param roots string[]  directories to scan; nested or repeated ones are scanned once
function Snapshot.new(host, domain, roots)
    local self = setmetatable({ host = host, domain = domain, roots = {}, entries = {} }, Snapshot)
    for _, root in ipairs(roots) do
        root = domain.path_normalize(root)
        if not self:covers(root) then
            self.roots[#self.roots + 1] = root
            for path, entry in pairs(host.scan(root)) do self.entries[path] = entry end
        end
    end
    return self
end

function Snapshot:covers(path)
    for _, root in ipairs(self.roots) do
        if self.domain.is_within(path, root) then return true end
    end
    return false
end

---@return {mode: string, mtime: number}?
function Snapshot:stat(path)
    if self:covers(path) then return self.entries[path] end
    return self.host.stat(path)
end

--- The names directly under a scanned directory, sorted.
function Snapshot:list(dir)
    local names = {}
    for path in pairs(self.entries) do
        if self.domain.parent_dir(path) == dir then names[#names + 1] = path:sub(#dir + 2) end
    end
    table.sort(names)
    return names
end

function Snapshot:is_dir(path)
    local e = self:stat(path)
    return e ~= nil and e.mode == "directory"
end

-- ── MuhNinja ───────────────────────────────────────────────────────────────

---@class MuhNinja
---@field host table
---@field domain table
---@field root string            Project root
---@field manifest Manifest
---@field snapshot Snapshot
---@field built table<string, boolean>  outputs produced in this run: newer than anything in the snapshot
---@field log fun(spec: string|{tag: string, level: string}, text: string)
local MuhNinja = {}
MuhNinja.__index = MuhNinja

---@param host table
---@param domain table
---@param root string
---@param mn Manifest
---@param log fun(spec: string|{tag: string, level: string}, text: string)
---@return MuhNinja
function MuhNinja.new(host, domain, root, mn, snapshot, log)
    local self = setmetatable({}, MuhNinja)
    self.host = host
    self.domain = domain
    self.root = root
    self.manifest = mn
    self.snapshot = snapshot
    self.built = {}
    self.log = assert(log, "muhninja missing log")
    return self
end

--- A target is up to date when its output exists and every input is older than it. An input built in
--- this run is newer by definition. An input as old as the output counts as newer: timestamps may be
--- coarse (FAT: 2 s), so equal times prove nothing; the cost is an occasional needless rebuild.
---@param tgt Target
---@return boolean
function MuhNinja:already_built(tgt)
    if self.built[tgt.name] then return true end -- another target needed it first, in this run
    local out = self.snapshot:stat(tgt.name)
    if not out then return false end
    local function older(path)
        if self.built[path] then return false end
        local attr = self.snapshot:stat(path)
        return attr ~= nil and attr.mtime < out.mtime
    end
    for _, src in ipairs(tgt.ins) do
        if not older(src) then return false end
    end
    for _, dep in ipairs(tgt.deps) do
        if not older(dep.name) then return false end
    end
    return true
end

---@param root Target
---@return Target[]
function MuhNinja.topo_sort(root)
    local order = {}
    local visited = {}
    local function visit(node)
        if visited[node] then return end
        visited[node] = true
        for i = 1, #node.deps do
            visit(node.deps[i])
        end
        order[#order + 1] = node
    end
    visit(root)
    return order
end

---@param root Target
---@return boolean
function MuhNinja:run(root)
    local order = MuhNinja.topo_sort(root)
    for i = 1, #order do
        local node = order[i]
        if not self:already_built(node) then
            if not node:run(self.host, self.domain, self.log) then return false end
            self.built[node.name] = true
        end
    end
    return true
end

--- The headers a compiled object depended on last time, from its depfile.
---@param dep_name string
---@return string[]?, string?
function MuhNinja:load_depfile(dep_name)
    local host = self.host
    local domain = self.domain
    local text, err = host.read_file(dep_name)
    if not text then return nil, err end
    local raw, perr = domain.parse_depfile(text)
    if not raw then return nil, perr end
    local dir = domain.parent_dir(dep_name) or "."
    local deps, seen = {}, {}
    for _, d in ipairs(raw) do
        local resolved = domain.path_normalize(domain.resolve_path(dir, d))
        if not seen[resolved] then
            seen[resolved] = true
            deps[#deps + 1] = resolved
        end
    end
    return deps, nil
end

-- ── Target constructors ────────────────────────────────────────────────────

---@param src string
---@param out string
---@param extra_args string[]
---@param deps Target[]
---@return Target
function MuhNinja:target_compile(src, out, extra_args, deps)
    local mn = self.manifest
    local ins = { src }
    local dep_name = out .. ".d"

    local out_attr = self.snapshot:stat(out)
    local dep_attr = self.snapshot:stat(dep_name)
    if out_attr and not dep_attr then
        ins[#ins + 1] = dep_name
    elseif out_attr and dep_attr then
        local discovered, err = self:load_depfile(dep_name)
        if discovered == nil and err then
            self.log({ tag = "build", level = "warn" }, "cannot load dependencies for " .. out .. ": " .. err)
        elseif discovered then
            for _, dep in ipairs(discovered) do
                if dep ~= src then
                    ins[#ins + 1] = dep
                end
            end
        end
    end

    return Target.new({
        name = out,
        ins = ins,
        deps = deps,
        tag = "compile",
        command = function(name, target_ins)
            return mn.compile_cmd(name, target_ins[1], extra_args, mn)
        end,
    })
end

---@param ins string[]
---@param out string
---@param extra_args string[]
---@param deps Target[]
---@return Target
function MuhNinja:target_link(ins, out, extra_args, deps)
    local mn = self.manifest
    return Target.new({
        name = out,
        ins = ins,
        deps = deps,
        tag = "link_exe",
        command = function(name, the_ins)
            return mn.link_cmd(name, the_ins, extra_args, mn)
        end,
    })
end

---@param ins string[]
---@param out string
---@param deps Target[]
---@return Target
function MuhNinja:target_archive(ins, out, deps)
    local mn = self.manifest
    local host = self.host
    return Target.new({
        name = out,
        ins = ins,
        deps = deps,
        tag = "archive",
        command = function(name, the_ins)
            host.remove(name)
            return mn.archive_cmd(name, the_ins, mn)
        end,
    })
end

-- ── MuhCmake (project graph builder) ───────────────────────────────────────

---@class NamedEntry
---@field target Target
---@field kind string

---@class TargetsResult
---@field named table<string, NamedEntry>
---@field defaults {name: string, target: Target}[]
---@field compile_targets Target[]
---@field build_dir string

---@class MuhCmake
---@field host table
---@field domain table
---@field root string
---@field manifest Manifest
---@field ninja MuhNinja
---@field log fun(spec: string|{tag: string, level: string}, text: string)
---@field packages table<string, {name: string, dir: string, srcs: string[], tests: string[]}>
---@field cmds table<string, {name: string, dir: string, src: string}>
local MuhCmake = {}
MuhCmake.__index = MuhCmake

---@param mn Manifest
---@param ninja MuhNinja
---@return MuhCmake
---@param deps BuildRecord[]
---@param build_dir string
function MuhCmake.new(mn, ninja, deps, build_dir)
    local self = setmetatable({}, MuhCmake)
    self.deps = deps
    self.build_dir = build_dir
    self.host = ninja.host
    self.domain = ninja.domain
    self.root = ninja.root
    self.manifest = mn
    self.ninja = ninja
    self.log = ninja.log
    self.packages = {}
    self.cmds = {}
    return self
end

--- The packages the manifest lists, in its order: the order they are built and linked in.
--- A package lives in public/<name> (includable from any repo) or internal/<name> (only from its own).
--- Directories the manifest does not list are not built.
function MuhCmake:discover_packages()
    local snap = self.ninja.snapshot
    local domain = self.domain
    local listed = self.manifest.packages
    self.package_order = {}
    if listed == nil then
        for _, kind in ipairs { "public", "internal" } do
            local kind_dir = domain.path_join(self.root, kind)
            if snap:is_dir(kind_dir) and #snap:list(kind_dir) > 0 then
                error("manifest of " .. self.root .. " must list its packages: it has " .. kind .. "/", 0)
            end
        end
        return
    end
    for _, name in ipairs(listed) do
        if self.packages[name] then error("package " .. name .. " is listed twice in " .. self.root, 0) end
        local pub = domain.path_join(self.root, "public", name)
        local int = domain.path_join(self.root, "internal", name)
        local kind, dir
        if snap:is_dir(pub) then kind, dir = "public", pub end
        if snap:is_dir(int) then
            if kind then error("package " .. name .. " exists in both public/ and internal/ of " .. self.root, 0) end
            kind, dir = "internal", int
        end
        if not kind then error("listed package " .. name .. " is in neither public/ nor internal/ of " .. self.root, 0) end

        local pkg = { name = name, kind = kind, dir = dir, srcs = {}, tests = {} }
        for _, file in ipairs(snap:list(dir)) do
            if file:match("%.c$") then
                local fpath = domain.path_join(dir, file)
                if file:match("_test%.c$") then pkg.tests[#pkg.tests + 1] = fpath
                else pkg.srcs[#pkg.srcs + 1] = fpath end
            end
        end
        table.sort(pkg.srcs)
        table.sort(pkg.tests)
        self.packages[name] = pkg
        self.package_order[#self.package_order + 1] = name
    end
end

function MuhCmake:discover_cmds()
    local snap = self.ninja.snapshot
    local domain = self.domain
    local cmd_dir = domain.path_join(self.root, "cmd")
    if not snap:is_dir(cmd_dir) then return end -- a project without executables
    for _, entry in ipairs(snap:list(cmd_dir)) do
        local full = domain.path_join(cmd_dir, entry)
        if not snap:is_dir(full) then goto continue end

        local main_c = domain.path_join(full, "main.c")
        if not snap:stat(main_c) then goto continue end

        self.cmds[entry] = { name = entry, dir = full, src = main_c }

        ::continue::
    end
end

---@param obj_paths string[]
---@param obj_targets Target[]
---@param all_lib_targets Target[]
---@param extra_archives string[]  archives from outside the package graph, linked after the project's own
---@return string[] link_ins
---@return Target[] link_deps
local function assemble_link_deps(obj_paths, obj_targets, all_lib_targets, extra_archives)
    local link_ins, link_deps = {}, {}
    for i, p in ipairs(obj_paths) do
        link_ins[#link_ins + 1] = p
        link_deps[#link_deps + 1] = obj_targets[i]
    end
    for _, lib_t in ipairs(all_lib_targets) do
        link_ins[#link_ins + 1] = lib_t.name
        link_deps[#link_deps + 1] = lib_t
    end
    for _, a in ipairs(extra_archives) do link_ins[#link_ins + 1] = a end
    return link_ins, link_deps
end

---@return TargetsResult
function MuhCmake:generate()
    self:discover_packages()
    self:discover_cmds()

    local host = self.host

    local domain = self.domain
    local mn = self.manifest
    local build_dir = self.build_dir

    local exports = mn.exports or {}
    local common_cflags, link_extra, link_flags, seen_link_flags = {}, {}, {}, {}
    local function add_link_flag(f)
        if not seen_link_flags[f] then
            seen_link_flags[f] = true
            link_flags[#link_flags + 1] = f
        end
    end

    -- Dependencies' records first: their include directories must win over the workspace root,
    -- so a pinned checkout of a repo is found before its working tree.
    for _, dep in ipairs(self.deps) do
        for _, d in ipairs(dep.include_dirs or {}) do common_cflags[#common_cflags + 1] = "-I" .. d end
        for _, d in ipairs(dep.defines or {}) do common_cflags[#common_cflags + 1] = "-D" .. d end
        for _, a in ipairs(dep.archives or {}) do link_extra[#link_extra + 1] = a end
        for _, f in ipairs(dep.link_flags or {}) do add_link_flag(f) end
    end

    -- Includes name the repo everywhere in the workspace ("<repo>/public/<pkg>/api.h"),
    -- so every compile searches the directory that holds the project.
    common_cflags[#common_cflags + 1] = "-I" .. domain.parent_dir(self.root)
    for _, d in ipairs(exports.include_dirs or {}) do
        common_cflags[#common_cflags + 1] = "-I" .. domain.path_normalize(domain.path_join(self.root, d))
    end
    for _, d in ipairs(exports.out_include_dirs or {}) do
        common_cflags[#common_cflags + 1] = "-I" .. domain.path_normalize(domain.path_join(build_dir, d))
    end
    -- This project's interface defines apply to its own sources as well.
    for _, d in ipairs(exports.defines or {}) do common_cflags[#common_cflags + 1] = "-D" .. d end
    for _, f in ipairs(mn.system_libs or {}) do add_link_flag(f) end

    -- The same -I or -D from several records counts once, at its first position.
    local seen_cflags, unique_cflags = {}, {}
    for _, f in ipairs(common_cflags) do
        if not seen_cflags[f] then
            seen_cflags[f] = true
            unique_cflags[#unique_cflags + 1] = f
        end
    end
    common_cflags = unique_cflags

    local all_lib_targets = {}
    local named = {}
    local default_targets = {}
    local compile_targets = {}


    local pkg_names = self.package_order -- the manifest's order is the link order

    for _, name in ipairs(pkg_names) do
        local pkg = self.packages[name]
        local obj_targets = {}
        local obj_paths = {}

        for _, src in ipairs(pkg.srcs) do
            local basename = src:match("([^/\\]+)%.c$")
            local obj_path = domain.path_join(build_dir, "objs", pkg.kind, name, basename .. ".o")
            local t = self.ninja:target_compile(src, obj_path, common_cflags, {})
            obj_targets[#obj_targets + 1] = t
            obj_paths[#obj_paths + 1] = obj_path
            compile_targets[#compile_targets + 1] = t
        end

        if #obj_paths > 0 then
            local lib_path = domain.path_join(build_dir, "lib", "lib" .. name .. ".a")
            local lib_t = self.ninja:target_archive(obj_paths, lib_path, obj_targets)
            all_lib_targets[#all_lib_targets + 1] = lib_t
            named["lib:" .. name] = { target = lib_t, kind = "lib" }
            -- libraries are products too: a project may have no cmd/ to pull them in
            default_targets[#default_targets + 1] = { name = "lib:" .. name, target = lib_t }
        end
    end

    local cmd_names = domain.sorted_keys(self.cmds)

    for _, name in ipairs(cmd_names) do
        local cmd_info = self.cmds[name]
        local obj_path = domain.path_join(build_dir, "objs", "cmd", name, "main.o")
        local main_t = self.ninja:target_compile(cmd_info.src, obj_path, common_cflags, {})
        compile_targets[#compile_targets + 1] = main_t

        local link_ins, link_deps = assemble_link_deps({ obj_path }, { main_t }, all_lib_targets, link_extra)

        local exe_path = domain.path_join(build_dir, "bin", name)
        local exe_t = self.ninja:target_link(link_ins, exe_path, link_flags, link_deps)
        local tname = "cmd:" .. name
        named[tname] = { target = exe_t, kind = "cmd" }
        default_targets[#default_targets + 1] = { name = tname, target = exe_t }
    end

    for _, name in ipairs(pkg_names) do
        local pkg = self.packages[name]
        if #pkg.tests > 0 then
            local test_obj_targets = {}
            local test_obj_paths = {}

            for _, test_src in ipairs(pkg.tests) do
                local basename = test_src:match("([^/\\]+)%.c$")
                local obj_path = domain.path_join(build_dir, "objs", pkg.kind, name, basename .. ".o")
                local test_obj_t = self.ninja:target_compile(test_src, obj_path, common_cflags, {})
                compile_targets[#compile_targets + 1] = test_obj_t
                test_obj_targets[#test_obj_targets + 1] = test_obj_t
                test_obj_paths[#test_obj_paths + 1] = obj_path
            end

            -- Link all test objects for this package into a single test binary
            local link_ins, link_deps = assemble_link_deps(test_obj_paths, test_obj_targets, all_lib_targets, link_extra)

            local test_exe_path = domain.path_join(build_dir, "bin", name .. "_test")
            local test_t = self.ninja:target_link(link_ins, test_exe_path, link_flags, link_deps)
            local tname = "test:" .. name
            named[tname] = { target = test_t, kind = "test" }
            default_targets[#default_targets + 1] = { name = tname, target = test_t }
        end
    end

    return {
        named = named,
        defaults = default_targets,
        compile_targets = compile_targets,
        build_dir = build_dir,
    }
end

---@param targets_result TargetsResult
--- This build's compile database entries.
---@return table[]
function MuhCmake:compile_entries(targets_result)
    local entries = {}
    for _, t in ipairs(targets_result.compile_targets) do
        local args = {}
        for word in t.command(t.name, t.ins):gmatch("%S+") do args[#args + 1] = word end
        entries[#entries + 1] = { directory = self.root, file = t.ins[1], arguments = args, output = t.name }
    end
    return entries
end

--- A compile_commands.json holding `entries`.
local function compile_db_json(domain, entries)
    local items = {}
    for _, e in ipairs(entries) do
        local args = {}
        for i, a in ipairs(e.arguments) do args[i] = '"' .. domain.json_escape(a) .. '"' end
        items[#items + 1] = string.format(
            '  {\n    "directory": "%s",\n    "file": "%s",\n    "arguments": [%s],\n    "output": "%s"\n  }',
            domain.json_escape(e.directory), domain.json_escape(e.file), table.concat(args, ", "),
            domain.json_escape(e.output))
    end
    return "[\n" .. table.concat(items, ",\n") .. "\n]\n"
end

---@param defaults {name: string, target: Target}[]
---@return boolean
local function run_defaults(ninja, defaults)
    for _, dt in ipairs(defaults) do
        if not ninja:run(dt.target) then
            ninja.log({ tag = "build", level = "error" }, dt.target.name)
            return false
        end
    end
    return true
end

-- ── Module API ─────────────────────────────────────────────────────────────

local M = {}
M.Infra = Infra
M.run_defaults = run_defaults

--- Deep merge: records merge key by key, `over` wins; a list (or any non-table) in `over` replaces.
---@param base any
---@param over any
---@return any
function M.merge(base, over)
    if type(base) ~= "table" or type(over) ~= "table" or over[1] ~= nil then
        return over
    end
    local r = {}
    for k, v in pairs(base) do r[k] = v end
    for k, v in pairs(over) do r[k] = M.merge(base[k], v) end
    return r
end

-- A repo may appear only once among a build's dependencies: two builds of one repo
-- would put two versions of its symbols into one link.
local function check_deps(deps)
    local by_repo = {}
    for _, dep in ipairs(deps or {}) do
        local prev = by_repo[dep.repo]
        if prev and prev.out ~= dep.out then
            error(string.format("repo %s appears twice among dependencies: %s and %s", dep.repo, prev.out, dep.out), 0)
        end
        by_repo[dep.repo] = dep
    end
end

--- The fields muh-build defines for every manifest, so params may set them even where a manifest omits them.
local PARAMS_FIELDS = { packages = true, exports = true, system_libs = true }

--- Refuse params that the manifest does not declare: a misspelt override would otherwise do nothing.
local function check_params(declared, params, path)
    for key in pairs(params) do
        if key == "muh_build" then
            error("params cannot set " .. key .. " (manifest " .. path .. ")", 0)
        end
        if declared[key] == nil and not PARAMS_FIELDS[key] then
            error("params set " .. tostring(key) .. ", which manifest " .. path .. " does not declare", 0)
        end
    end
end

---@class ConfigureArgs
---@field host table                The host every file access and command goes through
---@field domain table              Pure helpers: paths, logging, parsing
---@field manifest string           Path to the manifest; its directory is the project root
---@field params Params?            Overrides of the manifest's entries for this build
---@field deps BuildRecord[]?       Records of the builds this one compiles and links against
---@field out string?               Build directory (default: <project root>/build); relative to the host's current directory
---@field compile_db boolean?       Write compile_commands.json: this build's entries and its deps'
---@field log (string|fun(spec: string|{tag: string, level: string}, text: string))?  Log mode or printer
---@field infra Infra?              Passed to the manifest's pre/postconfigure hooks

---@param args ConfigureArgs
function M.configure(args)
    local host = assert(args.host, "configure: host is required")
    local domain = assert(args.domain, "configure: domain is required")
    local path = assert(args.manifest, "configure: manifest is required")
    path = domain.path_normalize(domain.resolve_path(host.cwd(), path))
    local root = domain.path_normalize(domain.parent_dir(path))

    local text, err = host.read_file(path)
    assert(text, "cannot read manifest " .. path .. ": " .. tostring(err))
    local declared = assert(load(text, "@" .. path, "t"))()
    domain.require_muh_build(declared.muh_build, "manifest " .. path)
    local params, deps = args.params or {}, args.deps or {}
    check_params(declared, params, path)
    local mn = M.merge(declared, params)
    local build_dir = args.out and domain.resolve_path(host.cwd(), args.out) or domain.path_join(root, "build")
    check_deps(deps)

    local infra = args.infra or Infra.new(host, domain)
    infra.host = host
    infra.manifest = mn
    infra.root = root
    infra.build_dir = build_dir
    if type(args.log) == "function" then infra.log = args.log
    elseif args.log then infra.log = domain.make_log_printer(args.log) end

    if mn.preconfigure then mn.preconfigure(infra) end
    -- the trees this build reads: its own, and each dependency's sources and build
    local trees = { root, infra.build_dir }
    for _, dep in ipairs(deps) do
        trees[#trees + 1] = dep.root
        trees[#trees + 1] = dep.out
    end
    local snapshot = Snapshot.new(host, domain, trees)
    local ninja = MuhNinja.new(host, domain, root, mn, snapshot, infra.log)
    local cmake = MuhCmake.new(mn, ninja, deps, build_dir)
    local targets = cmake:generate()
    if mn.postconfigure then mn.postconfigure(infra) end

    return {
        host = host,
        domain = domain,
        manifest = mn,
        root = root,
        infra = infra,
        ninja = ninja,
        cmake = cmake,
        targets = targets,
        deps = deps,
    }
end

--- What a finished build offers its consumers.
---@return BuildRecord
function M.record(ctx)
    local host = ctx.host
    local domain = ctx.domain
    local mn, t = ctx.manifest, ctx.targets
    local exports = mn.exports or {}
    -- includes name the repo ("L/public/pkg/api.h"), so consumers search the repo's parent
    local include_dirs = { domain.parent_dir(ctx.root) }
    for _, d in ipairs(exports.include_dirs or {}) do
        include_dirs[#include_dirs + 1] = domain.path_normalize(domain.path_join(ctx.root, d))
    end
    for _, d in ipairs(exports.out_include_dirs or {}) do
        include_dirs[#include_dirs + 1] = domain.path_normalize(domain.path_join(t.build_dir, d))
    end
    local archives, bins = {}, {}
    for _, name in ipairs(ctx.cmake.package_order) do
        local e = t.named["lib:" .. name]
        if e then archives[#archives + 1] = e.target.name end
    end
    for name, e in pairs(t.named) do
        if e.kind == "cmd" then bins[name:match("^cmd:(.*)$")] = e.target.name end
    end
    for _, a in ipairs(exports.archives or {}) do archives[#archives + 1] = domain.path_join(t.build_dir, a) end
    return {
        repo = ctx.root:match("([^/\\]+)$"),
        root = ctx.root,
        out = t.build_dir,
        include_dirs = include_dirs,
        defines = exports.defines or {},
        archives = archives,
        link_flags = mn.system_libs or {},
        bins = bins,
        compile_commands = ctx.cmake:compile_entries(t),
    }
end

---@param args ConfigureArgs|{target: string?}
---@return BuildRecord
function M.build(args)
    local ctx = M.configure(args)
    local ok
    if args.target then
        local entry = ctx.targets.named[args.target]
        assert(entry, "Unknown target '" .. args.target .. "'")
        ok = ctx.ninja:run(entry.target)
    else
        ok = run_defaults(ctx.ninja, ctx.targets.defaults)
    end
    if not ok then error("build failed in " .. ctx.root, 0) end
    local record = M.record(ctx)
    if args.compile_db then
        local entries = {}
        for _, e in ipairs(record.compile_commands) do entries[#entries + 1] = e end
        for _, dep in ipairs(ctx.deps) do
            for _, e in ipairs(dep.compile_commands or {}) do entries[#entries + 1] = e end
        end
        local path = ctx.domain.path_join(ctx.targets.build_dir, "compile_commands.json")
        ctx.host.write_file(path, compile_db_json(ctx.domain, entries))
        ctx.infra.log("wrote", path)
    end
    return record
end

return M
