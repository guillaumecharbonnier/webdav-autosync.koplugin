-- Offline harness: exercises the patched webdav.lua list_all against canned
-- PROPFIND replies. Scenario 1 = Koofr (207 + self-only for Depth: infinity),
-- 2 = fast path honored, 3 = genuinely empty folder.
-- Runs against the module next to the repo root:  lua5.1 tests/test_list_all.lua
package.path = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../?.lua;" .. package.path

local log = {}
local scenario_fn = nil
local scenario_body = nil

local ltn12_stub = {
    source = { string = function(s)
        local done = false
        return function() if done then return nil end done = true; return s end
    end },
    sink = {
        table = function(t)
            return function(chunk) if chunk then table.insert(t, chunk) end return 1 end
        end,
        file = function(f)
            return function(chunk) if chunk then f:write(chunk) end return 1 end
        end,
    },
}
local http_stub = {}
function http_stub.request(req)
    local depth = req.headers and tostring(req.headers.Depth) or "?"
    table.insert(log, "depth=" .. depth .. " " .. req.url)
    local body = {}
    local code = scenario_fn(req.url, depth) or 500
    local xml = scenario_body
    local sink = req.sink
    if sink and xml then sink(xml); sink(nil) end
    return 1, code, {}, "OK"
end

package.loaded["ltn12"] = ltn12_stub
package.loaded["socket.http"] = http_stub
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, error = function() end }
package.loaded["util"] = { makePath = function() return true end, partialMD5 = function() return "x" end }

local webdav = require("webdav")

local BASE = "https://app.koofr.net/dav/Koofr/fusion-panel"
local P = "/dav/Koofr/fusion-panel"
local SUB_URL = BASE .. "/sub/"

local function ms(...) return '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">' .. table.concat({ ... }) .. '</d:multistatus>' end
local function resp(href, coll)
    return '<d:response><d:href>' .. href .. '</d:href><d:propstat><d:prop><d:resourcetype>'
        .. (coll and '<d:collection/>' or '') .. '</d:resourcetype><d:getetag>"e1"</d:getetag>'
        .. '<d:getlastmodified>Sun, 15 Nov 2026 15:37:41 GMT</d:getlastmodified>'
        .. '<d:getcontentlength>123</d:getcontentlength></d:prop>'
        .. '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
end

local failures = 0
local function check(name, cond, extra)
    if cond then print("PASS  " .. name)
    else failures = failures + 1; print("FAIL  " .. name .. (extra and ("  [" .. extra .. "]") or "")) end
end
local function count_prefix(t, pre)
    local n = 0
    for _, l in ipairs(t) do if l:sub(1, #pre) == pre then n = n + 1 end end
    return n
end

-- ---- Scenario 1+2: Koofr degenerate infinity -------------------------------
scenario_fn = function(url, depth) return 207 end
local koofr = function(url, depth)
    if depth == "infinity" then
        scenario_body = ms(resp(P, true))                       -- self only, like the probe
    elseif url == BASE .. "/" then
        scenario_body = ms(resp(P, true), resp(P .. "/book.pdf"), resp(P .. "/sub", true))
    elseif url == SUB_URL then
        scenario_body = ms(resp(P .. "/sub", true), resp(P .. "/sub/other.pdf"))
    end
    return 207
end
scenario_fn = koofr

log = {}
local all, err1, err2 = webdav.list_all(BASE, "u", "p")
local n = all and #all or -1
check("koofr: 3 entries visible after fallback", n == 3, "got " .. n)
check("koofr: tried infinity first", log[1] and log[1]:find("depth=infinity") ~= nil, log[1])
check("koofr: base + sub walked recursively", count_prefix(log, "depth=1") == 2, #log .. " reqs")

local names = {}
if all then for _, e in ipairs(all) do names[#names + 1] = e.path end end
local joined = table.concat(names, ",")
check("koofr: book + sub + nested file", names["book"] == nil and #names == 3, joined)

-- second call in the same process: memo means NO new infinity probe
log = {}
local all2 = webdav.list_all(BASE, "u", "p")
check("koofr: memoed, no second infinity probe", count_prefix(log, "depth=infinity") == 0, #log .. " reqs")
check("koofr: same 3 entries on rerun", all2 and #all2 == 3)

-- etag/mtime parsed
local book
if all2 then for _, e in ipairs(all2) do if e.path:match("book%.pdf$") then book = e end end end
check("koofr: etag parsed", book and book.etag == "e1", book and tostring(book.etag) or "no book")
check("koofr: mtime parsed", book and type(book.mtime) == "number", book and tostring(book.mtime) or "no book")

-- ---- Scenario 3: correct server, infinity honored --------------------------
scenario_fn = function(url, depth)
    if depth == "infinity" then
        scenario_body = ms(resp("/dav/lib", true), resp("/dav/lib/book.pdf"), resp("/dav/lib/sub", true), resp("/dav/lib/sub/other.pdf"))
    else
        scenario_body = ms(resp("/dav/lib", true))
    end
    return 207
end
log = {}
-- new host so the memo from scenario 1 does not apply
local all3 = webdav.list_all("https://well.example.org/dav/lib", "u", "p")
check("fast path: 3 entries via one request", all3 and #all3 == 3, all3 and tostring(#all3))
check("fast path: exactly 1 request", #log == 1, #log .. " reqs")

-- ---- Scenario 4: genuinely empty folder ------------------------------------
local base4 = "https://empty.example.org/dav/void"
scenario_fn = function(url, depth) scenario_body = ms(resp("/dav/void", true)); return 207 end
log = {}
local all4, c4 = webdav.list_all(base4, "u", "p")
check("empty: returns success with 0 entries", all4 and #all4 == 0, all4 and tostring(#all4) or "nil " .. tostring(c4))

os.exit(failures == 0 and 0 or 1)
