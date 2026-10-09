// SyncPilot Linux host — a GTK4 window over one embedded Racket CS backend.
//
// The window has two states (parity with the Tauri v0.4.0 product):
//   1. BOOT PAGE: a centered card that starts the daemon through the backend
//      (initialize → get-handoff) and either hands the window over to the
//      official Resilio Web UI or shows a specific failure with actions
//      (retry / install rslsync from the CDN / open settings).
//   2. WEB VIEW: a WebKitWebView on the auth-injecting proxy URL. The Racket
//      backend injects basic auth, so the web view needs no credentials.
//
// Threading mirrors the Rivet scaffold: the runtime boots off the main
// thread; every RPC completion and backend event is dispatched back through
// g_idle_add before touching widgets (see dispatch.h). The daemon's phase is
// surfaced via the daemon-changed event: crashed/failed flip back to the
// boot page, other non-running phases show a thin top banner.
#include <gtk/gtk.h>

#ifdef HAVE_WEBKIT
#if defined(__has_include)
#if __has_include(<webkit/webkit.h>)
#include <webkit/webkit.h>
#elif __has_include(<webkitgtk-6.0/webkit/webkit.h>)
#include <webkitgtk-6.0/webkit/webkit.h>
#elif __has_include(<WebKit/WebKit.h>)
#include <WebKit/WebKit.h>
#else
#error "HAVE_WEBKIT is set but the WebKitGTK 6.0 headers were not found"
#endif
#endif
#endif

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "GeneratedBackend.hpp"
#include "GeneratedStrings.h"
#include "dispatch.h"
#include "settings_window.h"
#include "system_services.hpp"  // rivet::system — single-instance lease
#include "toast.h"
#include "update_flow.h"

namespace {

enum class UiState { Boot, Web };

struct AppState {
  GtkApplication* app{nullptr};
  GtkWindow* window{nullptr};
  GtkOverlay* overlay{nullptr};
  GtkStack* stack{nullptr};

  // Boot page widgets (rebuilt in place; the stack slot is stable).
  GtkLabel* boot_status{nullptr};
  GtkLabel* boot_detail{nullptr};
  GtkBox* boot_actions{nullptr};

  // Thin top banner shown over the web view while phase != running.
  GtkRevealer* banner{nullptr};
  GtkLabel* banner_label{nullptr};

#ifdef HAVE_WEBKIT
  WebKitWebView* web_view{nullptr};
#endif

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;

  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};

  UiState state{UiState::Boot};
  std::optional<rivet_app::DaemonStatus> last_status;
  std::string proxy_url;  // last handoff URL (opens in a browser without webkit)
  std::string executable;

  // The silent update auto-check runs once per process, after the first
  // successful handoff; the backend throttles repeat checks to daily.
  bool update_auto_check_done{false};

  // Tray presence and the close-to-tray behavior it enables. The tray lives
  // on the main context; hidden-window keep-alive mirrors the official
  // clients (close leaves the app running, tray Open is the way back).
  std::unique_ptr<rivet::system::TrayIcon> tray;
  bool close_to_tray{true};
};

AppState g_state;

// ------------------------------------------------------------ forward decls

void start_handoff();
void request_handoff();
void show_boot_page();
void show_retry_card(std::string const& error);
void show_install_card(std::string const& hint_text);
#ifdef HAVE_WEBKIT
void enter_web_view(std::string const& url);
#endif
void update_banner();

// ------------------------------------------------------------------ helpers

std::string executable_path() {
  try {
    return std::filesystem::read_symlink("/proc/self/exe").string();
  } catch (...) {
    return {};
  }
}

// Rivet keeps runtime/res beside the executable in development and packages.
struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  std::filesystem::path const exe = executable_path();
  if (exe.empty()) return std::nullopt;
  std::filesystem::path const root = exe.parent_path();
  RuntimeLayout layout{
      root / "runtime" / "petite.boot",
      root / "runtime" / "scheme.boot",
      root / "runtime" / "racket.boot",
      root / "res" / "core.zo",
  };
  if (std::filesystem::exists(layout.petite_boot) &&
      std::filesystem::exists(layout.scheme_boot) &&
      std::filesystem::exists(layout.racket_boot) &&
      std::filesystem::exists(layout.core)) {
    return layout;
  }
  return std::nullopt;
}

char const* phase_name(rivet_app::DaemonPhase phase) {
  switch (phase) {
    case rivet_app::DaemonPhase::stopped:
      return "stopped";
    case rivet_app::DaemonPhase::starting:
      return "starting";
    case rivet_app::DaemonPhase::running:
      return "running";
    case rivet_app::DaemonPhase::crashed:
      return "crashed";
    case rivet_app::DaemonPhase::failed:
      return "failed";
  }
  return "stopped";
}

std::string phase_label(rivet_app::DaemonPhase phase) {
  return l10n::t(std::string("daemon.phase.") + phase_name(phase));
}

std::optional<std::string> detected_binary() {
  if (g_state.last_status && g_state.last_status->binary) {
    return *g_state.last_status->binary;
  }
  return std::nullopt;
}

void clear_box(GtkBox* box) {
  GtkWidget* child = gtk_widget_get_first_child(GTK_WIDGET(box));
  while (child != nullptr) {
    GtkWidget* next = gtk_widget_get_next_sibling(child);
    gtk_box_remove(box, child);
    child = next;
  }
}

// --------------------------------------------------------------- boot page

GtkWidget* build_boot_page() {
  auto* holder = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_valign(holder, GTK_ALIGN_CENTER);
  gtk_widget_set_halign(holder, GTK_ALIGN_CENTER);

  auto* card = gtk_frame_new(nullptr);
  auto* inner = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_widget_set_margin_top(inner, 32);
  gtk_widget_set_margin_bottom(inner, 32);
  gtk_widget_set_margin_start(inner, 48);
  gtk_widget_set_margin_end(inner, 48);
  gtk_frame_set_child(GTK_FRAME(card), inner);

  auto* title = gtk_label_new("SyncPilot");
  gtk_widget_add_css_class(title, "title-1");
  gtk_widget_set_halign(title, GTK_ALIGN_CENTER);

  auto* status = gtk_label_new(l10n::t("boot.starting").c_str());
  gtk_widget_add_css_class(status, "title-2");
  gtk_label_set_wrap(GTK_LABEL(status), TRUE);
  gtk_label_set_justify(GTK_LABEL(status), GTK_JUSTIFY_CENTER);
  gtk_label_set_max_width_chars(GTK_LABEL(status), 60);
  gtk_widget_set_halign(status, GTK_ALIGN_CENTER);

  auto* detail = gtk_label_new("");
  gtk_widget_add_css_class(detail, "dim-label");
  gtk_label_set_wrap(GTK_LABEL(detail), TRUE);
  gtk_label_set_justify(GTK_LABEL(detail), GTK_JUSTIFY_CENTER);
  gtk_label_set_max_width_chars(GTK_LABEL(detail), 60);
  gtk_widget_set_halign(detail, GTK_ALIGN_CENTER);

  auto* actions = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_halign(actions, GTK_ALIGN_CENTER);

  gtk_box_append(GTK_BOX(inner), title);
  gtk_box_append(GTK_BOX(inner), status);
  gtk_box_append(GTK_BOX(inner), detail);
  gtk_box_append(GTK_BOX(inner), actions);

  g_state.boot_status = GTK_LABEL(status);
  g_state.boot_detail = GTK_LABEL(detail);
  g_state.boot_actions = GTK_BOX(actions);

  gtk_box_append(GTK_BOX(holder), card);
  return holder;
}

GtkWidget* build_banner() {
  auto* revealer = gtk_revealer_new();
  gtk_revealer_set_transition_type(GTK_REVEALER(revealer),
                                   GTK_REVEALER_TRANSITION_TYPE_CROSSFADE);
  gtk_revealer_set_transition_duration(GTK_REVEALER(revealer), 250);
  gtk_revealer_set_reveal_child(GTK_REVEALER(revealer), FALSE);

  auto* label = gtk_label_new("");
  gtk_widget_set_margin_top(label, 4);
  gtk_widget_set_margin_bottom(label, 4);
  gtk_widget_set_margin_start(label, 12);
  gtk_widget_set_margin_end(label, 12);
  gtk_revealer_set_child(GTK_REVEALER(revealer), label);

  gtk_widget_set_halign(revealer, GTK_ALIGN_FILL);
  gtk_widget_set_valign(revealer, GTK_ALIGN_START);
  gtk_overlay_add_overlay(g_state.overlay, revealer);
  // GTK4 removed the overlay pass-through API; can_target makes the banner
  // transparent to input so clicks reach the web view beneath it.
  gtk_widget_set_can_target(revealer, FALSE);

  g_state.banner = GTK_REVEALER(revealer);
  g_state.banner_label = GTK_LABEL(label);
  return revealer;
}

void show_boot_page() {
  g_state.state = UiState::Boot;
  gtk_stack_set_visible_child_name(g_state.stack, "boot");
  update_banner();
}

void reset_boot_card(std::string const& status, std::string const& detail) {
  show_boot_page();
  gtk_label_set_text(g_state.boot_status, status.c_str());
  gtk_label_set_text(g_state.boot_detail, detail.c_str());
  clear_box(g_state.boot_actions);
}

void on_open_settings_clicked(GtkButton*, gpointer) {
  sp::open_settings_window(g_state.app, g_state.api.get(), g_state.executable,
                           detected_binary());
}

GtkWidget* settings_button() {
  auto* button = gtk_button_new_with_label(l10n::t("boot.openSettings").c_str());
  g_signal_connect(button, "clicked", G_CALLBACK(on_open_settings_clicked),
                   nullptr);
  return button;
}

// -------------------------------------------------------------------- tray

void present_main_window() {
  if (g_state.window != nullptr) {
    // gtk_window_present only raises/focuses; a window hidden for
    // close-to-tray needs an explicit re-show.
    gtk_widget_set_visible(GTK_WIDGET(g_state.window), TRUE);
    gtk_window_present(g_state.window);
  }
}

// sp::set_close_to_tray_hint (declared in settings_window.h, defined after
// this anonymous namespace) lands in note_close_to_tray_hint.
void note_close_to_tray_hint(bool enabled) {
  g_state.close_to_tray = enabled;
}

void on_tray_quit() {
  // A real quit: the shutdown hook stops the backend, and the daemon lives
  // on or not per the keep-daemon-on-exit setting.
  g_state.shutting_down.store(true, std::memory_order_release);
  g_application_quit(G_APPLICATION(g_state.app));
}

gboolean on_window_close_request(GtkWindow*, gpointer) {
  if (g_state.shutting_down.load(std::memory_order_acquire)) return FALSE;
  if (g_state.tray && g_state.close_to_tray) {
    // Intercepting the close keeps the GtkWindow alive and registered with
    // the GtkApplication, so the process (and syncing) stays up with the
    // window merely hidden — no GApplication hold needed.
    gtk_widget_set_visible(GTK_WIDGET(g_state.window), FALSE);
    return TRUE;
  }
  return FALSE;
}

void build_tray() {
  try {
    if (!rivet::system::TrayIcon::available()) return;
    g_state.tray = std::make_unique<rivet::system::TrayIcon>(
        rivet_app::kIdentifier, rivet_app::kDisplayName,
        "emblem-synchronizing");
    g_state.tray->set_tooltip(rivet_app::kDisplayName, "Resilio Sync");
    g_state.tray->set_menu(
        {rivet::system::TrayMenuItem(l10n::t("tray.open"),
                                     [] { present_main_window(); }),
         rivet::system::TrayMenuItem(l10n::t("tray.settings"),
                                     [] {
                                       sp::open_settings_window(
                                           g_state.app, g_state.api.get(),
                                           g_state.executable,
                                           detected_binary());
                                     }),
         rivet::system::TrayMenuItem(
             rivet::system::TrayMenuItem::Type::separator),
         rivet::system::TrayMenuItem(l10n::t("tray.quit"),
                                     [] { on_tray_quit(); })});
  } catch (std::exception const& e) {
    // A session that cannot host the tray is supported: closing the window
    // then quits as before, and the launcher + single-instance lease is the
    // way back.
    std::fprintf(stderr, "tray unavailable: %s\n", e.what());
  }
}

void on_retry_clicked(GtkButton*, gpointer) { start_handoff(); }

void show_retry_card(std::string const& error) {
  reset_boot_card(l10n::t("boot.notReady"), error);
  auto* retry = gtk_button_new_with_label(l10n::t("boot.retry").c_str());
  g_signal_connect(retry, "clicked", G_CALLBACK(on_retry_clicked), nullptr);
  gtk_box_append(g_state.boot_actions, retry);
  gtk_box_append(g_state.boot_actions, settings_button());
}

void on_install_clicked(GtkButton* button, gpointer user_data) {
  auto* hint = GTK_LABEL(user_data);
  gtk_widget_set_sensitive(GTK_WIDGET(button), FALSE);
  gtk_button_set_label(button, l10n::t("boot.downloading").c_str());
  gtk_label_set_text(hint, "");
  (void)g_state.api->install_rslsync_async(
      [](rivet_app::Result<rivet_app::InstallResult> result) {
        auto unpacked = sp::unpack(result);
        sp::post_to_main<sp::Unpacked<rivet_app::InstallResult>>(
            [](sp::Unpacked<rivet_app::InstallResult>& r) {
              if (r.ok && r.value.ok) {
                sp::show_toast(g_state.overlay,
                               l10n::t("boot.installedToast",
                                       {r.value.path.value_or("")}),
                               false);
                // Parity: the old app retried the handoff automatically.
                request_handoff();
                return;
              }
              std::string const error =
                  r.ok ? r.value.error.value_or("install failed") : r.error;
              show_install_card(l10n::t("boot.installHint", {error}));
            },
            std::move(unpacked));
      });
}

void show_install_card(std::string const& hint_text) {
  reset_boot_card(l10n::t("boot.notInstalled"), l10n::t("boot.installDetail"));
  auto* install = gtk_button_new_with_label(
      hint_text.empty() ? l10n::t("boot.download").c_str()
                        : l10n::t("boot.downloadFailedRetry").c_str());
  auto* hint = gtk_label_new(hint_text.c_str());
  gtk_widget_add_css_class(hint, "dim-label");
  gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
  gtk_label_set_justify(GTK_LABEL(hint), GTK_JUSTIFY_CENTER);
  gtk_label_set_max_width_chars(GTK_LABEL(hint), 60);
  gtk_widget_set_halign(hint, GTK_ALIGN_CENTER);
  g_signal_connect(install, "clicked", G_CALLBACK(on_install_clicked), hint);
  gtk_box_append(g_state.boot_actions, install);
  gtk_box_append(g_state.boot_actions, settings_button());
  gtk_box_append(g_state.boot_actions, hint);
}

#ifndef HAVE_WEBKIT
void on_open_browser_clicked(GtkButton*, gpointer) {
  // GTK4 has no gtk_get_current_event_time(); GDK_CURRENT_TIME lets the
  // desktop place the browser window without a timestamp.
  gtk_show_uri(g_state.window, g_state.proxy_url.c_str(), GDK_CURRENT_TIME);
}

void show_no_webkit_card(std::string const& url) {
  reset_boot_card(l10n::t("boot.handoff", {"?"}),
                  "This build embeds no browser: the official UI needs the "
                  "webkitgtk-6.0 development package (Ubuntu 24.04+) at "
                  "build time. Open the UI in a browser, or manage the "
                  "daemon in SyncPilot Settings.");
  auto* open = gtk_button_new_with_label(url.c_str());
  g_signal_connect(open, "clicked", G_CALLBACK(on_open_browser_clicked),
                   nullptr);
  gtk_box_append(g_state.boot_actions, open);
  gtk_box_append(g_state.boot_actions, settings_button());
}
#endif  // !HAVE_WEBKIT

// ------------------------------------------------------------- boot handoff

void on_handoff(sp::Unpacked<rivet_app::Handoff> const& result) {
  if (!result.ok) {
    // The backend error for a missing rslsync mirrors the old app's
    // /binary not found/i match (manager.rkt's fixed message).
    if (result.error.find("binary not found") != std::string::npos) {
      show_install_card({});
    } else {
      show_retry_card(result.error);
    }
    return;
  }
  // Learn the close-to-tray hint once settings exist; the settings window
  // refreshes it on every save.
  if (g_state.api != nullptr) {
    (void)g_state.api->get_settings_async(
        [](rivet_app::Result<rivet_app::Settings> result) {
          auto unpacked = sp::unpack(result);
          sp::post_to_main<sp::Unpacked<rivet_app::Settings>>(
              [](sp::Unpacked<rivet_app::Settings>& r) {
                if (r.ok) note_close_to_tray_hint(r.value.close_to_tray);
              },
              std::move(unpacked));
        });
  }
  // Silent daily update auto-check (backend-throttled): only an available
  // update speaks, via the consent dialog. Never retries after handoffs.
  if (!g_state.update_auto_check_done && g_state.api != nullptr) {
    g_state.update_auto_check_done = true;
    sp::check_for_updates(g_state.api.get(), /*force=*/false, /*silent=*/true);
  }
#ifdef HAVE_WEBKIT
  enter_web_view(result.value.proxy_url);
#else
  show_no_webkit_card(result.value.proxy_url);
#endif
}

void request_handoff() {
  if (g_state.api == nullptr) return;
  (void)g_state.api->get_handoff_async(
      [](rivet_app::Result<rivet_app::Handoff> result) {
        auto unpacked = sp::unpack(result);
        sp::post_to_main<sp::Unpacked<rivet_app::Handoff>>(
            [](sp::Unpacked<rivet_app::Handoff>& r) { on_handoff(r); },
            std::move(unpacked));
      });
}

void start_handoff() {
  if (g_state.api == nullptr) return;
  reset_boot_card(l10n::t("boot.starting"), "");
  (void)g_state.api->initialize_async(
      [](rivet_app::Result<void> result) {
        auto unpacked = sp::unpack(result);
        sp::post_to_main<sp::Unpacked<void>>(
            [](sp::Unpacked<void>& r) {
              if (r.ok) {
                request_handoff();
              } else {
                show_retry_card(r.error);
              }
            },
            std::move(unpacked));
      });
}

#ifdef HAVE_WEBKIT
void enter_web_view(std::string const& url) {
  g_state.proxy_url = url;
  g_state.state = UiState::Web;
  gtk_stack_set_visible_child_name(g_state.stack, "web");
  webkit_web_view_load_uri(g_state.web_view, url.c_str());
  update_banner();
}
#endif

// ------------------------------------------------- daemon state surfacing

void on_daemon_changed(rivet_app::DaemonStatus const& status) {
  g_state.last_status = status;

  if (g_state.state != UiState::Web) {
    update_banner();
    return;
  }

  switch (status.phase) {
    case rivet_app::DaemonPhase::running:
    case rivet_app::DaemonPhase::starting:
    case rivet_app::DaemonPhase::stopped:
      // Thin banner over the web view while the daemon is not serving.
      update_banner();
      break;
    case rivet_app::DaemonPhase::crashed:
    case rivet_app::DaemonPhase::failed:
      // Parity with the old daemon://changed handling: leave the official UI
      // and force a human decision (retry / settings).
      show_retry_card(status.error ? *status.error
                                   : phase_label(status.phase));
      break;
  }
}

void update_banner() {
  if (g_state.banner == nullptr) return;
  bool const show = g_state.state == UiState::Web &&
                    g_state.last_status.has_value() &&
                    g_state.last_status->phase !=
                        rivet_app::DaemonPhase::running &&
                    g_state.last_status->phase !=
                        rivet_app::DaemonPhase::crashed &&
                    g_state.last_status->phase !=
                        rivet_app::DaemonPhase::failed;
  if (show) {
    gtk_label_set_text(g_state.banner_label,
                       phase_label(g_state.last_status->phase).c_str());
  }
  gtk_revealer_set_reveal_child(g_state.banner, show);
}

// --------------------------------------------------------- backend startup

int on_backend_finished(gpointer) {
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::string error;
  {
    std::lock_guard lock(g_state.startup_mutex);
    backend = std::move(g_state.startup_backend);
    error = std::move(g_state.startup_error);
  }

  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    if (backend != nullptr) {
      backend->stop();
    }
    return G_SOURCE_REMOVE;
  }

  if (!error.empty() || backend == nullptr) {
    reset_boot_card(
        "SyncPilot failed to start",
        error.empty() ? "backend startup completed without a backend" : error);
    return G_SOURCE_REMOVE;
  }

  g_state.backend = std::move(backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);

  // daemon-changed carries the daemon phase; run on the reader thread, so
  // dispatch to the main loop before touching widgets.
  g_state.backend->set_event_handler(
      [](std::string const& name, rivet::Value const& value) {
        try {
          rivet_app::Event const event = rivet_app::decode_event(name, value);
          if (auto* changed =
                  std::get_if<rivet_app::Daemon_changedEvent>(&event)) {
            sp::post_to_main<rivet_app::DaemonStatus>(
                [](rivet_app::DaemonStatus& status) {
                  on_daemon_changed(status);
                },
                changed->value);
          }
        } catch (...) {
          // Unknown events are ignored (forward compatibility).
        }
      });

  start_handoff();
  return G_SOURCE_REMOVE;
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout.has_value()) {
    reset_boot_card(
        "SyncPilot failed to start",
        "Missing Rivet runtime layout (runtime/*.boot, res/core.zo) next to "
        "the executable. Build with raco rivet build/dev.");
    return;
  }

  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = g_state.executable;
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  // Booting the embedded runtime blocks on file I/O; only startup runs off
  // the main loop. Everything after completion dispatches back through
  // g_idle_add.
  g_state.startup_thread = std::thread([config = std::move(config)]() mutable {
    auto backend =
        std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
    try {
      backend->start();
      {
        std::lock_guard lock(g_state.startup_mutex);
        g_state.startup_backend = std::move(backend);
      }
    } catch (std::exception const& e) {
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_error = e.what();
    }
    g_idle_add(on_backend_finished, nullptr);
  });
}

// ------------------------------------------------------------ application

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window != nullptr) {
    gtk_window_present(g_state.window);
    return;
  }

  g_state.app = app;
  g_state.executable = executable_path();

  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), rivet_app::kDisplayName);
  gtk_window_set_default_size(GTK_WINDOW(window), 1160, 760);
  gtk_widget_set_size_request(GTK_WIDGET(window), 960, 620);

  auto* overlay = gtk_overlay_new();
  gtk_window_set_child(GTK_WINDOW(window), overlay);
  g_state.overlay = GTK_OVERLAY(overlay);

  auto* stack = gtk_stack_new();
  gtk_stack_set_transition_type(GTK_STACK(stack),
                                GTK_STACK_TRANSITION_TYPE_NONE);
  gtk_overlay_set_child(g_state.overlay, stack);
  g_state.stack = GTK_STACK(stack);

  gtk_stack_add_named(g_state.stack, build_boot_page(), "boot");
#ifdef HAVE_WEBKIT
  g_state.web_view = WEBKIT_WEB_VIEW(webkit_web_view_new());
  gtk_stack_add_named(g_state.stack, GTK_WIDGET(g_state.web_view), "web");
#endif
  build_banner();

  g_state.window = GTK_WINDOW(window);
  g_signal_connect(window, "close-request",
                   G_CALLBACK(on_window_close_request), nullptr);
  gtk_stack_set_visible_child_name(g_state.stack, "boot");
  gtk_window_present(GTK_WINDOW(window));

  sp::set_update_flow_parent(g_state.window);
  start_backend();
  build_tray();
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  // Drop the tray before the backend goes: its menu callbacks reference
  // host state and must not fire during teardown. Same for the update
  // flow's poll timer, whose RPC must not hit a stopped backend.
  g_state.tray.reset();
  sp::stop_update_flow();
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  {
    std::lock_guard lock(g_state.startup_mutex);
    startup_backend = std::move(g_state.startup_backend);
  }
  if (startup_backend != nullptr) {
    startup_backend->stop();
  }
  if (g_state.backend != nullptr) {
    g_state.backend->stop();
  }
}

}  // namespace

void sp::set_close_to_tray_hint(bool enabled) {
  note_close_to_tray_hint(enabled);
}

int main(int argc, char** argv) {
  // Single-instance parity with the old app: a second launch forwards its
  // arguments to the running instance (which presents its window) and exits.
  std::unique_ptr<rivet::system::SingleInstanceLease> lease;
  try {
    lease = std::make_unique<rivet::system::SingleInstanceLease>(
        rivet_app::kIdentifier);
    if (!lease->is_primary()) {
      (void)lease->forward_arguments(
          std::vector<std::string>(argv + 1, argv + argc));
      return 0;
    }
    lease->set_activation_handler([](std::vector<std::string>) {
      sp::post_to_main<int>(
          [](int&) { present_main_window(); },
          0);
    });
  } catch (...) {
    // No single-instance support on this session; continue standalone.
    lease.reset();
  }

  auto* app =
      gtk_application_new(rivet_app::kIdentifier, G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
