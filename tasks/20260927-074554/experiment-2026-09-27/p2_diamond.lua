dofile(os.getenv("WS") .. "/common.lua")
local k1 = ws.build { project = "P2dia", repo = "K",  rev = K1,        term = REL }
local l2 = ws.build { project = "P2dia", repo = "L2", rev = L2a,       term = with(REL, { deps = { k1 } }) }
local k2 = ws.build { project = "P2dia", repo = "K",  rev = K2,        term = REL }
local p2 = ws.build { project = "P2dia", repo = "P2", rev = "working", term = with(REL, { deps = { l2, k1, k2 } }) }
ws.run(p2, "p2")
