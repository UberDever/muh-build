-- fixture.lua — helpers for writing projects as data.

local M = {}

--- The text of a manifest with dev/release modes compiling through clang.
---@param o {muh_build: string?, mode: string?, packages: string?, exports: string?, preconfigure: string?}
---   packages, exports and preconfigure are Lua source spliced into the manifest.
function M.manifest(o)
    return ([==[
local MODES = {
    dev     = { cflags = { "-O0", "-g3", "-std=c99", "-Wall", "-Werror" } },
    release = { cflags = { "-O2", "-DNDEBUG", "-std=c99" } },
}

return {
    muh_build = %q,
    mode      = %q,
    packages  = %s,
    exports   = %s,
    preconfigure = %s,

    compile_cmd = function(out, src, extra_args, m)
        local parts = { "clang", table.unpack(MODES[m.mode].cflags) }
        for _, a in ipairs(extra_args or {}) do parts[#parts + 1] = a end
        for _, a in ipairs { "-MMD", "-MF", out .. ".d", "-MT", out, "-c", src, "-o", out } do parts[#parts + 1] = a end
        return table.concat(parts, " ")
    end,
    link_cmd = function(out, ins, extra_args)
        return "clang " .. table.concat(ins, " ") .. " -o " .. out .. " " .. table.concat(extra_args or {}, " ")
    end,
    archive_cmd = function(out, ins) return "ar rcs " .. out .. " " .. table.concat(ins, " ") end,
}
]==]):format(o.muh_build or "0.1", o.mode or "dev", o.packages or "nil", o.exports or "{}", o.preconfigure or "nil")
end

--- A recipe: `requires` is Lua source for the entries, `body` for the run function's body.
function M.recipe(requires, body)
    return "return {\n    muh_build = \"0.1\",\n    requires = {\n" .. requires .. "    },\n    run = function(repo)\n" .. body .. "    end,\n}\n"
end

return M
