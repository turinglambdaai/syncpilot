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
// Calls flow over the official client's transport: the UI posts
// {m: method, args, i: index} to window.webkit.messageHandlers
// .jsToNativeHandler and — because our registration is the plain kind, so
// postMessage returns nothing — parks the reply resolver in
// window.btsync.cache[index]; the UI process delivers each answer by
// calling that resolver back in the page. (The official macOS/Windows
// client registers the channel with a reply and reads the returned
// promise; the UI supports both shapes — see sendTheMessage in app.js.)
// A previous attempt fetched over a custom "syncpilot-bridge://" URI
// scheme; WebKit's fetch rejects POSTs to a custom scheme before the
// scheme handler is consulted, so nothing ever arrived.
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
  function call(method, args) {
    var index = ++call.index;
    return new Promise(function(resolve) {
      // The native side answers by calling this resolver with the JSON
      // result text; errors resolve too, carrying an .error field.
      apiCache[index] = resolve;
      window.webkit.messageHandlers.jsToNativeHandler.postMessage(
          JSON.stringify({m: method, args: args === undefined ? null : args,
                          i: index}));
    });
  }
  call.index = 0;
  var apiCache = {};
  var api = {parameter: null, cache: apiCache, __sp: 1, call: call};
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
      new Image().src = "http://127.0.0.1:39778/diag?m=" +
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
    try {
      window.btsync.call("__probe", {}).then(function(v) {
        diag("PROBE-OK " + (Date.now() - t0) + "ms " + JSON.stringify(v));
      }).catch(function(e) {
        diag("PROBE-FAIL " + (Date.now() - t0) + "ms " + e);
      });
    } catch (e) { diag("PROBE-THROW " + e); }
  }, 2000);
  window.addEventListener("DOMContentLoaded", function() {
    try {
      var mh = "none";
      try { mh = JSON.stringify(Object.keys(window.webkit.messageHandlers)); } catch (e) { mh = "err " + e; }
      diag("DCL btasync=" + typeof window.btasync +
           " callapi=" + (window.btasync ? typeof window.btasync.callapi : "-") +
           " btsyncMine=" + (window.btsync && window.btsync.__sp ? "yes" : "no") +
           " cacheKeys=" + (window.btsync && window.btsync.cache ? Object.keys(window.btsync.cache).length : "-") +
           " channels=" + mh +
           " utilsURL=" + (window.app && window.app.utils ?
               typeof window.app.utils.URLDeserialize : "no-app"));
    } catch (e) { diag("DCL-ERR " + e); }
  });
  window.addEventListener("load", function() {
    try {
      if (window.btsync && window.btsync.onResponse) {
        var orig = window.btsync.onResponse.bind(window.btsync);
        window.btsync.onResponse = function(i, p) {
          diag("ONRESP " + i + " " + String(p).slice(0, 90));
          return orig(i, p);
        };
        var origCall = window.btsync.call.bind(window.btsync);
        window.btsync.call = function(m, a) {
          diag("THEIRCALL " + m);
          return origCall(m, a);
        };
        diag("WRAPPED onResponse/call");
      } else {
        diag("WRAP-SKIP no onResponse");
      }
      if (!window.jQuery || !window.app) { diag("LOADCHECK no jquery/app"); return; }
      diag("LOADCHECK btasync=" + typeof window.btasync +
           " callapi=" + (window.btasync ? typeof window.btasync.callapi : "-"));
      var orig = window.jQuery.ajax;
      window.jQuery.ajax = function(u, o) {
        var url = "?";
        try { url = typeof u === "string" ? u : (u && u.url) || "?"; } catch (e) {}
        diag("AJAX " + String(url).slice(0, 130));
        try {
          var r = orig.apply(this, arguments);
          try {
            if (r && r.fail) r.fail(function() { diag("AJAX-FAIL " + String(url).slice(0, 80)); });
            if (r && r.catch) r.catch(function(e) { diag("AJAX-REJECT " + String(url).slice(0, 80) + " " + e); });
          } catch (e) {}
          return r;
        } catch (e) {
          diag("AJAX-THROW " + String(url).slice(0, 80) + " " + e);
          throw e;
        }
      };
    } catch (e) { diag("LOADCHECK-ERR " + e); }
  });
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
