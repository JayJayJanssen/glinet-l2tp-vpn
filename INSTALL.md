# Install guide

## The installer

`scripts/install.sh` does everything below in one run. It shows the package dry run, asks before installing packages, asks for your server and credentials, and asks before adding the panel page.
**It never starts the VPN.** It is safe to run again. `sh install.sh --web-only` installs only the panel page, on a router that already has the VPN.

1. **Copy it to the router** as `/tmp/install.sh`. GL.iNet's SSH server has no SFTP, so graphical file-transfer tools fail. Use `scp` with the legacy protocol (`-O`):

       scp -O scripts/install.sh root@192.168.8.1:/tmp/

   If `scp` refuses the router's old host key type, add the option:

       scp -o HostKeyAlgorithms=+ssh-rsa -O scripts/install.sh root@192.168.8.1:/tmp/
2. **Check the copy.** On the router: `wc -l /tmp/install.sh; md5sum /tmp/install.sh; sh -n /tmp/install.sh && echo SYNTAX_OK`. The first two must match the same commands on your computer.
3. **Run it:** `sh /tmp/install.sh`. The router needs internet access while the packages install.
4. Start the VPN yourself afterwards (`l2tp-vpn start`), or from the panel.

(`192.168.8.1` is GL.iNet's default LAN address; use yours.)

## What the installer does, step by step

Run these by hand if you prefer. Everything is done in an SSH session on the router as `root`.

### 0. Prerequisites and checks (read-only)

    cat /etc/openwrt_release; uname -r; opkg print-architecture
    df -h /overlay; free -m

On the GL-SFT1200 (Opal, firmware 4.8.3) used for testing: kernel 4.14.90, architecture `mips_siflower`, about 81 MB free in `/overlay`, about 49 MB free RAM. GL.iNet's package feeds carry strongSwan 5.6.3, xl2tpd 1.3.12 and kernel modules that match the running kernel.
On another model, check that `opkg` can find these packages and that the kernel modules match your kernel.

Server requirements: an L2TP/IPsec server with a pre-shared key; UDP 500, 4500 and 1701 forwarded to it if it sits behind a home router. No cipher settings are needed: the script offers AES256/AES128/3DES, SHA1 and DH groups modp1024 and modp2048.

### 1. Dry run, then install the packages

    opkg update
    opkg install --noaction strongswan-isakmp strongswan-mod-stroke strongswan-mod-kernel-netlink xl2tpd kmod-ipsec kmod-ipsec4
    opkg install strongswan-isakmp strongswan-mod-stroke strongswan-mod-kernel-netlink xl2tpd kmod-ipsec kmod-ipsec4

`--noaction` prints "Installing..." lines but changes nothing. The install also pulls in `kmod-l2tp`, `kmod-pppol2tp`, `ppp-mod-pppol2tp` and the crypto modules.

### 2. Keep the stock services from starting by themselves

strongSwan's init script would regenerate `/etc/ipsec.conf` from UCI and overwrite the one the control script writes.

    for s in ipsec xl2tpd; do /etc/init.d/$s stop; /etc/init.d/$s disable; done 2>/dev/null

To reverse: `/etc/init.d/<name> enable`.

### 3. Verify the kernel modules

    lsmod | grep -Ei 'xfrm|esp4|authenc|l2tp|af_key'

Expected: `af_key`, `authenc`, `esp4`, `xfrm_user`, `xfrm_algo`, `xfrm4_mode_transport`, `l2tp_core`, `l2tp_ppp`. If nothing is listed, run `kmodloader` and check again.
Do not use `insmod <name>` on OpenWrt (it needs a full path); use `kmodloader`. A missing `/proc/net/xfrm_stat` is harmless.
If modules fail to load with "disagrees about version of symbol", the fallback is `strongswan-mod-kernel-libipsec` (userspace IPsec); it was not needed on the test router.

### 4. Check that the server name resolves

    nslookup vpn.example.com

You should see an IPv4 `Address` line after `Name:`. A trailing `*** Can't find ...: No answer` is only the missing IPv6 record.

### 5. Create the settings file

Use `scripts/l2tp-vpn.conf.example` as the template. Copy it to the router as `/etc/l2tp-vpn.conf`, with one of these commands on your computer (the second if the first is refused):

    scp -O scripts/l2tp-vpn.conf.example root@192.168.8.1:/etc/l2tp-vpn.conf
    scp -o HostKeyAlgorithms=+ssh-rsa -O scripts/l2tp-vpn.conf.example root@192.168.8.1:/etc/l2tp-vpn.conf

The template also has two optional lines for reconnecting after a drop (`RETRY_MINUTES`, `GIVE_UP_HOURS`); the defaults are fine. Then, on the router, make it private and fill in your values:

    chmod 600 /etc/l2tp-vpn.conf
    vi /etc/l2tp-vpn.conf

In `vi`: press `i` to edit, replace the values, press `Esc`, type `:wq`. Do not use a single quote (`'`) in any value, and no double quote (`"`) in the key.

### 6. Install the control script

Copy `scripts/l2tp-vpn` to the router as `/usr/bin/l2tp-vpn`, with one of these commands on your computer (the second if the first is refused):

    scp -O scripts/l2tp-vpn root@192.168.8.1:/usr/bin/l2tp-vpn
    scp -o HostKeyAlgorithms=+ssh-rsa -O scripts/l2tp-vpn root@192.168.8.1:/usr/bin/l2tp-vpn

Then, on the router:

    chmod +x /usr/bin/l2tp-vpn
    sh -n /usr/bin/l2tp-vpn && echo SYNTAX_OK; tail -n 3 /usr/bin/l2tp-vpn

Expected: `SYNTAX_OK` and a last line `esac`. If not, copy the file again.

### 7. First test

    l2tp-vpn start
    l2tp-vpn status
    ping -c 3 8.8.8.8
    l2tp-vpn stop

`start` prints three lines ending with `VPN up. All traffic now goes through the tunnel.` `status` should show `ESTABLISHED`, `INSTALLED, TRANSPORT`, an `inet` address on `ppp0`, the routes `0.0.0.0/1` and `128.0.0.0/1` via `ppp0`, a `DNS:` line and `Reconnect loop: running`. `start` also says whether the router's DNS now follows the server (`DNS follows the server: ...`) or why it was left unchanged; `l2tp-vpn dns` shows the details.
On the test router the tunnel came up on the first try with the broad cipher list, using NAT traversal (ESP in UDP).

### 8. Panel page (optional)

Adds **VPN > L2TP VPN**: status, server, tunnel address, an on/off switch, a "Connection settings" box with four plain-text fields, and an "If the connection drops" box with the two reconnect settings; both rewrite `/etc/l2tp-vpn.conf`. Only new files are added; no existing panel file is changed.
The easy way is `sh /tmp/install.sh --web-only`. It writes the files, then **tests that calls without a login are refused** (`get_status` and `set_config`) and removes everything again if it cannot confirm that.
On a re-install it offers to restart nginx (the web server caches modules), waits up to 20 seconds for the panel to answer, and then runs the check. If the web server still gives no answer, it removes the module and tells you to retry with `--web-only`.

| File on the router | Source | Role |
|---|---|---|
| `/usr/lib/oui-httpd/rpc/l2tp` | `webui/l2tp` | backend: status, start, stop, read and write settings |
| `/usr/share/gl-validator.d/l2tp.lua` | `webui/l2tp-validator.lua` | lets the panel pass passwords with symbols to the backend |
| `/www/views/gl-sdk4-ui-l2tp.common.js.gz` | `webui/l2tp-view-live.js`, gzipped with `gzip -9` | the page |
| `/www/i18n/gl-sdk4-ui-l2tp.en.json` | `{"menu_l2tp": "L2TP VPN"}` | the menu label |
| `/usr/share/oui/menu.d/l2tp.json` | `webui/l2tp-menu.json` | the menu entry |

By hand, in this order: the module and the validator, restart nginx, run the login check (below), then the page and the label, and the **menu entry last**.
The check: `curl -s http://127.0.0.1/rpc -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["bogus1234","l2tp","get_status",{}]}'` must answer with `-32000` (Access denied). If it does not, remove the module again.

Things to know:

- The password and key are plain text on the page and are returned by the backend, by choice. Only a signed-in panel admin can reach them.
- Values may not contain `'`, `"`, `\` or control characters.
- Never put start/stop or anything that reads credentials under `/www/cgi-bin`: nginx does not check a login there.

### 9. Optional cleanup

Turn off verbose PPP logging: `sed -i 's/ppp debug = yes/ppp debug = no/' /usr/bin/l2tp-vpn`.

## Updating an existing install

Re-running the installer is the way. It is safe to repeat, and it keeps your settings: `/etc/l2tp-vpn.conf` is never overwritten.

1. Copy the new `scripts/install.sh` to the router, as in step 1.
2. Stop the VPN with the old version: `l2tp-vpn stop`. A tunnel that an older version started keeps running through an update, but it has no reconnect loop and no DNS handling until it is started again.
3. Keep copies, so that you can go back. The installer only keeps the first backup of the panel files that it ever made:

       cp /usr/bin/l2tp-vpn /root/l2tp-vpn.old
       cp /usr/lib/oui-httpd/rpc/l2tp /root/l2tp-module.prev
       cp /www/views/gl-sdk4-ui-l2tp.common.js.gz /root/l2tp-view.prev.js.gz

4. Run `sh install.sh` and answer:
   - **Install these packages now?** `y`. They are already installed, so nothing changes; `n` cancels the whole installer before the control script is replaced. This step needs internet for `opkg update`.
   - **Install the web panel page?** `y`, and then **Restart nginx now?** `y`. The web server caches the backend module, so without the restart the old backend keeps answering.
5. Hard-refresh the panel in the browser (Cmd/Ctrl+Shift+R).
6. Start the VPN with `l2tp-vpn start` and check `l2tp-vpn status`: it should end with a `DNS:` line and `Reconnect loop: running`. If it says the loop is NOT running while Connect is on, the VPN was started before the update: `l2tp-vpn stop`, then `l2tp-vpn start`.

Your config file keeps its four lines. The reconnect settings use their defaults (5 minutes, never give up) until you press Save on the panel page, which adds them, or add `RETRY_MINUTES='5'` and `GIVE_UP_HOURS='0'` yourself.

Without internet, or to update only the control script: `scp -O scripts/l2tp-vpn root@192.168.8.1:/usr/bin/l2tp-vpn`, then `chmod +x /usr/bin/l2tp-vpn` on the router (add `-o HostKeyAlgorithms=+ssh-rsa` if your SSH client refuses). `sh install.sh --web-only` updates only the panel files.

To go back, copy the three files from step 3 to their places, run `/etc/init.d/nginx restart` (the module is cached), and refresh the browser.

## Undo and removal

- Stop the VPN: `l2tp-vpn stop` (this also ends the reconnect loop; do it before removing anything)
- Remove the files: `rm -f /usr/bin/l2tp-vpn /etc/l2tp-vpn.conf`
- Remove the packages (optional):

      opkg remove strongswan-isakmp strongswan-mod-stroke strongswan-mod-kernel-netlink xl2tpd kmod-ipsec kmod-ipsec4

- Remove the panel page (remove the menu entry first if you want the item gone at once; restart nginx afterwards so it forgets the module):

      rm -f /usr/share/oui/menu.d/l2tp.json /www/views/gl-sdk4-ui-l2tp.common.js.gz /www/i18n/gl-sdk4-ui-l2tp.en.json
      rm -f /usr/lib/oui-httpd/rpc/l2tp /usr/share/gl-validator.d/l2tp.lua /tmp/l2tp-web.busy
      /etc/init.d/nginx restart

- A reboot also clears any running tunnel, its routes and the reconnect loop, because nothing autostarts.

## After a firmware upgrade

An upgrade will probably remove the panel files, and may remove the installed packages. A normal upgrade that keeps settings should keep `/usr/bin/l2tp-vpn` and `/etc/l2tp-vpn.conf`.
After an upgrade check `ls /usr/sbin/ipsec /usr/sbin/xl2tpd`. If they are missing, run `sh install.sh` again: it reinstalls the packages and the panel page (`--web-only` does only the page).
