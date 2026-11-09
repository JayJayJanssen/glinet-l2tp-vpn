// Tests for webui/l2tp-view-live.js. Run from the package folder:  node tools/test_page.js
// A tiny stand-in for Vue 2 (data, computed, methods, render) with a fake backend, clock and timers.
// Its h() follows the real rule that caused an empty row once: a VNode passed where element data belongs throws.
const fs = require("fs");
const src = fs.readFileSync(__dirname + "/../webui/l2tp-view-live.js", "utf8");
let pass = 0, fail = 0;
function check(name, ok) { if (ok) { pass++; console.log("PASS " + name); } else { fail++; console.log("FAIL " + name); } }
const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };

function isVNode(x) { return x && typeof x === "object" && !Array.isArray(x) && ("tag" in x || "text" in x); }
function norm(children) {
  const out = [];
  const add = (c) => { if (c === null || c === undefined || c === false) return; if (Array.isArray(c)) c.forEach(add); else if (typeof c === "string" || typeof c === "number") out.push({ text: String(c) }); else out.push(c); };
  add(children); return out;
}
function h(tag, data, children) {
  if (Array.isArray(data) || typeof data === "string" || typeof data === "number") { children = data; data = undefined; }
  else if (isVNode(data)) throw new Error("a VNode was passed as element data for <" + tag + ">");
  return { tag, data: data || {}, children: norm(children) };
}
const textOf = (v) => (v.text !== undefined ? v.text : (v.children || []).map(textOf).join(""));
const all = (v, pred, acc = []) => { if (v.tag && pred(v)) acc.push(v); (v.children || []).forEach((c) => all(c, pred, acc)); return acc; };

function world() {
  const clock = { t: 1700000000000 }, timers = [], calls = [], messages = [];
  const backend = {
    deny: false, netfail: false,
    st: { status: "off", busy: false },
    cfg: { host: "vpn.example.com", user: "alice", password: "pw", psk: "key", retry_minutes: 5, giveup_hours: 0 },
    saveResult: { saved: true }, handlers: {}
  };
  backend.get_status = () => JSON.parse(JSON.stringify(backend.st));
  backend.get_config = () => JSON.parse(JSON.stringify(backend.cfg));
  backend.set_config = () => backend.saveResult;
  backend.start = () => ({ accepted: true });
  backend.stop = () => ({ accepted: true });
  const fetchStub = async (url, opts) => {
    const body = JSON.parse(opts.body); const [sid, mod, method, args] = body.params;
    calls.push({ url, sid, mod, method, args, headers: opts.headers });
    if (backend.netfail) throw new Error("Failed to fetch");
    if (backend.deny) return { json: async () => ({ error: { code: -32000, message: "Access denied" } }) };
    return { json: async () => ({ result: backend[method](args) }) };
  };
  const FakeDate = class extends Date { static now() { return clock.t; } };
  const doc = { cookie: "foo=1; Admin-Token=tok%20123; bar=2" };
  const setT = (fn, ms) => { const id = timers.length + 1; timers.push({ id, fn, at: clock.t + ms, ms, live: true }); return id; };
  const clearT = (id) => { const x = timers.find((q) => q.id === id); if (x) x.live = false; };
  const m = { exports: {} };
  new Function("module", "exports", "document", "fetch", "setTimeout", "clearTimeout", "Date", src)(m, m.exports, doc, fetchStub, setT, clearT, FakeDate);
  const comp = m.exports;
  const vm = {};
  Object.assign(vm, comp.data());
  for (const [k, fn] of Object.entries(comp.methods)) vm[k] = fn.bind(vm);
  for (const [k, fn] of Object.entries(comp.computed)) Object.defineProperty(vm, k, { get: () => fn.call(vm), enumerable: true });
  vm.$message = (o) => messages.push(o);
  vm.render = () => comp.render.call(vm, h);
  return {
    vm, comp, backend, calls, messages, clock, timers,
    live: () => timers.filter((q) => q.live),
    async mount() { comp.created.call(vm); await flush(); },
    async advance(ms) { clock.t += ms; const due = timers.filter((q) => q.live && q.at <= clock.t); for (const q of due) { q.live = false; q.fn(); } await flush(); },
    methodsCalled: () => calls.map((c) => c.method),
    page: () => textOf(vm.render()),
    inputs: () => all(vm.render(), (v) => v.tag === "input")
  };
}

(async () => {
  console.log("=== creation and loading");
  let w = world(); await w.mount();
  check("on creation the page loads the settings and the status, with the module name and the cookie's session id",
        w.methodsCalled().slice(0, 2).sort().join() === "get_config,get_status" && w.calls.every((c) => c.mod === "l2tp" && c.sid === "tok 123" && c.url === "/rpc"));
  check("the settings are loaded into the form, including the reconnect settings",
        w.vm.form.host === "vpn.example.com" && w.vm.form.psk === "key" && w.vm.form.retry === "5" && w.vm.form.giveup === "0" && w.vm.configLoaded === true);
  check("a freshly loaded form is not dirty and cannot be saved", w.vm.dirty === false && w.vm.canSave === false);
  w = world(); w.backend.cfg = { host: "h", user: "u", password: "p", psk: "k", retry_minutes: 0, giveup_hours: 0 }; await w.mount();
  check("zeros from the router show as 0, not as the defaults", w.vm.form.retry === "0" && w.vm.form.giveup === "0");
  w = world(); w.backend.cfg = { host: "h", user: "u", password: "p", psk: "k" }; await w.mount();
  check("an older backend without the new values: the page shows the defaults 5 and 0", w.vm.form.retry === "5" && w.vm.form.giveup === "0");
  w = world(); w.backend.cfg = { host: "h", user: "u", password: "p", psk: "k", retry_minutes: 12, giveup_hours: 24 }; await w.mount();
  check("saved values are shown", w.vm.form.retry === "12" && w.vm.form.giveup === "24");

  console.log("=== the two new fields on the page");
  w = world(); await w.mount();
  const text = w.page();
  check("both fields and their heading are on the page", text.includes("If the connection drops") && text.includes("Reconnect every (minutes)") && text.includes("Give up after (hours)"));
  check("the explanation says what 0 means for each field", text.includes("0 minutes means do not reconnect") && text.includes("0 means never"));
  const vals = w.inputs().map((i) => i.data.domProps.value);
  check("the inputs show the loaded values (the last two are the reconnect settings)", vals.length === 6 && vals[4] === "5" && vals[5] === "0");
  w.inputs()[4].data.on.input({ target: { value: "10" } }); w.inputs()[5].data.on.input({ target: { value: "48" } });
  check("typing in the inputs changes the form", w.vm.form.retry === "10" && w.vm.form.giveup === "48" && w.vm.dirty === true);
  check("the footer says when each kind of setting applies", w.page().includes("reconnect settings apply from the next drop"));

  console.log("=== checking what is typed");
  const prob = (retry, giveup) => { const x = world(); x.vm.form.host = "h.example.com"; x.vm.form.user = "u"; x.vm.form.password = "p"; x.vm.form.psk = "k"; x.vm.form.retry = retry; x.vm.form.giveup = giveup; return x.vm.problem; };
  check("valid: 5 and 0", prob("5", "0") === "");
  check("valid: the limits 0, 60, 168", prob("0", "0") === "" && prob("60", "168") === "");
  check("valid: leading zeros are fine (07 = 7)", prob("07", "012") === "");
  check("retry above 60 is a problem, naming the field", /Reconnect every/.test(prob("61", "0")));
  for (const bad of ["", "-1", "x", "1.5", "5 ", "100", " 5"]) check("retry " + JSON.stringify(bad) + " is a problem", /Reconnect every/.test(prob(bad, "0")));
  check("giveup above 168 is a problem, naming the field", /Give up after/.test(prob("5", "169")));
  for (const bad of ["", "-1", "x", "2.5", "1000", "1h"]) check("giveup " + JSON.stringify(bad) + " is a problem", /Give up after/.test(prob("5", bad)));
  w = world(); await w.mount(); w.vm.form.retry = "61";
  check("a problem shows on the page, and the settings cannot be saved", w.vm.dirty && w.page().includes("Reconnect every: a whole number of minutes from 0 to 60") && w.vm.canSave === false);

  console.log("=== saving");
  w = world(); await w.mount(); w.vm.form.retry = "10"; w.vm.form.giveup = "48"; w.calls.length = 0;
  check("a changed, valid form can be saved", w.vm.canSave === true);
  w.vm.save(false); await flush();
  const sc = w.calls.find((c) => c.method === "set_config");
  check("saving sends the four values and the two numbers as whole numbers", sc && sc.args.host === "vpn.example.com" && sc.args.psk === "key" && sc.args.retry_minutes === 10 && sc.args.giveup_hours === 48
        && Number.isInteger(sc.args.retry_minutes) && Number.isInteger(sc.args.giveup_hours));
  check("after saving the form is clean again, and the user is told", w.vm.dirty === false && w.messages.some((m) => /saved/i.test(m.message)));
  w = world(); await w.mount(); w.vm.form.retry = "0"; w.calls.length = 0; w.vm.save(false); await flush();
  check("0 is sent as the number 0 (not left out)", w.calls.find((c) => c.method === "set_config").args.retry_minutes === 0);
  w = world(); await w.mount(); w.vm.form.retry = "x"; w.calls.length = 0; w.vm.save(false); await flush();
  check("an invalid form is not sent at all", !w.methodsCalled().includes("set_config"));
  w = world(); await w.mount(); w.vm.form.retry = "7"; w.backend.saveResult = { saved: false, error: "invalid_retry" }; w.vm.save(false); await flush();
  check("a refusal from the router is shown in words", w.vm.formError.includes("Reconnect every") && w.vm.dirty === true);
  w = world(); await w.mount(); w.vm.form.giveup = "7"; w.backend.saveResult = { saved: false, error: "invalid_giveup" }; w.vm.save(false); await flush();
  check("... also for the give-up setting", w.vm.formError.includes("Give up after"));
  w = world(); await w.mount(); w.vm.form.giveup = "7"; w.backend.saveResult = { saved: false, error: "busy" }; w.vm.save(false); await flush();
  check("a busy router is reported (existing behaviour)", /busy/i.test(w.vm.formError));
  w = world(); await w.mount(); w.vm.form.retry = "9"; w.calls.length = 0; w.vm.save(true); await flush();
  check("Save and reconnect saves, then starts the VPN when it is off", w.methodsCalled().join() === "set_config,start");

  console.log("=== when the reconnect loop switches Connect off");
  w = world(); w.backend.st = { status: "connecting", busy: false, server: "203.0.113.5" }; await w.mount();
  check("while connecting the page shows Connecting and the switch is on", /Connecting/.test(w.page()) && w.vm.on === true);
  w.backend.st = { status: "off", busy: false, message: "Gave up reconnecting after 1 hour; Connect was switched off." };
  await w.advance(4000);
  check("when the router switches it off by itself the switch follows", w.vm.on === false && w.vm.state === "off");
  check("the reason is shown on the page", w.page().includes("Gave up reconnecting after 1 hour; Connect was switched off."));
  w.backend.st = { status: "off", busy: false }; await w.advance(4000);
  check("the reason disappears with the next status that has none", !w.page().includes("Gave up reconnecting"));
  w = world(); w.backend.st = { status: "connecting", busy: false, message: "stale" }; await w.mount();
  check("a message is not shown while connecting", !w.page().includes("stale"));
  w = world(); w.backend.st = { status: "connected", busy: false, address: "10.9.8.2", peer: "10.9.8.1/32", message: "stale" }; await w.mount();
  check("... nor while connected", !w.page().includes("stale") && w.page().includes("10.9.8.2"));

  console.log("=== the rest of the page still works");
  w = world(); await w.mount(); w.calls.length = 0; w.vm.toggle(true); await flush();
  check("the switch starts the VPN", w.methodsCalled()[0] === "start" && w.vm.pending === "start");
  w = world(); await w.mount(); check("polling is scheduled every 4 seconds", w.live().length === 1 && w.live()[0].ms === 4000);
  w.calls.length = 0; await w.advance(4000);
  check("... and asks for the status again", w.methodsCalled().includes("get_status"));
  w = world(); w.backend.deny = true; await w.mount();
  check("access denied is explained", /sign in again/i.test(w.vm.error));
  w = world(); w.backend.netfail = true; await w.mount();
  check("an unreachable router is explained", /Cannot reach/.test(w.vm.error));
  w = world(); await w.mount(); w.vm.beforeDestroy ? 0 : 0; w.comp.beforeDestroy.call(w.vm);
  check("leaving the page stops the polling", w.live().length === 0);

  console.log("=== RESULT: " + pass + " passed, " + fail + " failed");
  process.exit(fail === 0 ? 0 : 1);
})();
