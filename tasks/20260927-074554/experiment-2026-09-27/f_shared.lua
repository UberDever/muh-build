dofile(os.getenv("WS") .. "/common.lua")
local a = ws.build { project = "F1", repo = "K", rev = "working", term = DEV }
local b = ws.build { project = "F2", repo = "K", rev = "working", term = REL }
print("F1 archive: " .. a.archives[1]); print("F2 archive: " .. b.archives[1])
print("F1 gen root: " .. a.include_roots[2]); print("F2 gen root: " .. b.include_roots[2])
