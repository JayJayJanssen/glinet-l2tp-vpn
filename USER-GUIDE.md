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
| `l2tp-vpn start` | Resolves the server, brings up IPsec, then L2TP/PPP, then adds routes and firewall rules |
| `l2tp-vpn stop` | Removes the routes and firewall rules, stops xl2tpd and strongSwan |
| `l2tp-vpn status` | Shows IPsec state, the `ppp0` address and the VPN routes |
| `l2tp-vpn stop; l2tp-vpn start` | Restart. Use after changing networks |

A successful `start` prints three lines ending with `VPN up. All traffic now goes through the tunnel.`

## Web panel

Open the router's panel, then **VPN > L2TP VPN** (sign in as usual).

- **Status:** a coloured dot with Off, Connecting, Disconnecting or Connected.
- **Server** and **Tunnel address:** the server's IP, and the router's tunnel address and peer.
- **Connect:** the on/off switch. It follows changes made from SSH within a few seconds, and ignores clicks while a start or stop is running. A message tells you when the VPN connected, or that it could not (the router log then has the reason).
- **Connection settings:** four plain-text fields: Server, Username, Password, Secret key (PSK). They show the saved values and map to the four lines of `/etc/l2tp-vpn.conf`.
  - **Save** writes the file. The new settings apply the next time the VPN starts.
  - **Save and reconnect** saves, then stops the VPN if it is up and starts it with the new settings (or just starts it when it is off).
  - **To use a different server:** change the fields, then Save and reconnect.
  - Not allowed in any field: `'`, `"`, `\` and control characters. The server name may only contain letters, digits, dots and hyphens and may not start with a hyphen. Limits: server 253, username 128, password 128, key 256 characters.
    A username like `DOMAIN\user` is therefore not possible. An orange line under the box says what is wrong.
  - Saving is refused while a start or stop is running.
- The password and key are shown as plain text, by design. Only a signed-in panel admin can see or change them. Over `http://` they travel unencrypted on your local network; `https://<router address>` (self-signed certificate) avoids that.

Limits: if you open the page while a stop is running (started from SSH), it shows "Connecting" until the stop finishes. Only the panel's admin account can use the page.

## What a healthy tunnel looks like

`l2tp-vpn status` shows `ESTABLISHED` and `INSTALLED, TRANSPORT ... ESP in UDP`, an `inet <address> peer <address> ... ppp0` line, and the routes `0.0.0.0/1` and `128.0.0.0/1` via `ppp0`.
To check that traffic leaves at the server's side, open a "what is my IP" page from a device on the router's Wi-Fi. It should show the server's public address.

## Things to know

- **Nothing autostarts.** After a reboot the VPN is off until you start it.
- **All traffic goes through the tunnel,** including every device on the router's Wi-Fi.
- **Switching Wi-Fi networks:** stop and start the VPN so the script picks up the new gateway. The server's address is looked up again on every start, so dynamic DNS works.
- **Expect extra latency.** Every request travels to the server first. With the server on another continent, expect hundreds of milliseconds: browsing feels slower, video calls and games suffer, downloads are fine. Speed is capped by the server side's upload speed.

## Settings that can conflict with L2TP

- **WireGuard client (or OpenVPN client):** do not run it together with L2TP. Both are full-tunnel VPNs, and the handshake of the second would be routed into the first. Turn one off before starting the other. A VPN kill switch in the panel may block traffic over `ppp0`.
- **WireGuard server:** replies to remote clients would leave through the L2TP tunnel, so the server stops working from outside while L2TP is on. Devices on the router's own Wi-Fi are not affected.
- **Any panel change that reloads the firewall or network** (WireGuard, port forwards, guest Wi-Fi, ...) can wipe the NAT and forward rules the script added. The status still looks fine, but devices lose internet. Fix: stop and start the VPN.
  Check with `iptables -t nat -S POSTROUTING | grep ppp0` (nothing printed means the rules are gone).
- **Uplink changes** (another Wi-Fi, cable instead of Wi-Fi, repeater reconnect): stop and start the VPN so the saved gateway is refreshed.
- **DNS settings** (DNS over TLS, custom DNS, AdGuard Home): lookups may leave outside the tunnel (a DNS leak). Not handled by this project.
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

### DNS may leak outside the tunnel

The script asks the server for DNS (`usepeerdns`), but the router's own dnsmasq may keep using the uplink's DNS. Run a DNS leak test from a device on the router's Wi-Fi while the VPN is on.
If it shows the local network's DNS, the fix is to point dnsmasq at the VPN's DNS while connected. This is not implemented.

### The tunnel drops after minutes or hours

Some networks filter or disrupt L2TP/IPsec (UDP 500/4500). Collect the log with `logread | grep -Ei 'charon|pppd' | tail -40`. A more resilient option is WireGuard on a non-standard port, or OpenVPN over TCP 443; that needs a server change.
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

Power-cycle the router. Routes and firewall rules are not persistent, so it returns to normal.

## Files on the router

| Path | Role |
|---|---|
| `/usr/bin/l2tp-vpn` | Control script |
| `/etc/l2tp-vpn.conf` | Your server name, username, password and key. Root-only |
| `/tmp/l2tp-vpn.state` | Exists while the VPN is up: server address, gateway, interface |
| `/usr/lib/oui-httpd/rpc/l2tp` | Panel backend (status, start, stop, read and write settings) |
| `/usr/share/gl-validator.d/l2tp.lua` | Lets the panel pass passwords with symbols to the backend |
| `/www/views/gl-sdk4-ui-l2tp.common.js.gz`, `/www/i18n/gl-sdk4-ui-l2tp.en.json`, `/usr/share/oui/menu.d/l2tp.json` | The panel page, its label and its menu entry |
| `/tmp/l2tp-web.busy` | Exists while the panel is running a start or stop |
| `/etc/ipsec.conf`, `/etc/ipsec.secrets`, `/etc/xl2tpd/xl2tpd.conf`, `/etc/ppp/options.xl2tpd` | Regenerated by the script on every start. Do not edit by hand |

## Logs

    logread | grep -Ei 'xl2tpd|pppd'             # PPP details
    logread | grep -E '\[(IKE|ENC|NET|CFG)\]'     # IPsec negotiation (charon)
    logread | grep l2tp-web                      # what the panel started or stopped

## Changing settings

- **New server, username, password or key:** use the Connection settings on the panel page (Save and reconnect), or edit `/etc/l2tp-vpn.conf` and then stop and start.
- **Ciphers, MTU, PPP options:** edit the matching lines in `/usr/bin/l2tp-vpn`, then stop and start.
- **Quieter logs:** `sed -i 's/ppp debug = yes/ppp debug = no/' /usr/bin/l2tp-vpn`
