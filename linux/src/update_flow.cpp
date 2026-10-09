#include "update_flow.h"

#include <gtk/gtk.h>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <optional>
#include <string>
#include <utility>

#include "GeneratedBackend.hpp"
#include "GeneratedStrings.h"
#include "dispatch.h"

namespace sp {
namespace {

struct UpdateFlowState {
  rivet_app::API* api{nullptr};
  GtkWindow* parent{nullptr};

  // download progress; owned here so the poll callback stays simple
  guint poll_source{0};
  GtkWindow* progress_dialog{nullptr};
  GtkProgressBar* progress_bar{nullptr};
};

UpdateFlowState g_flow;

std::string format_size(double bytes) {
  char buffer[32];
  std::snprintf(buffer, sizeof buffer, "%.1f MB", bytes / (1024.0 * 1024.0));
  return buffer;
}

// ------------------------------------------------------------ dialog helpers

void show_message_dialog(std::string const& title, std::string const& body) {
  auto* dialog = gtk_dialog_new_with_buttons(
      title.c_str(), g_flow.parent,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      l10n::t("update.close").c_str(), GTK_RESPONSE_CLOSE, nullptr);
  GtkWidget* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* text = gtk_label_new(body.c_str());
  gtk_label_set_wrap(GTK_LABEL(text), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(text), 60);
  gtk_widget_set_margin_top(text, 8);
  gtk_widget_set_margin_bottom(text, 8);
  gtk_widget_set_margin_start(text, 16);
  gtk_widget_set_margin_end(text, 16);
  gtk_box_append(GTK_BOX(area), text);
  gtk_window_set_transient_for(GTK_WINDOW(dialog), g_flow.parent);
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, int, gpointer) {
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  gtk_window_present(GTK_WINDOW(dialog));
}

void show_error_dialog(std::string const& body) {
  show_message_dialog(l10n::t("update.failedTitle"), body);
}

// -------------------------------------------------------------- poll ticker

void stop_update_poll() {
  if (g_flow.poll_source != 0) {
    g_source_remove(g_flow.poll_source);
    g_flow.poll_source = 0;
  }
}

void close_progress_dialog() {
  if (g_flow.progress_dialog != nullptr) {
    gtk_window_destroy(g_flow.progress_dialog);
    g_flow.progress_dialog = nullptr;
    g_flow.progress_bar = nullptr;
  }
}

// Downloaded: hand off the verified tar.gz. Installation stays manual —
// extract the new archive over the app directory — so the dialog points at
// the file and explains the step; rslsync state is never involved.
void show_downloaded_dialog(std::string const& version,
                            std::string const& path) {
  std::string body = l10n::t("update.readyBody", {version});
  auto* dialog = gtk_dialog_new_with_buttons(
      l10n::t("update.readyTitle").c_str(), g_flow.parent,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      l10n::t("update.close").c_str(), GTK_RESPONSE_CLOSE, nullptr);
  GtkWidget* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(content, 8);
  gtk_widget_set_margin_bottom(content, 8);
  gtk_widget_set_margin_start(content, 16);
  gtk_widget_set_margin_end(content, 16);
  gtk_box_append(GTK_BOX(area), content);

  auto* text = gtk_label_new(body.c_str());
  gtk_label_set_wrap(GTK_LABEL(text), TRUE);
  gtk_box_append(GTK_BOX(content), text);

  auto* path_label = gtk_label_new(path.c_str());
  gtk_widget_add_css_class(path_label, "dim-label");
  gtk_label_set_selectable(GTK_LABEL(path_label), TRUE);
  gtk_box_append(GTK_BOX(content), path_label);

  auto* note = gtk_label_new(l10n::t("update.installNote").c_str());
  gtk_widget_add_css_class(note, "dim-label");
  gtk_label_set_wrap(GTK_LABEL(note), TRUE);
  gtk_box_append(GTK_BOX(content), note);

  auto* open = gtk_button_new_with_label(l10n::t("update.openFolder").c_str());
  g_signal_connect(
      open, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer user_data) {
        auto const* p = static_cast<std::string*>(user_data);
        std::filesystem::path const dir =
            std::filesystem::path(*p).parent_path();
        gtk_show_uri(g_flow.parent, ("file://" + dir.string()).c_str(),
                     GDK_CURRENT_TIME);
      }),
      new std::string(path));
  gtk_box_append(GTK_BOX(content), open);

  gtk_window_set_transient_for(GTK_WINDOW(dialog), g_flow.parent);
  gtk_window_present(GTK_WINDOW(dialog));
}

int poll_tick(gpointer) {
  if (g_flow.api == nullptr) return G_SOURCE_REMOVE;
  (void)g_flow.api->update_state_async(
      [](rivet_app::Result<rivet_app::UpdateState> result) {
        auto unpacked = unpack(result);
        post_to_main<Unpacked<rivet_app::UpdateState>>(
            [](Unpacked<rivet_app::UpdateState>& r) {
              if (!r.ok) return;
              rivet_app::UpdateState const& state = r.value;
              if (g_flow.progress_bar != nullptr) {
                gtk_progress_bar_set_fraction(
                    g_flow.progress_bar,
                    std::clamp(static_cast<double>(state.percent), 0.0,
                               100.0) /
                        100.0);
              }
              if (state.phase != "downloaded" && state.phase != "error") {
                return;
              }
              stop_update_poll();
              close_progress_dialog();
              if (state.phase == "error") {
                show_error_dialog(l10n::t(
                    "update.downloadFailed",
                    {state.message.value_or("unknown failure")}));
                return;
              }
              show_downloaded_dialog(
                  state.available_version.value_or("?"),
                  state.downloaded_path.value_or(""));
            },
            std::move(unpacked));
      });
  return G_SOURCE_CONTINUE;
}

void start_update_download(rivet_app::API* api) {
  if (api == nullptr) return;
  auto* dialog = gtk_dialog_new_with_buttons(
      l10n::t("update.availableTitle").c_str(), g_flow.parent,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      l10n::t("update.cancel").c_str(), GTK_RESPONSE_CLOSE, nullptr);
  GtkWidget* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(content, 8);
  gtk_widget_set_margin_bottom(content, 8);
  gtk_widget_set_margin_start(content, 16);
  gtk_widget_set_margin_end(content, 16);
  gtk_box_append(GTK_BOX(area), content);
  auto* bar = gtk_progress_bar_new();
  gtk_widget_set_size_request(bar, 300, -1);
  gtk_box_append(GTK_BOX(content), bar);
  auto* label = gtk_label_new(l10n::t("settings.downloadingUpdate").c_str());
  gtk_box_append(GTK_BOX(content), label);
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, int, gpointer) {
        // The backend keeps downloading; cancelling only detaches the
        // progress UI (parity with the family pattern — no cancel RPC).
        stop_update_poll();
        g_flow.progress_dialog = nullptr;
        g_flow.progress_bar = nullptr;
        gtk_window_destroy(GTK_WINDOW(dialog));
      }),
      nullptr);
  gtk_window_set_transient_for(GTK_WINDOW(dialog), g_flow.parent);
  gtk_window_present(GTK_WINDOW(dialog));
  g_flow.progress_dialog = GTK_WINDOW(dialog);
  g_flow.progress_bar = GTK_PROGRESS_BAR(bar);
  g_flow.poll_source = g_timeout_add(400, poll_tick, nullptr);

  (void)api->start_download_async(
      [api](rivet_app::Result<void> result) {
        auto unpacked = unpack(result);
        post_to_main<Unpacked<void>>(
            [](Unpacked<void>& r) {
              if (!r.ok) {
                // the download never started; stop staring at a 0% bar
                stop_update_poll();
                close_progress_dialog();
                show_error_dialog(r.error);
              }
            },
            std::move(unpacked));
      });
}

void show_update_consent(rivet_app::API* api,
                         rivet_app::UpdateCheck const& check) {
  std::string const version = check.available_version.value_or("?");
  std::string body = l10n::t("update.availableBody",
                             {version,
                              format_size(static_cast<double>(
                                  check.size_bytes.value_or(0)))});
  auto* dialog = gtk_dialog_new_with_buttons(
      l10n::t("update.availableTitle").c_str(), g_flow.parent,
      static_cast<GtkDialogFlags>(GTK_DIALOG_MODAL |
                                  GTK_DIALOG_DESTROY_WITH_PARENT),
      l10n::t("update.cancel").c_str(), GTK_RESPONSE_CANCEL,
      l10n::t("update.download").c_str(), GTK_RESPONSE_ACCEPT, nullptr);
  GtkWidget* area = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
  auto* text = gtk_label_new(body.c_str());
  gtk_label_set_wrap(GTK_LABEL(text), TRUE);
  gtk_widget_set_margin_top(text, 8);
  gtk_widget_set_margin_bottom(text, 8);
  gtk_widget_set_margin_start(text, 16);
  gtk_widget_set_margin_end(text, 16);
  gtk_box_append(GTK_BOX(area), text);
  gtk_window_set_transient_for(GTK_WINDOW(dialog), g_flow.parent);

  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* dialog, int response, gpointer user_data) {
        auto* api = static_cast<rivet_app::API*>(user_data);
        bool const go = response == GTK_RESPONSE_ACCEPT;
        gtk_window_destroy(GTK_WINDOW(dialog));
        if (go) {
          post_to_main<int>(
              [api](int&) { start_update_download(api); }, 0);
        }
      }),
      api);
  gtk_window_present(GTK_WINDOW(dialog));
}

}  // namespace

void set_update_flow_parent(GtkWindow* window) { g_flow.parent = window; }

void stop_update_flow() {
  stop_update_poll();
  close_progress_dialog();
  g_flow.api = nullptr;
}

void check_for_updates(rivet_app::API* api, bool force, bool silent,
                       FinishedCallback on_finished) {
  if (api == nullptr) {
    if (on_finished) on_finished();
    return;
  }
  g_flow.api = api;
  (void)api->check_updates_async(
      force,
      [api, silent,
       on_finished = std::move(on_finished)](
          rivet_app::Result<rivet_app::UpdateCheck> result) mutable {
        auto unpacked = unpack(result);
        post_to_main<Unpacked<rivet_app::UpdateCheck>>(
            [api, silent,
             on_finished = std::move(on_finished)](
                Unpacked<rivet_app::UpdateCheck>& r) {
              if (on_finished) on_finished();
              if (!r.ok) {
                if (!silent) {
                  show_error_dialog(
                      l10n::t("settings.updateCheckFailed", {r.error}));
                }
                return;
              }
              rivet_app::UpdateCheck const& check = r.value;
              if (check.status == "available") {
                show_update_consent(api, check);
                return;
              }
              if (silent) return;  // auto-check only speaks when there is news
              if (check.status == "error") {
                show_error_dialog(l10n::t(
                    "settings.updateCheckFailed",
                    {check.error.value_or("unknown failure")}));
                return;
              }
              // "up-to-date" and "throttled" both mean nothing to do
              show_message_dialog(
                  l10n::t("settings.updates"),
                  l10n::t("settings.upToDate", {check.current_version}));
            },
            std::move(unpacked));
      });
}

}  // namespace sp
