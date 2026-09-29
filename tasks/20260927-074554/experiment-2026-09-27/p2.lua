dofile(os.getenv("WS") .. "/common.lua")
local k  = ws.build { project = "P2", repo = "K",  rev = K3,        term = REL }
local l2 = ws.build { project = "P2", repo = "L2", rev = L2b,       term = with(REL, { deps = { k } }) }
local p2 = ws.build { project = "P2", repo = "P2", rev = "working", term = with(REL, { deps = { l2, k }, defines = { "WANT_K_VERSION" } }) }
ws.run(p2, "p2")
