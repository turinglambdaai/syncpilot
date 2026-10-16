// UI-process side of the desktop JS bridge — see js_bridge.h for the
// contract, and webext/syncpilot_extension.cpp for the page-side half.
//
// Every UI call arrives as window.webkit.messageHandlers.btsync.postMessage
// with a JSON body {id, method, args}; the message handler here does the
// native work and answers by evaluating __btsyncResolve(id, is_error,
// json_payload) back in the page — the call's promise is the reply channel.
// An is_error reply rejects with the payload as the message; an empty
// payload resolves null; anything else is JSON-encoded result text.
// Replies may legitimately stay pending for a long time (a modal folder
// chooser) and are delivered when the native side resolves.
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
GtkFileChooserNative* g_dialog{nullptr};  // one chooser at a time
unsigned long g_dialog_id{0};             // the call awaiting the chooser
std::string g_callback_name;              // setcallback target (core events)
SoupSession* g_soup{nullptr};                 // callapi transport, lazy
std::string g_proxy_origin;                   // scheme://host:port the UI is served from
std::string g_webui_token;                    // token.html credential for forwarded calls

// The marker the official WebKit client puts in the user agent; app.js keys
// its isWebKitWebView flag (and therefore the btsync.call routing) on it.
constexpr char kUaMarker[] = " SyncWebKitWebView";

// ------------------------------------------------------------ body helpers

// JSON text for a string result, with quotes and escapes (defined below).
std::string json_string(std::string const& s);

// Answer the call `index` by invoking the resolver the UI parked in
// window.btsync.cache[index] (sendTheMessage's fallback when postMessage
// returns no promise). `json_value` is a JSON literal: the resolver
// receives the decoded value (true, an object, a string — whatever the
// caller passed). The callapi path passes json_string(body) so the UI
// gets the body text it JSON.parse()s once more.
void respond_result(unsigned long id, std::string const& json_value) {
  if (g_view == nullptr) return;
  std::string script = "(window.btsync.cache[" + std::to_string(id) +
                       "]||function(){})( " + json_value +
                       ");delete window.btsync.cache[" + std::to_string(id) +
                       "];";
  webkit_web_view_evaluate_javascript(g_view, script.c_str(),
                                      static_cast<gssize>(script.size()),
                                      nullptr, nullptr, nullptr, nullptr,
                                      nullptr);
}

// Transport/native failures surface as a resolved JSON text carrying the
// error — the caller JSON.parse()s it into {\"error\": …}, the shape the
// request wrapper's `.error` check expects. Rejecting instead would crash
// that wrapper on its missing result (observed as a fully blank
// interface).
void respond_error(unsigned long id, std::string const& message) {
  respond_result(id, json_string("{\"error\":" + json_string(message) + "}"));
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

// Parse a JSON object body; the parser object is leaked deliberately — one
// small tree per bridge call, cheaper than wiring ownership through every
// handler.
JsonObject* args_object(std::string const& body) {
  if (body.empty()) return nullptr;
  JsonParser* parser = json_parser_new();
  if (!json_parser_load_from_data(parser, body.data(),
                                  static_cast<gssize>(body.size()), nullptr)) {
    g_object_unref(parser);
    return nullptr;
  }
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
  unsigned long id = g_dialog_id;
  g_dialog_id = 0;
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
  if (id != 0) respond_result(id, json);
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
  unsigned long id;      // the call awaiting the daemon's answer
  std::string type;      // GET / POST
  std::string action;
  std::string params;
  bool retried;          // already re-bootstrapped the token once
  SoupMessage* message{nullptr};
};

void start_api_call(CallapiJob* job);
void on_callapi_sent(GObject* session, GAsyncResult* result, gpointer user_data);

// The daemon gates /gui/ API actions on a WebUI token issued by
// /gui/token.html plus the GUID cookie that rides the same session (the
// web flow gets both through requestToken; desktop mode must provide them
// itself). One session keeps the cookie jar; the token is fetched lazily
// on the first call and refreshed whenever the daemon answers 400.
void start_api_call(CallapiJob* job);
void on_callapi_sent(GObject* session, GAsyncResult* result, gpointer user_data);

void on_token_sent(GObject* session, GAsyncResult* result, gpointer user_data) {
  auto* job = static_cast<CallapiJob*>(user_data);
  GError* error = nullptr;
  GInputStream* stream =
      soup_session_send_finish(SOUP_SESSION(session), result, &error);
  std::string body;
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
    } else {
      g_error_free(splice);
    }
    g_object_unref(out);
  }
  if (error != nullptr) g_error_free(error);
  if (stream != nullptr) g_object_unref(stream);

  // <html><div id='token' style='display:none;'>TOKEN</div></html>
  std::size_t const begin = body.find("'>");
  std::size_t const end = body.find("</div>", begin == std::string::npos ? 0 : begin);
  if (begin != std::string::npos && end != std::string::npos && end > begin) {
    g_webui_token = body.substr(begin + 2, end - begin - 2);
  }
  start_api_call(job);
}

void start_token_bootstrap(CallapiJob* job) {
  SoupMessage* message =
      soup_message_new("POST", (g_proxy_origin + "/gui/token.html").c_str());
  soup_session_send_async(g_soup, message, G_PRIORITY_DEFAULT, nullptr,
                          on_token_sent, job);
}

void start_api_call(CallapiJob* job) {
  std::string url = g_proxy_origin + "/gui/?token=" + g_webui_token +
                    "&action=" + job->action;
  if (job->type != "POST" && !job->params.empty()) url += "&" + job->params;
  SoupMessage* message =
      soup_message_new(job->type == "POST" ? "POST" : "GET", url.c_str());
  if (message == nullptr) {
    respond_error(job->id, "bad callapi target");
    delete job;
    return;
  }
  if (job->type == "POST" && !job->params.empty()) {
    GBytes* payload = g_bytes_new(job->params.data(), job->params.size());
    soup_message_set_request_body_from_bytes(message, "application/json", payload);
    g_bytes_unref(payload);
  }
  job->message = message;
  soup_session_send_async(g_soup, message, G_PRIORITY_DEFAULT, nullptr,
                          on_callapi_sent, job);
}

void on_callapi_sent(GObject* session, GAsyncResult* result, gpointer user_data) {
  auto* job = static_cast<CallapiJob*>(user_data);
  GError* error = nullptr;
  GInputStream* stream =
      soup_session_send_finish(SOUP_SESSION(session), result, &error);
  std::string body;
  bool sent = false;
  guint status = 0;
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
      status = soup_message_get_status(job->message);
    } else {
      g_error_free(splice);
    }
    g_object_unref(out);
  }
  if (sent && status == 400 && !job->retried) {
    // The WebUI token went stale (token.html rotates them): fetch a fresh
    // one and retry this call once before giving up.
    g_webui_token.clear();
    job->retried = true;
    start_token_bootstrap(job);
    g_object_unref(job->message);
    return;
  }
  if (sent) {
    if (status < 200 || status >= 300) {
      body = "{\"error\":\"HTTP " + std::to_string(status) + " from the daemon\"}";
    }
    respond_result(job->id, json_string(body));
  } else {
    std::string const detail =
        error != nullptr ? error->message : "no response from the daemon";
    respond_result(job->id, "{\"error\":" + json_string(detail) + "}");
  }
  if (error != nullptr) g_error_free(error);
  if (stream != nullptr) g_object_unref(stream);
  g_object_unref(job->message);
  delete job;
}

// Returns false when the forwarding plumbing is not up; the caller answers
// with the legacy benign stub so the UI keeps its web-fallback behavior.
bool dispatch_callapi(unsigned long id, JsonObject* args) {
  if (g_proxy_origin.empty() || g_view == nullptr) return false;
  if (g_soup == nullptr) {
    g_soup = soup_session_new();
    // The GUID cookie gates API actions and rotates with responses; the jar
    // keeps it in sync the way a browser would.
    soup_session_add_feature(g_soup,
                             SOUP_SESSION_FEATURE(soup_cookie_jar_new()));
  }

  auto* job = new CallapiJob{id, "GET", "", "", false};
  args_string(args, "type", &job->type);
  args_string(args, "action", &job->action);
  args_string(args, "params", &job->params);

  if (g_webui_token.empty()) {
    start_token_bootstrap(job);
  } else {
    start_api_call(job);
  }
  return true;
}

void dispatch_call(unsigned long id, std::string const& method,
                   JsonObject* args, std::string const& body) {
  if (method == "openpath") {
    std::string path;
    bool const ok = args_string(args, "path", &path) &&
                    open_path_in_file_manager(path);
    respond_result(id, ok ? "true" : "false");
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
    respond_result(id, ok ? "true" : "false");
    return;
  }
  if (method == "showchoosefolderdialog" || method == "showchoosefiledialog") {
    if (g_dialog != nullptr) {
      // One chooser at a time; report cancelled rather than queueing.
      respond_result(id, "false");
      return;
    }
    bool const folder = method == "showchoosefolderdialog";
    GtkFileChooserNative* chooser = gtk_file_chooser_native_new(
        nullptr, g_parent,
        folder ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_OPEN,
        nullptr, nullptr);
    gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(chooser), TRUE);
    g_dialog = chooser;
    // Answered whenever the dialog closes; see on_choose_response.
    g_dialog_id = id;
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
    respond_result(id, app != nullptr ? "true" : "false");
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
    respond_result(id, ok ? "true" : "false");
    return;
  }
  if (method == "opensyspreferences") {
    // The official client opens OS preferences (pageid-numbered); there is
    // no portable Linux equivalent, so report unsupported. The UI treats a
    // falsy result the same way it treats a closed preferences pane.
    log_call(method, body);
    respond_result(id, "false");
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
          respond_result(id, json_string(contents));
          served = true;
          g_free(contents);
        }
      }
    }
    if (!served) respond_error(id, "file not found");
    return;
  }
  if (method == "setcallback") {
    // Registered now so the UI switches its long-poll transport to async;
    // we do not push core events into the JS callback yet.
    std::string name;
    if (args_string(args, "functionname", &name)) g_callback_name = name;
    respond_result(id, "true");
    return;
  }
  if (method == "get") {
    // Only "parameter" is queried (launch parameters; we have none).
    respond_result(id, "null");
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
    respond_result(id, "true");
    return;
  }
  if (method == "callapi") {
    // Desktop-mode API surface — the UI's only data path (see the forwarding
    // notes above dispatch).
    log_call(method, body);
    if (!dispatch_callapi(id, args)) {
      respond_result(id, "null");
    }
    return;
  }
  if (method == "__ready") {
    std::fprintf(stderr, "js-bridge: installed, page script alive\n");
    respond_result(id, "");
    return;
  }
  log_call(method, body);
  respond_result(id, "null");
}

// Entry point for window.webkit.messageHandlers.jsToNativeHandler
// .postMessage. The UI's sendTheMessage passes a plain JS object
// {m: method, args, i: index, t} — read the properties through JSC
// directly; a JSON string form is accepted too for the bridge's own
// bootstrap call.
void on_bridge_message(WebKitUserContentManager* manager, JSCValue* value,
                       gpointer) {
  (void)manager;
  if (value == nullptr) return;

  unsigned long id = 0;
  std::string method;
  std::string body;
  JsonObject* args = nullptr;

  if (jsc_value_is_string(value)) {
    char* body_cstr = jsc_value_to_string(value);
    body = body_cstr != nullptr ? body_cstr : "";
    g_free(body_cstr);
    // The parser object keeps the node tree alive for the handler's
    // duration; one small tree per call, cheaper than wiring ownership
    // through dispatch_call.
    JsonParser* parser = json_parser_new();
    JsonObject* message = nullptr;
    if (json_parser_load_from_data(parser, body.data(),
                                   static_cast<gssize>(body.size()), nullptr)) {
      JsonNode* root = json_parser_get_root(parser);
      if (root != nullptr && JSON_NODE_HOLDS_OBJECT(root)) {
        message = json_node_get_object(root);
      }
    }
    if (message == nullptr) return;
    if (json_object_has_member(message, "i")) {
      JsonNode* n = json_object_get_member(message, "i");
      if (n != nullptr && JSON_NODE_HOLDS_VALUE(n)) {
        GValue v = G_VALUE_INIT;
        json_node_get_value(n, &v);
        if (G_VALUE_HOLDS_INT64(&v)) id = static_cast<unsigned long>(g_value_get_int64(&v));
        else if (G_VALUE_HOLDS_DOUBLE(&v)) id = static_cast<unsigned long>(g_value_get_double(&v));
        g_value_unset(&v);
      }
    }
    if (json_object_has_member(message, "m")) {
      JsonNode* n = json_object_get_member(message, "m");
      if (n != nullptr && JSON_NODE_HOLDS_VALUE(n)) {
        GValue v = G_VALUE_INIT;
        json_node_get_value(n, &v);
        if (G_VALUE_HOLDS_STRING(&v)) method = g_value_get_string(&v);
        g_value_unset(&v);
      }
    }
    if (json_object_has_member(message, "args") &&
        JSON_NODE_HOLDS_OBJECT(json_object_get_member(message, "args"))) {
      args = json_object_get_object_member(message, "args");
    }
  } else if (jsc_value_is_object(value)) {
    JSCValue* m_val = jsc_value_object_get_property(value, "m");
    if (m_val != nullptr && jsc_value_is_string(m_val)) {
      char* mc = jsc_value_to_string(m_val);
      method = mc != nullptr ? mc : "";
      g_free(mc);
    }
    JSCValue* i_val = jsc_value_object_get_property(value, "i");
    if (i_val != nullptr && jsc_value_is_number(i_val)) {
      id = static_cast<unsigned long>(jsc_value_to_int32(i_val));
    }
    JSCValue* a_val = jsc_value_object_get_property(value, "args");
    if (a_val != nullptr && jsc_value_is_object(a_val)) {
      char* json = jsc_value_to_json(a_val, 0);
      if (json != nullptr) {
        body = json;
        args = args_object(body);  // parser leaked deliberately (see above)
        g_free(json);
      }
    }
  } else {
    return;
  }

  if (g_view == nullptr || g_parent == nullptr) {
    respond_error(id, "bridge not ready");
    return;
  }
  dispatch_call(id, method, args, body);
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

  // The call channel: the page's postMessage lands here, answers go back by
  // evaluating __btsyncResolve. Default world — that is where the extension
  // defines the bridge object. Connect before registering so no early call
  // races the signal.
  WebKitUserContentManager* manager =
      webkit_web_view_get_user_content_manager(web_view);
  g_signal_connect(manager, "script-message-received::jsToNativeHandler",
                   G_CALLBACK(on_bridge_message), nullptr);
  gboolean registered = webkit_user_content_manager_register_script_message_handler(
      manager, "jsToNativeHandler", nullptr);
  std::fprintf(stderr, "js-bridge: jsToNativeHandler registered: %s\n",
               registered ? "yes" : "NO");
}

}  // namespace sp
#endif  // HAVE_WEBKIT
