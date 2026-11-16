-- Offline harness for runner.open_document_rel's path canonicalization.
-- Simulates KOReader's ffi/util.realpath (C realpath semantics: relative ->
-- resolved against CWD, symlinks resolved) and the historical failure:
-- download_folder stored relative-to-data-dir vs an absolute document path
-- used to compare unequal, silently killing the reload prompt and the
-- open-book deletion protection.
-- Run from repo root:  lua5.1 tests/test_open_document_rel.lua
package.path = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../?.lua;" .. package.path

local CWD = "/rootdir/koreader"
local LINKS = { ["/mnt/onboard"] = "/mnt/kobo" }

local function realpath(p)
    if type(p) ~= "string" or p == "" then return nil end
    local abs = p:sub(1, 1) == "/" and p or (CWD .. "/" .. p)
    local parts = {}
    for seg in abs:gmatch("[^/]+") do
        if seg == ".." then table.remove(parts)
        elseif seg ~= "." then table.insert(parts, seg) end
    end
    abs = "/" .. table.concat(parts, "/")
    for from, to in pairs(LINKS) do
        if abs:sub(1, #from) == from and abs:sub(#from + 1, #from + 1) == "/" then
            abs = to .. abs:sub(#from + 1)
            break
        end
    end
    return abs
end

-- Stub every module runner.lua pulls in, so runner loads standalone.
local empty = {}
for _, m in ipairs({ "ui/uimanager", "ui/widget/infomessage", "ui/widget/buttondialogtitle",
                     "ui/event", "logger", "sync", "triggers",
                     "luasettings", "datastorage", "util", "webdav" }) do
    package.loaded[m] = setmetatable({}, { __index = empty })
end
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, error = function() end }
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["ffi/util"] = { template = function(s) return s end, realpath = realpath }

local runner = require("runner")

local failures = 0
local function check(name, got, want)
    if got == want then print("PASS  " .. name)
    else failures = failures + 1; print("FAIL  " .. name .. "  got=" .. tostring(got) .. " want=" .. tostring(want)) end
end

-- 1: plain absolute match
check("abs match", runner.open_document_rel("/data/books", "/data/books/a.pdf"), "a.pdf")
check("abs match nested", runner.open_document_rel("/data/books", "/data/books/sub/b.pdf"), "sub/b.pdf")
-- 2: THE REGRESSION: folder relative to cwd (what PathChooser can store),
--    document opened with an absolute path — old code returned nil.
check("relative folder vs abs doc",
    runner.open_document_rel("documents/books", "/rootdir/koreader/documents/books/a.pdf"), "a.pdf")
check("relative folder with dotdot",
    runner.open_document_rel("documents/../documents/books", "/rootdir/koreader/documents/books/a.pdf"), "a.pdf")
-- 3: symlinked mount alias: folder picked via /mnt/onboard, doc opened via /mnt/kobo
check("symlink alias both sides",
    runner.open_document_rel("/mnt/onboard/books", "/mnt/kobo/books/b.pdf"), "b.pdf")
-- 4: genuine mismatches stay nil
check("outside folder", runner.open_document_rel("/data/books", "/elsewhere/a.pdf"), nil)
check("empty folder", runner.open_document_rel("", "/data/books/a.pdf"), nil)
check("empty doc", runner.open_document_rel("/data/books", ""), nil)
check("doc IS the folder", runner.open_document_rel("/data/books", "/data/books"), nil)
check("trailing slash folder", runner.open_document_rel("/data/books/", "/data/books/a.pdf"), "a.pdf")
check("prefix lookalike dir", runner.open_document_rel("/data/books", "/data/books-archive/a.pdf"), nil)

-- 5: no realpath available (abspath fallback) — old raw-prefix semantics
package.loaded["ffi/util"] = { template = function(s) return s end }
check("fallback: abs match still works", runner.open_document_rel("/data/books", "/data/books/a.pdf"), "a.pdf")
check("fallback: relative still nil (documented degradation)",
    runner.open_document_rel("documents/books", "/rootdir/koreader/documents/books/a.pdf"), nil)

os.exit(failures == 0 and 0 or 1)
