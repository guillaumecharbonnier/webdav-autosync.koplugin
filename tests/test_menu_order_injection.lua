-- Offline harness for inject_into_tools_order(): our placement trick that
-- registers "webdav_sync" in the `tools` list of KOReader's core order
-- modules so the Tools submenu shows us right after "Storefront" (same
-- in-memory technique Storefront itself uses for its own slot). Loads the
-- REAL main.lua against stubbed widgets and fake order modules registered
-- in package.loaded (mirroring how require-cached core modules are mutated
-- at runtime; nothing on disk).
-- Run from repo root:  lua5.1 tests/test_menu_order_injection.lua
package.path = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../?.lua;" .. package.path

local function class_stub(name)
    local cls = {}
    cls.new = function(_, tbl)
        local o = setmetatable({ class = name }, { __index = cls })
        for k, v in pairs(tbl or {}) do o[k] = v end
        return o
    end
    return cls
end

-- Stub every module main.lua (and the real runner it pulls in) requires.
local uimanager_stub = { show = function() end, nextTick = function() end, close = function() end }
package.loaded["ui/uimanager"] = uimanager_stub
package.loaded["ui/widget/infomessage"] = class_stub("InfoMessage")
package.loaded["ui/widget/confirmbox"] = class_stub("ConfirmBox")
package.loaded["ui/widget/buttondialogtitle"] = class_stub("ButtonDialogTitle")
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(self, o) return setmetatable(o, { __index = self }) end,
}
package.loaded["ui/event"] = {}
package.loaded["dispatcher"] = { registerAction = function() end }
package.loaded["ui"] = { show_help = function() end }
package.loaded["settings"] = { mark_auto_run = function() end }
package.loaded["triggers"] = {}
package.loaded["sync"] = {}
package.loaded["webdav"] = {}
package.loaded["luasettings"] = {}
package.loaded["datastorage"] = {}
package.loaded["util"] = { makePath = function() return true end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, error = function() end }
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["ffi/util"] = { template = function(s) return s end, realpath = function(p) return p end }

local WebDAVSync = require("main")

local failures = 0
local function check(name, cond, extra)
    if cond then print("PASS  " .. name)
    else failures = failures + 1; print("FAIL  " .. name .. (extra and ("  [" .. extra .. "]") or "")) end
end

local READER_ORDER = "ui/elements/reader_menu_order"
local FM_ORDER = "ui/elements/filemanager_menu_order"

-- Core-like fixture: array of ids, separators included, Storefront already
-- injected at slot 2 by its own hook.
local function fresh_orders(with_storefront)
    local mk = function()
        local t = { "read_timer", "calibre", "exporter", "statistics", "progress_sync",
                    "wallabag", "----------------------------", "more_tools" }
        if with_storefront then table.insert(t, 2, "Storefront") end
        return { tools = t }
    end
    package.loaded[READER_ORDER] = mk()
    package.loaded[FM_ORDER] = mk()
end

local function call_add()
    local menu_items = {}
    local ok, err = pcall(WebDAVSync.addToMainMenu, { ui = false }, menu_items)
    return ok, err, menu_items
end

local function count(list, id)
    local n = 0
    for i = 1, #list do if list[i] == id then n = n + 1 end end
    return n
end

-- 1: Storefront present -> we land immediately after it, in BOTH menus.
fresh_orders(true)
local ok, err, mi = call_add()
check("add to menu: no error", ok, tostring(err))
check("entry registered", mi.webdav_sync ~= nil and mi.webdav_sync.text == "WebDAV Sync")
check("fallback anchor kept (sorting_hint)", mi.webdav_sync and mi.webdav_sync.sorting_hint == "tools")
for _, key in ipairs({ READER_ORDER, FM_ORDER }) do
    local tools = package.loaded[key].tools
    local sf
    for i = 1, #tools do
        if tools[i] == "Storefront" then sf = i end
    end
    check(key .. ": right after Storefront",
        sf ~= nil and tools[sf + 1] == "webdav_sync", tools[3])
    check(key .. ": inserted exactly once", count(tools, "webdav_sync") == 1)
end

-- 2: idempotence — menus rebuild repeatedly (reader <-> FM switches).
call_add()
call_add()
local tools = package.loaded[READER_ORDER].tools
check("no duplicates after rebuilds", count(tools, "webdav_sync") == 1, tostring(count(tools, "webdav_sync")))
check("position stable after rebuilds", tools[3] == "webdav_sync", tools[3])

-- 3: Storefront absent -> slot 2 (right below read_timer), like Storefront's own rule.
fresh_orders(false)
ok = call_add()
tools = package.loaded[READER_ORDER].tools
check("no error without Storefront", ok)
check("slot 2 fallback", tools[2] == "webdav_sync" and tools[1] == "read_timer", tools[2])

-- 4: order module unavailable (require fails — plain lua5.1 here finds no
-- such file anyway once unloaded) or malformed -> pcall-guarded no-op.
package.loaded[READER_ORDER] = nil
package.loaded[FM_ORDER] = { tools = "not-a-list" }
ok, err = call_add()
check("missing/malformed order: no crash", ok, tostring(err))

os.exit(failures == 0 and 0 or 1)
