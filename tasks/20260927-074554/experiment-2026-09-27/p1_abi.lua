dofile(os.getenv("WS") .. "/common.lua")
local k  = ws.build { project = "P1abi", repo = "K",  rev = K1,        term = DEV }
local l1 = ws.build { project = "P1abi", repo = "L1", rev = "working", term = with(DEV, { deps = { k } }) }
local l3 = ws.build { project = "P1abi", repo = "L3", rev = L3a,       term = with(DEV, { defines = { "L3_WIDE" } }) }
local l3_nodefs = with(l3, { defines = {} })
local p1 = ws.build { project = "P1abi", repo = "P1", rev = "working", term = with(DEV, { deps = { l1, l3_nodefs, k } }) }
ws.run(p1, "p1")
