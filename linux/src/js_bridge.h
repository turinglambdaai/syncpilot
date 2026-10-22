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
// install_js_bridge wires the same contract onto our WebKitWebView: a web
// process extension (linux/webext) defines window.btsync in the page world
// at document start — UserContentManager scripts cannot (they miss the
// first document on WebKitGTK 2.52) — every call funnels through
// btsync.call(method, args) into the "syncpilot-bridge://" URI scheme, and
// this side does the native work and finishes each request.
#pragma once

#ifdef HAVE_WEBKIT
#include <gtk/gtk.h>
#include <webkit/webkit.h>

#include <string>

namespace sp {

// Call once, after the web view is created and before it loads anything:
// sets the user-agent marker, enables developer extras, and registers the
// bridge script and message handler.
void install_js_bridge(WebKitWebView* web_view, GtkWindow* parent);

// Call before the web view loads: the origin the embedded UI is served from
// (the proxy URL's scheme://host:port). The callapi bridge forwards the
// desktop-mode API traffic there.
void set_bridge_proxy_origin(std::string const& origin);

}  // namespace sp
#endif  // HAVE_WEBKIT
