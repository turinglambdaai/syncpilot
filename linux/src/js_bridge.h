// Desktop JS bridge for the embedded Resilio Web UI.
//
// The official UI gates every desktop integration on a global `window.btsync`
// object that the official client injects into its embedded web view:
//   window.app.isDesktop = !_.isUndefined(window.btsync)
// and its WebKit code path additionally requires the "SyncWebKitWebView"
// user-agent marker before routing calls through the bridge. With the bridge
// absent the UI falls back to web-only behavior — double-clicking a synced
// folder opens an explanation dialog instead of the folder itself, adding a
// folder uses the HTML picker, and notifications stay in-page.
//
// install_js_bridge wires the same contract onto our WebKitWebView: a
// document-start user script defines window.btsync, every call funnels
// through btsync.call(method, args) into a script message handler, and the
// native side answers by resolving the JS-side promise.
#pragma once

#ifdef HAVE_WEBKIT
#include <gtk/gtk.h>
#include <webkit/webkit.h>

namespace sp {

// Call once, after the web view is created and before it loads anything:
// sets the user-agent marker, enables developer extras, and registers the
// bridge script and message handler.
void install_js_bridge(WebKitWebView* web_view, GtkWindow* parent);

}  // namespace sp
#endif  // HAVE_WEBKIT
