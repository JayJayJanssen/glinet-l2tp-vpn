#!/bin/sh
# Tests the reconnect loop of scripts/l2tp-vpn with a scripted simulation: a fake clock, a fake "sleep" that advances it and fires
# events (the tunnel drops, the uplink returns, Connect is switched off ...), and a fake reconnect attempt that succeeds or fails on cue.
HERE=$(cd "$(dirname "$0")/.." && pwd); SCRIPT="$HERE/scripts/l2tp-vpn"
W=$(mktemp -d /tmp/l2tp-keeper-test.XXXXXX); mkdir -p "$W/bin"
cat > "$W/bin/sleep" <<'S'
#!/bin/sh
echo "sleep $1" >> "$W/log"
n=$(cat "$W/sleepn" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$W/sleepn"
now=$(cat "$W/now"); echo $((now + $1)) > "$W/now"
grep "^$n " "$W/events" 2>/dev/null | cut -d' ' -f2- | while read -r c; do eval "$c"; done
[ "$n" -gt 400 ] && { echo RUNAWAY >> "$W/log"; rm -f "$W/state"; }
exit 0
S
printf '#!/bin/sh\necho "date" >> "$W/log"\ncase "$1" in +%%s) cat "$W/now" ;; *) /bin/date "$@" ;; esac\n' > "$W/bin/date"
printf '#!/bin/sh\nshift 2\necho "log: $*" >> "$W/log"\n' > "$W/bin/logger"
cat > "$W/bin/ip" <<'S'
#!/bin/sh
echo "ip $*" >> "$W/log"
case "$*" in "route show default") [ -e "$W/uplink" ] && echo "default via 192.168.1.1 dev eth0" ;; esac
exit 0
S
printf '#!/bin/sh\necho "ping $*" >> "$W/log"\n[ -e "$W/uplink" ]\n' > "$W/bin/ping"
for c in iptables killall ipsec; do printf '#!/bin/sh\nexit 0\n' > "$W/bin/$c"; done
printf '#!/bin/sh\nexit 1\n' > "$W/bin/pidof"
cat > "$W/attempt" <<'S'
#!/bin/sh
echo "attempt" >> "$W/log"
now=$(cat "$W/now"); echo $((now + 40)) > "$W/now"
r=$(head -n 1 "$W/results" 2>/dev/null); sed -i 1d "$W/results" 2>/dev/null
[ -z "$r" ] && r=1
if [ "$r" = 0 ]; then printf 'ppp0\t00000000\n' >> "$W/route"; echo "VPN up."; else echo "PPP failed. Check: logread"; fi
exit "$r"
S
chmod +x "$W/bin"/* "$W/attempt"
export W; export PATH="$W/bin:$PATH"
export L2TP_VPN_STATE="$W/state" KEEPER_PID="$W/kpid" ATTEMPT_PID="$W/apid" ATTEMPT_OUT="$W/aout" L2TP_VPN_MSG="$W/msg" PROC_ROUTE="$W/route" L2TP_VPN_CONF="$W/conf" T0="$W/t0" DNS_BAK="$W/dnsbak" ATTEMPT_CMD="$W/attempt"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; echo "     got:      '$2'"; echo "     expected: '$3'"; fi; }
setup() { rm -f "$W"/log "$W"/sleepn "$W"/events "$W"/results "$W"/msg "$W"/kpid "$W"/apid "$W"/conf "$W"/dnsbak; echo 1000000 > "$W/now"; : > "$W/log"
          touch "$W/state" "$W/uplink"; printf 'Iface\tDestination\neth0\t00000000\nppp0\t00000000\n' > "$W/route"; }
ev() { printf '%s %s\n' "$1" "$2" >> "$W/events"; }
export SCRIPT
run_keeper() { timeout 20 sh -c 'L2TP_VPN_LIB=1; . "$SCRIPT"; keeper' >/dev/null 2>&1; }      # a loop that never ends fails the test instead of hanging it
seq() { grep -E '^(sleep|attempt)' "$W/log" | sed 's/^sleep //' | tr '\n' ' '; }
logs() { grep '^log:' "$W/log" | sed 's/^log: //' | tr '\n' '|'; }
count() { grep -c "^$1" "$W/log"; }
DROP=': > $W/route'; BACK='printf "ppp0\t0\n" > $W/route'; END='rm -f $W/state'
F5="5 5 5 5 5 5 5 5 5"

echo "=== a healthy tunnel"
setup; ev 4 "$END"; run_keeper
check "healthy: it only sleeps 30 seconds at a time" "$(seq)" "30 30 30 30 "
check "healthy: no program but sleep is started (no ip, ping, date, log)" "$(grep -vc '^sleep' "$W/log")" "0"
check "the loop's pid file is gone once it ends" "$([ -f "$W/kpid" ] && echo present)" ""

echo "=== a drop with a quick reconnect"
setup; echo 0 > "$W/results"; ev 2 "$DROP"; ev 14 "$END"; run_keeper
check "a drop: 30 s checks, then 9 checks of 5 s, then one attempt, then back to 30 s" "$(seq)" "30 30 $F5 attempt 30 30 30 "
check "the log says: dropped, attempt 1, reconnected" "$(logs)" "the tunnel dropped|reconnect attempt 1|reconnected|"
setup; ev 1 "$DROP"; ev 4 "$BACK"; ev 6 "$END"; run_keeper
check "a drop that heals within the 45 s grace period causes no attempt and no log line" "$(seq)$(logs)" "30 5 5 5 30 30 "

echo "=== failing attempts: 1 minute, 2 minutes, then the retry time"
setup; printf '1\n1\n1\n1\n0\n' > "$W/results"; ev 1 "$DROP"; ev 16 "$END"; run_keeper
check "default: waits 60, 120, 300, 300 between attempts, and then it is connected" "$(seq)" "30 $F5 attempt 60 attempt 120 attempt 300 attempt 300 attempt 30 30 "
check "each failure is logged with its reason" "$(logs | grep -o 'attempt [0-9] failed: PPP failed. Check: logread' | wc -l | tr -d ' ')" "4"
setup; echo "RETRY_MINUTES='2'" > "$W/conf"; printf '1\n1\n1\n0\n' > "$W/results"; ev 1 "$DROP"; ev 14 "$END"; run_keeper
check "RETRY_MINUTES=2: 60, 120, then 120" "$(seq | grep -o 'attempt [0-9]* attempt [0-9]* attempt [0-9]* attempt')" "attempt 60 attempt 120 attempt 120 attempt"
setup; echo "RETRY_MINUTES='1'" > "$W/conf"; printf '1\n1\n1\n0\n' > "$W/results"; ev 1 "$DROP"; ev 14 "$END"; run_keeper
check "RETRY_MINUTES=1: the early waits are cut to 1 minute too" "$(seq | grep -o 'attempt [0-9]* attempt [0-9]* attempt [0-9]* attempt')" "attempt 60 attempt 60 attempt 60 attempt"
setup; echo "RETRY_MINUTES='5'" > "$W/conf"; printf '1\n1\n1\n0\n' > "$W/results"; ev 1 "$DROP"; ev 1 'printf "RETRY_MINUTES='"'"'1'"'"'\n" > $W/conf'; ev 14 "$END"; run_keeper
check "settings saved before the drop is noticed are the ones used" "$(seq | grep -o 'attempt 60 attempt 60 attempt 60 attempt')" "attempt 60 attempt 60 attempt 60 attempt"
setup; echo "RETRY_MINUTES='999'" > "$W/conf"; printf '1\n1\n1\n0\n' > "$W/results"; ev 1 "$DROP"; ev 14 "$END"; run_keeper
check "RETRY_MINUTES above 60 counts as 60" "$(seq | grep -o 'attempt 60 attempt 120 attempt 3600 attempt')" "attempt 60 attempt 120 attempt 3600 attempt"
setup; printf "RETRY_MINUTES='abc'\nGIVE_UP_HOURS='x'\n" > "$W/conf"; printf '1\n1\n1\n0\n' > "$W/results"; ev 1 "$DROP"; ev 14 "$END"; run_keeper
check "rubbish settings fall back to 5 minutes and never giving up" "$(seq | grep -o 'attempt 60 attempt 120 attempt 300 attempt')" "attempt 60 attempt 120 attempt 300 attempt"
check "settings are read with their limits" "$( ( printf "RETRY_MINUTES='999'\nGIVE_UP_HOURS='999'\n" > "$W/conf"; L2TP_VPN_LIB=1; . "$SCRIPT"; read_settings; echo "$RETRY_MINUTES $GIVE_UP_HOURS" ) )" "60 168"
check "and without any settings: 5 minutes, never give up" "$( ( rm -f "$W/conf"; L2TP_VPN_LIB=1; . "$SCRIPT"; read_settings; echo "$RETRY_MINUTES $GIVE_UP_HOURS" ) )" "5 0"

echo "=== no uplink: no attempts until it is back"
setup; echo 0 > "$W/results"; ev 1 "$DROP; rm -f \$W/uplink"; ev 14 'touch $W/uplink'; ev 16 "$END"; run_keeper
check "no attempt while the uplink is down; the first one right when it returns" "$(seq)" "30 $F5 30 30 30 30 attempt 30 30 "

echo "=== giving up"
setup; printf "GIVE_UP_HOURS='1'\n" > "$W/conf"; ev 1 "$DROP"; run_keeper
t_start=1000075; elapsed=$(( $(cat "$W/now") - t_start ))
check "after 1 hour of failed attempts: Connect is switched off, with the reason for the panel" "$([ -f "$W/state" ] && echo on)|$(cat "$W/msg")" "|Gave up reconnecting after 1 hour; Connect was switched off."
check "it gives up at the hour mark, not much later (within one attempt)" "$([ "$elapsed" -ge 3600 ] && [ "$elapsed" -le 3640 ] && echo ok)" "ok"
check "it kept trying until then (about 10 to 14 attempts)" "$([ "$(count attempt)" -ge 10 ] && [ "$(count attempt)" -le 14 ] && echo ok)" "ok"
check "it tore the connection down when it gave up, and the log says why" "$(count 'ip route del 0.0.0.0/1')$(logs | grep -c 'stopping: Gave up')" "11"
setup; printf "GIVE_UP_HOURS='2'\n" > "$W/conf"; ev 1 "$DROP; rm -f \$W/uplink"; run_keeper
check "an uplink that never returns: no attempt at all, and it gives up after the 2 hours" "$(count attempt)|$(cat "$W/msg")" "0|Gave up reconnecting after 2 hours; Connect was switched off."
setup; printf "RETRY_MINUTES='0'\n" > "$W/conf"; ev 1 "$DROP"; run_keeper
check "RETRY_MINUTES=0: no attempt, and a dropped tunnel switches Connect off, with the reason" "$(count attempt)|$([ -f "$W/state" ] && echo on)|$(cat "$W/msg")" "0||The tunnel dropped and automatic reconnect is off, so Connect was switched off."

echo "=== Connect is switched off while the loop works"
setup; ev 1 "$DROP"; ev 11 "$END"; run_keeper
check "switched off during the wait after a failed attempt: no further attempt, no message" "$(seq | sed 's/.*attempt/attempt/')$([ -f "$W/msg" ] && echo msg)" "attempt 60 "
setup; ev 1 "$DROP; rm -f \$W/uplink"; ev 12 "$END"; run_keeper
check "switched off while waiting for the uplink: no attempt" "$(count attempt)" "0"
setup; ev 3 "$END"; run_keeper
check "switched off during the 45 s check: the loop just ends" "$(seq)" "30 30 30 "

echo "=== stop: ends the loop and a running attempt, and tears everything down"
setup; echo "gave up earlier" > "$W/msg"
python3 -c 'import time; time.sleep(60)' & kp=$!; python3 -c 'import time; time.sleep(60)' & ap=$!
echo $kp > "$W/kpid"; echo $ap > "$W/apid"; ( L2TP_VPN_LIB=1; . "$SCRIPT"; do_stop ) >/dev/null 2>&1
dead() { st=$(ps -o stat= -p "$1" 2>/dev/null | head -c1); [ -z "$st" ] || [ "$st" = Z ] && echo dead || echo alive; }
check "the loop and the attempt are both ended" "$(dead $kp) $(dead $ap)" "dead dead"
check "the pid files, the state and the old message are removed, and the tunnel is torn down" "$([ -f "$W/kpid" ] && echo k)$([ -f "$W/apid" ] && echo a)$([ -f "$W/state" ] && echo s)$([ -f "$W/msg" ] && echo m)|$(count 'ip route del 0.0.0.0/1')" "|1"
kill $kp $ap 2>/dev/null

echo "=== an attempt, and start"
setup; ( L2TP_VPN_LIB=1; . "$SCRIPT"; teardown() { echo teardown >> "$W/log"; }; connect() { echo connect >> "$W/log"; return 0; }; attempt ) >/dev/null 2>&1
check "an attempt cleans up first, then connects" "$(grep -E '^(teardown|connect)' "$W/log" | tr '\n' ' ')" "teardown connect "
setup; ( L2TP_VPN_LIB=1; . "$SCRIPT"; teardown() { :; }; connect() { return 1; }; attempt ); rc=$?
check "a failed attempt returns an error and leaves the state (Connect stays on)" "$rc$([ -f "$W/state" ] && echo state)" "1state"
setup; rm -f "$W/state"; ( L2TP_VPN_LIB=1; . "$SCRIPT"; connect() { echo connect >> "$W/log"; touch "$W/state"; return 0; }; launch_keeper() { echo launch >> "$W/log"; }; do_start ) >/dev/null 2>&1
check "a successful start connects, then launches the loop" "$(grep -E '^(connect|launch)' "$W/log" | tr '\n' ' ')" "connect launch "
setup; rm -f "$W/state"; ( L2TP_VPN_LIB=1; . "$SCRIPT"; connect() { touch "$W/state"; return 1; }; launch_keeper() { echo launch >> "$W/log"; }; do_start ) >/dev/null 2>&1; rc=$?
check "a failed start tears down, forgets the state, starts no loop and returns an error" "$rc$([ -f "$W/state" ] && echo state)$(count launch)" "10"
setup; ( L2TP_VPN_LIB=1; . "$SCRIPT"; connect() { echo connect >> "$W/log"; return 0; }; do_start ) >/dev/null 2>&1; rc=$?
check "start refuses when Connect is already on" "$rc$(count connect)" "10"
setup; echo "old reason" > "$W/msg"; rm -f "$W/state"; ( L2TP_VPN_LIB=1; . "$SCRIPT"; connect() { touch "$W/state"; return 0; }; launch_keeper() { :; }; do_start ) >/dev/null 2>&1
check "start removes an old 'gave up' message" "$([ -f "$W/msg" ] && echo msg)" ""
check "connect never exits the whole script (the loop depends on it)" "$(sed -n '/^connect() {/,/^}/p' "$SCRIPT" | grep -c 'exit ')" "0"

echo "=== helpers"
setup; printf 'Iface\tDestination\neth0\t0\n' > "$W/route"; check "tunnel_up: no ppp0 route" "$( ( L2TP_VPN_LIB=1; . "$SCRIPT"; tunnel_up && echo up || echo down ) )" "down"
printf 'Iface\tDestination\npppoe-wan\t0\nppp0\t0\n' > "$W/route"; check "tunnel_up: a ppp0 route (and another ppp interface is not mistaken for it)" "$( ( L2TP_VPN_LIB=1; . "$SCRIPT"; tunnel_up && echo up || echo down ) )" "up"
printf 'Iface\tDestination\npppoe-wan\t0\n' > "$W/route"; check "tunnel_up: only pppoe-wan is not the tunnel" "$( ( L2TP_VPN_LIB=1; . "$SCRIPT"; tunnel_up && echo up || echo down ) )" "down"
: > "$W/route"; check "tunnel_up: an empty table" "$( ( L2TP_VPN_LIB=1; . "$SCRIPT"; tunnel_up && echo up || echo down ) )" "down"
setup; check "uplink_up: a default route whose gateway answers" "$( ( L2TP_VPN_LIB=1; . "$SCRIPT"; uplink_up && echo up || echo down ) )" "up"
setup; rm -f "$W/uplink"; check "uplink_up: no default route" "$( ( L2TP_VPN_LIB=1; . "$SCRIPT"; uplink_up && echo up || echo down ) )" "down"
setup; printf '#!/bin/sh\necho "default dev wwan0 scope link"\n' > "$W/bin/ip"; check "uplink_up: a default route without a gateway counts as up (nothing to ping)" "$( ( L2TP_VPN_LIB=1; . "$SCRIPT"; uplink_up && echo up || echo down ) )" "up"
printf '#!/bin/sh\necho "default via 192.168.1.1 dev eth0"\n' > "$W/bin/ip"; rm -f "$W/uplink"; check "uplink_up: a gateway that does not answer" "$( ( L2TP_VPN_LIB=1; . "$SCRIPT"; uplink_up && echo up || echo down ) )" "down"
setup; ( echo $$ > "$W/kpid"; L2TP_VPN_LIB=1; . "$SCRIPT"; keeper_status ) > "$W/out" 2>&1
check "status: a running loop is reported" "$(cat "$W/out")" "Reconnect loop: running"
setup; ( L2TP_VPN_LIB=1; . "$SCRIPT"; keeper_status ) > "$W/out" 2>&1
check "status: Connect on but no loop is a warning" "$(cat "$W/out")" "Reconnect loop: NOT running (a dropped tunnel will not be reconnected)"
setup; rm -f "$W/state"; ( L2TP_VPN_LIB=1; . "$SCRIPT"; keeper_status ) > "$W/out" 2>&1
check "status: nothing about the loop when the VPN is off" "$(cat "$W/out")" ""
check "the status command shows the loop line, and the internal commands exist" "$(grep -c 'keeper_status ;;' "$SCRIPT")$(grep -c '_attempt) attempt' "$SCRIPT")$(grep -c '_keeper) keeper' "$SCRIPT")" "111"
echo "=== the real process: launched by start, detached, ended by stop"
setup; mkdir -p "$W/bin2"; printf '#!/bin/sh\nexec /bin/sleep 0.2\n' > "$W/bin2/sleep"; chmod +x "$W/bin2/sleep"      # a real, short sleep so that the loop stays alive for a moment
( PATH="$W/bin2:$PATH"; L2TP_VPN_SELF="$SCRIPT"; export PATH L2TP_VPN_SELF; L2TP_VPN_LIB=1; . "$SCRIPT"; launch_keeper )
i=0; while [ ! -s "$W/kpid" ] && [ $i -lt 60 ]; do /bin/sleep 0.1; i=$((i+1)); done
kp=$(cat "$W/kpid" 2>/dev/null)
check "start launches the loop as its own process, which writes its own pid" "$([ -n "$kp" ] && [ -d "/proc/$kp" ] && echo alive)" "alive"
check "the process is the script itself, run with _keeper" "$(tr '\0' ' ' < "/proc/$kp/cmdline" 2>/dev/null | grep -c '_keeper')" "1"
mask=$(awk '/SigIgn/{print $2}' "/proc/$kp/status" 2>/dev/null)
check "it ignores a hangup, so closing the SSH session does not end it" "$([ -n "$mask" ] && [ $(( 0x$mask & 1 )) -eq 1 ] && echo ignores)" "ignores"
check "its output goes nowhere (it holds neither the terminal nor the panel's pipe)" "$(ls -l "/proc/$kp/fd/1" "/proc/$kp/fd/2" 2>/dev/null | grep -c '/dev/null')" "2"
( L2TP_VPN_LIB=1; . "$SCRIPT"; do_stop ) >/dev/null 2>&1
j=0; while [ -d "/proc/$kp" ] && [ "$(ps -o stat= -p "$kp" 2>/dev/null | head -c1)" != Z ] && [ $j -lt 30 ]; do /bin/sleep 0.1; j=$((j+1)); done
check "stop ends the real process, and removes its pid file and the state" "$(st=$(ps -o stat= -p "$kp" 2>/dev/null | head -c1); { [ -z "$st" ] || [ "$st" = Z ]; } && echo ended)|$([ -f "$W/kpid" ] && echo pidfile)$([ -f "$W/state" ] && echo state)" "ended|"
rm -rf "$W"
echo "=== RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
