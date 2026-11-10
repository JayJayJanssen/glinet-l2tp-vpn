#!/bin/sh
# install.sh - installs the L2TP/IPsec VPN client on a GL.iNet GL-SFT1200 (Opal)
# Run on the router as root:  sh install.sh
# Only (re)install the web panel part:  sh install.sh --web-only
# Safe to re-run. Asks before installing packages, and never overwrites an
# existing /etc/l2tp-vpn.conf.

set -u
PKGS="strongswan-isakmp strongswan-mod-stroke strongswan-mod-kernel-netlink xl2tpd kmod-ipsec kmod-ipsec4"

say()  { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# waits until the panel's web server answers on /rpc (after an nginx restart it needs a few seconds); about 20 s at most
wait_for_panel() {
  i=0
  while [ "$i" -lt 20 ]; do
    out=$(curl -s -m 2 http://127.0.0.1/rpc -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["bogus1234","l2tp","get_status",{}]}' 2>/dev/null)
    [ -n "$out" ] && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}
ask()  { # $1 = prompt; returns 0 for yes
  printf '%s [y/N] ' "$1"; read ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

WEB_ONLY=0
[ "${1:-}" = "--web-only" ] && WEB_ONLY=1

[ "$(id -u)" = "0" ] || fail "run as root"
[ -f /etc/openwrt_release ] || fail "this does not look like an OpenWrt router"

if [ "$WEB_ONLY" = 0 ]; then

say "Checking the router"
ARCH=$(opkg print-architecture | awk '$2 != "all" && $2 != "noarch" {print $2}' | tail -n1)
KERN=$(uname -r)
echo "    architecture: $ARCH, kernel: $KERN"
if [ "$ARCH" != "mips_siflower" ] || [ "$KERN" != "4.14.90" ]; then
  echo "    This was tested on a GL-SFT1200 (mips_siflower, kernel 4.14.90)."
  ask "    Your router differs. Continue anyway?" || exit 1
fi
FREE_KB=$(df -k /overlay | awk 'NR==2 {print $4}')
[ "${FREE_KB:-0}" -gt 10240 ] || fail "less than 10 MB free on /overlay"

say "Refreshing package lists (needs internet)"
opkg update || fail "opkg update failed - is the router online?"

say "Dry run of the install (changes nothing):"
opkg install --noaction $PKGS || fail "dry run failed"

ask "Install these packages now?" || { echo "Cancelled. Nothing was installed."; exit 0; }

say "Installing packages"
opkg install $PKGS || fail "package install failed"

say "Disabling autostart of the stock ipsec and xl2tpd services"
for s in ipsec xl2tpd; do
  /etc/init.d/$s stop >/dev/null 2>&1
  /etc/init.d/$s disable >/dev/null 2>&1
done

say "Loading kernel modules"
kmodloader >/dev/null 2>&1
MISSING=""
for m in esp4 xfrm_user af_key authenc l2tp_ppp xfrm4_mode_transport; do
  lsmod | grep -q "^$m " || MISSING="$MISSING $m"
done
[ -z "$MISSING" ] || fail "kernel modules not loaded:$MISSING (see INSTALL.md, libipsec fallback)"
[ -x /usr/sbin/ipsec ] && [ -x /usr/sbin/xl2tpd ] || fail "ipsec or xl2tpd binary missing"
echo "    modules and binaries OK"

say "Writing /usr/bin/l2tp-vpn"
cat > /usr/bin/l2tp-vpn <<'EOF_L2TP_VPN_SCRIPT'
#!/bin/sh
CONF=${L2TP_VPN_CONF:-/etc/l2tp-vpn.conf}
STATE=${L2TP_VPN_STATE:-/tmp/l2tp-vpn.state}
CTL=/var/run/xl2tpd/l2tp-control
DNS_BAK=${DNS_BAK:-/tmp/l2tp-vpn.resolv.bak}            # the uplink's DNS file as it was before the tunnel
DNS_MARK="# managed by l2tp-vpn"
PPP_RESOLV=${PPP_RESOLV:-"/etc/ppp/resolv.conf /tmp/resolv.conf.ppp"}    # where pppd (usepeerdns) writes the server's DNS
T0=${T0:-/tmp/l2tp-vpn.t0}                              # touched just before dialing: only DNS files newer than this count
DNSMASQ_INIT=${DNSMASQ_INIT:-/etc/init.d/dnsmasq}
KEEPER_PID=${KEEPER_PID:-/tmp/l2tp-vpn.keeper.pid}      # the reconnect loop, while Connect is on
ATTEMPT_PID=${ATTEMPT_PID:-/tmp/l2tp-vpn.attempt.pid}   # a reconnect attempt that is running right now
ATTEMPT_OUT=${ATTEMPT_OUT:-/tmp/l2tp-vpn.attempt.out}
MSG=${L2TP_VPN_MSG:-/tmp/l2tp-vpn.msg}                  # why the loop switched Connect off (the panel shows it)
PROC_ROUTE=${PROC_ROUTE:-/proc/net/route}
SELF=${L2TP_VPN_SELF:-$0}
[ -f "$CONF" ] && . "$CONF"
UPLOAD_MBIT=10     # cap on what goes into the tunnel, in Mbit/s (0 = no cap): the router cannot encrypt much more, and when it is overloaded the
                   # tunnel's own control messages get lost. Change it in /etc/l2tp-vpn.extra (a line UPLOAD_MBIT=15), which the panel never rewrites.
[ -f "${L2TP_VPN_EXTRA:-/etc/l2tp-vpn.extra}" ] && . "${L2TP_VPN_EXTRA:-/etc/l2tp-vpn.extra}"

fw_rules() {  # $1 = -I or -D
  iptables -t nat $1 POSTROUTING -o ppp0 -j MASQUERADE
  iptables $1 FORWARD -o ppp0 -j ACCEPT
  iptables $1 FORWARD -i ppp0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

# --- DNS: while the tunnel is up the router's DNS forwarder (dnsmasq) follows the DNS servers the L2TP server handed out ---
is_ipv4() { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

peer_dns() {  # prints the DNS servers pppd got from the server (written since this start), one per line
  for f in $PPP_RESOLV; do
    [ -f "$f" ] && ! [ "$T0" -nt "$f" ] || continue      # written since this start (not older than the marker)
    out=$(sed -n 's/^nameserver[[:space:]]\{1,\}\([0-9.]\{7,15\}\).*/\1/p' "$f" | while read -r a; do is_ipv4 "$a" && echo "$a"; done | head -n 3)
    [ -n "$out" ] && { echo "$out"; return 0; }
  done
  return 1
}

dns_file() {  # the file dnsmasq reads its upstream servers from
  f=$(uci -q get "dhcp.@dnsmasq[0].resolvfile" 2>/dev/null)
  echo "${f:-/tmp/resolv.conf.auto}"
}

dns_blocked() {  # succeeds, and says why, when the file should not or cannot be changed
  case "$(dns_file)" in
    /tmp/*|/var/*|/run/*) ;;                           # in RAM: a power cut or restart brings the uplink's DNS back by itself
    *) echo "dnsmasq reads a file that survives a restart ($(dns_file)), so a power cut could leave the tunnel's DNS in it"; return 0 ;;
  esac
  [ "$(uci -q get "dhcp.@dnsmasq[0].noresolv" 2>/dev/null)" = 1 ] && { echo "dnsmasq ignores its resolv file (noresolv)"; return 0; }
  [ -n "$(uci -q get "dhcp.@dnsmasq[0].server" 2>/dev/null)" ] && { echo "dnsmasq has fixed DNS servers (the panel's DNS settings)"; return 0; }
  pidof AdGuardHome >/dev/null 2>&1 && { echo "AdGuard Home is running"; return 0; }
  return 1
}

dns_apply() {
  if why=$(dns_blocked); then echo "DNS left unchanged: $why."; return 0; fi
  dns=$(peer_dns) || { echo "DNS left unchanged: the server gave no DNS address."; return 0; }
  rf=$(dns_file)
  if [ ! -f "$DNS_BAK" ]; then                         # keep the first original, even if this runs again
    if [ -f "$rf" ] && ! grep -q "$DNS_MARK" "$rf"; then cp "$rf" "$DNS_BAK"; else : > "$DNS_BAK"; fi
  fi
  { echo "$DNS_MARK"; for a in $dns; do echo "nameserver $a"; done; } > "$rf"
  for a in $dns; do ip route replace "$a/32" dev ppp0 2>/dev/null; done      # reach them through the tunnel, whatever the uplink's subnet is
  "$DNSMASQ_INIT" restart >/dev/null 2>&1
  echo "DNS follows the server: $(echo $dns)."
}

dns_restore() {
  [ -f "$DNS_BAK" ] || return 0
  rf=$(dns_file)
  if grep -q "$DNS_MARK" "$rf" 2>/dev/null; then       # still our file: put the uplink's back
    cp "$DNS_BAK" "$rf"
    "$DNSMASQ_INIT" restart >/dev/null 2>&1
  fi                                                   # otherwise the network service rewrote it already: leave it
  rm -f "$DNS_BAK"
}

dns_status() {
  if [ -f "$DNS_BAK" ]; then echo "DNS: follows the VPN server ($(grep '^nameserver' "$(dns_file)" 2>/dev/null | cut -d' ' -f2 | tr '\n' ' '))"
  else echo "DNS: not changed"; fi
}

dns_report() {
  rf=$(dns_file)
  echo "dnsmasq reads its upstream servers from: $rf"
  if why=$(dns_blocked); then echo "The tunnel's DNS cannot be applied: $why."; fi
  for f in $PPP_RESOLV; do [ -f "$f" ] && { echo "--- $f (written by pppd):"; cat "$f"; }; done
  echo "--- $rf now:"; cat "$rf" 2>/dev/null
  if [ -f "$DNS_BAK" ]; then echo "The server's DNS is applied (the original is kept in $DNS_BAK)."; else echo "The server's DNS is not applied."; fi
}

teardown() {   # everything the tunnel set up; the state file ("Connect is on") is kept
  [ -f "$STATE" ] && read IP GW DEV < "$STATE"
  dns_restore
  fw_rules -D 2>/dev/null
  ip route del 0.0.0.0/1 dev ppp0 2>/dev/null
  ip route del 128.0.0.0/1 dev ppp0 2>/dev/null
  [ -n "$IP" ] && ip route del "$IP/32" 2>/dev/null
  if pidof xl2tpd >/dev/null; then
    [ -p "$CTL" ] && echo "d vpn" > "$CTL"
    sleep 1
    killall xl2tpd 2>/dev/null
  fi
  ipsec stop >/dev/null 2>&1
  rm -f "$T0"
}

do_stop() {   # the user's stop: end the reconnect loop and any attempt, tear everything down, forget that Connect was on
  stop_keeper
  teardown
  rm -f "$STATE" "$MSG"
}

shape_upload() {   # limits what is sent into the tunnel (the router's own control messages are not affected); it disappears with ppp0
  case "$UPLOAD_MBIT" in ''|*[!0-9]*) return 0 ;; esac
  [ "$UPLOAD_MBIT" -gt 0 ] || return 0
  command -v tc >/dev/null 2>&1 || { echo "Upload cap not applied: the tc command is not installed (opkg install tc kmod-sched-core)."; return 0; }
  burst=$((UPLOAD_MBIT * 3 + 10))      # kB; must be at least the rate divided by the kernel's timer rate, or the cap comes out lower than asked
  tc qdisc del dev ppp0 root >/dev/null 2>&1
  if tc qdisc add dev ppp0 root tbf rate "${UPLOAD_MBIT}mbit" burst "${burst}kb" latency 100ms >/dev/null 2>&1; then
    echo "Upload into the tunnel limited to $UPLOAD_MBIT Mbit/s."
  else
    echo "Upload cap not applied: tc could not set it (is kmod-sched-core installed?)."
  fi
}

connect() {   # one full connection; returns 0 when the tunnel is up, otherwise tears it down again and returns 1 (the state is kept)
  [ -n "$HOST" ] && [ -n "$VPN_USER" ] && [ -n "$VPN_PASS" ] && [ -n "$VPN_PSK" ] \
    || { echo "Fill in $CONF first"; return 1; }

  IP=$(nslookup "$HOST" 2>/dev/null | sed -n '/^Name:/,$p' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
  [ -n "$IP" ] || { echo "Cannot resolve $HOST"; return 1; }
  GW=$(ip route show default | awk '{print $3; exit}')
  DEV=$(ip route show default | awk '{print $5; exit}')
  [ -n "$GW" ] && [ -n "$DEV" ] || { echo "No default route (is the router online?)"; return 1; }
  echo "$IP $GW $DEV" > "$STATE"
  echo "Server $HOST = $IP, via $GW on $DEV"

  mkdir -p /var/run/xl2tpd /etc/xl2tpd
  umask 077

  ESP_FAST="aes128-sha1"                        # the data encryption costs CPU on every packet; AES-128 needs 10 rounds where AES-256 needs 14
  ESP_WIDE="aes256-sha1,aes128-sha1,3des-sha1"  # what was offered before; used once if the server does not accept the line above
  cat > /etc/ipsec.conf <<EOF
config setup
    uniqueids=no
    charondebug="ike 1, knl 1, cfg 0, net 1, esp 1, dmn 1, mgr 1"

conn l2tpvpn
    keyexchange=ikev1
    authby=secret
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=$IP
    rightprotoport=17/1701
    ike=aes256-sha1-modp2048,aes128-sha1-modp2048,aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024
    esp=$ESP_FAST
    ikelifetime=8h
    keylife=1h
    forceencaps=yes
    dpdaction=clear
    dpddelay=30s
    auto=add
EOF
  echo ": PSK \"$VPN_PSK\"" > /etc/ipsec.secrets

  cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lac vpn]
lns = $IP
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
autodial = no
redial = no
ppp debug = yes
EOF

  cat > /etc/ppp/options.xl2tpd <<EOF
name "$VPN_USER"
password "$VPN_PASS"
noauth
refuse-pap
refuse-eap
noccp
noipdefault
nodefaultroute
usepeerdns
ipcp-accept-local
ipcp-accept-remote
mtu 1400
mru 1400
connect-delay 5000
lcp-echo-interval 30
lcp-echo-failure 4
EOF

  umask 022       # the files above hold the password and the key; everything started from here on (strongSwan, xl2tpd, pppd and the hooks
                  # it runs, dnsmasq) must create world-readable files, or dnsmasq (an unprivileged user) cannot read its DNS files
  ipsec start >/dev/null 2>&1
  sleep 3
  ipsec up l2tpvpn >/dev/null 2>&1
  sleep 2
  if ! ipsec statusall 2>/dev/null | grep -q INSTALLED; then      # the server may not accept AES-128 alone: offer the old list, once
    echo "No agreement on AES-128 alone; trying the wider list."
    sed -i "s/^    esp=.*/    esp=$ESP_WIDE/" /etc/ipsec.conf
    ipsec update >/dev/null 2>&1
    sleep 2
    ipsec up l2tpvpn >/dev/null 2>&1
    sleep 2
  fi
  ipsec statusall 2>/dev/null | grep -q INSTALLED || {
    echo "IPsec failed. Check: logread | grep -i charon | tail -40"
    teardown; return 1; }
  echo "IPsec up."

  touch "$T0"
  xl2tpd -c /etc/xl2tpd/xl2tpd.conf -C "$CTL"
  sleep 1
  echo "c vpn" > "$CTL"
  i=0
  while [ $i -lt 30 ]; do
    ip addr show ppp0 2>/dev/null | grep -q inet && break
    i=$((i+1)); sleep 1
  done
  ip addr show ppp0 2>/dev/null | grep -q inet || {
    echo "PPP failed. Check: logread | grep -Ei 'xl2tpd|pppd' | tail -40"
    teardown; return 1; }

  ip route replace "$IP/32" via "$GW" dev "$DEV"
  ip route add 0.0.0.0/1 dev ppp0
  ip route add 128.0.0.0/1 dev ppp0
  fw_rules -I
  shape_upload
  dns_apply
  echo "VPN up. All traffic now goes through the tunnel."
}

do_start() {
  [ -f "$STATE" ] && { echo "Already started. Run: l2tp-vpn stop"; exit 1; }
  rm -f "$MSG"
  connect || { do_stop; exit 1; }
  launch_keeper
}

# --- the reconnect loop: while Connect is on and the tunnel has dropped, tear it down cleanly and try again ---
# It is one small background shell started by "start" and ended by "stop". It costs next to nothing while the tunnel is
# healthy: every 30 seconds it reads the routing table with shell builtins (no program is started).
# Settings in /etc/l2tp-vpn.conf (read again when a drop is noticed):
#   RETRY_MINUTES   0 to 60, default 5: the wait between attempts once the first two (1 and 2 minutes) failed;
#                   0 = no automatic reconnect: a dropped tunnel switches Connect off
#   GIVE_UP_HOURS   0 to 168, default 0 = never: stop trying (and switch Connect off) this long after the drop

klog() { logger -t l2tp-keeper "$*" 2>/dev/null; }

tunnel_up() {   # the tunnel's routes on ppp0 exist (they go away with the interface)
  while read -r ifc _; do
    [ "$ifc" = ppp0 ] && return 0
  done < "$PROC_ROUTE"
  return 1
}

uplink_up() {   # a default route exists and its gateway answers
  r=$(ip route show default 2>/dev/null | head -n 1)
  [ -n "$r" ] || return 1
  gw=$(echo "$r" | sed -n 's/.* via \([0-9.]*\).*/\1/p')
  [ -z "$gw" ] || ping -c 1 -W 2 "$gw" >/dev/null 2>&1
}

read_settings() {
  RETRY_MINUTES=5; GIVE_UP_HOURS=0
  [ -f "$CONF" ] && . "$CONF"
  case "$RETRY_MINUTES" in ''|*[!0-9]*) RETRY_MINUTES=5 ;; esac
  case "$GIVE_UP_HOURS" in ''|*[!0-9]*) GIVE_UP_HOURS=0 ;; esac
  [ "$RETRY_MINUTES" -gt 60 ] && RETRY_MINUTES=60
  [ "$GIVE_UP_HOURS" -gt 168 ] && GIVE_UP_HOURS=168
}

give_up() {   # $1 = why; Connect is switched off, and the panel shows the reason
  klog "stopping: $1"
  echo "$1" > "$MSG"
  teardown
  rm -f "$STATE"
}

time_left() {   # seconds until GIVE_UP_HOURS after the drop have passed; a huge number when there is no limit
  if [ "$GIVE_UP_HOURS" -gt 0 ]; then echo $((t_drop + GIVE_UP_HOURS * 3600 - $(date +%s))); else echo 999999999; fi
}

give_up_text() {
  unit=hours; [ "$GIVE_UP_HOURS" -eq 1 ] && unit=hour
  echo "Gave up reconnecting after $GIVE_UP_HOURS $unit; Connect was switched off."
}

run_attempt() {   # one attempt as a separate process, so that "stop" can end it
  if [ -n "$ATTEMPT_CMD" ]; then $ATTEMPT_CMD > "$ATTEMPT_OUT" 2>&1 &
  else sh "$SELF" _attempt > "$ATTEMPT_OUT" 2>&1 &
  fi
  echo $! > "$ATTEMPT_PID"
  wait $!
  rc=$?
  rm -f "$ATTEMPT_PID"
  return $rc
}

attempt() {   # what an attempt does: a clean slate, then a full connection; the state stays either way
  teardown
  connect
}

reconnect_cycle() {   # returns 0 when the tunnel is back, 1 when it gave up or Connect was switched off
  [ "$RETRY_MINUTES" -gt 0 ] || { give_up "The tunnel dropped and automatic reconnect is off, so Connect was switched off."; return 1; }
  fails=0
  while [ -f "$STATE" ]; do
    until uplink_up; do                                  # no attempts while there is no uplink
      [ "$(time_left)" -le 0 ] && { give_up "$(give_up_text)"; return 1; }
      sleep 30
      [ -f "$STATE" ] || return 1
    done
    klog "reconnect attempt $((fails + 1))"
    if run_attempt; then klog "reconnected"; return 0; fi
    [ -f "$STATE" ] || return 1
    fails=$((fails + 1))
    klog "attempt $fails failed: $(tail -n 1 "$ATTEMPT_OUT" 2>/dev/null)"
    case $fails in 1) w=60 ;; 2) w=120 ;; *) w=$((RETRY_MINUTES * 60)) ;; esac      # 1, 2, then every RETRY_MINUTES
    [ "$w" -gt $((RETRY_MINUTES * 60)) ] && w=$((RETRY_MINUTES * 60))
    left=$(time_left)
    [ "$left" -le 0 ] && { give_up "$(give_up_text)"; return 1; }
    [ "$w" -gt "$left" ] && w=$left
    sleep "$w"
    [ -f "$STATE" ] || return 1
    [ "$(time_left)" -le 0 ] && { give_up "$(give_up_text)"; return 1; }
  done
  return 1
}

keeper() {
  trap '' HUP
  echo $$ > "$KEEPER_PID"
  while [ -f "$STATE" ]; do
    if tunnel_up; then sleep 30; continue; fi
    n=0                                                  # the routes are gone: look every 5 seconds, for about 45 seconds
    while [ "$n" -lt 9 ] && [ -f "$STATE" ] && ! tunnel_up; do sleep 5; n=$((n + 1)); done
    [ -f "$STATE" ] || break
    tunnel_up && continue
    read_settings
    t_drop=$(date +%s)
    klog "the tunnel dropped"
    reconnect_cycle || break
  done
  rm -f "$KEEPER_PID"
}

launch_keeper() {
  ( trap '' HUP; exec sh "$SELF" _keeper </dev/null >/dev/null 2>&1 ) &
}

stop_keeper() {   # the loop and an attempt that may be running
  for f in "$KEEPER_PID" "$ATTEMPT_PID"; do
    [ -f "$f" ] || continue
    read -r pid < "$f"
    [ -n "$pid" ] && [ "$pid" != "$$" ] && kill "$pid" 2>/dev/null
    rm -f "$f"
  done
}

keeper_status() {
  if [ -f "$KEEPER_PID" ]; then
    read -r pid < "$KEEPER_PID"
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && { echo "Reconnect loop: running"; return; }
  fi
  [ -f "$STATE" ] && echo "Reconnect loop: NOT running (a dropped tunnel will not be reconnected)"
}

[ -n "$L2TP_VPN_LIB" ] && return 0       # sourced by the tests: define the functions only

case "$1" in
  start) do_start ;;
  stop) do_stop; echo "Stopped." ;;
  status)
    ipsec statusall 2>/dev/null | grep -E 'ESTABLISHED|INSTALLED'
    ip addr show ppp0 2>/dev/null | grep inet
    ip route | grep ppp0
    dns_status
    keeper_status ;;
  dns) dns_report ;;
  _attempt) attempt ;;     # used by the reconnect loop
  _keeper) keeper ;;       # the reconnect loop itself
  *) echo "Usage: l2tp-vpn start|stop|status|dns" ;;
esac
EOF_L2TP_VPN_SCRIPT
chmod +x /usr/bin/l2tp-vpn
sh -n /usr/bin/l2tp-vpn || fail "l2tp-vpn failed the syntax check"

say "Credentials"
if [ -f /etc/l2tp-vpn.conf ]; then
  echo "    /etc/l2tp-vpn.conf already exists - keeping it."
else
  echo "    Values are stored in plain text in /etc/l2tp-vpn.conf (root-only)."
  echo "    Do not use a single quote ' in any value, or a double quote \" in the PSK."
  printf '    Server hostname: '; read HOST
  printf '    Username: '; read VPN_USER
  stty -echo 2>/dev/null
  printf '    Password: '; read VPN_PASS; echo
  printf '    Pre-shared key: '; read VPN_PSK; echo
  stty echo 2>/dev/null
  for v in "$HOST" "$VPN_USER" "$VPN_PASS" "$VPN_PSK"; do
    [ -n "$v" ] || fail "empty value - nothing written. Re-run the installer."
    case "$v" in *"'"*) fail "single quote not allowed - nothing written." ;; esac
  done
  case "$VPN_PSK" in *'"'*) fail "double quote not allowed in the PSK - nothing written." ;; esac
  umask 077
  {
    echo "HOST='$HOST'"
    echo "VPN_USER='$VPN_USER'"
    echo "VPN_PASS='$VPN_PASS'"
    echo "VPN_PSK='$VPN_PSK'"
    echo "RETRY_MINUTES='5'"
    echo "GIVE_UP_HOURS='0'"
  } > /etc/l2tp-vpn.conf
  chmod 600 /etc/l2tp-vpn.conf
  echo "    saved /etc/l2tp-vpn.conf"
fi

fi

say "Web panel page (optional)"
if [ -d /usr/share/oui/menu.d ] && [ -d /www/views ] && [ -d /usr/lib/oui-httpd/rpc ] \
   && command -v lua >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
  echo "    Adds VPN > L2TP VPN to the GL.iNet panel: status, server, tunnel address and an"
  echo "    on/off switch. New files only (a backend module, a page, a label, a menu entry)."
  echo "    Firmware upgrades will probably remove them; run this installer again after one."
  if ask "    Install the web panel page?"; then
    WEB_OK=1
    MOD=/usr/lib/oui-httpd/rpc/l2tp
    cat > /tmp/l2tp.new <<'EOF_WEB_MODULE'
-- /usr/lib/oui-httpd/rpc/l2tp
-- GL.iNet panel backend for the L2TP VPN: get_status, start, stop, get_config, set_config.
-- Besides the four connection values, set_config and get_config carry two reconnect settings:
-- retry_minutes (0 to 60, default 5, 0 = do not reconnect) and giveup_hours (0 to 168, default 0 = never).
-- Called through /rpc, so the panel's login and ACL apply (default deny).
-- By design the password and PSK are plain text: get_config returns them.

local STATE = "/tmp/l2tp-vpn.state"
local BUSY  = "/tmp/l2tp-web.busy"
local CONF  = "/etc/l2tp-vpn.conf"
local MSG   = "/tmp/l2tp-vpn.msg"   -- why the reconnect loop switched Connect off

local function exists(p)
    local f = io.open(p, "r")
    if f then f:close() return true end
    return false
end

local function run(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

local function is_busy()
    local f = io.open(BUSY, "r")
    if not f then return false end
    local t = tonumber(f:read("*l"))
    f:close()
    -- a marker older than 2 minutes is stale
    return t ~= nil and (os.time() - t) < 120
end

local function set_busy()
    local f = io.open(BUSY, "w")
    if f then f:write(tostring(os.time()), "\n") f:close() end
end

-- Run /usr/bin/l2tp-vpn <action> fully detached from the web server:
-- close inherited descriptors (nginx sockets), no stdin/stdout.
local function detach(action)
    set_busy()
    os.execute("( i=3; while [ $i -le 63 ]; do eval \"exec $i>&-\"; i=$((i+1)); done; " ..
        "/usr/bin/l2tp-vpn " .. action .. " >/tmp/l2tp-vpn.out 2>&1; " ..
        "logger -t l2tp-web < /tmp/l2tp-vpn.out; rm -f " .. BUSY .. " ) " ..
        "</dev/null >/dev/null 2>&1 &")
end

local function read_msg()
    local f = io.open(MSG, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if line and #line > 0 then return line:sub(1, 200) end
    return nil
end

local function status()
    local res = { status = "off", busy = is_busy() }
    local ppp = run("ip addr show ppp0")
    local addr, peer = ppp:match("inet (%S+) peer (%S+)")
    if not addr then addr = ppp:match("inet (%S+)") end

    if exists(STATE) then
        local f = io.open(STATE, "r")
        local line = f and f:read("*l") or ""
        if f then f:close() end
        res.server = line:match("^(%S+)")
    end

    if addr and exists(STATE) then
        res.status = "connected"
        res.address = addr
        res.peer = peer
    elseif exists(STATE) or res.busy then
        res.status = "connecting"
    else
        res.message = read_msg()
    end
    return res
end

local function get_status(args)
    return status()
end

local function start(args)
    local s = status()
    if s.busy then return { accepted = false, reason = "busy" } end
    if s.status ~= "off" then return { accepted = false, reason = "already_running" } end
    detach("start")
    return { accepted = true }
end

local function stop(args)
    local s = status()
    if s.busy then return { accepted = false, reason = "busy" } end
    if s.status == "off" then return { accepted = false, reason = "not_running" } end
    detach("stop")
    return { accepted = true }
end

-- ---- credentials ------------------------------------------------------
-- /etc/l2tp-vpn.conf is read by /usr/bin/l2tp-vpn as shell (KEY='value'), and its values
-- end up inside double-quoted strings of ppp and ipsec config files. So quotes, backslashes
-- and control characters are refused everywhere.

local function valid_text(v, max)
    return type(v) == "string" and #v >= 1 and #v <= max and not v:find("[%c\"'\\]")
end

local function valid_host(v)
    -- hostname or IPv4 address; must not start with "-" or "." (it is passed to nslookup)
    return type(v) == "string" and #v >= 1 and #v <= 253 and v:match("^[%w][%w%.%-]*$") ~= nil
end

-- a whole number lo..hi, given as a number or as a string of digits; nil otherwise
local function to_int(v, lo, hi)
    if type(v) == "string" then
        if not v:match("^%d+$") then return nil end
        v = tonumber(v)
    end
    if type(v) ~= "number" or v ~= math.floor(v) or v < lo or v > hi then return nil end
    return math.floor(v)
end

local function read_conf()
    local c = {}
    local f = io.open(CONF, "r")
    if not f then return c end
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)='(.*)'$")
        if k then c[k] = v end
    end
    f:close()
    return c
end

-- create the temp file root-only first, then rename it into place (atomic, never world-readable)
local function write_conf(c)
    local tmp = CONF .. ".tmp"
    os.execute("umask 077; : > " .. tmp)
    local f = io.open(tmp, "w")
    if not f then return false end
    local ok = f:write("HOST='", c.host, "'\n",
                       "VPN_USER='", c.user, "'\n",
                       "VPN_PASS='", c.pass, "'\n",
                       "VPN_PSK='", c.psk, "'\n",
                       "RETRY_MINUTES='", string.format("%d", c.retry), "'\n",
                       "GIVE_UP_HOURS='", string.format("%d", c.giveup), "'\n")
    local closed = f:close()
    if not ok or not closed then os.remove(tmp) return false end
    os.execute("chmod 600 " .. tmp)
    if not os.rename(tmp, CONF) then os.remove(tmp) return false end
    return true
end

local function get_config(args)
    local c = read_conf()
    return {
        host = c.HOST or "",
        user = c.VPN_USER or "",
        password = c.VPN_PASS or "",
        psk = c.VPN_PSK or "",
        retry_minutes = to_int(c.RETRY_MINUTES, 0, 60) or 5,
        giveup_hours = to_int(c.GIVE_UP_HOURS, 0, 168) or 0
    }
end

-- the four connection values are required; the two reconnect settings are optional (what is saved, or the default,
-- stays when they are left out); the whole file is rewritten
local function set_config(args)
    args = args or {}
    if is_busy() then return { saved = false, error = "busy" } end

    local host, user, pass, psk = args.host, args.user, args.password, args.psk

    if not valid_host(host) then return { saved = false, error = "invalid_host" } end
    if not valid_text(user, 128) then return { saved = false, error = "invalid_user" } end
    if pass == nil or pass == "" then return { saved = false, error = "password_required" } end
    if not valid_text(pass, 128) then return { saved = false, error = "invalid_password" } end
    if psk == nil or psk == "" then return { saved = false, error = "psk_required" } end
    if not valid_text(psk, 256) then return { saved = false, error = "invalid_psk" } end

    local cur = read_conf()
    local retry, giveup = args.retry_minutes, args.giveup_hours
    if retry == nil then retry = to_int(cur.RETRY_MINUTES, 0, 60) or 5
    else
        retry = to_int(retry, 0, 60)
        if not retry then return { saved = false, error = "invalid_retry" } end
    end
    if giveup == nil then giveup = to_int(cur.GIVE_UP_HOURS, 0, 168) or 0
    else
        giveup = to_int(giveup, 0, 168)
        if not giveup then return { saved = false, error = "invalid_giveup" } end
    end

    if not write_conf({ host = host, user = user, pass = pass, psk = psk, retry = retry, giveup = giveup }) then
        return { saved = false, error = "write_failed" }
    end
    return { saved = true }
end

return {
    get_status = get_status,
    start = start,
    stop = stop,
    get_config = get_config,
    set_config = set_config
}
EOF_WEB_MODULE
    lua -e 'assert(loadfile("/tmp/l2tp.new"))' >/dev/null 2>&1 || {
      echo "    ERROR: the backend module failed its syntax check - web panel skipped."; WEB_OK=0; }

    if [ "$WEB_OK" = 1 ]; then
      MOD_EXISTED=0
      [ -f "$MOD" ] && { MOD_EXISTED=1; [ -f /root/l2tp-module.bak ] || cp "$MOD" /root/l2tp-module.bak; }
      cp /tmp/l2tp.new "$MOD"; chmod 644 "$MOD"
      mkdir -p /usr/share/gl-validator.d
      cat > /usr/share/gl-validator.d/l2tp.lua <<'EOF_WEB_VALIDATOR'
-- /usr/share/gl-validator.d/l2tp.lua
-- The panel's generic argument check only allows letters, digits and a few symbols in
-- strings, which would reject most passwords. set_config validates its own arguments
-- strictly (see the module), so the generic check is skipped for it only.
return {
    set_config = true
}
EOF_WEB_VALIDATOR
      if [ "$MOD_EXISTED" = 1 ]; then
        echo "    The module was already installed. The web server caches modules, so nginx must"
        echo "    restart to load this one (the panel drops for a few seconds; the VPN is unaffected)."
        ask "    Restart nginx now?" && /etc/init.d/nginx restart >/dev/null 2>&1
      fi
      # safety check: calls without a login must be refused (set_config with a bogus
      # session and no username cannot write anything even if it were allowed)
      echo "    Waiting for the panel's web server to answer..."
      wait_for_panel
      R1=$(curl -s http://127.0.0.1/rpc -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["bogus1234","l2tp","get_status",{}]}' 2>/dev/null)
      R2=$(curl -s http://127.0.0.1/rpc -d '{"jsonrpc":"2.0","id":1,"method":"call","params":["bogus1234","l2tp","set_config",{"host":"x"}]}' 2>/dev/null)
      case "$R1" in *-32000*) C1=1 ;; *) C1=0 ;; esac
      case "$R2" in *-32000*) C2=1 ;; *) C2=0 ;; esac
      if [ "$C1$C2" = "11" ]; then
        echo "    access check OK: calls without a login are refused."
      else
        rm -f "$MOD" /usr/share/gl-validator.d/l2tp.lua; WEB_OK=0
        echo "    ERROR: could not confirm that the module refuses calls without a login."
        echo "    The module was removed again. Replies were: $R1 $R2"
        [ -z "$R1$R2" ] && echo "    The web server gave no answer at all (it may still be restarting). Wait a minute, then run: sh install.sh --web-only"
      fi
    fi

    if [ "$WEB_OK" = 1 ]; then
      cat > /tmp/l2tp-view.js <<'EOF_WEB_VIEW'
/* GL.iNet panel view "l2tp" - step 4: live status, on/off switch and connection settings.
   Talks to the backend module /usr/lib/oui-httpd/rpc/l2tp through POST /rpc.
   The session id is the panel's own Admin-Token cookie, so the panel login and ACL apply.
   The settings (including password and key) are plain text, by design.
   Contract: module.exports is a Vue 2 component options object.
   Rule for h(tag, X): an array or string X is content, any other object (even a VNode) is
   treated as element data. Child VNodes must therefore be wrapped in an array. */
module.exports = {
  name: "l2tp",
  data: function () {
    return {
      st: { status: "off", busy: false },
      on: false,
      pending: "",
      error: "",
      timer: null,
      startedAt: 0,
      restartAfter: false,
      saved: { host: "", user: "", password: "", psk: "", retry: "5", giveup: "0" },
      configLoaded: false,
      form: { host: "", user: "", password: "", psk: "", retry: "5", giveup: "0" },
      saving: false,
      formError: ""
    };
  },
  computed: {
    state: function () {
      if (this.pending === "stop") return "stopping";
      if (this.pending === "start" && this.st.status !== "connected") return "connecting";
      return this.st.status;
    },
    label: function () {
      return {
        off: "Off", connecting: "Connecting\u2026",
        stopping: "Disconnecting\u2026", connected: "Connected"
      }[this.state] || "Unknown";
    },
    color: function () {
      return {
        off: "#909399", connecting: "#e6a23c",
        stopping: "#e6a23c", connected: "#67c23a"
      }[this.state] || "#909399";
    },
    server: function () {
      return this.st.server || "\u2014";
    },
    address: function () {
      if (!this.st.address) return "\u2014";
      var peer = this.st.peer ? String(this.st.peer).replace(/\/32$/, "") : "";
      return peer ? this.st.address + " \u2192 " + peer : this.st.address;
    },
    dirty: function () {
      var f = this.form, v = this.saved;
      return f.host !== v.host || f.user !== v.user ||
        f.password !== v.password || f.psk !== v.psk ||
        f.retry !== v.retry || f.giveup !== v.giveup;
    },
    problem: function () {
      var f = this.form;
      var bad = /[\u0000-\u001f\u007f"'\\]/;
      if (!/^[A-Za-z0-9][A-Za-z0-9.\-]{0,252}$/.test(f.host)) {
        return "Server: a hostname or IP address (letters, digits, dots and hyphens).";
      }
      if (!f.user || f.user.length > 128 || bad.test(f.user)) {
        return "Username: 1 to 128 characters, no quotes or backslashes.";
      }
      if (!f.password || f.password.length > 128 || bad.test(f.password)) {
        return "Password: 1 to 128 characters, no quotes or backslashes.";
      }
      if (!f.psk || f.psk.length > 256 || bad.test(f.psk)) {
        return "Secret key: 1 to 256 characters, no quotes or backslashes.";
      }
      if (!/^[0-9]{1,2}$/.test(f.retry) || Number(f.retry) > 60) {
        return "Reconnect every: a whole number of minutes from 0 to 60 (0 = do not reconnect).";
      }
      if (!/^[0-9]{1,3}$/.test(f.giveup) || Number(f.giveup) > 168) {
        return "Give up after: a whole number of hours from 0 to 168 (0 = never).";
      }
      return "";
    },
    canSave: function () {
      return this.configLoaded && this.dirty && !this.problem && !this.saving && !this.pending;
    }
  },
  created: function () {
    var self = this;
    this.loadConfig();
    this.refresh().then(function () { self.schedule(4000); });
  },
  beforeDestroy: function () {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  },
  methods: {
    sid: function () {
      var m = document.cookie.match(/(?:^|;\s*)Admin-Token=([^;]*)/);
      return m ? decodeURIComponent(m[1]) : "";
    },
    call: function (method, args) {
      var body = JSON.stringify({
        jsonrpc: "2.0", id: Date.now(), method: "call",
        params: [this.sid(), "l2tp", method, args || {}]
      });
      return fetch("/rpc", {
        method: "POST", credentials: "same-origin",
        headers: { "Content-Type": "application/json" }, body: body
      }).then(function (r) { return r.json(); }).then(function (j) {
        if (j.error) {
          var e = new Error(j.error.message || "error");
          e.code = j.error.code;
          throw e;
        }
        return j.result;
      });
    },
    explain: function (e) {
      if (e && e.code === -32000) return "Access denied. Please sign in again.";
      return "Cannot reach the router backend (" + (e && e.message ? e.message : "error") + ").";
    },
    notice: function (msg, type) {
      if (this.$message) this.$message({ message: msg, type: type || "info" });
    },
    reasonText: function (reason) {
      return {
        busy: "The VPN is busy. Please wait a moment.",
        already_running: "The VPN is already running.",
        not_running: "The VPN is not running."
      }[reason] || "The request was not accepted.";
    },
    configErrorText: function (code) {
      return {
        busy: "The VPN is busy. Please try again in a moment.",
        invalid_host: "The server name is not valid.",
        invalid_user: "The username is not valid.",
        invalid_password: "The password is not valid.",
        invalid_psk: "The secret key is not valid.",
        invalid_retry: "Reconnect every: a whole number of minutes from 0 to 60.",
        invalid_giveup: "Give up after: a whole number of hours from 0 to 168.",
        password_required: "Enter the password.",
        psk_required: "Enter the secret key.",
        write_failed: "The router could not write the settings."
      }[code] || "The settings were not saved.";
    },
    loadConfig: function () {
      var self = this;
      return this.call("get_config").then(function (r) {
        self.saved = {
          host: r.host || "", user: r.user || "",
          password: r.password || "", psk: r.psk || "",
          retry: String(r.retry_minutes === undefined || r.retry_minutes === null ? 5 : r.retry_minutes),
          giveup: String(r.giveup_hours === undefined || r.giveup_hours === null ? 0 : r.giveup_hours)
        };
        self.form.host = self.saved.host;
        self.form.user = self.saved.user;
        self.form.password = self.saved.password;
        self.form.psk = self.saved.psk;
        self.form.retry = self.saved.retry;
        self.form.giveup = self.saved.giveup;
        self.configLoaded = true;
      }).catch(function (e) {
        self.formError = self.explain(e);
      });
    },
    save: function (reconnect) {
      var self = this;
      if (!this.canSave) return;
      this.saving = true;
      this.formError = "";
      this.call("set_config", {
        host: this.form.host, user: this.form.user,
        password: this.form.password, psk: this.form.psk,
        retry_minutes: parseInt(this.form.retry, 10),
        giveup_hours: parseInt(this.form.giveup, 10)
      }).then(function (r) {
        self.saving = false;
        if (!r.saved) {
          self.formError = self.configErrorText(r.error);
          return;
        }
        self.saved = {
          host: self.form.host, user: self.form.user,
          password: self.form.password, psk: self.form.psk,
          retry: self.form.retry, giveup: self.form.giveup
        };
        self.notice("Settings saved.", "success");
        if (reconnect) {
          self.reconnect();
        } else if (self.st.status !== "off") {
          self.notice("The new settings apply the next time the VPN starts.", "info");
        }
      }).catch(function (e) {
        self.saving = false;
        self.formError = self.explain(e);
      });
    },
    reconnect: function () {
      if (this.st.status === "off") {
        this.toggle(true);
      } else {
        this.restartAfter = true;
        this.toggle(false);
      }
    },
    schedule: function (ms) {
      var self = this;
      if (this.timer) clearTimeout(this.timer);
      this.timer = setTimeout(function () {
        self.refresh().then(function () { self.schedule(self.pending ? 1500 : 4000); });
      }, ms);
    },
    refresh: function () {
      var self = this;
      return this.call("get_status").then(function (r) {
        self.error = "";
        self.st = r;
        self.afterStatus();
      }).catch(function (e) {
        self.error = self.explain(e);
      });
    },
    afterStatus: function () {
      var s = this.st;
      var restart = false;
      if (this.pending === "start") {
        if (s.status === "connected") {
          this.pending = "";
          this.notice("VPN connected.", "success");
        } else if (!s.busy && s.status === "off" && Date.now() - this.startedAt > 2000) {
          this.pending = "";
          this.notice("The VPN could not connect. See the router log: logread | grep l2tp", "warning");
        }
      } else if (this.pending === "stop") {
        if (!s.busy && s.status === "off") {
          this.pending = "";
          restart = this.restartAfter;
          this.restartAfter = false;
        }
      }
      if (this.pending && Date.now() - this.startedAt > 120000) {
        this.pending = "";
        this.restartAfter = false;
      }
      this.on = this.pending ? this.pending === "start" : s.status !== "off";
      if (restart) this.toggle(true);
    },
    toggle: function (v) {
      var self = this;
      if (this.pending) { this.on = this.pending === "start"; return; }
      var action = v ? "start" : "stop";
      this.pending = action;
      this.startedAt = Date.now();
      this.on = v;
      this.call(action).then(function (r) {
        if (!r.accepted) {
          self.pending = "";
          self.restartAfter = false;
          self.notice(self.reasonText(r.reason), "warning");
          return self.refresh();
        }
        self.schedule(1500);
      }).catch(function (e) {
        self.pending = "";
        self.restartAfter = false;
        self.error = self.explain(e);
        self.on = self.st.status !== "off";
      });
    }
  },
  render: function (h) {
    var self = this;
    var boxStyle = { padding: "4px 20px", border: "1px solid rgba(128,128,128,.3)", borderRadius: "6px" };
    var rowStyle = {
      display: "flex", justifyContent: "space-between", alignItems: "center",
      padding: "12px 0", borderBottom: "1px solid rgba(128,128,128,.25)"
    };
    var row = function (name, value) {
      return h("div", { style: rowStyle }, [h("span", name), h("span", [value])]);
    };
    var inputStyle = {
      width: "260px", maxWidth: "60%", boxSizing: "border-box", padding: "6px 10px",
      border: "1px solid rgba(128,128,128,.5)", borderRadius: "4px",
      background: "transparent", color: "inherit", font: "inherit"
    };
    var field = function (label, key, placeholder) {
      return h("div", { style: rowStyle }, [
        h("span", label),
        h("input", {
          attrs: {
            type: "text", placeholder: placeholder, spellcheck: "false",
            autocapitalize: "off", autocomplete: "off"
          },
          domProps: { value: self.form[key] },
          style: inputStyle,
          on: { input: function (e) { self.form[key] = e.target.value; } }
        })
      ]);
    };
    var button = function (text, enabled, onClick) {
      return h("button", {
        attrs: { type: "button", disabled: !enabled },
        style: {
          padding: "7px 16px", borderRadius: "4px", border: "1px solid rgba(128,128,128,.5)",
          background: "transparent", color: "inherit", font: "inherit",
          cursor: enabled ? "pointer" : "not-allowed", opacity: enabled ? 1 : 0.45
        },
        on: { click: onClick }
      }, text);
    };
    var status = h("span", { style: { color: this.color } }, "\u25CF " + this.label);
    return h("div", { style: { padding: "20px 0", maxWidth: "640px" } }, [
      h("gl-title", { attrs: { title: "L2TP VPN" } }),
      h("div", { style: boxStyle }, [
        row("Status", status),
        row("Server", this.server),
        row("Tunnel address", this.address),
        h("div", { style: { display: "flex", justifyContent: "space-between", alignItems: "center", padding: "12px 0" } }, [
          h("span", "Connect"),
          h("gl-switch", {
            attrs: { size: "small", disabled: !!this.pending },
            model: {
              value: this.on,
              callback: function (v) { self.on = v; self.toggle(v); },
              expression: "on"
            }
          })
        ])
      ]),
      this.error
        ? h("p", { style: { marginTop: "16px", fontSize: "13px", color: "#f56c6c" } }, this.error)
        : null,
      this.state === "off" && this.st.message
        ? h("p", { style: { marginTop: "16px", fontSize: "13px", color: "#e6a23c" } }, this.st.message)
        : null,

      h("h3", { style: { margin: "28px 0 10px", fontSize: "16px" } }, "Connection settings"),
      h("div", { style: boxStyle }, [
        field("Server", "host", "vpn.example.com"),
        field("Username", "user", ""),
        field("Password", "password", ""),
        field("Secret key (PSK)", "psk", "")
      ]),
      h("h3", { style: { margin: "28px 0 10px", fontSize: "16px" } }, "If the connection drops"),
      h("div", { style: boxStyle }, [
        field("Reconnect every (minutes)", "retry", "5"),
        field("Give up after (hours)", "giveup", "0")
      ]),
      h("p", { style: { marginTop: "8px", fontSize: "12px", opacity: 0.7 } },
        "When the tunnel drops and the internet is back, the router connects again: after 1 minute, after 2 more minutes, and then every number of minutes set here. 0 minutes means do not reconnect: Connect switches off. Give up after switches Connect off when this many hours have passed since the drop; 0 means never."),
      this.dirty && this.problem
        ? h("p", { style: { marginTop: "12px", fontSize: "13px", color: "#e6a23c" } }, this.problem)
        : null,
      this.formError
        ? h("p", { style: { marginTop: "12px", fontSize: "13px", color: "#f56c6c" } }, this.formError)
        : null,
      h("div", { style: { display: "flex", gap: "10px", marginTop: "16px", flexWrap: "wrap" } }, [
        button(this.saving ? "Saving\u2026" : "Save", this.canSave, function () { self.save(false); }),
        button("Save and reconnect", this.canSave, function () { self.save(true); })
      ]),
      h("p", { style: { marginTop: "16px", fontSize: "12px", opacity: 0.7 } },
        "The connection settings apply the next time the VPN starts; the reconnect settings apply from the next drop. The status refreshes every few seconds.")
    ]);
  }
};
EOF_WEB_VIEW
      [ -f /www/views/gl-sdk4-ui-l2tp.common.js.gz ] && { [ -f /root/l2tp-view.bak.js.gz ] || cp /www/views/gl-sdk4-ui-l2tp.common.js.gz /root/l2tp-view.bak.js.gz; }
      gzip -9 < /tmp/l2tp-view.js > /www/views/gl-sdk4-ui-l2tp.common.js.gz
      chmod 664 /www/views/gl-sdk4-ui-l2tp.common.js.gz
      echo '{"menu_l2tp": "L2TP VPN"}' > /www/i18n/gl-sdk4-ui-l2tp.en.json
      cat > /tmp/l2tp-menu.json <<'EOF_WEB_MENU'
{
    "index": 90,
    "view": "l2tp",
    "level": 2,
    "parent": "vpn",
    "parent_icon": "vpn",
    "parent_index": 40,
    "lang_hide": [
        "zh-cn"
    ],
    "show_mode": [
        "router"
    ],
    "disables": [
        "portal"
    ]
}
EOF_WEB_MENU
      # the menu entry goes last, and only if its JSON is valid
      if [ "$(jsonfilter -i /tmp/l2tp-menu.json -e '@.view' 2>/dev/null)" = "l2tp" ]; then
        cp /tmp/l2tp-menu.json /usr/share/oui/menu.d/l2tp.json
        echo "    Installed. Hard-refresh the panel (Cmd/Ctrl+Shift+R) and open VPN > L2TP VPN."
      else
        echo "    ERROR: the menu entry is not valid JSON - not installed."
      fi
    fi
  fi
else
  echo "    GL.iNet panel files (or lua / jsonfilter) not found - skipping the web panel page."
fi

say "Done. Nothing was started and nothing autostarts."
echo "    Start:   l2tp-vpn start"
echo "    Status:  l2tp-vpn status"
echo "    Stop:    l2tp-vpn stop"
echo "    If the tunnel drops while the VPN is on, it reconnects by itself (USER-GUIDE.md: When the connection drops)."
