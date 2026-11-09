# Design

## The control script (`scripts/l2tp-vpn`)

`start`, in order:

1. Reads `/etc/l2tp-vpn.conf`, resolves the server name **on every start** (so dynamic DNS works) and remembers the router's default gateway and interface in `/tmp/l2tp-vpn.state`.
2. Writes `/etc/ipsec.conf` (IKEv1, pre-shared key, transport mode, UDP 1701, NAT traversal forced, dead-peer detection), `/etc/ipsec.secrets`, `/etc/xl2tpd/xl2tpd.conf` and `/etc/ppp/options.xl2tpd`, all root-only. The cipher offer is broad: AES256/AES128/3DES, SHA1, DH groups modp2048 and modp1024.
3. Starts strongSwan, brings up the IPsec connection and checks that it is installed; then starts xl2tpd, dials the L2TP session and waits up to 30 seconds for `ppp0` to get an address. PAP and EAP are refused, so the server must offer MS-CHAPv2.
4. Adds a host route to the server through the original gateway (so the tunnel's own packets do not loop into the tunnel), then two routes, `0.0.0.0/1` and `128.0.0.0/1` via `ppp0`, which override the default route without deleting it, and three firewall rules (masquerade on `ppp0`, forward to and from it).
5. Makes the router's DNS follow the server: the DNS servers that pppd got from the server (`usepeerdns` makes pppd write them to a resolv file; the script looks in `/etc/ppp/resolv.conf` and `/tmp/resolv.conf.ppp`, and only a file written since this start counts) replace the content of the file `dnsmasq` reads (`/tmp/resolv.conf.auto` unless uci names another), each address gets a `/32` route on `ppp0`, and `dnsmasq` is restarted. The uplink's original file is kept in `/tmp/l2tp-vpn.resolv.bak`. Nothing is changed when `dnsmasq` does not use that file (`noresolv`, fixed `server=` entries, AdGuard Home), when the file is not in RAM (so a power cut can never leave the tunnel's DNS behind), or when the server hands out no DNS; the script says so.

`stop` puts the uplink's DNS file back (unless the network service has already rewritten it), removes the rules and routes, ends the L2TP session, stops xl2tpd and strongSwan, and deletes the state file. A failed start runs `stop` for you. Nothing is saved across a reboot, so a reboot always returns the router to normal.

The stock `ipsec` and `xl2tpd` services are disabled so that strongSwan's init script does not regenerate its configuration from UCI over the one the script writes.

## The reconnect loop (inside `scripts/l2tp-vpn`)

`start` ends by launching one small background shell, `l2tp-vpn _keeper`, detached from the terminal; `stop` ends it. It does not survive a restart, like the rest.

- **What "Connect is on" means:** the state file exists. `teardown` removes everything the tunnel set up (routes, rules, daemons, the DNS change) but keeps the state file, so the loop can take the connection down and up again while the panel keeps showing "Connecting". Only `stop` (or the loop giving up) removes it. `connect` is one full connection and returns a status instead of exiting, so the loop and `start` can share it.
- **Noticing a drop without starting programs:** every 30 seconds the loop reads `/proc/net/route` with shell builtins and looks for a `ppp0` route (the tunnel's routes disappear with the interface, and the script adds them only after `ppp0` has an address). Measured on a test machine that is 0.04 ms instead of 1.66 ms for `ip addr show ppp0 | grep -q inet`. When the routes are gone it looks every 5 seconds, and after 9 rounds (about 45 seconds) counts the tunnel as dropped. PPP's own echo check ends a dead link after about 2 minutes, so a longer interval would not make recovery faster.
- **Attempts:** none while there is no uplink (a default route whose gateway answers a ping). Then `l2tp-vpn _attempt` runs as a separate process (so `stop` can end it): `teardown`, then `connect`. After a failure the wait is 1 minute, 2 minutes, then `RETRY_MINUTES`, never longer than `RETRY_MINUTES`. The settings are read again when a drop is noticed.
- **Giving up:** after `GIVE_UP_HOURS` since the drop (also while waiting for the uplink) the loop tears down, removes the state file and writes the reason to `/tmp/l2tp-vpn.msg`, which the panel backend passes on. `RETRY_MINUTES=0` gives up at once: a dropped tunnel switches Connect off instead of staying in "Connecting" for ever.
- **Not done, on purpose:** cron (a crontab line on flash, one-minute resolution, `crond` must run), a pppd `ip-down` hook (a permanent file for every PPP link, cannot be tested without the router), a compiled helper, and starting the VPN at boot.
- **Tested with stand-ins:** a fake clock and a fake `sleep` that fires scripted events (the tunnel drops, the uplink returns, Connect is switched off) and a fake attempt that succeeds or fails on cue (`tools/test_keeper.sh`), including that the healthy loop starts no program but `sleep`.

## The panel page (`webui/`)

Four files, all new, nothing existing is changed:

- **`l2tp`** is a backend module (Lua) in the panel's `oui-httpd` RPC directory, with `get_status`, `start`, `stop`, `get_config` and `set_config`. Start and stop run detached from nginx and are guarded by a busy marker against double clicks.
  `set_config` validates every value strictly (characters, lengths, a legal host name, and the two reconnect settings as whole numbers within their limits) and replaces `/etc/l2tp-vpn.conf` atomically, root-only. The two reconnect settings are optional in the call: what is saved stays when they are left out. `get_status` also returns `message`, the reason the reconnect loop switched Connect off, only while the VPN is off.
- **`l2tp-validator.lua`** exempts only `set_config` from the panel's generic argument check, which would reject most passwords.
- **`l2tp-view-live.js`** is the page, written against the panel's Vue 2 runtime, gzipped into `/www/views/`.
- **`l2tp-menu.json`** is the menu entry, installed last.

**Login protection** is the panel's own `/rpc` access check, so the backend is never placed under `/www/cgi-bin`, where nginx does not check a login. The installer calls the backend with a bogus session and refuses to keep it unless both `get_status` and `set_config` answer `-32000` (Access denied).
After an nginx restart the web server needs a few seconds before it answers, so the installer waits up to 20 seconds for any answer first; without that wait, a re-install could remove a working module because the check got no reply.

## Lessons from building it

- The panel page's `h(tag, ...)` helper treats a bare VNode as data; always wrap children in an array.
- nginx caches the backend module: restart it after replacing the file.
- In a test, feed a component the real output of the thing it talks to, not a hand-written sample.
- A loop that must stay cheap should start no program while nothing is wrong: reading the routing table with builtins is 40 times cheaper than piping `ip` into `grep`, and the `sleep` it needs is then the main cost.
- Test a loop with a fake clock and a fake `sleep` that fires events, and give every run a time limit: a loop that never sleeps hangs the test instead of failing it.
- Write test events with `printf`, not `echo`: some shells' `echo` expands `\t` and `\n`.

## Limits

- IKEv1 with a pre-shared key and MS-CHAPv2 only; no certificates, no IKEv2.
- IPv4 only. All traffic goes through the tunnel; there is no split tunnelling.
- The DNS follows the server only if `dnsmasq` uses its normal resolv file and the server hands out DNS (see the user guide). IPv6 DNS and devices with their own DNS are not covered.
- The reconnect loop reacts to a tunnel that has disappeared (its routes on `ppp0` are gone). A tunnel that still exists but passes no traffic is left to PPP's own echo check (about 2 minutes). A server that keeps the old session can refuse the first attempts.
- The credentials are stored in plain text (root-only files).
