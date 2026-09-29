-- cli.lua — runs a project's recipe on this machine.
--
-- Usage:  build/lua scripts/cli.lua <path/to/recipe.lua> [--log color|plain|quiet]

local HERE    = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local domain  = dofile(HERE .. "domain.lua")
local project = dofile(HERE .. "project.lua")
local repo    = dofile(HERE .. "repo.lua")

--- The host for the platform this runs on.
local function platform_host()
    if package.config:sub(1, 1) == "\\" then error("no host for Windows yet", 0) end
    local p = io.popen("uname -s")
    local system = p and p:read("l") or ""
    if p then p:close() end
    if system == "Linux" then return dofile(HERE .. "host.linux.lua").new { domain = domain } end
    error("no host for " .. system .. " yet", 0)
end

local USAGE = "usage: build/lua scripts/cli.lua <path/to/recipe.lua> [--log color|plain|quiet]"

local function usage()
    io.stderr:write(USAGE, "\n")
    os.exit(2)
end

local recipe, log = nil, "color"
local i = 1
while arg[i] do
    if arg[i] == "--log" then
        log = arg[i + 1]
        if not domain.LOG_MODES[log or ""] then usage() end
        i = i + 2
    elseif not recipe and not arg[i]:match("^%-") then
        recipe, i = arg[i], i + 1
    else
        usage()
    end
end
if not recipe then usage() end

local ok, err = pcall(function()
    return repo.run { host = platform_host(), domain = domain, project = project, recipe = recipe, log = log }
end)
if not ok then
    io.stderr:write("muh-build: ", tostring(err), "\n")
    os.exit(1)
end
