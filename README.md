# glinet-l2tp-vpn

An **L2TP/IPsec VPN client for GL.iNet routers**  e.g. GL.iNet Opal (GL-SFT1200) that do not have one. It uses strongSwan (IPsec) and xl2tpd (L2TP) from the router's own package feed, and adds:

- a control script, `l2tp-vpn start | stop | status`;
- an optional **panel page** `VPN > L2TP VPN` (the installer asks; without it you control the VPN over SSH) with status, an on/off switch and editable connection settings (server, username, password, key);
- an installer that does all of it, shows a dry run first, asks before every change, and never starts the VPN.

All traffic from the router, and from every device on its Wi-Fi, goes through the tunnel while it is on. Nothing runs at boot.

## Requirements

- A GL.iNet router on firmware 4.x (OpenWrt based). Tested on one model only: the **GL-SFT1200 (Opal)**, firmware 4.8.3 (see "Tested on" below). Other models are untested; the installer checks the router and asks before it continues on a different one.
- An **L2TP/IPsec server** that accepts a pre-shared key (PSK) and MS-CHAPv2 (username and password), reachable on UDP 500, 4500 and 1701.
- Internet access on the router while the packages install.

## Quick start

1. Copy `scripts/install.sh` to the router as `/tmp/install.sh` (see [INSTALL.md](INSTALL.md)) and run `sh /tmp/install.sh`.
2. Answer the questions: install the packages (a dry run is shown first), your server, username, password and key, and whether to add the panel page (optional).
3. Start the VPN from the panel, or with `l2tp-vpn start` (see "Start and stop" below).

Daily use, troubleshooting and what can conflict: [USER-GUIDE.md](USER-GUIDE.md). How it works: [DESIGN.md](DESIGN.md).

## Start and stop

**Without the panel page**, over SSH as root on the router (`ssh root@192.168.8.1`; use your router's address, and add `-o HostKeyAlgorithms=+ssh-rsa` if your SSH client refuses the router's old host key type):

    l2tp-vpn start      # takes up to 40 seconds; ends with "VPN up. All traffic now goes through the tunnel."
    l2tp-vpn status     # shows the IPsec state, the tunnel address and the routes
    l2tp-vpn stop       # removes the tunnel, the routes and the firewall rules

**With the panel page**, open `VPN > L2TP VPN` in the router's web panel and turn **Connect** on or off.

Nothing starts by itself at boot, so after the router restarts the VPN is off until you start it. More in [USER-GUIDE.md](USER-GUIDE.md).

## Security

- The username, password and key are stored in **plain text** in `/etc/l2tp-vpn.conf`, and the script writes them into `/etc/ipsec.secrets` and `/etc/ppp/options.xl2tpd` at every start. All three are root-only files. Keep them out of backups you share.
- The panel page shows the password and key as plain text, by design. Only a signed-in panel admin can reach them. Over `http://` they travel unencrypted on your local network; use `https://` (self-signed certificate) to avoid that.
- The installer checks that calls to the panel backend without a login are refused, and removes the backend if it cannot confirm that.

## Tested on

| | Details |
|---|---|
| Tested on | **GL.iNet GL-SFT1200 (Opal)**, firmware 4.8.3, OpenWrt 18.06, kernel 4.14.90, architecture `mips_siflower` |
| Not tested | any other GL.iNet model or firmware version; other OpenWrt routers |

## Status

Verified by hand on one GL-SFT1200: connecting to a server with a PSK, stopping, the panel page (status, switch, settings), the login check, and a wrong-server test.
**Not verified:** how a wrong password or key is reported, behaviour after a reboot, the panel over https, behaviour after a firmware upgrade, and any other model.
There are no behavioural tests in this repository, only static checks (`sh run-checks.sh`: shell, Lua and JavaScript syntax, and that the installer embeds exact copies of the other files).
The installer's wait for the panel after an nginx restart (see DESIGN.md) is tested in isolation, not through a full installer run.

## Layout

    scripts/   install.sh (the installer, self-contained), l2tp-vpn (control script), l2tp-vpn.conf.example
    webui/     the panel page's sources: l2tp (backend module), l2tp-validator.lua, l2tp-view-live.js (the page), l2tp-menu.json (menu entry)
    tools/     check_installer.py, test_wait_for_panel.sh
    run-checks.sh   the static checks

## License

MIT. See [LICENSE](LICENSE).
