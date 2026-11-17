-- Offline harness for the WiFi pre-flight auto-accept: a MANUAL sync while
-- WiFi is off must flip the radio on immediately with NO confirmation
-- dialog (the tap is the consent), then proceed with turn_off_wifi set so
-- the radio goes back down afterwards. AUTO triggers must stay silent
-- no-ops offline (pocket battery), and an already-on WiFi must go straight
-- through. Loads the real main.lua against stubbed widgets/NetworkMgr and
-- a stubbed runner.run_planned so no network code ever runs.
-- Run from repo root:  lua5.1 tests/test_wifi_autoon.lua
package.path = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/../?.lua;" .. package.path

local shown = {}      -- every widget handed to UIManager:show
local wifi = { state = false, on_calls = 0 }

local function class_stub(name)
    local cls = {}
    cls.new = function(_, tbl)
        local o = setmetatable({ class = name }, { __index = cls })
        for k, v in pairs(tbl or {}) do o[k] = v end
        return o
    end
    return cls
end

package.loaded["ui/uimanager"] = {
    show = function(_, w) table.insert(shown, w) end,
    nextTick = function(_, f) f() end,
    close = function() end,
}
package.loaded["ui/widget/infomessage"] = class_stub("InfoMessage")
package.loaded["ui/widget/confirmbox"] = class_stub("ConfirmBox")
package.loaded["ui/widget/buttondialogtitle"] = class_stub("ButtonDialogTitle")
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(self, o) return setmetatable(o, { __index = self }) end,
}
package.loaded["ui/event"] = {}
package.loaded["dispatcher"] = { registerAction = function() end }
package.loaded["ui"] = { show_help = function() end }
package.loaded["luasettings"] = {}
package.loaded["datastorage"] = {}
package.loaded["util"] = { makePath = function() return true end }
package.loaded["webdav"] = {}
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, error = function() end }
package.loaded["gettext"] = setmetatable({}, { __call = function(_, s) return s end })
package.loaded["ffi/util"] = { template = function(s) return s end, realpath = function(p) return p end }
package.loaded["settings"] = {
    mark_auto_run = function() end,
    is_master_on = function() return true end,
    get = function(key, default)
        local t = { server_url = "https://x.example/dav", username = "u",
                    password = "p", download_folder = "/books", file_extensions = "" }
        return t[key] or default
    end,
}
package.loaded["triggers"] = { check_in_flight = function() return false end }

package.loaded["ui/network/manager"] = {
    isWifiOn = function() return wifi.state end,
    isOnline = function() return wifi.state end,
    turnOnWifi = function(_, cb)
        wifi.on_calls = wifi.on_calls + 1
        wifi.state = true  -- production semantics: callback fires once up
        cb()
    end,
    turnOffWifi = function() wifi.state = false end,
}

local WebDAVSync = require("main")

-- Stub the sync planner so neither the real planner nor the network runs.
local planned = {}
local runner = require("runner")
runner.run_planned = function(_, ctx, opts)
    table.insert(planned, { ctx = ctx, opts = opts })
    if opts and opts.on_done then opts.on_done() end
end
runner.run_one_way = runner.run_planned

-- KOReader global the plugin reads for the two-way toggle / metadata mode.
G_reader_settings = {
    isTrue = function() return true end,
    readSetting = function() return "doc" end,
}

local failures = 0
local function check(name, cond, extra)
    if cond then print("PASS  " .. name)
    else failures = failures + 1; print("FAIL  " .. name .. (extra and ("  [" .. extra .. "]") or "")) end
end

local function reset(state)
    shown, planned = {}, {}
    wifi.state = state
    wifi.on_calls = 0
end

local function any_confirmbox()
    for _, w in ipairs(shown) do if w.class == "ConfirmBox" then return true end end
    return false
end

-- The auto-accept continuations re-enter self:doSync / self:doProgressSync,
-- so the instance needs the class in its lookup chain, like a real one.
local self = setmetatable({ ui = { document = false } }, { __index = WebDAVSync })

-- 1: manual book sync with WiFi off -> radio ON immediately, NO dialog,
--    sync then runs with turn_off_wifi so the radio goes back down.
reset(false)
WebDAVSync.doSync(self, {})
check("manual+offline: no confirmation dialog", not any_confirmbox())
check("manual+offline: turnOnWifi called once", wifi.on_calls == 1, tostring(wifi.on_calls))
check("manual+offline: status message shown", #shown == 1 and shown[1].class == "InfoMessage",
    shown[1] and shown[1].class or "none")
check("manual+offline: sync proceeded", #planned == 1, tostring(#planned))
check("manual+offline: radio restored afterwards",
    planned[1] and planned[1].ctx.turn_off_wifi == true)

-- 2: automatic trigger with WiFi off -> silent skip, radio untouched.
reset(false)
WebDAVSync.doSync(self, { is_auto = true })
check("auto+offline: radio NOT enabled", wifi.on_calls == 0)
check("auto+offline: nothing synced", #planned == 0)
check("auto+offline: nothing shown", #shown == 0)

-- 3: WiFi already on -> straight through, no turn-on, no message.
reset(true)
WebDAVSync.doSync(self, {})
check("manual+online: straight through",
    wifi.on_calls == 0 and #planned == 1 and #shown == 0,
    string.format("on=%d planned=%d shown=%d", wifi.on_calls, #planned, #shown))

-- 4: manual progress sync with WiFi off -> same auto-accept contract.
reset(false)
WebDAVSync.doProgressSync(self, { manual = true })
check("progress manual+offline: turnOnWifi called", wifi.on_calls == 1)
check("progress manual+offline: no confirmation dialog", not any_confirmbox())
check("progress manual+offline: progress sync ran",
    #planned == 1 and planned[1].opts.chain_section == "progress",
    planned[1] and tostring(planned[1].opts.chain_section) or "none")

-- 5: automatic progress sync with WiFi off -> silent skip (isOnline gate).
reset(false)
WebDAVSync.doProgressSync(self, {})
check("progress auto+offline: silent", wifi.on_calls == 0 and #planned == 0 and #shown == 0)

-- 6: "Refresh this book" (focus_open_book) must survive the WiFi
--    round-trip: after the auto radio-on, the sync still completes in
--    focus mode — feedback on the completion hook proves the flag was
--    carried through the continuation (it once wasn't, and the refresh
--    silently degraded to a plain full sync).
reset(false)
WebDAVSync.doSync(self, { focus_open_book = true })
check("refresh+wifi-off: sync ran", #planned == 1, tostring(#planned))
local oc = planned[1] and planned[1].opts and planned[1].opts.on_completed
if oc then pcall(oc, { downloaded_rels = {} }) end
local last = shown[#shown]
check("refresh+wifi-off: focus feedback survived",
    oc ~= nil and last and last.class == "InfoMessage"
    and (last.text or ""):find("up to date") ~= nil,
    last and (last.class .. ":" .. tostring(last.text)) or "none")

os.exit(failures == 0 and 0 or 1)
