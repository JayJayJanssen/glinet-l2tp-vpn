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
