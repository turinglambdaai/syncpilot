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
// Calls flow over the custom "syncpilot-bridge://" URI scheme instead of a
// message channel: the injected object turns every call into a fetch, the
// UI process's scheme handler does the native work and finishes the
// request, and fetch's own promise is the reply channel.
//
// Loaded from <app>/webext next to the host binary; the directory is
// registered by the UI process before the first load (js_bridge.cpp).
#include <jsc/jsc.h>
#include <webkit/webkit-web-process-extension.h>

namespace {

// Defines window.btsync before any page script runs. Every call funnels
// through call(): the UI's wrapper keys on isWebKitWebView and uses exactly
// this shape (btsync.call("openpath", {path}) → promise). The direct method
// properties mirror the official surface for non-WebKit caller styles. A
// non-empty body starting with "!" is a native error and rejects; an empty
// body resolves null; anything else is JSON-encoded result text.
constexpr char kBridgeScript[] = R"JS((function() {
  function call(method, args) {
    return fetch("syncpilot-bridge://" + method, {
      method: "POST",
      body: JSON.stringify(args === undefined ? null : args)
    }).then(function(response) {
      return response.text();
    }).then(function(text) {
      if (text.charCodeAt(0) === 33 /* ! */) throw new Error(text.slice(1));
      return text === "" ? null : JSON.parse(text);
    });
  }
  var api = {parameter: null, call: call};
  ["openpath", "openurl", "shownotification", "showchoosefolderdialog",
   "showchoosefiledialog", "copytoclipboard", "opensyspreferences",
   "callapi", "getuifile", "setcallback"].forEach(function(name) {
    api[name] = function(args) { return call(name, args); };
  });
  api.get = function(key) { return call("get", {key: key}); };
  api.set = function(key, value) { return call("set", {key: key, value: value}); };
  window.btsync = api;
  fetch("syncpilot-bridge://__ready").catch(function() {});
})();)JS";

void on_window_object_cleared(WebKitScriptWorld* world, WebKitWebPage* page,
                              WebKitFrame* frame, gpointer user_data) {
  if (!webkit_frame_is_main_frame(frame)) return;
  JSCContext* context = webkit_frame_get_js_context(frame);
  jsc_context_evaluate(context, kBridgeScript, -1);
}

}  // namespace

extern "C" __attribute__((visibility("default"))) void
webkit_web_process_extension_initialize(WebKitWebProcessExtension* extension) {
  WebKitScriptWorld* world = webkit_script_world_get_default();
  g_signal_connect(world, "window-object-cleared",
                   G_CALLBACK(on_window_object_cleared), nullptr);
}
