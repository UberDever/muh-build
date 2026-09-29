-- Experiment manifest: flags and deps come from the term file named by MUH_TERM.
local term = os.getenv("MUH_TERM") and dofile(os.getenv("MUH_TERM")) or {}
local deps = term.deps or {}
local CFLAGS = term.cflags or { "-O0", "-g", "-std=c99", "-Wall", "-Wextra", "-Werror" }
local LDFLAGS = term.ldflags or {}
local dep_cflags, dep_archives = {}, {}
for _, d in ipairs(deps) do
    for _, r in ipairs(d.include_roots) do dep_cflags[#dep_cflags + 1] = "-I" .. r end
    for _, def in ipairs(d.defines or {}) do dep_cflags[#dep_cflags + 1] = "-D" .. def end
    for _, a in ipairs(d.archives) do dep_archives[#dep_archives + 1] = a end
end
local own_defines = {}
for _, def in ipairs(term.defines or {}) do own_defines[#own_defines + 1] = "-D" .. def end
local extra = io.open((os.getenv("MUH_SRC") or ".") .. "/extra.lua") -- repo-specific additions
local ex = {}
if extra then extra:close(); ex = dofile(os.getenv("MUH_SRC") .. "/extra.lua")(term) end
return {
    build_dir = "build",
    exports = { defines = term.defines or {}, include_dirs = ex.include_dirs or {} },
    preconfigure = function() end,
    postconfigure = function() end,
    compile_cmd = function(out, src, extra_args)
        local p = { "clang", table.unpack(CFLAGS) }
        for _, t in ipairs({ extra_args or {}, dep_cflags, own_defines, ex.cflags or {} }) do
            for _, a in ipairs(t) do p[#p + 1] = a end
        end
        for _, a in ipairs({ "-MMD", "-MF", out .. ".d", "-MT", out, "-c", src, "-o", out }) do p[#p + 1] = a end
        return table.concat(p, " ")
    end,
    link_cmd = function(out, ins, extra_args)
        local p = { "clang", table.unpack(LDFLAGS) }
        for _, i in ipairs(ins) do p[#p + 1] = i end
        for _, a in ipairs(dep_archives) do p[#p + 1] = a end
        p[#p + 1] = "-o"; p[#p + 1] = out
        for _, a in ipairs(extra_args or {}) do p[#p + 1] = a end
        return table.concat(p, " ")
    end,
    archive_cmd = function(out, ins) return "ar rcs " .. out .. " " .. table.concat(ins, " ") end,
    vendor_libs = ex.vendor_libs,
    system_libs = { "-lm" },
}
