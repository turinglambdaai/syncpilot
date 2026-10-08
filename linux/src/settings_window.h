// The standalone SyncPilot settings window (the main window shows the
// official Resilio Web UI after the boot page hands over).
#pragma once

#include <gtk/gtk.h>

#include <optional>
#include <string>

namespace rivet_app {
class API;
}

namespace sp {

// Opens (or presents, if already open) the settings window. `api` must
// outlive the window — it is the app-lifetime backend client. `executable`
// is the running binary's absolute path (XDG autostart entry); `binary_hint`
// is the daemon's currently detected rslsync path, or nullopt.
void open_settings_window(GtkApplication* app, rivet_app::API* api,
                          std::string const& executable,
                          std::optional<std::string> const& binary_hint);

// Called when a settings save settles: keeps the main window's
// close-to-tray behavior in sync with the saved setting.
void set_close_to_tray_hint(bool enabled);

}  // namespace sp
