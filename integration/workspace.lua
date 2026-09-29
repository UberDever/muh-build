-- workspace.lua — the integration workspace: projects as data, written onto a host.
--
-- A project file (integration/<name>.lua) returns its files (path -> contents), or
-- {files = ..., revisions = {rev -> files}} when it has older commits.

local HERE = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"

local M = {}

M.ALL = { "muh-game", "lua-5.5.0", "SDL3-3.4.8", "stb_ds-0.67",
          "mathx", "physics", "raytracer", "sandbox", "asset-tool", "viewer" }

--- The projects `names` (default: all), as {name -> {files, revisions}}.
function M.load(names)
    local projects = {}
    for _, name in ipairs(names or M.ALL) do
        local data = dofile(HERE .. name .. ".lua")
        if data.files then
            projects[name] = { files = data.files, revisions = data.revisions or {} }
        else
            projects[name] = { files = data, revisions = {} }
        end
    end
    return projects
end

--- Write `projects` under `ws`. `commit(dir, rev, files)` records an older revision of a repo; it is
--- called for each revision (in name order) before the working files are written.
function M.write(host, domain, ws, projects, commit)
    for _, name in ipairs(M.sorted(projects)) do
        local p, dir = projects[name], domain.path_join(ws, name)
        host.mkdir_p(dir)
        for _, rev in ipairs(M.sorted(p.revisions)) do commit(dir, rev, p.revisions[rev]) end
        for path, text in pairs(p.files) do host.write_file(domain.path_join(dir, path), text) end
    end
end

function M.sorted(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

return M
