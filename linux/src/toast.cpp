#include "toast.h"

namespace sp {
namespace {

struct Toast {
  GtkOverlay* overlay{nullptr};
  GtkWidget* revealer{nullptr};
  guint hide_id{0};
  guint remove_id{0};
};

// The overlay's window went away before the toast expired: drop the pending
// timers and the Toast itself (registered as a weak ref on the overlay).
void on_overlay_gone(gpointer data, GObject*) {
  auto* toast = static_cast<Toast*>(data);
  if (toast->hide_id != 0) g_source_remove(toast->hide_id);
  if (toast->remove_id != 0) g_source_remove(toast->remove_id);
  delete toast;
}

int on_hide_timeout(gpointer data) {
  auto* toast = static_cast<Toast*>(data);
  toast->hide_id = 0;
  gtk_revealer_set_reveal_child(GTK_REVEALER(toast->revealer), FALSE);
  return G_SOURCE_REMOVE;
}

int on_remove_timeout(gpointer data) {
  auto* toast = static_cast<Toast*>(data);
  toast->remove_id = 0;
  g_object_weak_unref(G_OBJECT(toast->overlay), on_overlay_gone, toast);
  gtk_overlay_remove_overlay(toast->overlay, toast->revealer);
  delete toast;
  return G_SOURCE_REMOVE;
}

}  // namespace

void show_toast(GtkOverlay* overlay, std::string const& message, bool error) {
  if (overlay == nullptr) return;

  auto* const box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_add_css_class(box, "osd");
  gtk_widget_add_css_class(box, error ? "error" : "toast");

  auto* const label = gtk_label_new(message.c_str());
  gtk_label_set_wrap(GTK_LABEL(label), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(label), 48);
  gtk_widget_set_margin_start(label, 12);
  gtk_widget_set_margin_end(label, 12);
  gtk_widget_set_margin_top(label, 8);
  gtk_widget_set_margin_bottom(label, 8);
  gtk_box_append(GTK_BOX(box), label);

  auto* const revealer = gtk_revealer_new();
  gtk_revealer_set_transition_type(GTK_REVEALER(revealer),
                                   GTK_REVEALER_TRANSITION_TYPE_CROSSFADE);
  gtk_revealer_set_transition_duration(GTK_REVEALER(revealer), 250);
  gtk_revealer_set_reveal_child(GTK_REVEALER(revealer), TRUE);
  gtk_revealer_set_child(GTK_REVEALER(revealer), box);

  gtk_widget_set_halign(revealer, GTK_ALIGN_END);
  gtk_widget_set_valign(revealer, GTK_ALIGN_END);
  gtk_widget_set_margin_start(revealer, 12);
  gtk_widget_set_margin_end(revealer, 12);
  gtk_widget_set_margin_bottom(revealer, 12);

  gtk_overlay_add_overlay(overlay, revealer);
  // Banners are informational only: let clicks fall through to the content.
  gtk_overlay_set_overlay_pass_through(overlay, revealer, TRUE);

  auto* const toast = new Toast{overlay, revealer, 0, 0};
  g_object_weak_ref(G_OBJECT(overlay), on_overlay_gone, toast);
  toast->hide_id = g_timeout_add(3400, on_hide_timeout, toast);
  toast->remove_id = g_timeout_add(3400 + 400, on_remove_timeout, toast);
}

}  // namespace sp
