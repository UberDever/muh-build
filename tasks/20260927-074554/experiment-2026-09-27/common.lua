package.path = "/tmp/claude-1001/-home-uberdever-dev-c-vetochka/11f5ad79-bf11-4b28-85ca-9924e1d0501e/scratchpad/ws/?.lua;" .. package.path
ws = require "ws"
K1, K2, L2a, L3a, K3, L2b, L3b = "76bce42a", "a20d4842", "7e2e1352", "735b7588", "7f3f6a74", "934dea33", "4beb0de1"
DEV = { cflags = { "-O0", "-g", "-std=c99", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", "-fno-omit-frame-pointer" },
        ldflags = { "-fsanitize=address,undefined" } }
REL = { cflags = { "-O2", "-std=c99", "-Wall", "-Wextra", "-Werror" }, ldflags = {} }
function with(base, extra) local t = {} for k, v in pairs(base) do t[k] = v end for k, v in pairs(extra or {}) do t[k] = v end return t end
