#!/bin/sh
# Tests the waiting function of scripts/install.sh in isolation, with a fake curl and a fake sleep.
cd "$(dirname "$0")/.." || exit 1
fn=$(sed -n '/^wait_for_panel() {/,/^}/p' scripts/install.sh)
[ -n "$fn" ] || { echo "FAIL: wait_for_panel not found in scripts/install.sh"; exit 1; }
W=$(mktemp -d /tmp/l2tp-wfp.XXXXXX); pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1 (got '$2', expected '$3')"; fi; }
run() { # $1 = number of empty answers before the first real one; prints "<return code> <calls>"
  echo 0 > "$W/calls"; EMPTY=$1
  ( sleep() { :; }
    curl() { n=$(cat "$W/calls"); n=$((n+1)); echo $n > "$W/calls"; [ "$n" -le "$EMPTY" ] && return 0; echo '{"error":{"code":-32000}}'; }
    eval "$fn"; wait_for_panel; rc=$?; echo "$rc $(cat "$W/calls")" )
}
check "answers at once: success after 1 call"                          "$(run 0)"   "0 1"
check "answers after 3 empty replies: success after 4 calls"           "$(run 3)"   "0 4"
check "answers on the 20th call: still success"                        "$(run 19)"  "0 20"
check "never answers: gives up after 20 calls and returns failure"     "$(run 999)" "1 20"
rm -rf "$W"
echo "=== RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
