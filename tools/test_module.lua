-- Tests for the backend module webui/l2tp. Run from the package folder:  texlua tools/test_module.lua
-- The module's fixed paths are replaced by a temporary folder, /usr/bin/l2tp-vpn by a stand-in script, and "ip" by a stand-in.
local T = os.tmpname() .. ".d"
os.execute("rm -f " .. T .. "; mkdir -p " .. T .. "/bin")
local function sh(cmd) return os.execute(cmd) end
local function readall(p) local f = io.open(p, "r") if not f then return nil end local s = f:read("*a") f:close() return s end
local function writeall(p, s) local f = assert(io.open(p, "w")) f:write(s) f:close() end

local STUB = T .. "/l2tp-vpn"
writeall(STUB, "#!/bin/sh\necho \"$1 called\" >> " .. T .. "/calls.log; sleep 1; echo \"stub did $1\"\n")
writeall(T .. "/bin/ip", "#!/bin/sh\n[ -f " .. T .. "/ppp ] && cat " .. T .. "/ppp\nexit 0\n")
writeall(T .. "/bin/logger", "#!/bin/sh\ncat >/dev/null\n")
sh("chmod +x " .. STUB .. " " .. T .. "/bin/ip " .. T .. "/bin/logger")
local oldpath = os.getenv("PATH")

local src = assert(readall("webui/l2tp"))
local function patched(s)
    s = s:gsub('"/tmp/l2tp%-vpn%.state"', '"' .. T .. '/state"')
    s = s:gsub('"/tmp/l2tp%-web%.busy"', '"' .. T .. '/busy"')
    s = s:gsub('"/etc/l2tp%-vpn%.conf"', '"' .. T .. '/l2tp-vpn.conf"')
    s = s:gsub('"/tmp/l2tp%-vpn%.msg"', '"' .. T .. '/msg"')
    s = s:gsub('/tmp/l2tp%-vpn%.out', T .. '/out')
    s = s:gsub('/usr/bin/l2tp%-vpn', STUB)
    return s
end
-- The module's detach command closes descriptors 3..63 in a loop, which the router's BusyBox shell accepts but the sandbox's
-- dash does not; the module's os.execute and io.popen therefore run under bash here (same logic, other shell), with the stand-in ip first in PATH.
local real_execute, real_popen = os.execute, io.popen
local pre = "PATH=" .. T .. "/bin:" .. oldpath .. "; export PATH; "
local env = setmetatable({
    os = setmetatable({ execute = function(c) return real_execute("bash -c '" .. (pre .. c):gsub("'", "'\\''") .. "'") end }, { __index = os }),
    io = setmetatable({ popen = function(c, m) return real_popen("bash -c '" .. (pre .. c):gsub("'", "'\\''") .. "'", m) end }, { __index = io })
}, { __index = _G })
local M = assert(load(patched(src), "l2tp", "t", env))()

local pass, fail = 0, 0
local function check(name, ok) if ok then pass = pass + 1 print("PASS " .. name) else fail = fail + 1 print("FAIL " .. name) end end
local CONF = T .. "/l2tp-vpn.conf"
local function clear() sh("rm -f " .. T .. "/busy " .. T .. "/out " .. T .. "/calls.log " .. T .. "/state " .. T .. "/msg " .. T .. "/ppp " .. CONF .. " " .. CONF .. ".tmp") end
local function wait_idle() for _ = 1, 30 do if not M.get_status().busy then return end sh("sleep 0.2") end end
local GOOD = { host = "vpn.example.com", user = "alice", password = "p4ss word!", psk = "s3cret/key" }
local function with(extra) local a = {} for k, v in pairs(GOOD) do a[k] = v end for k, v in pairs(extra or {}) do a[k] = v end return a end

print("=== status")
clear()
local s = M.get_status()
check("off: no state file, no interface", s.status == "off" and s.busy == false and s.address == nil and s.message == nil)
writeall(T .. "/state", "203.0.113.5 192.168.1.1 eth0\n")
s = M.get_status()
check("connecting: the state exists but the tunnel has no address; the server comes from the state file", s.status == "connecting" and s.server == "203.0.113.5" and s.address == nil)
writeall(T .. "/ppp", "    inet 10.9.8.2 peer 10.9.8.1/32 scope global ppp0\n")
s = M.get_status()
check("connected: address and peer", s.status == "connected" and s.address == "10.9.8.2" and s.peer == "10.9.8.1/32")
clear()
writeall(T .. "/msg", "Gave up reconnecting after 1 hour; Connect was switched off.\n")
s = M.get_status()
check("off with a message from the reconnect loop: the message is passed on", s.status == "off" and s.message == "Gave up reconnecting after 1 hour; Connect was switched off.")
writeall(T .. "/state", "203.0.113.5 192.168.1.1 eth0\n")
check("no message while connecting (it would be stale)", M.get_status().message == nil)
clear(); writeall(T .. "/msg", string.rep("x", 500) .. "\n")
check("a very long message is cut to 200 characters", #M.get_status().message == 200)
clear(); writeall(T .. "/msg", "\n")
check("an empty message file means no message", M.get_status().message == nil)

print("=== reading the settings")
clear()
local c = M.get_config()
check("no config file: empty values and the reconnect defaults (5 minutes, never give up)", c.host == "" and c.user == "" and c.password == "" and c.psk == "" and c.retry_minutes == 5 and c.giveup_hours == 0)
writeall(CONF, "HOST='h.example.com'\nVPN_USER='bob'\nVPN_PASS='pw'\nVPN_PSK='key'\n")
c = M.get_config()
check("an old config file without the new keys: the connection values, and the defaults for the new ones", c.host == "h.example.com" and c.user == "bob" and c.password == "pw" and c.psk == "key" and c.retry_minutes == 5 and c.giveup_hours == 0)
writeall(CONF, "HOST='h'\nVPN_USER='u'\nVPN_PASS='p'\nVPN_PSK='k'\nRETRY_MINUTES='12'\nGIVE_UP_HOURS='24'\n")
c = M.get_config()
check("the reconnect settings are read as numbers", c.retry_minutes == 12 and c.giveup_hours == 24)
writeall(CONF, "HOST='h'\nVPN_USER='u'\nVPN_PASS='p'\nVPN_PSK='k'\nRETRY_MINUTES='abc'\nGIVE_UP_HOURS='999'\n")
c = M.get_config()
check("rubbish or out-of-range values in the file show as the defaults", c.retry_minutes == 5 and c.giveup_hours == 0)

print("=== saving the settings")
clear()
local r = M.set_config(with({ retry_minutes = 10, giveup_hours = 48 }))
check("a valid save is accepted", r.saved == true)
check("the file has the four values and the two reconnect values, and only root can read it", readall(CONF) == "HOST='vpn.example.com'\nVPN_USER='alice'\nVPN_PASS='p4ss word!'\nVPN_PSK='s3cret/key'\nRETRY_MINUTES='10'\nGIVE_UP_HOURS='48'\n"
      and (io.popen("stat -c %a " .. CONF):read("*l") == "600"))
check("reading it back gives the same numbers", M.get_config().retry_minutes == 10 and M.get_config().giveup_hours == 48)
r = M.set_config(with({ retry_minutes = 0, giveup_hours = 0 }))
check("0 and 0 are valid (never reconnect / never give up)", r.saved == true and M.get_config().retry_minutes == 0)
r = M.set_config(with({ retry_minutes = 60, giveup_hours = 168 }))
check("the upper limits 60 and 168 are valid", r.saved == true and M.get_config().retry_minutes == 60 and M.get_config().giveup_hours == 168)
r = M.set_config(with({ retry_minutes = "15", giveup_hours = "6" }))
check("numbers given as strings of digits are accepted", r.saved == true and M.get_config().retry_minutes == 15 and M.get_config().giveup_hours == 6)
r = M.set_config(with({ retry_minutes = 7.0, giveup_hours = 3.0 }))
check("a whole number given as 7.0 is written as 7", r.saved == true and readall(CONF):find("RETRY_MINUTES='7'", 1, true) ~= nil and readall(CONF):find("GIVE_UP_HOURS='3'", 1, true) ~= nil)
M.set_config(with({ retry_minutes = 9, giveup_hours = 12 }))
r = M.set_config(with({}))
check("leaving the reconnect settings out keeps what was saved", r.saved == true and M.get_config().retry_minutes == 9 and M.get_config().giveup_hours == 12)
clear()
r = M.set_config(with({}))
check("leaving them out on a fresh install saves the defaults", r.saved == true and M.get_config().retry_minutes == 5 and M.get_config().giveup_hours == 0)

print("=== refusing bad values")
clear(); writeall(CONF, "HOST='keep'\nVPN_USER='keep'\nVPN_PASS='keep'\nVPN_PSK='keep'\n"); local before = readall(CONF)
for _, bad in ipairs({ -1, 61, 1.5, "abc", "", "5 ", "5;reboot", "-1", {}, true, 1e9 }) do
    r = M.set_config(with({ retry_minutes = bad }))
    check("retry_minutes " .. tostring(type(bad) == "string" and ('"' .. bad .. '"') or bad) .. " is refused", r.saved == false and r.error == "invalid_retry")
end
for _, bad in ipairs({ -1, 169, 2.5, "abc", "", "1h", "$(id)", {}, false }) do
    r = M.set_config(with({ giveup_hours = bad }))
    check("giveup_hours " .. tostring(type(bad) == "string" and ('"' .. bad .. '"') or bad) .. " is refused", r.saved == false and r.error == "invalid_giveup")
end
check("a refused save leaves the file as it was", readall(CONF) == before)
check("the connection values are still checked as before",
      M.set_config(with({ host = "-bad" })).error == "invalid_host" and M.set_config(with({ user = "a'b" })).error == "invalid_user"
      and M.set_config(with({ password = "" })).error == "password_required" and M.set_config(with({ psk = 'x"y' })).error == "invalid_psk")
writeall(T .. "/busy", tostring(os.time()) .. "\n")
check("saving while the VPN is busy is refused", M.set_config(with({})).error == "busy")

print("=== start and stop still work")
clear()
r = M.start({})
check("start is accepted and runs the control script", r.accepted == true); wait_idle()
check("... which was called with start", (readall(T .. "/calls.log") or ""):find("start called", 1, true) ~= nil)
writeall(T .. "/state", "203.0.113.5 192.168.1.1 eth0\n")
check("start while Connect is on is refused", M.start({}).reason == "already_running")
r = M.stop({}); wait_idle()
check("stop is accepted", r.accepted == true and (readall(T .. "/calls.log") or ""):find("stop called", 1, true) ~= nil)
clear()
check("stop while off is refused", M.stop({}).reason == "not_running")
writeall(T .. "/busy", tostring(os.time()) .. "\n")
check("start while busy is refused", M.start({}).reason == "busy")
check("the module returns the five calls the panel uses", type(M.get_status) == "function" and type(M.start) == "function" and type(M.stop) == "function" and type(M.get_config) == "function" and type(M.set_config) == "function")

os.execute("rm -rf " .. T)
print("=== RESULT: " .. pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
