// UI-process side of the desktop JS bridge — see js_bridge.h for the
// contract, and webext/syncpilot_extension.cpp for the page-side half.
//
// Every UI call arrives as a fetch to "syncpilot-bridge://<method>" whose
// body is the JSON-encoded args object; the scheme handler here does the
// native work and finishes the request — fetch's promise is the reply
// channel. Response bodies are JSON-encoded result text ("" → null); a
// body starting with "!" reports a native error and rejects the promise.
// Requests may legitimately stay pending for a long time (a modal folder
// chooser) and are answered when the native side resolves.
//
// Signatures are WebKitGTK 6.0 (GTK4).
#ifdef HAVE_WEBKIT
#include "js_bridge.h"

#include <jsc/jsc.h>
#include <json-glib/json-glib.h>
#include <libsoup/soup.h>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>

namespace sp {
namespace {

WebKitWebView* g_view{nullptr};
GtkWindow* g_parent{nullptr};
GtkFileChooserNative* g_dialog{nullptr};      // one chooser at a time
WebKitURISchemeRequest* g_dialog_request{nullptr};  // ref'd until answered
std::string g_callback_name;                  // setcallback target (core events)
SoupSession* g_soup{nullptr};                 // callapi transport, lazy
std::string g_proxy_origin;                   // scheme://host:port the UI is served from

// The marker the official WebKit client puts in the user agent; app.js keys
// its isWebKitWebView flag (and therefore the btsync.call routing) on it.
constexpr char kUaMarker[] = " SyncWebKitWebView";

constexpr char kScheme[] = "syncpilot-bridge";
constexpr gsize kMaximumBodyBytes = 1 << 20;

// ------------------------------------------------------------ body helpers

std::string read_body(WebKitURISchemeRequest* request) {
  GInputStream* body = webkit_uri_scheme_request_get_http_body(request);
  if (body == nullptr) return {};
  std::string out;
  char buffer[16384];
  while (out.size() < kMaximumBodyBytes) {
    gssize count = g_input_stream_read(body, buffer, sizeof buffer, nullptr, nullptr);
    if (count <= 0) break;
    out.append(buffer, static_cast<size_t>(count));
  }
  return out;
}

void finish_text(WebKitURISchemeRequest* request, std::string const& text) {
  GBytes* bytes = g_bytes_new(text.data(), text.size());
  GInputStream* stream = g_memory_input_stream_new_from_bytes(bytes);
  webkit_uri_scheme_request_finish(request, stream, static_cast<gint64>(text.size()),
                                   "text/plain");
  g_object_unref(stream);
  g_bytes_unref(bytes);
}

void finish_result(WebKitURISchemeRequest* request, std::string const& json_value) {
  finish_text(request, json_value);
}

void finish_error(WebKitURISchemeRequest* request, std::string const& message) {
  finish_text(request, "!" + message);
}

// JSON text for a string result, with quotes and escapes.
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

// --------------------------------------------------------- args extraction

JsonObject* args_object(std::string const& body) {
  if (body.empty()) return nullptr;
  JsonParser* parser = json_parser_new();
  if (!json_parser_load_from_data(parser, body.data(),
                                  static_cast<gssize>(body.size()), nullptr)) {
    g_object_unref(parser);
    return nullptr;
  }
  // The parser object keeps the node tree alive; leak it deliberately —
  // one small tree per bridge call, cheaper than wiring ownership through
  // every handler.
  JsonNode* root = json_parser_get_root(parser);
  if (root == nullptr || !JSON_NODE_HOLDS_OBJECT(root)) return nullptr;
  return json_node_get_object(root);
}

bool args_string(JsonObject* args, char const* name, std::string* out) {
  if (args == nullptr || !json_object_has_member(args, name)) return false;
  JsonNode* node = json_object_get_member(args, name);
  if (node == nullptr || !JSON_NODE_HOLDS_VALUE(node)) return false;
  GValue value = G_VALUE_INIT;
  json_node_get_value(node, &value);
  bool const ok = G_VALUE_HOLDS_STRING(&value);
  if (ok) *out = g_value_get_string(&value);
  g_value_unset(&value);
  return ok;
}

// -------------------------------------------------------- native dispatch

void log_call(std::string const& method, std::string const& body) {
  if (body.empty()) {
    std::fprintf(stderr, "js-bridge: %s\n", method.c_str());
  } else {
    std::fprintf(stderr, "js-bridge: %s %s\n", method.c_str(), body.c_str());
  }
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

void on_choose_response(GtkNativeDialog* native, int response, gpointer) {
  WebKitURISchemeRequest* request = g_dialog_request;
  g_dialog_request = nullptr;
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
  if (request != nullptr) {
    finish_result(request, json);
    g_object_unref(request);  // our keep-alive reference
  }
}

// --------------------------------------------------- callapi forwarding

// Desktop-mode API transport. The UI's jQuery.ajax override routes every
// /gui/ and /api/ request through btsync.call("callapi", {type, action,
// params, async}) — in desktop mode the daemon's HTTP API never sees webview
// traffic (a stub answer here blanks the whole interface). We forward to the
// daemon via the proxy (which injects the WebUI credentials) and answer with
// the response body wrapped as a JSON string: the page JSON.parse()s the
// result once more before looking at it. Failures answer as
// {"error": "..."} instead of rejecting — a rejected promise makes the UI's
// request wrapper dereference a missing result and drop the request.
//
// Every request this UI build makes passes a falsy async flag and expects
// the full response from the call — the core-events long poll (action=
// events, ~30s) included, which is why the session sets no timeout. The
// apiRequestQueue/callback channel for async:true calls is unused here and
// unimplemented.
struct CallapiJob {
  WebKitURISchemeRequest* request;  // our keep-alive reference
  SoupMessage* message;
};

void on_callapi_sent(GObject* session, GAsyncResult* result, gpointer user_data) {
  auto* job = static_cast<CallapiJob*>(user_data);
  GError* error = nullptr;
  GInputStream* stream =
      soup_session_send_finish(SOUP_SESSION(session), result, &error);
  std::string body;
  bool sent = false;
  if (stream != nullptr) {
    GOutputStream* out = g_memory_output_stream_new_resizable();
    GError* splice = nullptr;
    g_output_stream_splice(
        out, stream,
        static_cast<GOutputStreamSpliceFlags>(G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE |
                                              G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET),
        nullptr, &splice);
    if (splice == nullptr) {
      body.assign(
          static_cast<gchar*>(g_memory_output_stream_get_data(
              G_MEMORY_OUTPUT_STREAM(out))),
          g_memory_output_stream_get_data_size(G_MEMORY_OUTPUT_STREAM(out)));
      sent = true;
    } else {
      g_error_free(splice);
    }
    g_object_unref(out);
  }
  if (sent) {
    guint const status = soup_message_get_status(job->message);
    if (status < 200 || status >= 300) {
      body = "{\"error\":\"HTTP " + std::to_string(status) + " from the daemon\"}";
    }
    finish_result(job->request, json_string(body));
  } else {
    std::string const detail =
        error != nullptr ? error->message : "no response from the daemon";
    finish_result(job->request, "{\"error\":" + json_string(detail) + "}");
  }
  if (error != nullptr) g_error_free(error);
  if (stream != nullptr) g_object_unref(stream);
  g_object_unref(job->message);
  g_object_unref(job->request);  // our keep-alive reference
  delete job;
}

// Returns false when the forwarding plumbing is not up; the caller answers
// with the legacy benign stub so the UI keeps its web-fallback behavior.
bool dispatch_callapi(WebKitURISchemeRequest* request, JsonObject* args) {
  if (g_proxy_origin.empty() || g_view == nullptr) return false;
  if (g_soup == nullptr) g_soup = soup_session_new();

  std::string type = "GET";
  std::string action;
  std::string params;
  args_string(args, "type", &type);
  args_string(args, "action", &action);
  args_string(args, "params", &params);

  std::string url = g_proxy_origin + "/gui/?action=" + action;
  if (type != "POST" && !params.empty()) url += "&" + params;
  SoupMessage* message =
      soup_message_new(type == "POST" ? "POST" : "GET", url.c_str());
  if (message == nullptr) return false;
  if (type == "POST" && !params.empty()) {
    GBytes* payload = g_bytes_new(params.data(), params.size());
    soup_message_set_request_body_from_bytes(message, "application/json", payload);
    g_bytes_unref(payload);
  }

  auto* job = new CallapiJob{request, message};
  g_object_ref(request);  // answered later in on_callapi_sent
  soup_session_send_async(g_soup, message, G_PRIORITY_DEFAULT, nullptr,
                          on_callapi_sent, job);
  return true;
}

void dispatch(WebKitURISchemeRequest* request, std::string const& method,
              JsonObject* args, std::string const& body) {
  if (method == "openpath") {
    std::string path;
    bool const ok = args_string(args, "path", &path) &&
                    open_path_in_file_manager(path);
    finish_result(request, ok ? "true" : "false");
    return;
  }
  if (method == "openurl") {
    std::string url;
    bool ok = false;
    if (args_string(args, "url", &url)) {
      char* scheme = g_uri_parse_scheme(url.c_str());
      if (scheme != nullptr &&
          (std::strcmp(scheme, "http") == 0 || std::strcmp(scheme, "https") == 0)) {
        gtk_show_uri(g_parent, url.c_str(), GDK_CURRENT_TIME);
        ok = true;
      }
      g_free(scheme);
    }
    finish_result(request, ok ? "true" : "false");
    return;
  }
  if (method == "showchoosefolderdialog" || method == "showchoosefiledialog") {
    if (g_dialog != nullptr) {
      // One chooser at a time; report cancelled rather than queueing.
      finish_result(request, "false");
      return;
    }
    bool const folder = method == "showchoosefolderdialog";
    GtkFileChooserNative* chooser = gtk_file_chooser_native_new(
        nullptr, g_parent,
        folder ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_OPEN,
        nullptr, nullptr);
    gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(chooser), TRUE);
    g_dialog = chooser;
    // Keep the request alive for as long as the dialog takes; answered in
    // on_choose_response.
    g_dialog_request = WEBKIT_URI_SCHEME_REQUEST(g_object_ref(request));
    g_signal_connect(chooser, "response", G_CALLBACK(on_choose_response), nullptr);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(chooser));
    return;
  }
  if (method == "shownotification") {
    std::string title;
    std::string message;
    bool const has_title = args_string(args, "title", &title);
    bool const has_message = args_string(args, "message", &message);
    GNotification* notification =
        g_notification_new(has_title && !title.empty() ? title.c_str() : "SyncPilot");
    if (has_message && !message.empty()) {
      g_notification_set_body(notification, message.c_str());
    }
    g_notification_set_icon(notification, G_ICON(g_themed_icon_new("syncpilot")));
    g_notification_set_default_action_and_target(notification, "app.present-main",
                                                 NULL);
    GtkApplication* app =
        g_parent != nullptr ? gtk_window_get_application(g_parent) : nullptr;
    if (app != nullptr) {
      g_application_send_notification(G_APPLICATION(app), "syncpilot-ui",
                                      notification);
    }
    g_object_unref(notification);
    finish_result(request, app != nullptr ? "true" : "false");
    return;
  }
  if (method == "copytoclipboard") {
    std::string text;
    bool const ok = args_string(args, "text", &text);
    if (ok) {
      GdkClipboard* clipboard =
          gdk_display_get_clipboard(gdk_display_get_default());
      gdk_clipboard_set_text(clipboard, text.c_str());
    }
    finish_result(request, ok ? "true" : "false");
    return;
  }
  if (method == "opensyspreferences") {
    // The official client opens OS preferences (pageid-numbered); there is
    // no portable Linux equivalent, so report unsupported. The UI treats a
    // falsy result the same way it treats a closed preferences pane.
    log_call(method, body);
    finish_result(request, "false");
    return;
  }
  if (method == "getuifile") {
    // UI override files, parity with the official client: resolve with the
    // contents when the override exists under
    // ~/.local/share/site.jrtx.syncpilot/uifiles/, otherwise reject — the
    // same outcome a missing file produces in the browser fallback
    // ($.ajax 404 → the caller's error path).
    std::string path;
    bool served = false;
    if (args_string(args, "path", &path) && !path.empty() && path.front() != '/' &&
        path.find("..") == std::string::npos) {
      std::filesystem::path const full =
          std::filesystem::path(g_get_user_data_dir()) / "site.jrtx.syncpilot" /
          "uifiles" / std::filesystem::path(path);
      if (std::filesystem::is_regular_file(full)) {
        gchar* contents = nullptr;
        if (g_file_get_contents(full.c_str(), &contents, nullptr, nullptr)) {
          finish_result(request, json_string(contents));
          served = true;
          g_free(contents);
        }
      }
    }
    if (!served) finish_error(request, "file not found");
    return;
  }
  if (method == "setcallback") {
    // Registered now so the UI switches its long-poll transport to async;
    // we do not push core events into the JS callback yet.
    std::string name;
    if (args_string(args, "functionname", &name)) g_callback_name = name;
    finish_result(request, "true");
    return;
  }
  if (method == "get") {
    // Only "parameter" is queried (launch parameters; we have none).
    finish_result(request, "null");
    return;
  }
  if (method == "set") {
    // Only "debugtools" is set: toggle the WebKit inspector.
    std::string key;
    if (args_string(args, "key", &key) && key == "debugtools") {
      bool const enable = args != nullptr && json_object_has_member(args, "value") &&
                          json_node_get_boolean(json_object_get_member(args, "value"));
      if (enable) {
        webkit_web_inspector_show(webkit_web_view_get_inspector(g_view));
      } else {
        webkit_web_inspector_close(webkit_web_view_get_inspector(g_view));
      }
    }
    finish_result(request, "true");
    return;
  }
  if (method == "callapi") {
    // Desktop-mode API surface — the UI's only data path (see the forwarding
    // notes above dispatch).
    log_call(method, body);
    if (!dispatch_callapi(request, args)) {
      finish_result(request, "null");
    }
    return;
  }
  if (method == "__ready") {
    std::fprintf(stderr, "js-bridge: installed, page script alive\n");
    finish_text(request, "");
    return;
  }
  log_call(method, body);
  finish_result(request, "null");
}

void on_scheme_request(WebKitURISchemeRequest* request, gpointer) {
  char const* uri = webkit_uri_scheme_request_get_uri(request);
  char* host = nullptr;
  // The method rides in the URI host: syncpilot-bridge://openpath
  g_uri_split_network(uri, G_URI_FLAGS_NONE, nullptr, &host, nullptr, nullptr);
  std::string const method = host != nullptr ? host : "";
  g_free(host);

  std::string const body = read_body(request);
  if (g_view == nullptr || g_parent == nullptr) {
    finish_error(request, "bridge not ready");
    return;
  }
  dispatch(request, method, args_object(body), body);
}

}  // namespace

void set_bridge_proxy_origin(std::string const& origin) { g_proxy_origin = origin; }

void install_js_bridge(WebKitWebView* web_view, GtkWindow* parent) {
  g_view = web_view;
  g_parent = parent;

  WebKitSettings* settings = webkit_web_view_get_settings(web_view);
  char const* ua = webkit_settings_get_user_agent(settings);
  std::string marked = std::string(ua != nullptr ? ua : "") + kUaMarker;
  webkit_settings_set_user_agent(settings, marked.c_str());
  webkit_settings_set_enable_developer_extras(settings, TRUE);

  WebKitWebContext* context = webkit_web_context_get_default();
  // The extension defines window.btsync in the page world; it must be
  // registered before the web process spawns, i.e. before the first load.
  std::filesystem::path const extensions_dir =
      std::filesystem::read_symlink("/proc/self/exe").parent_path() / "app" / "webext";
  webkit_web_context_set_web_process_extensions_directory(
      context, extensions_dir.c_str());
  static bool scheme_registered = false;
  if (!scheme_registered) {
    webkit_web_context_register_uri_scheme(context, kScheme, on_scheme_request,
                                           nullptr, nullptr);
    scheme_registered = true;
  }
}

}  // namespace sp
#endif  // HAVE_WEBKIT
