
---@class Domain
local M = {}

--- The version of muh-build. Manifests and recipes state, as `muh_build`, the version they are written
--- for: a minimum, as Go's `go` line. An older muh-build refuses them; a newer one keeps building them,
--- and where its behaviour changes, it chooses by the version they state.
M.VERSION = "0.1"

--- Refuse a manifest or recipe that states no muh-build version, or a newer one than this.
---@param declared any  its `muh_build` field
---@param what string   what it is, for the message
function M.require_muh_build(declared, what)
    if type(declared) ~= "string" then
        error(what .. " must state the muh-build version it is written for: muh_build = \"" .. M.VERSION .. "\"", 0)
    end
    if M.compare_versions(M.parse_version(declared), M.parse_version(M.VERSION)) > 0 then
        error(what .. " is written for muh-build " .. declared .. "; this is muh-build " .. M.VERSION, 0)
    end
end

---@param ... string
---@return string
function M.path_join(...)
    local args = { ... }
    local sep = "/"
    return (table.concat(args, sep):gsub(sep .. sep .. "+", sep))
end

---@param p string
---@return string
function M.path_normalize(p)
    local parts = {}
    for seg in p:gmatch("[^/\\]+") do
        if seg == ".." and #parts > 0 and parts[#parts] ~= ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    local result = table.concat(parts, "/")
    if p:sub(1, 1) == "/" or p:sub(1, 1) == "\\" then
        result = "/" .. result
    end
    return result
end

---@param path string
---@return boolean
function M.is_absolute(path)
    return path:sub(1, 1) == "/"
        or path:match("^%a:[/\\]") ~= nil
        or path:match("^[/\\][/\\]") ~= nil
end

---@param base string
---@param p string
---@return string
function M.resolve_path(base, p)
    if M.is_absolute(p) then return p end
    return M.path_join(base, p)
end

---@param path string
---@return string?
function M.parent_dir(path)
    return path:match("(.*)[/\\][^/\\]+$")
end

--- Whether `path` is `dir` or lies under it.
---@param path string
---@param dir string
---@return boolean
function M.is_within(path, dir)
    return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

---@param t table
---@return string[]
function M.sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

---@param s string
---@return string
function M.json_escape(s)
    return (s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'))
end

M.LOG_MODES = {
    color = true,
    plain = true,
    quiet = true,
}

M.LOG_LEVELS = {
    debug = true,
    info = true,
    warn = true,
    error = true,
}

M.KNOWN_LOG_TAGS = {
    compile = true,
    archive = true,
    link_exe = true,
    vendor_lib = true,
    vendor_clean = true,
    install = true,
    rm = true,
    rmdir = true,
    wrote = true,
    build = true,
}

local ANSI_RESET = "\27[0m"
local ANSI_BOLD = "\27[1m"
local ANSI_DIM = "\27[2m"

local LOG_STYLE_DEFAULT = {
    debug = ANSI_DIM,
    info = ANSI_BOLD,
    warn = "\27[33m",
    error = "\27[1;31m",
}

local LOG_STYLE = {
    compile = { info = "\27[1;32m" },
    archive = { info = "\27[1;33m" },
    link_exe = { info = "\27[1;36m" },
    vendor_lib = { info = "\27[1;35m" },
    vendor_clean = { info = "\27[0;35m" },
    install = { info = "\27[1;34m" },
    rm = { info = "\27[0;31m" },
    rmdir = { info = "\27[0;31m" },
}

---@param spec string|{tag: string, level: string}
---@return {tag: string, level: string}
function M.log_normalize_spec(spec)
    if type(spec) == "string" then
        spec = { tag = spec, level = "info" }
    end
    assert(type(spec) == "table", "log spec must be string or table")
    local tag = assert(spec.tag, "log spec missing tag")
    local level = spec.level or "info"
    if not M.KNOWN_LOG_TAGS[tag] then tag = "build" end
    if not M.LOG_LEVELS[level] then level = "info" end
    return { tag = tag, level = level }
end

---@param mode string
---@param spec string|{tag: string, level: string}
---@return boolean
function M.log_should_emit(mode, spec)
    local normalized = M.log_normalize_spec(spec)
    assert(M.LOG_MODES[mode], "unknown log mode '" .. tostring(mode) .. "'")
    if mode == "quiet" then
        return normalized.level == "warn" or normalized.level == "error"
    end
    return true
end

---@param spec string|{tag: string, level: string}
---@return string
function M.log_prefix_plain(spec)
    local normalized = M.log_normalize_spec(spec)
    return string.format("[%s.%s]", normalized.tag, normalized.level)
end

---@param mode string
---@param spec string|{tag: string, level: string}
---@return string
function M.log_prefix(mode, spec)
    local normalized = M.log_normalize_spec(spec)
    local plain = M.log_prefix_plain(normalized)
    if mode ~= "color" then
        return plain
    end
    local style = (LOG_STYLE[normalized.tag] and LOG_STYLE[normalized.tag][normalized.level])
        or LOG_STYLE_DEFAULT[normalized.level]
        or ANSI_BOLD
    return style .. plain .. ANSI_RESET
end

---@param mode string
---@return fun(spec: string|{tag: string, level: string}, text: string)
function M.make_log_printer(mode)
    assert(M.LOG_MODES[mode], "unknown log mode '" .. tostring(mode) .. "'")
    return function(spec, text)
        if not M.log_should_emit(mode, spec) then return end
        print(M.log_prefix(mode, spec) .. " " .. text)
    end
end

--- Parse a make-style depfile (as written by `cc -MD -MF`): the prerequisites after the first ':'.
---@param text string
---@return string[]?, string?
function M.parse_depfile(text)
    text = text:gsub("\\\r?\n", " ")
    local colon = text:find(":", 1, true)
    if not colon then return nil, "depfile missing ':' separator" end
    local deps = {}
    for dep in text:sub(colon + 1):gmatch("%S+") do deps[#deps + 1] = dep end
    return deps, nil
end

---@param s string
---@return integer[]
function M.parse_version(s)
    local parts = {}
    for n in s:gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(n)
    end
    return parts
end

---@param a integer[]
---@param b integer[]
---@return -1|0|1
function M.compare_versions(a, b)
    local len = math.max(#a, #b)
    for i = 1, len do
        local va = a[i] or 0
        local vb = b[i] or 0
        if va < vb then return -1 end
        if va > vb then return 1 end
    end
    return 0
end

--- A canonical text form of a value: table keys in sorted order, so equal values print equally.
---@param v any
---@return string
function M.serialize(v)
    if type(v) ~= "table" then return string.format("%q", v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) < type(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. M.serialize(k) .. "]=" .. M.serialize(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

--- A short hash of a string (32-bit FNV-1a), as 8 hex digits; names build directories.
---@param s string
---@return string
function M.hash(s)
    local h = 0x811c9dc5
    for i = 1, #s do h = ((h ~ s:byte(i)) * 0x01000193) & 0xffffffff end
    return string.format("%08x", h)
end

return M
