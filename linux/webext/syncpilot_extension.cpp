// SyncPilot web-process extension.
//
// Injects the official-UI desktop bridge (window.btsync) into the page
// world at document start. The UI process's UserContentManager cannot do
// this on WebKitGTK 2.52: default-world user scripts added through it
// reliably miss the first document after the web process spawns (they do
// apply to later navigations, but the first document is exactly where the
// UI decides app.isDesktop), and named script worlds are isolated from the
// page. The extension's window-object-cleared hook runs in the page world
// before any page script, deterministically.
//
// Calls flow over a user script message channel: the injected object turns
// every call into window.webkit.messageHandlers.btsync.postMessage(JSON)
// and the UI process answers each one by evaluating __btsyncResolve in the
// page (the call's promise is the reply channel). The previous transport —
// fetch over a custom "syncpilot-bridge://" URI scheme — never delivered
// non-GET requests: WebKit's fetch rejects them before the scheme handler
// is consulted ("TypeError: Load failed"), so with the UI build that routes
// its whole data plane through callapi the interface came up empty.
//
// Loaded from <app>/webext next to the host binary; the directory is
// registered by the UI process before the first load (js_bridge.cpp).
#include <jsc/jsc.h>
#include <webkit/webkit-web-process-extension.h>

namespace {

// Defines window.btsync before any page script runs. Every call funnels
// through call(): the UI's wrapper keys on isWebKitWebView and uses exactly
// this shape (btsync.call("openpath", {path}) → promise). The direct method
// properties mirror the official surface for non-WebKit caller styles. The
// reply rides __btsyncResolve(id, is_error, json_payload): is_error rejects
// with the payload as the error message; an empty payload resolves null;
// anything else is JSON-encoded result text.
constexpr char kBridgeScript[] = R"JS((function() {
  var pending = {};
  var seq = 0;
  function call(method, args) {
    var id = ++seq;
    return new Promise(function(resolve, reject) {
      pending[id] = {resolve: resolve, reject: reject};
      window.webkit.messageHandlers.btsync.postMessage(
          JSON.stringify({id: id, method: method,
                          args: args === undefined ? null : args}));
    });
  }
  window.__btsyncResolve = function(id, is_error, payload) {
    var p = pending[id];
    if (!p) return;
    delete pending[id];
    if (is_error) p.reject(new Error(payload));
    else p.resolve(payload === "" ? null : JSON.parse(payload));
  };
  var api = {parameter: null, call: call};
  ["openpath", "openurl", "shownotification", "showchoosefolderdialog",
   "showchoosefiledialog", "copytoclipboard", "opensyspreferences",
   "callapi", "getuifile", "setcallback"].forEach(function(name) {
    api[name] = function(args) { return call(name, args); };
  });
  api.get = function(key) { return call("get", {key: key}); };
  api.set = function(key, value) { return call("set", {key: key, value: value}); };
  window.btsync = api;
  call("__ready").catch(function() {});
})();)JS";

// TEMPORARY diagnostics (PR #6 install-testing): mirror the page's console,
// errors and boot state onto same-origin image requests so they are
// observable from outside (requests to /__diag on the proxy port). Also
// probes the POST-fetch bridge transport once and reports the exact
// resolved/rejected outcome with error text.
constexpr char kDiagScript[] = R"JS((function() {
  var n = 0;
  function diag(msg) {
    try {
      if (n > 80) return;
      n++;
      new Image().src = "http://127.0.0.1:39777/diag?m=" +
        encodeURIComponent(String(msg).slice(0, 260));
    } catch (e) {}
  }
  window.__diag = diag;
  ["log", "warn", "error", "info"].forEach(function(k) {
    var orig = console[k] ? console[k].bind(console) : function() {};
    console[k] = function() {
      try {
        diag(k + ": " + Array.prototype.map.call(arguments, function(a) {
          try { return typeof a === "string" ? a : JSON.stringify(a); }
          catch (e) { return String(a); }
        }).join(" "));
      } catch (e) {}
      orig.apply(console, arguments);
    };
  });
  window.onerror = function(msg, src, line, col) {
    diag("ONERROR: " + msg + " @ " + String(src || "").split("/").pop() +
         ":" + line + ":" + col);
  };
  window.addEventListener("unhandledrejection", function(e) {
    var r = e.reason;
    diag("UNHANDLED: " + (r && (r.stack || r.message) || r));
  });
  function state() {
    var el = document.getElementById("app-loading-text");
    return "ready=" + document.readyState +
      " loading=" + (el ? el.textContent : "-") +
      " app=" + (typeof window.app) +
      " isDesktop=" + (window.app ? window.app.isDesktop : "-") +
      " textLen=" + (document.body ? document.body.innerText.length : -1);
  }
  var ticks = 0;
  var timer = setInterval(function() {
    diag("T" + ticks + " " + state());
    if (++ticks > 12) clearInterval(timer);
  }, 4000);
  diag("BOOT " + state());
  setTimeout(function() {
    var t0 = Date.now();
    fetch("syncpilot-bridge://__probe", {method: "POST", body: "{}"})
      .then(function(r) {
        return r.text().then(function(t) {
          diag("PROBE-OK " + (Date.now() - t0) + "ms body=" +
               JSON.stringify(String(t).slice(0, 60)));
        });
      })
      .catch(function(e) {
        diag("PROBE-FAIL " + (Date.now() - t0) + "ms " + e);
      });
  }, 2000);
})();)JS";

void on_window_object_cleared(WebKitScriptWorld* world, WebKitWebPage* page,
                              WebKitFrame* frame, gpointer user_data) {
  if (!webkit_frame_is_main_frame(frame)) return;
  JSCContext* context = webkit_frame_get_js_context(frame);
  jsc_context_evaluate(context, kBridgeScript, -1);
  jsc_context_evaluate(context, kDiagScript, -1);
}

}  // namespace

extern "C" __attribute__((visibility("default"))) void
webkit_web_process_extension_initialize(WebKitWebProcessExtension* extension) {
  WebKitScriptWorld* world = webkit_script_world_get_default();
  g_signal_connect(world, "window-object-cleared",
                   G_CALLBACK(on_window_object_cleared), nullptr);
}
