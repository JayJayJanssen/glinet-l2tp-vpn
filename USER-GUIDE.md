# User guide

Daily use of the L2TP/IPsec VPN on a GL.iNet router. For first-time setup see [INSTALL.md](INSTALL.md).
Tested on one router only: the GL.iNet GL-SFT1200 (Opal), firmware 4.8.3. Other models are untested.

## Quick start

1. Connect the router to the internet first (Wi-Fi, repeater, hotspot or cable).
2. Start the VPN, either way:
   - **Web panel:** VPN > L2TP VPN, turn the Connect switch on.
   - **SSH:** `l2tp-vpn start`
3. Wait up to 40 seconds. The panel shows the progress; over SSH, confirm with `l2tp-vpn status`.
4. Stop it with the panel switch, or with `l2tp-vpn stop`.

## Commands

| Command | What it does |
|---|---|
| `l2tp-vpn start` | Resolves the server, brings up IPsec, then L2TP/PPP, then adds routes and firewall rules, and starts the reconnect loop |
| `l2tp-vpn stop` | Ends the reconnect loop, removes the routes and firewall rules, stops xl2tpd and strongSwan |
| `l2tp-vpn status` | Shows IPsec state, the `ppp0` address, the VPN routes, whether the DNS follows the server, and whether the reconnect loop runs |
| `l2tp-vpn dns` | Shows how DNS is set up: the file dnsmasq reads, what the server handed out, and whether it is applied |
| `l2tp-vpn stop; l2tp-vpn start` | Restart. Use after changing networks |

A successful `start` prints three lines ending with `VPN up. All traffic now goes through the tunnel.`

## Web panel

Open the router's panel, then **VPN > L2TP VPN** (sign in as usual).

- **Status:** a coloured dot with Off, Connecting, Disconnecting or Connected. After a drop it shows Connecting while the reconnect loop waits or tries again.
- **Server** and **Tunnel address:** the server's IP, and the router's tunnel address and peer.
- **Connect:** the on/off switch. It follows changes made from SSH within a few seconds, and ignores clicks while a start or stop is running. A message tells you when the VPN connected, or that it could not (the router log then has the reason).
- **Connection settings:** four plain-text fields: Server, Username, Password, Secret key (PSK). They show the saved values and map to the first four lines of `/etc/l2tp-vpn.conf`.
  - **Save** writes the file. The new settings apply the next time the VPN starts.
  - **Save and reconnect** saves, then stops the VPN if it is up and starts it with the new settings (or just starts it when it is off).
  - **To use a different server:** change the fields, then Save and reconnect.
- **If the connection drops:** two number fields, saved with the same Save buttons. **Reconnect every (minutes)**, 0 to 60, default 5: the wait between attempts (0 = do not reconnect: a dropped tunnel switches Connect off). **Give up after (hours)**, 0 to 168, default 0 (never): switch Connect off when this many hours have passed since the drop. They apply from the next drop. See "When the connection drops".
- **A message under the status:** when the router itself switched Connect off (it gave up, or reconnecting is off), the reason shows in orange until the next start.
  - Not allowed in any field: `'`, `"`, `\` and control characters. The server name may only contain letters, digits, dots and hyphens and may not start with a hyphen. Limits: server 253, username 128, password 128, key 256 characters.
    A username like `DOMAIN\user` is therefore not possible. An orange line under the box says what is wrong.
  - Saving is refused while a start or stop is running.
- The password and key are shown as plain text, by design. Only a signed-in panel admin can see or change them. Over `http://` they travel unencrypted on your local network; `https://<router address>` (self-signed certificate) avoids that.

Limits: if you open the page while a stop is running (started from SSH), it shows "Connecting" until the stop finishes. Only the panel's admin account can use the page.

## What a healthy tunnel looks like

`l2tp-vpn status` shows `ESTABLISHED` and `INSTALLED, TRANSPORT ... ESP in UDP`, an `inet <address> peer <address> ... ppp0` line, the routes `0.0.0.0/1` and `128.0.0.0/1` via `ppp0`, and `DNS: follows the VPN server (<addresses>)`.
To check that traffic leaves at the server's side, open a "what is my IP" page from a device on the router's Wi-Fi. It should show the server's public address.

## When the connection drops

While Connect is on, a small background loop watches the tunnel. It starts with `l2tp-vpn start` and ends with `l2tp-vpn stop`. If the tunnel disappears, for example because the internet went away:

1. It waits about 45 seconds in case the tunnel comes back by itself. (PPP itself needs about 2 minutes of silence before it gives up, so a short outage often needs nothing at all.)
2. It waits for the uplink: no attempt is made while the gateway does not answer.
3. It then takes the old connection down cleanly (the uplink's DNS is put back, so the server's name can be looked up), keeps Connect on, so the panel shows "Connecting", and connects again.
4. If an attempt fails it waits 1 minute, then 2 minutes, then the *Reconnect every* time (5 minutes unless you changed it), and keeps trying at that interval.
5. When an attempt works, it goes back to watching.

| Setting in `/etc/l2tp-vpn.conf` (and on the panel page) | Range | Meaning |
|---|---|---|
| `RETRY_MINUTES` (Reconnect every) | 0 to 60, default 5 | The wait between attempts after the first two. 0 = do not reconnect: a dropped tunnel switches Connect off |
| `GIVE_UP_HOURS` (Give up after) | 0 to 168, default 0 | Stop trying and switch Connect off when this many hours have passed since the drop. 0 = never. The panel shows the reason under the status |

The settings are read again when a drop is noticed, so a change applies from the next drop without a restart.

- **The server may keep the old session** for a few minutes and refuse or drop the new one (see "IPsec comes up, then the server deletes the tunnel" below). Early attempts can therefore fail, which is why the first waits are only 1 and 2 minutes.
- **It costs very little.** While the tunnel is healthy the loop reads the routing table with shell builtins every 30 seconds (every 5 seconds while a drop is suspected) and starts no program. On a test machine one check cost 0.04 ms of CPU; the router is slower, but it stays far below 1% of one core. It is one shell process of 1 to 2 MB.
- **`l2tp-vpn status`** shows `Reconnect loop: running`. If it says NOT running while Connect is on, something ended it: stop and start the VPN.
- **Log:** `logread | grep l2tp-keeper` shows each drop, attempt and result.
- **A restart or power cut** ends the loop together with the VPN; nothing starts again by itself.

## Things to know

- **Nothing autostarts.** After a reboot the VPN is off until you start it.
- **All traffic goes through the tunnel,** including every device on the router's Wi-Fi.
- **Switching Wi-Fi networks:** the tunnel drops, and the reconnect loop then connects again with the new gateway, but only after PPP has given up (about 2 minutes) and the loop's 45-second check. To switch at once, stop and start the VPN. The server's address is looked up again on every start and every attempt, so dynamic DNS works.
- **Expect extra latency.** Every request travels to the server first. With the server on another continent, expect hundreds of milliseconds: browsing feels slower, video calls and games suffer, downloads are fine. Speed is capped by the server side's upload speed.

## Settings that can conflict with L2TP

- **WireGuard client (or OpenVPN client):** do not run it together with L2TP. Both are full-tunnel VPNs, and the handshake of the second would be routed into the first. Turn one off before starting the other. A VPN kill switch in the panel may block traffic over `ppp0`.
- **WireGuard server:** replies to remote clients would leave through the L2TP tunnel, so the server stops working from outside while L2TP is on. Devices on the router's own Wi-Fi are not affected.
- **Any panel change that reloads the firewall or network** (WireGuard, port forwards, guest Wi-Fi, ...) can wipe the NAT and forward rules the script added. The status still looks fine, but devices lose internet. Fix: stop and start the VPN.
  Check with `iptables -t nat -S POSTROUTING | grep ppp0` (nothing printed means the rules are gone).
- **Uplink changes** (another Wi-Fi, cable instead of Wi-Fi, repeater reconnect): the reconnect loop refreshes the saved gateway when it reconnects after the drop (about 3 minutes); stop and start the VPN to do it at once.
- **DNS settings in the panel** (DNS over TLS, manual DNS, AdGuard Home): with these on, the tunnel's DNS is not applied (`l2tp-vpn start` says `DNS left unchanged: ...`) and lookups follow those settings.
- **LAN subnet:** do not use 192.168.2.0/24, the L2TP link uses 192.168.2.x.
- **Two tunnels from one public address:** devices behind the router already go through its tunnel. Running a second L2TP connection to the same server from a device behind it can confuse the server. Use one tunnel at a time.

## Troubleshooting

### `start` says "Already started"

The state file `/tmp/l2tp-vpn.state` exists. Run `l2tp-vpn stop`, then `l2tp-vpn start`.

### `start` says "Cannot resolve ..."

The router has no working DNS. Check that it is online. Test with `nslookup <your server name>`.

### `start` says "No default route"

The router has no internet uplink. Connect it to Wi-Fi, a hotspot or a cable first.

### `start` says "IPsec failed"

The hint printed by the script (`grep -i charon`) hides the useful lines. IKE messages look like `[IKE]`, `[ENC]`, `[NET]`; use this instead, right after a failed start:

    logread | grep -E '\[(IKE|ENC|NET|CFG)\]' | tail -60

- `no proposal chosen`: cipher mismatch. The server needs something outside the list. If it insists on SHA256, install `strongswan-mod-sha2` and add SHA256 proposals to the `ike=` and `esp=` lines in the script.
- No reply, timeouts: the server is not reachable on UDP 500/4500. Check the port forwarding at the server's router, check that the dynamic DNS record is current, and check whether the network you are on blocks IPsec (some hotel and public networks do).
- `AUTH_FAILED` or similar: the PSK is wrong. Check `/etc/l2tp-vpn.conf`.

### `start` says "PPP failed"

IPsec is fine, but PPP login failed.

    logread | grep -Ei 'xl2tpd|pppd' | tail -40

Check the username and password in `/etc/l2tp-vpn.conf`, and check that the server accepts MS-CHAPv2 (the script refuses PAP and EAP). Remove usernames, passwords and keys from any log before sharing it.

### Tunnel is up but some sites hang or load partially

An MTU problem. Lower `mtu 1400` and `mru 1400` in the script to about `1300` (they are in the `options.xl2tpd` section), then stop and start the VPN.

### DNS

While the tunnel is up, the router's DNS forwarder (`dnsmasq`) is pointed at the DNS servers the L2TP server hands out over the PPP link, so the lookups of the router and of every device that uses it leave from the far end of the tunnel. When the tunnel stops, the uplink's DNS file is put back. The change lives in `/tmp` only, so a restart of the router always returns to normal.

Check it: `l2tp-vpn status` ends with `DNS: follows the VPN server (...)`, and `l2tp-vpn dns` shows the details. From a device on the router's Wi-Fi, `nslookup whoami.akamai.net` prints the address of the resolver that really asked: it should belong to the server's network, not to the uplink's.

- **`DNS left unchanged: the server gave no DNS address.`** The server doesn't hand out DNS over PPP. Set that on the server (the DNS option of its L2TP/PPP profile).
- **`DNS left unchanged: dnsmasq ignores its resolv file`, `... has fixed DNS servers` or `AdGuard Home is running`.** The panel's DNS settings (DNS over TLS, manual DNS, AdGuard Home) take precedence. Turn them off while you use the tunnel if you want its DNS.
- **`DNS left unchanged: dnsmasq reads a file that survives a restart`.** dnsmasq has been told to read its servers from a file on flash. The script only changes files in RAM, so that a power cut can never leave the tunnel's DNS behind.
- **Lookups still go elsewhere after the uplink renewed its address.** The network service can rewrite the uplink's DNS file at that moment. Stop and start the VPN.
- **Not covered:** devices with a DNS server of their own built in, and IPv6 DNS.

### The tunnel drops after minutes or hours

Some networks filter or disrupt L2TP/IPsec (UDP 500/4500). Collect the log with `logread | grep -Ei 'charon|pppd' | tail -40`. If it drops and does not come back, see "When the connection drops" above: `l2tp-vpn status` shows whether the reconnect loop runs, and `logread | grep l2tp-keeper` what it did. A more resilient option is WireGuard on a non-standard port, or OpenVPN over TCP 443; that needs a server change.
The router already has the WireGuard kernel module.

### IPsec comes up, then the server deletes the tunnel about a second later

In the log: `IKE_SA ... established`, `CHILD_SA ... established`, then a received DELETE for the ESP SA and "closing CHILD_SA ... (0 bytes)". In the case where this was seen, the router's settings were not the cause (two uplinks, other IKE identities, proposals, NAT-T and rekey settings and an immediate L2TP start made no difference):
the server decided to drop the tunnel, because of a stale conflicting session that cleared on its own. Look at the server first: its VPN logs and its list of sessions. Remember that the server and the router may log in different time zones.

### Panel page: Status empty, "Access denied" or "Cannot reach the router backend"

- **Status or a field is empty although the VPN is up:** an old copy of the page. Hard-refresh (Cmd/Ctrl+Shift+R). To see what the router really serves, compare `gunzip -c /www/views/gl-sdk4-ui-l2tp.common.js.gz | md5sum` on the router with `md5sum webui/l2tp-view-live.js` on your computer.
- **"Access denied. Please sign in again.":** the panel session expired. Sign in again.
- **"Cannot reach the router backend":** the module is missing or the web server needs a restart. Check `ls /usr/lib/oui-httpd/rpc/l2tp` and run `/etc/init.d/nginx restart`.
- **Save is greyed out:** nothing changed yet, or a field is invalid (see the orange line), or a start or stop is running.
- **"The settings were not saved." with an error:** busy (try again in a moment), an invalid value, or the router could not write the file.
- **Passwords with symbols are rejected as "Invalid params":** the validator file is missing: `ls /usr/share/gl-validator.d/l2tp.lua` (install it with `sh install.sh --web-only`).

### Locked out or confused

Power-cycle the router. Routes, firewall rules and the reconnect loop are not persistent, so it returns to normal. Without a reboot: `l2tp-vpn stop` ends the VPN and its reconnect attempts.

## Files on the router

| Path | Role |
|---|---|
| `/usr/bin/l2tp-vpn` | Control script |
| `/etc/l2tp-vpn.conf` | Your server name, username, password and key, and the two reconnect settings. Root-only |
| `/tmp/l2tp-vpn.state` | Exists while the VPN is up: server address, gateway, interface |
| `/tmp/l2tp-vpn.keeper.pid` | Exists while the reconnect loop runs: its process id |
| `/tmp/l2tp-vpn.attempt.pid`, `/tmp/l2tp-vpn.attempt.out` | A reconnect attempt that is running right now, and its output |
| `/tmp/l2tp-vpn.msg` | Why the loop switched Connect off (the panel shows it); removed at the next start |
| `/tmp/l2tp-vpn.resolv.bak` | Exists while the server's DNS is applied: the uplink's DNS file as it was |
| `/usr/lib/oui-httpd/rpc/l2tp` | Panel backend (status, start, stop, read and write settings) |
| `/usr/share/gl-validator.d/l2tp.lua` | Lets the panel pass passwords with symbols to the backend |
| `/www/views/gl-sdk4-ui-l2tp.common.js.gz`, `/www/i18n/gl-sdk4-ui-l2tp.en.json`, `/usr/share/oui/menu.d/l2tp.json` | The panel page, its label and its menu entry |
| `/tmp/l2tp-web.busy` | Exists while the panel is running a start or stop |
| `/etc/ipsec.conf`, `/etc/ipsec.secrets`, `/etc/xl2tpd/xl2tpd.conf`, `/etc/ppp/options.xl2tpd` | Regenerated by the script on every start. Do not edit by hand |

## Logs

    logread | grep -Ei 'xl2tpd|pppd'             # PPP details
    logread | grep -E '\[(IKE|ENC|NET|CFG)\]'     # IPsec negotiation (charon)
    logread | grep l2tp-web                      # what the panel started or stopped
    logread | grep l2tp-keeper                   # the reconnect loop: drops, attempts, results

## Changing settings

- **New server, username, password or key:** use the Connection settings on the panel page (Save and reconnect), or edit `/etc/l2tp-vpn.conf` and then stop and start.
- **Reconnecting:** the two fields on the panel page, or `RETRY_MINUTES` and `GIVE_UP_HOURS` in `/etc/l2tp-vpn.conf`. The panel's Save rewrites the whole file with its six values, so keep any other lines of your own somewhere else.
- **Ciphers, MTU, PPP options:** edit the matching lines in `/usr/bin/l2tp-vpn`, then stop and start.
- **Quieter logs:** `sed -i 's/ppp debug = yes/ppp debug = no/' /usr/bin/l2tp-vpn`
