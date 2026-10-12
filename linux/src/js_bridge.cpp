// Native side of the desktop JS bridge — see js_bridge.h for the contract.
//
// Every UI call arrives as one postMessage on the "btsync" channel carrying
// {id, method, args}; dispatch happens here and the reply resolves or
// rejects the JS-side promise by id. Signatures are WebKitGTK 6.0 (GTK4):
// script messages deliver a JSCValue, replies go back through
// webkit_web_view_evaluate_javascript in the default (page) world.
#ifdef HAVE_WEBKIT
#include "js_bridge.h"

#include <jsc/jsc.h>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>

namespace sp {
namespace {

WebKitWebView* g_view{nullptr};
GtkWindow* g_parent{nullptr};
GtkFileChooserNative* g_dialog{nullptr};  // one chooser at a time
gint g_dialog_call{0};                    // bridge call id awaiting the dialog
std::string g_callback_name;              // setcallback target (core events)

// The marker the official WebKit client puts in the user agent; app.js keys
// its isWebKitWebView flag (and therefore the btsync.call routing) on it.
constexpr char kUaMarker[] = " SyncWebKitWebView";

// Loopback-only injection: the bridge must exist for the proxied official UI
// and for nothing else the view might ever display.
constexpr char const* kAllowList[] = {"http://127.0.0.1*/*", "http://localhost*/*",
                                      "http://[::1]*/*", nullptr};

// Defines window.btsync before any page script runs. Everything routes
// through call(): the UI's wrapper keys on isWebKitWebView and uses exactly
// this shape (btsync.call("openpath", {path}) → promise). The direct method
// properties mirror the official surface for non-WebKit caller styles.
constexpr char kBridgeScript[] = R"JS((function() {
  if (window.btsync) return;
  var seq = 0;
  var pending = Object.create(null);
  window.__btsyncResolve = function(id, value) {
    var p = pending[id];
    if (p) { delete pending[id]; p.resolve(value); }
  };
  window.__btsyncReject = function(id, message) {
    var p = pending[id];
    if (p) { delete pending[id]; p.reject(new Error(message || "bridge error")); }
  };
  function call(method, args) {
    return new Promise(function(resolve, reject) {
      var id = ++seq;
      pending[id] = {resolve: resolve, reject: reject};
      try {
        window.webkit.messageHandlers.btsync.postMessage(
            JSON.stringify({id: id, method: method, args: (args === undefined ? null : args)}));
      } catch (e) {
        delete pending[id];
        reject(e);
      }
    });
  }
  window.btsync = {
    parameter: null,
    call: call,
    openpath: function(a) { return call("openpath", a); },
    openurl: function(a) { return call("openurl", a); },
    shownotification: function(a) { return call("shownotification", a); },
    showchoosefolderdialog: function(a) { return call("showchoosefolderdialog", a); },
    showchoosefiledialog: function(a) { return call("showchoosefiledialog", a); },
    copytoclipboard: function(a) { return call("copytoclipboard", a); },
    opensyspreferences: function(a) { return call("opensyspreferences", a); },
    callapi: function(a) { return call("callapi", a); },
    getuifile: function(a) { return call("getuifile", a); },
    setcallback: function(a) { return call("setcallback", a); },
    get: function(k) { return call("get", {key: k}); },
    set: function(k, v) { return call("set", {key: k, value: v}); }
  };
})();)JS";

std::string json_string(std::string const& s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof buf, "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  out += "\"";
  return out;
}

// Property read helpers. jsc_value_object_get_property transfers a full
// reference; every helper releases what it borrows before returning.

char* prop_string(JSCValue* args, char const* name) {
  if (args == nullptr || !jsc_value_is_object(args)) return nullptr;
  JSCValue* v = jsc_value_object_get_property(args, name);
  char* s = jsc_value_is_string(v) ? jsc_value_to_string(v) : nullptr;
  g_object_unref(v);
  return s;
}

bool prop_bool(JSCValue* args, char const* name) {
  if (args == nullptr || !jsc_value_is_object(args)) return false;
  JSCValue* v = jsc_value_object_get_property(args, name);
  bool const b = jsc_value_to_boolean(v);
  g_object_unref(v);
  return b;
}

void log_call(std::string const& method, JSCValue* args) {
  if (args != nullptr && jsc_value_is_object(args)) {
    char* json = jsc_value_to_json(args, 0);
    std::fprintf(stderr, "js-bridge: %s %s\n", method.c_str(),
                 json != nullptr ? json : "");
    g_free(json);
  } else {
    std::fprintf(stderr, "js-bridge: %s\n", method.c_str());
  }
}

void respond(gint id, std::string const& json_value) {
  if (g_view == nullptr) return;
  std::string js =
      "window.__btsyncResolve(" + std::to_string(id) + "," + json_value + ");";
  webkit_web_view_evaluate_javascript(g_view, js.c_str(),
                                      static_cast<gssize>(js.size()), nullptr,
                                      "syncpilot-btsync", nullptr, nullptr, nullptr);
}

void respond_error(gint id, std::string const& message) {
  if (g_view == nullptr) return;
  std::string js = "window.__btsyncReject(" + std::to_string(id) + "," +
                   json_string(message) + ");";
  webkit_web_view_evaluate_javascript(g_view, js.c_str(),
                                      static_cast<gssize>(js.size()), nullptr,
                                      "syncpilot-btsync", nullptr, nullptr, nullptr);
}

void on_choose_response(GtkNativeDialog* native, int response, gpointer) {
  gint const id = g_dialog_call;
  g_dialog_call = 0;
  g_dialog = nullptr;
  std::string json = "false";  // cancel: the UI resolves its defer with ""
  if (response == GTK_RESPONSE_ACCEPT) {
    GFile* f = gtk_file_chooser_get_file(GTK_FILE_CHOOSER(native));
    if (f != nullptr) {
      char* path = g_file_get_path(f);
      if (path != nullptr) json = json_string(path);
      g_free(path);
      g_object_unref(f);
    }
  }
  gtk_native_dialog_destroy(native);
  g_object_unref(native);
  respond(id, json);
}

bool open_path_in_file_manager(std::string const& path) {
  if (path.empty() || path.front() != '/') return false;
  if (!g_file_test(path.c_str(), G_FILE_TEST_EXISTS)) return false;
  GFile* f = g_file_new_for_path(path.c_str());
  char* uri = g_file_get_uri(f);
  g_object_unref(f);
  // GTK4's gtk_show_uri is void; a local file: URI on an existing path is
  // the strongest success signal available.
  gtk_show_uri(g_parent, uri, GDK_CURRENT_TIME);
  g_free(uri);
  return true;
}

void dispatch(gint id, std::string const& method, JSCValue* args) {
  if (method == "openpath") {
    char* path = prop_string(args, "path");
    bool const ok = path != nullptr && open_path_in_file_manager(path);
    g_free(path);
    respond(id, ok ? "true" : "false");
    return;
  }
  if (method == "openurl") {
    char* url = prop_string(args, "url");
    bool ok = false;
    if (url != nullptr) {
      char* scheme = g_uri_parse_scheme(url);
      if (scheme != nullptr &&
          (std::strcmp(scheme, "http") == 0 || std::strcmp(scheme, "https") == 0)) {
        gtk_show_uri(g_parent, url, GDK_CURRENT_TIME);
        ok = true;
      }
      g_free(scheme);
    }
    g_free(url);
    respond(id, ok ? "true" : "false");
    return;
  }
  if (method == "showchoosefolderdialog" || method == "showchoosefiledialog") {
    if (g_dialog != nullptr) {
      // One chooser at a time; report cancelled rather than queueing.
      respond(id, "false");
      return;
    }
    bool const folder = method == "showchoosefolderdialog";
    GtkFileChooserNative* chooser = gtk_file_chooser_native_new(
        nullptr, g_parent,
        folder ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_OPEN,
        nullptr, nullptr);
    gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(chooser), TRUE);
    g_dialog = chooser;
    g_dialog_call = id;
    g_signal_connect(chooser, "response", G_CALLBACK(on_choose_response), nullptr);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(chooser));
    return;
  }
  if (method == "shownotification") {
    char* title = prop_string(args, "title");
    char* message = prop_string(args, "message");
    GNotification* notification =
        g_notification_new(title != nullptr && *title != 0 ? title : "SyncPilot");
    if (message != nullptr && *message != 0) {
      g_notification_set_body(notification, message);
    }
    g_notification_set_icon(notification, G_ICON(g_themed_icon_new("syncpilot")));
    g_notification_set_default_action_and_target(notification, "app.present-main",
                                                 NULL);
    GtkWindow* parent = g_parent;
    GtkApplication* app =
        parent != nullptr ? gtk_window_get_application(parent) : nullptr;
    if (app != nullptr) {
      g_application_send_notification(G_APPLICATION(app), "syncpilot-ui",
                                      notification);
    }
    g_object_unref(notification);
    g_free(title);
    g_free(message);
    respond(id, app != nullptr ? "true" : "false");
    return;
  }
  if (method == "copytoclipboard") {
    char* text = prop_string(args, "text");
    if (text != nullptr) {
      GdkClipboard* clipboard =
          gdk_display_get_clipboard(gdk_display_get_default());
      gdk_clipboard_set_text(clipboard, text);
    }
    g_free(text);
    respond(id, text != nullptr ? "true" : "false");
    return;
  }
  if (method == "opensyspreferences") {
    // The official client opens OS preferences (pageid-numbered); there is
    // no portable Linux equivalent, so report unsupported. The UI treats a
    // falsy result the same way it treats a closed preferences pane.
    log_call(method, args);
    respond(id, "false");
    return;
  }
  if (method == "getuifile") {
    // UI override files, parity with the official client: resolve with the
    // contents when the override exists under
    // ~/.local/share/site.jrtx.syncpilot/uifiles/, otherwise reject — the
    // same outcome a missing file produces in the browser fallback
    // ($.ajax 404 → the caller's error path).
    char* path = prop_string(args, "path");
    bool served = false;
    if (path != nullptr && *path != 0 && path[0] != '/' &&
        std::string(path).find("..") == std::string::npos) {
      std::filesystem::path const full = std::filesystem::path(g_get_user_data_dir()) /
                                         "site.jrtx.syncpilot" / "uifiles" /
                                         std::filesystem::path(static_cast<char const*>(path));
      if (std::filesystem::is_regular_file(full)) {
        gchar* contents = nullptr;
        if (g_file_get_contents(full.c_str(), &contents, nullptr, nullptr)) {
          respond(id, json_string(contents));
          served = true;
          g_free(contents);
        }
      }
    }
    g_free(path);
    if (!served) respond_error(id, "file not found");
    return;
  }
  if (method == "setcallback") {
    // Registered now so the UI switches its long-poll transport to async;
    // we do not push core events into the JS callback yet.
    char* name = prop_string(args, "functionname");
    g_callback_name = name != nullptr ? name : "";
    g_free(name);
    respond(id, "true");
    return;
  }
  if (method == "get") {
    // Only "parameter" is queried (launch parameters; we have none).
    respond(id, "null");
    return;
  }
  if (method == "set") {
    // Only "debugtools" is set: toggle the WebKit inspector.
    if (prop_bool(args, "value")) {
      webkit_web_inspector_show(webkit_web_view_get_inspector(g_view));
    } else {
      webkit_web_inspector_close(webkit_web_view_get_inspector(g_view));
    }
    respond(id, "true");
    return;
  }
  if (method == "callapi") {
    // Generic desktop-client API surface; no entries are reachable in this
    // UI build, so answer with a benign null.
    log_call(method, args);
    respond(id, "null");
    return;
  }
  if (method == "__ready") {
    std::fprintf(stderr, "js-bridge: installed, page script alive\n");
    return;
  }
  log_call(method, args);
  respond(id, "null");
}

void on_script_message(WebKitUserContentManager*, JSCValue* value, gpointer) {
  if (value == nullptr || !jsc_value_is_object(value)) return;
  JSCValue* idv = jsc_value_object_get_property(value, "id");
  gint const id = jsc_value_is_number(idv) ? jsc_value_to_int32(idv) : 0;
  g_object_unref(idv);
  JSCValue* methodv = jsc_value_object_get_property(value, "method");
  char* method = jsc_value_is_string(methodv) ? jsc_value_to_string(methodv) : nullptr;
  g_object_unref(methodv);
  if (method == nullptr) return;
  JSCValue* argsv = jsc_value_object_get_property(value, "args");
  dispatch(id, method, jsc_value_is_undefined(argsv) || jsc_value_is_null(argsv) ? nullptr : argsv);
  g_object_unref(argsv);
  g_free(method);
}

}  // namespace

void install_js_bridge(WebKitWebView* web_view, GtkWindow* parent) {
  g_view = web_view;
  g_parent = parent;

  WebKitSettings* settings = webkit_web_view_get_settings(web_view);
  char const* ua = webkit_settings_get_user_agent(settings);
  std::string marked = std::string(ua != nullptr ? ua : "") + kUaMarker;
  webkit_settings_set_user_agent(settings, marked.c_str());
  webkit_settings_set_enable_developer_extras(settings, TRUE);

  WebKitUserContentManager* manager = webkit_web_view_get_user_content_manager(web_view);
  g_signal_connect(manager, "script-message-received::btsync",
                   G_CALLBACK(on_script_message), nullptr);
  if (!webkit_user_content_manager_register_script_message_handler(manager, "btsync",
                                                                   nullptr)) {
    std::fprintf(stderr, "js-bridge: failed to register the btsync channel\n");
    return;
  }
  WebKitUserScript* script = webkit_user_script_new(
      kBridgeScript, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
      WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, kAllowList, nullptr);
  webkit_user_content_manager_add_script(manager, script);
  webkit_user_script_unref(script);
}

}  // namespace sp
#endif  // HAVE_WEBKIT
