#!/bin/sh
# Tests the DNS handling of scripts/l2tp-vpn (the router's DNS follows the DNS servers the L2TP server hands out),
# with fake uci, ip, pidof, iptables, killall, ipsec and sleep commands, fake pppd resolv files and a fake dnsmasq init script.
HERE=$(cd "$(dirname "$0")/.." && pwd); SCRIPT="$HERE/scripts/l2tp-vpn"
W=$(mktemp -d /tmp/l2tp-dns-test.XXXXXX); mkdir -p "$W/bin" "$W/uci"
cat > "$W/bin/uci" <<'S'
#!/bin/sh
# uci -q get KEY: the answer is the content of $W/uci/<KEY with odd characters replaced by _>
f="$W/uci/$(printf '%s' "$3" | tr -c 'A-Za-z0-9._\n' '_')"
[ -f "$f" ] && cat "$f" || exit 1
S
printf '#!/bin/sh\necho "ip $*" >> "$W/ip.log"\n' > "$W/bin/ip"
printf '#!/bin/sh\n[ -e "$W/running.$1" ] && { echo 1234; exit 0; }\nexit 1\n' > "$W/bin/pidof"
for c in iptables killall ipsec sleep; do printf '#!/bin/sh\nexit 0\n' > "$W/bin/$c"; done
printf '#!/bin/sh\necho "$1" >> "$W/dnsmasq.log"\n' > "$W/dnsmasq-init"
chmod +x "$W/bin"/* "$W/dnsmasq-init"
export W; export PATH="$W/bin:$PATH"
export PPP_RESOLV="$W/ppp1 $W/ppp2" DNS_BAK="$W/bak" T0="$W/t0" DNSMASQ_INIT="$W/dnsmasq-init" L2TP_VPN_STATE="$W/state"
RF="$W/resolv.auto"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1 (got '$2', expected '$3')"; fi; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
reset() { rm -rf "$W"/uci/* "$W"/ppp1 "$W"/ppp2 "$W"/bak "$W"/ip.log "$W"/dnsmasq.log "$W"/running.* "$W"/state; touch -d '2026-01-01 00:00:00' "$W/t0"
          printf 'nameserver 192.168.1.1\nnameserver 192.168.1.2\n' > "$RF"; printf '%s' "$RF" > "$W/uci/dhcp._dnsmasq_0_.resolvfile"; }
fn() { ( L2TP_VPN_LIB=1; . "$SCRIPT"; "$@" ) 2>&1; }           # runs one function from the script
fresh_ppp() { printf 'nameserver 10.0.0.1\nnameserver 10.0.0.2\n' > "$W/ppp1"; }

echo "=== finding the server's DNS"
reset; touch -d '2020-01-01' "$W/ppp1"; printf 'nameserver 10.0.0.9\n' > "$W/ppp1"; touch -d '2020-01-01' "$W/ppp1"
check "a DNS file older than this start is ignored (it is from an earlier connection)" "$(fn peer_dns)" ""
reset; printf 'nameserver 10.0.0.1\nnameserver 10.0.0.2\nnameserver 10.0.0.3\nnameserver 10.0.0.4\n' > "$W/ppp1"
check "a fresh file gives the addresses, at most three" "$(fn peer_dns | tr '\n' ' ')" "10.0.0.1 10.0.0.2 10.0.0.3 "
reset; printf '# comment\nsearch lan\nnameserver fe80::1\nnameserver 10.0.0.7\nnameserver not-an-address\n' > "$W/ppp1"
check "only IPv4 addresses count; comments, IPv6 and rubbish are skipped" "$(fn peer_dns | tr '\n' ' ')" "10.0.0.7 "
reset; printf 'nameserver 10.0.0.9\n' > "$W/ppp1"; touch -d '2020-01-01' "$W/ppp1"; printf 'nameserver 10.0.0.5\n' > "$W/ppp2"
check "if the first file is stale the second one is used" "$(fn peer_dns | tr '\n' ' ')" "10.0.0.5 "
reset; check "which file dnsmasq reads comes from uci" "$(fn dns_file)" "$RF"
reset; rm -f "$W/uci/dhcp._dnsmasq_0_.resolvfile"; check "without a uci answer the usual /tmp/resolv.conf.auto is used" "$(fn dns_file)" "/tmp/resolv.conf.auto"

echo "=== applying it"
reset; out=$(fn dns_apply)
check "the server gave no DNS: nothing changes, nothing restarts, and it says so" "$(echo "$out" | grep -c 'the server gave no DNS address')$(cmp -s "$RF" "$W/bak" 2>/dev/null; echo $?)$(lines "$W/dnsmasq.log")$([ -f "$W/bak" ] && echo bak)" "120"
reset; fresh_ppp; out=$(fn dns_apply)
check "the uplink's DNS file is replaced by the server's DNS, marked as ours" "$(cat "$RF" | tr '\n' '|')" "# managed by l2tp-vpn|nameserver 10.0.0.1|nameserver 10.0.0.2|"
check "... the original is kept" "$(cat "$W/bak" | tr '\n' '|')" "nameserver 192.168.1.1|nameserver 192.168.1.2|"
check "... each DNS address is routed through the tunnel (a /32 route on ppp0)" "$(grep -c 'route replace 10.0.0.[12]/32 dev ppp0' "$W/ip.log")" "2"
check "... dnsmasq is restarted once, and the message names the servers" "$(lines "$W/dnsmasq.log")$(echo "$out" | grep -c 'DNS follows the server: 10.0.0.1 10.0.0.2')" "11"
fn dns_apply >/dev/null
check "applying again keeps the FIRST original, not our own file" "$(cat "$W/bak" | tr '\n' '|')" "nameserver 192.168.1.1|nameserver 192.168.1.2|"

echo "=== restoring it"
reset; fresh_ppp; fn dns_apply >/dev/null; : > "$W/dnsmasq.log"; fn dns_restore
check "the uplink's DNS file is put back, dnsmasq restarted once, the backup removed" "$(cat "$RF" | tr '\n' '|')$(lines "$W/dnsmasq.log")$([ -f "$W/bak" ] && echo bak)" "nameserver 192.168.1.1|nameserver 192.168.1.2|1"
reset; fresh_ppp; fn dns_apply >/dev/null; printf 'nameserver 172.16.0.1\n' > "$RF"; : > "$W/dnsmasq.log"; fn dns_restore
check "if the network service already rewrote the file, it is left alone (no restart), and the backup removed" "$(cat "$RF")$(lines "$W/dnsmasq.log")$([ -f "$W/bak" ] && echo bak)" "nameserver 172.16.0.10"
reset; fn dns_restore; check "no backup: nothing happens" "$(lines "$W/dnsmasq.log")$(cat "$RF" | wc -l | tr -d ' ')" "02"
reset; rm -f "$RF"; fresh_ppp; fn dns_apply >/dev/null; fn dns_restore
check "an uplink file that did not exist is restored as an empty file, not a leftover of ours" "$(grep -c 'managed by' "$RF")$(wc -c < "$RF" | tr -d ' ')" "00"

echo "=== when it must not touch DNS"
reset; fresh_ppp; echo 1 > "$W/uci/dhcp._dnsmasq_0_.noresolv"; out=$(fn dns_apply)
check "noresolv (the panel's DNS over TLS): says so, file unchanged, no restart" "$(echo "$out" | grep -c 'DNS left unchanged: dnsmasq ignores its resolv file')$(grep -c 'managed by' "$RF")$(lines "$W/dnsmasq.log")" "100"
reset; fresh_ppp; echo '1.1.1.1' > "$W/uci/dhcp._dnsmasq_0_.server"; out=$(fn dns_apply)
check "fixed DNS servers in dnsmasq (the panel's manual DNS): says so, file unchanged" "$(echo "$out" | grep -c 'dnsmasq has fixed DNS servers')$(grep -c 'managed by' "$RF")" "10"
reset; fresh_ppp; touch "$W/running.AdGuardHome"; out=$(fn dns_apply)
check "AdGuard Home running: says so, file unchanged" "$(echo "$out" | grep -c 'AdGuard Home is running')$(grep -c 'managed by' "$RF")" "10"
reset; echo 192.0.2.1 > "$W/x"; printf '%s' "$W/custom.resolv" > "$W/uci/dhcp._dnsmasq_0_.resolvfile"; printf 'nameserver 8.8.8.8\n' > "$W/custom.resolv"; fresh_ppp; fn dns_apply >/dev/null
check "a different resolv file named in uci is the one that is changed" "$(grep -c 'nameserver 10.0.0.1' "$W/custom.resolv")$(grep -c 'managed by' "$RF")" "10"

reset; fresh_ppp; printf '%s' "/etc/custom.resolv" > "$W/uci/dhcp._dnsmasq_0_.resolvfile"; out=$(fn dns_apply)
check "a resolv file that survives a restart (not in RAM) is never touched: says so, no backup, no restart" "$(echo "$out" | grep -c 'survives a restart')$([ -f "$W/bak" ] && echo bak)$(lines "$W/dnsmasq.log")" "10"

echo "=== a power cut while the tunnel is up, then a restart"
reset; fresh_ppp; fn dns_apply >/dev/null
rm -f "$W/bak" "$W/t0" "$W/state" "$W/ip.log"; printf 'nameserver 192.168.1.1\nnameserver 192.168.1.2\n' > "$RF"     # RAM is gone; the network service writes the uplink's file again
: > "$W/dnsmasq.log"; fn dns_restore
check "after the restart there is nothing to undo: the uplink's DNS is in place, nothing is restarted" "$(cat "$RF" | tr '\n' '|')$(lines "$W/dnsmasq.log")" "nameserver 192.168.1.1|nameserver 192.168.1.2|0"
touch -d '2026-06-01 00:00:00' "$W/ppp1"; touch "$W/t0"      # the server's DNS file on flash is older than the new start
check "a DNS file left on flash from before the power cut is not trusted at the next start" "$(fn peer_dns)" ""
fresh_ppp; fn dns_apply >/dev/null
check "the next connection starts clean and keeps the NEW original" "$(cat "$W/bak" | tr '\n' '|')$(head -1 "$RF")" "nameserver 192.168.1.1|nameserver 192.168.1.2|# managed by l2tp-vpn"

echo "=== status and report"
reset; check "status when not applied" "$(fn dns_status)" "DNS: not changed"
reset; fresh_ppp; fn dns_apply >/dev/null; check "status when applied lists the servers" "$(fn dns_status)" "DNS: follows the VPN server (10.0.0.1 10.0.0.2 )"
reset; fresh_ppp; out=$(fn dns_report); check "the report shows the file, pppd's file, the current content and whether it is applied" "$(echo "$out" | grep -c 'dnsmasq reads its upstream servers from')$(echo "$out" | grep -c 'written by pppd')$(echo "$out" | grep -c 'not applied')" "111"
reset; out=$(sh "$SCRIPT" dns); check "the dns command works when the script is run directly" "$(echo "$out" | grep -c 'dnsmasq reads its upstream servers from')" "1"
out=$(sh "$SCRIPT" nonsense); check "the usage line names the dns command" "$(echo "$out" | grep -c 'start|stop|status|dns')" "1"

echo "=== stop restores it, and the start hooks are in the right places"
reset; fresh_ppp; fn dns_apply >/dev/null; echo "1.2.3.4 192.168.1.1 eth0" > "$W/state"; touch "$W/t0"; : > "$W/dnsmasq.log"
( L2TP_VPN_LIB=1; . "$SCRIPT"; do_stop ) >/dev/null 2>&1
check "do_stop puts the uplink's DNS back and removes the state and the time marker" "$(cat "$RF" | tr '\n' '|')$([ -f "$W/state" ] && echo state)$([ -f "$W/t0" ] && echo t0)" "nameserver 192.168.1.1|nameserver 192.168.1.2|"
n_touch=$(grep -n 'touch "$T0"' "$SCRIPT" | head -1 | cut -d: -f1); n_dial=$(grep -n 'echo "c vpn"' "$SCRIPT" | head -1 | cut -d: -f1)
n_fw=$(grep -n '^  fw_rules -I' "$SCRIPT" | head -1 | cut -d: -f1); n_apply=$(grep -n '^  dns_apply' "$SCRIPT" | head -1 | cut -d: -f1)
check "the time marker is set before dialing, and the DNS is applied after the routes and firewall rules" "$([ "$n_touch" -lt "$n_dial" ] && echo before)$([ "$n_apply" -gt "$n_fw" ] && echo after)" "beforeafter"
rm -rf "$W"
echo "=== RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
