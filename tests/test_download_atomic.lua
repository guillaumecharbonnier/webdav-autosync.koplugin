-- Offline harness for webdav.download_file's atomic mode: staging through
-- <target>.part + rename, cleanup on HTTP failure, non-atomic regression.
-- Run from repo root:  lua5.1 tests/test_download_atomic.lua
package.path = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../?.lua;" .. package.path

local http_code, http_body = 200, "BODYBYTES"

local ltn12_stub = {
    source = { string = function(s)
        local done = false
        return function() if done then return nil end done = true; return s end
    end },
    sink = {
        table = function(t)
            return function(chunk) if chunk then table.insert(t, chunk) end return 1 end
        end,
        -- mirrors ltn12.sink.file: writes chunks, closes on nil
        file = function(f)
            return function(chunk)
                if chunk then f:write(chunk) return 1 end
                f:close(); return 1
            end
        end,
    },
}
local http_stub = {}
function http_stub.request(req)
    local sink = req.sink
    if sink and http_body then sink(http_body); sink(nil) end
    return 1, http_code, {}, "OK"
end

package.loaded["ltn12"] = ltn12_stub
package.loaded["socket.http"] = http_stub
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, error = function() end }
package.loaded["util"] = { makePath = function() return true end, partialMD5 = function() return "x" end }

local webdav = require("webdav")

local dir = os.getenv("TMPDIR") or "/tmp"
dir = dir:gsub("/+$", "") .. "/wdtest_" .. tostring(os.time()) .. "_" .. tostring(math.random(10000))
os.execute("mkdir -p " .. dir)

local function slurp(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end
local function spit(path, content)
    local f = assert(io.open(path, "wb")); f:write(content); f:close()
end

local failures = 0
local function check(name, cond, extra)
    if cond then print("PASS  " .. name)
    else failures = failures + 1; print("FAIL  " .. name .. (extra and ("  [" .. extra .. "]") or "")) end
end

-- 1: atomic success — target published with new content, no .part left
local t1 = dir .. "/book.pdf"
spit(t1, "OLD")
http_code, http_body = 200, "NEWFULLBOOK"
local ok, err = webdav.download_file("https://x.example/f/book.pdf", t1, nil, nil, true)
check("atomic: returns ok", ok == true, tostring(err))
check("atomic: target holds new bytes", slurp(t1) == "NEWFULLBOOK", tostring(slurp(t1)))
check("atomic: no .part residue", slurp(t1 .. ".part") == nil)

-- 2: atomic failure — old file untouched, no .part left
http_code, http_body = 500, nil
local t2 = dir .. "/open.pdf"
spit(t2, "STILL_GOOD")
ok, err = webdav.download_file("https://x.example/f/open.pdf", t2, nil, nil, true)
check("atomic fail: error returned", not ok and err ~= nil, tostring(ok))
check("atomic fail: old content intact", slurp(t2) == "STILL_GOOD", tostring(slurp(t2)))
check("atomic fail: no .part residue", slurp(t2 .. ".part") == nil)

-- 3: non-atomic regression — direct write still works
local t3 = dir .. "/plain.pdf"
http_code, http_body = 200, "PLAINBODY"
ok = webdav.download_file("https://x.example/f/plain.pdf", t3, nil, nil, nil)
check("plain: returns ok", ok == true)
check("plain: content", slurp(t3) == "PLAINBODY")

-- 4: atomic into a NEW file (no pre-existing target) — rename must still land
local t4 = dir .. "/fresh.pdf"
http_code, http_body = 200, "FRESH"
ok, err = webdav.download_file("https://x.example/f/fresh.pdf", t4, nil, nil, true)
check("atomic new file: ok", ok == true, tostring(err))
check("atomic new file: content", slurp(t4) == "FRESH")

os.execute("rm -rf " .. dir)
os.exit(failures == 0 and 0 or 1)
