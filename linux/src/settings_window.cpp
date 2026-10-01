#include "settings_window.h"

#include <gtk/gtk.h>

#include <exception>
#include <string>

#include "GeneratedBackend.hpp"
#include "GeneratedStrings.h"
#include "dispatch.h"
#include "system_services.hpp"  // rivet::system — Autostart, Capabilities
#include "toast.h"

namespace sp {
namespace {

struct SettingsUi {
  rivet_app::API* api{nullptr};
  std::string executable;

  GtkOverlay* overlay{nullptr};
  GtkLabel* binary_label{nullptr};
  GtkEntry* binary_entry{nullptr};
  GtkButton* restart_button{nullptr};
  GtkButton* regenerate_button{nullptr};
  GtkCheckButton* autostart_check{nullptr};
  GtkCheckButton* restart_crash_check{nullptr};
  GtkCheckButton* keep_daemon_check{nullptr};
  GtkCheckButton* close_to_tray_check{nullptr};
  GtkCheckButton* login_check{nullptr};
  GtkEntry* device_entry{nullptr};
  GtkSpinButton* port_spin{nullptr};
  GtkButton* save_button{nullptr};

  // Filled by get-settings; Save refuses to run before it lands.
  std::optional<rivet_app::Settings> loaded;
  std::optional<std::string> binary_hint;
};

SettingsUi g_ui;
GtkWindow* g_window{nullptr};

// ------------------------------------------------------------- card helpers

GtkWidget* field_label(std::string const& text) {
  auto* label = gtk_label_new(text.c_str());
  gtk_widget_set_halign(label, GTK_ALIGN_START);
  gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
  gtk_label_set_wrap(GTK_LABEL(label), TRUE);
  gtk_widget_add_css_class(label, "dim-label");
  return label;
}

GtkWidget* make_card(char const* title) {
  auto* frame = gtk_frame_new(title);
  auto* inner = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(inner, 12);
  gtk_widget_set_margin_bottom(inner, 12);
  gtk_widget_set_margin_start(inner, 12);
  gtk_widget_set_margin_end(inner, 12);
  gtk_frame_set_child(GTK_FRAME(frame), inner);
  return frame;
}

void card_append(GtkWidget* card, GtkWidget* row) {
  gtk_box_append(GTK_BOX(gtk_frame_get_child(GTK_FRAME(card))), row);
}

GtkCheckButton* check_row(GtkWidget* card, std::string const& label) {
  auto* check = gtk_check_button_new_with_label(label.c_str());
  gtk_widget_set_halign(check, GTK_ALIGN_START);
  card_append(card, check);
  return GTK_CHECK_BUTTON(check);
}

void row_button(GtkWidget* card, GtkButton* button,
                GCallback clicked, gpointer user_data) {
  gtk_widget_set_halign(GTK_WIDGET(button), GTK_ALIGN_START);
  g_signal_connect(button, "clicked", clicked, user_data);
  card_append(card, GTK_WIDGET(button));
}

// ------------------------------------------------------------------ actions

void on_restart_clicked(GtkButton*, gpointer) {
  if (g_ui.api == nullptr || !g_ui.loaded) return;
  gtk_widget_set_sensitive(GTK_WIDGET(g_ui.restart_button), FALSE);
  (void)g_ui.api->daemon_restart_async(
      [](rivet_app::Result<rivet_app::DaemonStatus> result) {
        auto unpacked = unpack(result);
        post_to_main<Unpacked<rivet_app::DaemonStatus>>(
            [](Unpacked<rivet_app::DaemonStatus>& r) {
              if (g_window == nullptr) return;
              gtk_widget_set_sensitive(GTK_WIDGET(g_ui.restart_button), TRUE);
              if (r.ok) {
                show_toast(g_ui.overlay, l10n::t("settings.daemonRestarted"),
                           false);
              } else {
                show_toast(g_ui.overlay, r.error, true);
              }
            },
            std::move(unpacked));
      });
}

void on_regenerate_clicked(GtkButton*, gpointer) {
  if (g_ui.api == nullptr) return;
  gtk_widget_set_sensitive(GTK_WIDGET(g_ui.regenerate_button), FALSE);
  (void)g_ui.api->regenerate_password_async(
      [](rivet_app::Result<rivet_app::Settings> result) {
        auto unpacked = unpack(result);
        post_to_main<Unpacked<rivet_app::Settings>>(
            [](Unpacked<rivet_app::Settings>& r) {
              if (g_window == nullptr) return;
              gtk_widget_set_sensitive(GTK_WIDGET(g_ui.regenerate_button),
                                       TRUE);
              if (r.ok) {
                g_ui.loaded = r.value;
                show_toast(g_ui.overlay,
                           l10n::t("settings.passwordRegenerated"), false);
              } else {
                show_toast(g_ui.overlay, r.error, true);
              }
            },
            std::move(unpacked));
      });
}

void on_login_toggled(GtkCheckButton* button, gpointer) {
  bool const enabled = gtk_check_button_get_active(button);
  if (g_ui.executable.empty()) {
    gtk_check_button_set_active(button, !enabled);
    show_toast(g_ui.overlay, "cannot determine the SyncPilot executable path",
               true);
    return;
  }
  try {
    rivet::system::Autostart::SetEnabled(rivet_app::kIdentifier,
                                         g_ui.executable, enabled);
    show_toast(g_ui.overlay,
               l10n::t(enabled ? "settings.willStartAtLogin"
                               : "settings.willNotStartAtLogin"),
               false);
  } catch (std::exception const& e) {
    gtk_check_button_set_active(button, !enabled);
    show_toast(g_ui.overlay, e.what(), true);
  }
}

void on_settings_loaded(Unpacked<rivet_app::Settings>& result);

void on_save_clicked(GtkButton*, gpointer) {
  if (g_ui.api == nullptr || !g_ui.loaded) return;

  rivet_app::SettingsDraft draft{};
  draft.rslsync_path = gtk_entry_get_text(g_ui.binary_entry);
  draft.webui_port = gtk_spin_button_get_value_as_int(g_ui.port_spin);
  draft.webui_login = g_ui.loaded->webui_login;
  draft.device_name = gtk_entry_get_text(g_ui.device_entry);
  draft.autostart = gtk_check_button_get_active(g_ui.autostart_check);
  draft.restart_on_crash =
      gtk_check_button_get_active(g_ui.restart_crash_check);
  draft.keep_daemon_on_exit =
      gtk_check_button_get_active(g_ui.keep_daemon_check);
  // Tray is out of scope in v1 (see linux/README.md); the stored value is
  // passed through untouched so the setting round-trips.
  draft.close_to_tray = gtk_check_button_get_active(g_ui.close_to_tray_check);

  auto const port_before = static_cast<gint>(g_ui.loaded->webui_port);
  gtk_widget_set_sensitive(GTK_WIDGET(g_ui.save_button), FALSE);
  (void)g_ui.api->save_settings_async(
      draft, [port_before](rivet_app::Result<rivet_app::Settings> result) {
        auto unpacked = unpack(result);
        post_to_main<Unpacked<rivet_app::Settings>>(
            [port_before](Unpacked<rivet_app::Settings>& r) {
              if (g_window == nullptr) return;
              gtk_widget_set_sensitive(GTK_WIDGET(g_ui.save_button), TRUE);
              if (!r.ok) {
                show_toast(g_ui.overlay, r.error, true);
                return;
              }
              g_ui.loaded = r.value;
              bool const port_changed =
                  static_cast<gint>(r.value.webui_port) != port_before;
              show_toast(g_ui.overlay,
                         l10n::t(port_changed ? "settings.savedRestartForPort"
                                              : "settings.saved"),
                         false);
            },
            std::move(unpacked));
      });
}

// -------------------------------------------------------------------- cards

GtkWidget* build_daemon_card() {
  auto* card = make_card(l10n::t("settings.daemon").c_str());

  g_ui.binary_label = GTK_LABEL(field_label(l10n::t("settings.loading")));
  card_append(card, GTK_WIDGET(g_ui.binary_label));

  g_ui.binary_entry = GTK_ENTRY(gtk_entry_new());
  gtk_entry_set_placeholder_text(
      g_ui.binary_entry, l10n::t("settings.binaryPlaceholder").c_str());
  card_append(card, GTK_WIDGET(g_ui.binary_entry));

  g_ui.restart_button = GTK_BUTTON(
      gtk_button_new_with_label(l10n::t("settings.restartDaemon").c_str()));
  row_button(card, g_ui.restart_button, G_CALLBACK(on_restart_clicked),
             nullptr);

  g_ui.autostart_check = check_row(card, l10n::t("settings.startWithApp"));
  g_ui.restart_crash_check =
      check_row(card, l10n::t("settings.restartOnCrash"));
  g_ui.keep_daemon_check =
      check_row(card, l10n::t("settings.keepDaemonOnExit"));

  auto* regenerate = gtk_button_new_with_label(
      l10n::t("settings.regeneratePassword").c_str());
  g_ui.regenerate_button = GTK_BUTTON(regenerate);
  row_button(card, g_ui.regenerate_button, G_CALLBACK(on_regenerate_clicked),
             nullptr);
  return card;
}

GtkWidget* build_device_card() {
  auto* card = make_card(l10n::t("settings.device").c_str());

  card_append(card, field_label(l10n::t("settings.deviceNameLabel")));
  g_ui.device_entry = GTK_ENTRY(gtk_entry_new());
  card_append(card, GTK_WIDGET(g_ui.device_entry));

  card_append(card, field_label(l10n::t("settings.portLabel")));
  g_ui.port_spin = GTK_SPIN_BUTTON(
      gtk_spin_button_new_with_range(1024.0, 65535.0, 1.0));
  card_append(card, GTK_WIDGET(g_ui.port_spin));
  return card;
}

GtkWidget* build_desktop_card() {
  auto* card = make_card(l10n::t("settings.desktop").c_str());

  bool autostart_supported = false;
  for (auto const& capability : rivet::system::Capabilities()) {
    if (capability == "autostart") autostart_supported = true;
  }
  if (autostart_supported) {
    g_ui.login_check = check_row(card, l10n::t("settings.launchAtLogin"));
    bool enabled = false;
    try {
      enabled = rivet::system::Autostart::Enabled(rivet_app::kIdentifier);
    } catch (...) {
      enabled = false;
    }
    gtk_check_button_set_active(g_ui.login_check, enabled);
    g_signal_connect(g_ui.login_check, "toggled",
                     G_CALLBACK(on_login_toggled), nullptr);
  }
  // close-to-tray needs a tray contract the rivet Linux adapter deliberately
  // lacks (StatusNotifierItem is compositor-dependent); the row is shown
  // insensitive so the stored setting stays visible but inert.
  g_ui.close_to_tray_check = check_row(card, l10n::t("settings.hideToTray"));
  gtk_widget_set_sensitive(GTK_WIDGET(g_ui.close_to_tray_check), FALSE);
  return card;
}

GtkWidget* build_about_card() {
  auto* card = make_card(l10n::t("settings.about").c_str());

  auto* note = gtk_label_new(
      l10n::t("settings.aboutText", {rivet_app::kVersion}).c_str());
  gtk_label_set_wrap(GTK_LABEL(note), TRUE);
  gtk_label_set_xalign(GTK_LABEL(note), 0.0f);
  gtk_widget_add_css_class(note, "dim-label");
  card_append(card, note);

  auto* link = gtk_link_button_new_with_label(
      "https://github.com/turinglambdaai/syncpilot",
      "github.com/turinglambdaai/syncpilot");
  gtk_widget_set_halign(link, GTK_ALIGN_START);
  card_append(card, link);
  return card;
}

// ------------------------------------------------------------- data loading

void on_settings_loaded(Unpacked<rivet_app::Settings>& result) {
  if (g_window == nullptr) return;  // closed before the reply landed
  if (!result.ok) {
    show_toast(g_ui.overlay, result.error, true);
    return;
  }
  g_ui.loaded = result.value;
  auto const& s = result.value;

  std::string const detail = g_ui.binary_hint
                                 ? *g_ui.binary_hint
                                 : std::string(l10n::t("settings.binaryNotDetected"));
  gtk_label_set_text(g_ui.binary_label,
                     l10n::t("settings.binaryLabel", {detail}).c_str());
  gtk_entry_set_text(g_ui.binary_entry, s.rslsync_path.c_str());
  gtk_check_button_set_active(g_ui.autostart_check, s.autostart);
  gtk_check_button_set_active(g_ui.restart_crash_check, s.restart_on_crash);
  gtk_check_button_set_active(g_ui.keep_daemon_check, s.keep_daemon_on_exit);
  gtk_check_button_set_active(g_ui.close_to_tray_check, s.close_to_tray);
  gtk_entry_set_text(g_ui.device_entry, s.device_name.c_str());
  gtk_spin_button_set_value(g_ui.port_spin,
                            static_cast<gdouble>(s.webui_port));
}

void load_settings() {
  if (g_ui.api == nullptr) return;
  (void)g_ui.api->get_settings_async(
      [](rivet_app::Result<rivet_app::Settings> result) {
        auto unpacked = unpack(result);
        post_to_main<Unpacked<rivet_app::Settings>>(
            [](Unpacked<rivet_app::Settings>& r) { on_settings_loaded(r); },
            std::move(unpacked));
      });
}

void on_window_destroy(GtkWidget*, gpointer) {
  g_window = nullptr;
  g_ui = SettingsUi{};
}

}  // namespace

void open_settings_window(GtkApplication* app, rivet_app::API* api,
                          std::string const& executable,
                          std::optional<std::string> const& binary_hint) {
  if (g_window != nullptr) {
    gtk_window_present(g_window);
    return;
  }

  g_ui = SettingsUi{};
  g_ui.api = api;
  g_ui.executable = executable;
  g_ui.binary_hint = binary_hint;

  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), l10n::t("settings.title").c_str());
  gtk_window_set_default_size(GTK_WINDOW(window), 720, 640);

  auto* overlay = gtk_overlay_new();
  gtk_window_set_child(GTK_WINDOW(window), overlay);
  g_ui.overlay = GTK_OVERLAY(overlay);

  auto* scroll = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER,
                                 GTK_POLICY_AUTOMATIC);
  gtk_overlay_set_child(GTK_OVERLAY(overlay), scroll);

  auto* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
  gtk_widget_set_margin_top(content, 24);
  gtk_widget_set_margin_bottom(content, 24);
  gtk_widget_set_margin_start(content, 24);
  gtk_widget_set_margin_end(content, 24);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), content);

  gtk_box_append(GTK_BOX(content), build_daemon_card());
  gtk_box_append(GTK_BOX(content), build_device_card());
  gtk_box_append(GTK_BOX(content), build_desktop_card());
  gtk_box_append(GTK_BOX(content), build_about_card());

  g_ui.save_button = GTK_BUTTON(
      gtk_button_new_with_label(l10n::t("settings.save").c_str()));
  g_signal_connect(g_ui.save_button, "clicked", G_CALLBACK(on_save_clicked),
                   nullptr);
  gtk_box_append(GTK_BOX(content), GTK_WIDGET(g_ui.save_button));

  g_signal_connect(window, "destroy", G_CALLBACK(on_window_destroy), nullptr);
  g_window = GTK_WINDOW(window);
  gtk_window_present(GTK_WINDOW(window));

  load_settings();
}

}  // namespace sp
