//! SyncPilot — native desktop GUI for Resilio Sync (rslsync) on Linux.

mod api;
mod autostart;
mod commands;
mod manager;
mod rslsync_config;
mod settings;

use manager::{Manager, Phase};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager as _};

fn show_main_window(app: &tauri::AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.unminimize();
        let _ = win.set_focus();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&dir).ok();
            let settings = settings::AppSettings::load(&dir);
            app.manage(Manager::new(dir, settings));

            build_tray(app)?;

            // Daemon watchdog.
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move { manager::supervisor(handle).await });

            // Bring the daemon up with the app when configured to.
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let m = handle.state::<Manager>();
                if m.settings().autostart_daemon {
                    let _ = m.ensure_running(&handle).await;
                }
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Behave like the official clients: optionally hide to tray.
                let keep = window
                    .app_handle()
                    .state::<Manager>()
                    .settings()
                    .close_to_tray;
                if keep {
                    let _ = window.hide();
                    api.prevent_close();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::daemon_status,
            commands::daemon_start,
            commands::daemon_stop,
            commands::sync_status,
            commands::list_folders,
            commands::list_known_peers,
            commands::add_folder,
            commands::remove_folder,
            commands::pause_folder,
            commands::pause_all,
            commands::generate_secret,
            commands::get_speed_limits,
            commands::set_speed_limits,
            commands::license_state,
            commands::start_trial,
            commands::get_app_settings,
            commands::update_app_settings,
            commands::get_autostart,
            commands::set_autostart,
            commands::pick_folder,
            commands::get_app_version,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                // Orphaned daemons are the failure mode to avoid: shut the
                // managed daemon down unless the user asked to keep it.
                let m = app.state::<Manager>();
                if m.status().phase == Phase::Running && !m.settings().keep_daemon_on_exit {
                    let h = app.clone();
                    tauri::async_runtime::block_on(async move {
                        let m = h.state::<Manager>();
                        let _ = m.stop(&h).await;
                    });
                }
            }
        });
}

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open SyncPilot", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    // No pause/resume entries: rslsync 3.x has no global-pause action.
    let quit = MenuItem::with_id(app, "quit", "Quit SyncPilot", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &sep, &quit])?;

    let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/32x32.png"))
        .expect("bundled tray icon parses")
        .to_owned();

    TrayIconBuilder::with_id("main")
        .icon(icon)
        .tooltip("SyncPilot")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main_window(app),
            "quit" => {
                let _ = app.emit("app://quit-requested", ());
                app.exit(0);
            }
            _ => {}
        })
        .build(app)?;
    Ok(())
}
