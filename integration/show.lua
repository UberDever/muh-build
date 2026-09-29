#!/usr/bin/env lua
-- show.lua — runs a recipe on the mock workspace and prints what happened: the commands, in order,
-- then the files the run created or changed, as a tree.
--
-- Usage:  lua integration/show.lua <project> [recipe.lua]
--         lua integration/show.lua raytracer
--         lua integration/show.lua asset-tool
--         lua integration/show.lua edit          (raytracer and asset-tool, then an edit in mathx)

local HERE    = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local SCRIPTS = HERE .. "../scripts/"
local domain  = dofile(SCRIPTS .. "domain.lua")
local project = dofile(SCRIPTS .. "project.lua")
local repo    = dofile(SCRIPTS .. "repo.lua")
local mock    = dofile(HERE .. "mock_host.lua")

local WS = "/ws"
local fixtures = dofile(HERE .. "workspace.lua")
local host = mock.new { domain = domain, cwd = WS, tools = mock.tools() }
fixtures.write(host, domain, WS, fixtures.load(), host.add_revision)

--- The paths written since write number `first`, as an indented tree under WS.
local function tree(first)
    local paths, seen = {}, {}
    for i = first, #host.writes do
        local p = host.writes[i]
        if not seen[p] and host.files[p] then seen[p] = true; paths[#paths + 1] = p:sub(#WS + 2) end
    end
    table.sort(paths)
    local lines, shown = {}, {}
    for _, p in ipairs(paths) do
        local parts = {}
        for seg in p:gmatch("[^/]+") do parts[#parts + 1] = seg end
        for depth = 1, #parts do
            local key = table.concat(parts, "/", 1, depth)
            if not shown[key] then
                shown[key] = true
                lines[#lines + 1] = string.rep("  ", depth - 1) .. parts[depth] .. (depth < #parts and "/" or "")
            end
        end
    end
    return table.concat(lines, "\n")
end

local function show(name, recipe)
    local first_cmd, first_write = #host.commands + 1, #host.writes + 1
    local ok, err = pcall(repo.run, {
        host = host, domain = domain, project = project,
        recipe = domain.path_join(WS, name, recipe or "recipe.lua"),
        log = function() end,
    })
    print(("── %s%s %s"):format(name, recipe and (" (" .. recipe .. ")") or "", ok and "" or ("FAILED: " .. tostring(err))))
    print("commands:")
    for i = first_cmd, #host.commands do print("  " .. host.commands[i]) end
    if #host.commands < first_cmd then print("  (none)") end
    print("files written:")
    local t = tree(first_write)
    print(t ~= "" and t:gsub("[^\n]+", "  %0") or "  (none)")
    print()
end

local which = arg[1] or "raytracer"
if which == "edit" then
    show("raytracer")
    show("asset-tool")
    host.touch(WS .. "/mathx/public/vec/api.h")
    print("── (mathx/public/vec/api.h edited)\n")
    show("raytracer")
    show("asset-tool")
else
    show(which, arg[2])
end
