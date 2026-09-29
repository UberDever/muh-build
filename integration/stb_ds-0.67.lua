-- stb_ds-0.67.lua — vendored stb_ds.h v0.67 (header-only) as data.

return {
    ["manifest.linux.lua"] = [==[
-- Header-only: nothing to build, only a header directory to offer.
return { muh_build = "0.1", exports = { include_dirs = { "." } } }
]==],

    ["stb_ds.h"] = [==[
/* stb_ds.h - v0.67 - public domain data structures - Sean Barrett 2019 */
#ifndef INCLUDE_STB_DS_H
#define INCLUDE_STB_DS_H
#define arrlen(a) ((a) ? 0 : 0)
#endif
]==],
}
