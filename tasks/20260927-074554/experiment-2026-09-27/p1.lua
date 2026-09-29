dofile(os.getenv("WS") .. "/common.lua")
local k  = ws.build { project = "P1", repo = "K",  rev = K1,        term = DEV }
local l1 = ws.build { project = "P1", repo = "L1", rev = "working", term = with(DEV, { deps = { k } }) }
local l3 = ws.build { project = "P1", repo = "L3", rev = L3a,       term = with(DEV, { defines = { "L3_WIDE" } }) }
local p1 = ws.build { project = "P1", repo = "P1", rev = "working", term = with(DEV, { deps = { l1, l3, k } }) }
ws.run(p1, "p1")
