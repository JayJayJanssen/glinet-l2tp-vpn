# Design

## The control script (`scripts/l2tp-vpn`)

`start`, in order:

1. Reads `/etc/l2tp-vpn.conf`, resolves the server name **on every start** (so dynamic DNS works) and remembers the router's default gateway and interface in `/tmp/l2tp-vpn.state`.
2. Writes `/etc/ipsec.conf` (IKEv1, pre-shared key, transport mode, UDP 1701, NAT traversal forced, dead-peer detection), `/etc/ipsec.secrets`, `/etc/xl2tpd/xl2tpd.conf` and `/etc/ppp/options.xl2tpd`, all root-only. The cipher offer is broad: AES256/AES128/3DES, SHA1, DH groups modp2048 and modp1024.
3. Starts strongSwan, brings up the IPsec connection and checks that it is installed; then starts xl2tpd, dials the L2TP session and waits up to 30 seconds for `ppp0` to get an address. PAP and EAP are refused, so the server must offer MS-CHAPv2.
4. Adds a host route to the server through the original gateway (so the tunnel's own packets do not loop into the tunnel), then two routes, `0.0.0.0/1` and `128.0.0.0/1` via `ppp0`, which override the default route without deleting it, and three firewall rules (masquerade on `ppp0`, forward to and from it).

`stop` removes the rules and routes, ends the L2TP session, stops xl2tpd and strongSwan, and deletes the state file. A failed start runs `stop` for you. Nothing is saved across a reboot, so a reboot always returns the router to normal.

The stock `ipsec` and `xl2tpd` services are disabled so that strongSwan's init script does not regenerate its configuration from UCI over the one the script writes.

## The panel page (`webui/`)

Four files, all new, nothing existing is changed:

- **`l2tp`** is a backend module (Lua) in the panel's `oui-httpd` RPC directory, with `get_status`, `start`, `stop`, `get_config` and `set_config`. Start and stop run detached from nginx and are guarded by a busy marker against double clicks.
  `set_config` validates every value strictly (characters, lengths, a legal host name) and replaces `/etc/l2tp-vpn.conf` atomically, root-only.
- **`l2tp-validator.lua`** exempts only `set_config` from the panel's generic argument check, which would reject most passwords.
- **`l2tp-view-live.js`** is the page, written against the panel's Vue 2 runtime, gzipped into `/www/views/`.
- **`l2tp-menu.json`** is the menu entry, installed last.

**Login protection** is the panel's own `/rpc` access check, so the backend is never placed under `/www/cgi-bin`, where nginx does not check a login. The installer calls the backend with a bogus session and refuses to keep it unless both `get_status` and `set_config` answer `-32000` (Access denied).
After an nginx restart the web server needs a few seconds before it answers, so the installer waits up to 20 seconds for any answer first; without that wait, a re-install could remove a working module because the check got no reply.

## Lessons from building it

- The panel page's `h(tag, ...)` helper treats a bare VNode as data; always wrap children in an array.
- nginx caches the backend module: restart it after replacing the file.
- In a test, feed a component the real output of the thing it talks to, not a hand-written sample.

## Limits

- IKEv1 with a pre-shared key and MS-CHAPv2 only; no certificates, no IKEv2.
- IPv4 only. All traffic goes through the tunnel; there is no split tunnelling.
- DNS may still leave the tunnel (see the user guide).
- It does not reconnect by itself when the uplink changes; stop and start it.
- The credentials are stored in plain text (root-only files).
