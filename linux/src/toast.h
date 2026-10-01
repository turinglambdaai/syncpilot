// Transient in-window notification banner (bottom right, ~3.4s auto-hide),
// parity with the old web UI's .toast styles.
#pragma once

#include <gtk/gtk.h>

#include <string>

namespace sp {

// Post a banner into the window's GtkOverlay. Main thread only. The banner
// is click-through (input passes to the widget below) and removes itself.
void show_toast(GtkOverlay* overlay, std::string const& message, bool error);

}  // namespace sp
