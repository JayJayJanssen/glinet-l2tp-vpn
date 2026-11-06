#!/usr/bin/env python3
"""Checks that scripts/install.sh embeds exact copies of the other files, and that its safety steps are still there.

The installer is one self-contained file (it is copied to the router on its own), so it carries copies of the control script and the
web panel files. If you change one of those files, copy the change into install.sh too, then run this.
"""
import json, os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def read(p): return open(os.path.join(root, p)).read()
inst = read('scripts/install.sh').split('\n')
blocks, i = {}, 0
while i < len(inst):
    m = re.search(r"<<'(EOF_[A-Z_0-9]+)'", inst[i])
    if m:
        d, j = m.group(1), i + 1
        while inst[j] != d: j += 1
        blocks[d] = '\n'.join(inst[i + 1:j]) + '\n'; i = j
    i += 1
pairs = {'EOF_L2TP_VPN_SCRIPT': 'scripts/l2tp-vpn', 'EOF_WEB_MODULE': 'webui/l2tp',
         'EOF_WEB_VALIDATOR': 'webui/l2tp-validator.lua', 'EOF_WEB_VIEW': 'webui/l2tp-view-live.js', 'EOF_WEB_MENU': 'webui/l2tp-menu.json'}
bad = 0
for marker, path in pairs.items():
    ok = marker in blocks and blocks[marker] == read(path)
    print("%-10s %s  (%s)" % ("identical" if ok else "DIFFERENT", path, marker)); bad += (not ok)
text = '\n'.join(inst)
for needle, what in (('could not confirm that the module refuses calls without a login', 'the login check removes the module if calls are not refused'),
                     ('rm -f "$MOD" /usr/share/gl-validator.d/l2tp.lua', 'the module and validator are removed when the check fails'),
                     ('wait_for_panel\n      R1=', 'the installer waits for the panel before the login check'),
                     ('[ "$C1$C2" = "11" ]', 'both calls (get_status and set_config) must be refused')):
    ok = needle in text; print("%-10s installer: %s" % ("present" if ok else "MISSING", what)); bad += (not ok)
json.loads(read('webui/l2tp-menu.json')); print("valid      webui/l2tp-menu.json is valid JSON")
sys.exit(1 if bad else 0)
