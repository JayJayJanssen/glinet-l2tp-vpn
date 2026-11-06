#!/bin/sh
# Static checks: shell syntax, Lua syntax, JavaScript syntax, and that the installer embeds exact copies of the other files.
# There are no behavioural tests in this repository: the code was verified by hand on a router (see README.md).
cd "$(dirname "$0")" || exit 1
fail=0
step() { printf '%-44s' "$1"; }
ok()   { echo ok; }
bad()  { echo "FAILED"; fail=1; }
for f in scripts/install.sh scripts/l2tp-vpn; do step "sh -n $f"; sh -n "$f" 2>/dev/null && ok || bad; done
LUA=""; for c in lua lua5.1 lua5.3 lua5.4 luajit texlua; do command -v $c >/dev/null 2>&1 && { LUA=$c; break; }; done
if [ -n "$LUA" ]; then
  for f in webui/l2tp webui/l2tp-validator.lua; do
    step "$LUA loadfile $f"
    printf 'local f, e = loadfile("%s"); if not f then io.stderr:write(e, "\\n") os.exit(1) end\n' "$f" > /tmp/l2tp-check.$$.lua
    $LUA /tmp/l2tp-check.$$.lua 2>/dev/null && ok || bad
  done; rm -f /tmp/l2tp-check.$$.lua
else echo "(no Lua interpreter found: skipping the Lua syntax checks)"; fi
if command -v node >/dev/null 2>&1; then step "node --check webui/l2tp-view-live.js"; node --check webui/l2tp-view-live.js 2>/dev/null && ok || bad
else echo "(node not found: skipping the JavaScript syntax check)"; fi
echo "--- the installer's wait for the panel"
sh tools/test_wait_for_panel.sh | tail -1 | grep -q " 0 failed" && echo "wait_for_panel: ok" || { echo "wait_for_panel: FAILED"; fail=1; }
echo "--- installer consistency"
python3 tools/check_installer.py || fail=1
[ "$fail" = 0 ] && echo "all checks passed" || echo "SOME CHECKS FAILED"
exit $fail
