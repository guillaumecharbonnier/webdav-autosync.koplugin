-- Offline harness for WebDAVSync:offerReloadIfUpdated, the hook that shows
-- the "Reload now?" ConfirmBox when a sync replaced the open book. It loads
-- the REAL main.lua (and the real runner through it) against stubbed KOReader
-- widgets, so regressions like the device-reported
--   main.lua:276: attempt to call local '_' (a number value)
-- — a `for _, r in ipairs` dummy shadowing gettext's `_` inside the loop —
-- fail HERE instead of on the device. The gettext stub asserts string input,
-- and a shadowed `_` is a number, so the call errors on its own.
-- Run from repo root:  lua5.1 tests/test_offer_reload.lua
package.path = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../?.lua;" .. package.path

local shown = {}     -- widgets passed to UIManager:show
local ticked = {}    -- closures passed to UIManager:nextTick
local opened = {}    -- files passed to ReaderUI:showReader

local function class_stub(name)
    local cls = {}
    cls.new = function(_, tbl)
        local o = setmetatable({ class = name }, { __index = cls })
        for k, v in pairs(tbl or {}) do o[k] = v end
        return o
    end
    return cls
end

local uimanager_stub = {
    show = function(_, w) table.insert(shown, w) end,
    nextTick = function(_, f) table.insert(ticked, f) end,
    close = function() end,
}
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
package.loaded["gettext"] = setmetatable({}, {
    __call = function(_, s)
        if type(s) ~= "string" then
            error("gettext called with non-string (" .. type(s) .. "): shadowed `_`?")
        end
        return s
    end,
})
package.loaded["ffi/util"] = {
    template = function(s, ...) return s end,
    realpath = function(p) return p end, -- absolute paths on the device already
}
package.loaded["apps/reader/readerui"] = {
    showReader = function(_, file) table.insert(opened, file) end,
}

local WebDAVSync = require("main")

local failures = 0
local function check(name, cond, extra)
    if cond then print("PASS  " .. name)
    else failures = failures + 1; print("FAIL  " .. name .. (extra and ("  [" .. extra .. "]") or "")) end
end

local DOC = "/mnt/onboard/Vahid/fusion-panel/sync-test.pdf"
local FOLDER = "/mnt/onboard/Vahid"

local function fresh_self()
    return { ui = { document = { file = DOC } } }
end

-- 1: the device scenario — downloaded rel equals open-book rel.
-- The `_`-shadowing crash made this error out entirely.
local ok_call, ok_ret, err = pcall(WebDAVSync.offerReloadIfUpdated,
    fresh_self(),
    { downloaded_rels = { "fusion-panel/sync-test.pdf", "fusion-panel/other.pdf" } },
    FOLDER)
check("match: call survives gettext lookups", ok_call, tostring(ok_ret))
check("match: returns true", ok_ret == true, tostring(ok_ret))
local box = shown[1]
check("match: ConfirmBox shown", box ~= nil and box.class == "ConfirmBox",
    box and box.class or "none")
check("match: dialog text mentions the update",
    box and type(box.text) == "string" and box.text:find("updated on the server") ~= nil,
    box and tostring(box.text))
check("match: dialog offers Reload now", box and box.ok_text == "Reload now",
    box and tostring(box.ok_text))

-- 2: accepting the box must reach ReaderUI:showReader through nextTick.
if box and box.ok_callback then
    local ok_cb = pcall(box.ok_callback)
    check("reload: ok_callback runs", ok_cb)
    check("reload: nextTick queued one action", #ticked == 1, tostring(#ticked))
    if #ticked == 1 then pcall(ticked[1]) end
    check("reload: showReader got the open file", opened[1] == DOC, tostring(opened[1]))
else
    check("reload: ok_callback runs", false, "no callback captured")
end

-- 3: sync touched other books only -> no prompt, returns false.
shown, ticked, opened = {}, {}, {}
ok_call, ok_ret = pcall(WebDAVSync.offerReloadIfUpdated,
    fresh_self(), { downloaded_rels = { "fusion-panel/other.pdf" } }, FOLDER)
check("no match: no error", ok_call, tostring(ok_ret))
check("no match: returns false", ok_ret == false, tostring(ok_ret))
check("no match: nothing shown", #shown == 0)

-- 4: book outside the synced folder -> silent false (focus mode messages it).
ok_call, ok_ret = pcall(WebDAVSync.offerReloadIfUpdated,
    fresh_self(), { downloaded_rels = { "fusion-panel/sync-test.pdf" } },
    "/mnt/onboard/SomewhereElse")
check("outside folder: false, no dialog", ok_call and ok_ret == false and #shown == 0)

-- 5: file manager context (no document) -> silent false.
ok_call, ok_ret = pcall(WebDAVSync.offerReloadIfUpdated,
    { ui = {} }, { downloaded_rels = { "fusion-panel/sync-test.pdf" } }, FOLDER)
check("no document: false", ok_call and ok_ret == false)

os.exit(failures == 0 and 0 or 1)
