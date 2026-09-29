-- K v2 generates public/k/version.h into its build output, via a vendor-lib step.
return function(term)
    return { include_dirs = { "build/gen" }, vendor_libs = { {
        name = "gen", version = "2", src = ".", out = "build/gen/K/public/k",
        build_cmd = function(src, out_dir) return "mkdir -p " .. out_dir .. " && echo '#define K_VERSION 2' > " .. out_dir .. "/version.h" end,
        sentinel = "build/gen/K/public/k/version.h", include_dirs = {}, static_libs = {},
    } } }
end
