// Consent-based online update flow for the Linux host, ported from the
// family pattern (payback): a check RPC feeds a consent dialog, the
// download runs on a backend worker thread with progress surfaced by
// polling the update-state RPC, and a verified tar.gz is handed off with
// an open-folder action. Installation itself stays manual (extract the new
// tar.gz over the app directory) — the host never touches rslsync state.
#pragma once

#include <functional>

#include <gtk/gtk.h>

namespace rivet_app {
class API;
}

namespace sp {

// Every update dialog is parented to the main window: it outlives the
// settings window, and a download finishing later must not point a modal
// at a dead parent. Call once from on_activate.
void set_update_flow_parent(GtkWindow* window);

// Detach the flow from the backend at shutdown (stops the progress poll —
// its RPC would otherwise hit a dead API). Call from on_shutdown.
void stop_update_flow();

// Check for updates. force bypasses the backend's 24h throttle; silent
// keeps "up-to-date"/"throttled"/errors invisible (startup auto-check) —
// an available update always asks. on_finished fires once the check RPC
// settles (the settings card uses it to un-busy its button), before any
// consent dialog the result may open.
using FinishedCallback = std::function<void()>;
void check_for_updates(rivet_app::API* api, bool force, bool silent,
                       FinishedCallback on_finished = {});

}  // namespace sp
