//! SyncPilot — native desktop shell for Resilio Sync (rslsync) on Linux.
//!
//! The main window embeds the official Resilio Web UI, served through a
//! loopback proxy that injects the app-generated credentials (`proxy.rs`),
//! so the interface and interaction model are exactly the official ones.
//! SyncPilot owns everything around it: daemon lifecycle, tray, autostart,
//! first-run installation of rslsync, and app updates.

mod api;
mod autostart;
mod commands;
mod manager;
mod proxy;
mod rslsync_config;
mod rslsync_install;
mod settings;

use manager::{Manager, Phase};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager as _, WebviewUrl, WebviewWindowBuilder};

fn show_main_window(app: &tauri::AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.unminimize();
        let _ = win.set_focus();
    }
}

pub(crate) fn open_settings_window(app: &tauri::AppHandle) {
    if let Some(win) = app.get_webview_window("settings") {
        let _ = win.show();
        let _ = win.set_focus();
        return;
    }
    let _ = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title("SyncPilot Settings")
        .inner_size(720.0, 640.0)
        .resizable(true)
        .build();
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            let dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&dir).ok();
            let settings = settings::AppSettings::load(&dir);
            app.manage(Manager::new(dir, settings.clone()));

            // Auth-injecting proxy in front of the daemon's Web UI. The
            // window (boot page) asks for its URL via the gui_url command.
            {
                let cfg = proxy::ProxyConfig {
                    daemon_port: settings.webui_port,
                    login: settings.webui_login.clone(),
                    password: settings.webui_password.clone(),
                };
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    match proxy::spawn(cfg).await {
                        Ok(h) => {
                            handle.manage(h);
                        }
                        Err(e) => {
                            eprintln!("web ui proxy failed to start: {e}");
                        }
                    }
                });
            }

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
            // The settings window closes outright; the main window can hide
            // to tray like the official clients do.
            if window.label() == "settings" {
                if let tauri::WindowEvent::CloseRequested { .. } = event {
                    let _ = window.destroy();
                }
                return;
            }
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
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
            commands::gui_url,
            commands::install_rslsync,
            commands::get_app_settings,
            commands::update_app_settings,
            commands::get_autostart,
            commands::set_autostart,
            commands::open_settings,
            commands::pick_folder,
            commands::get_app_version,
            commands::check_for_updates,
            commands::install_update,
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
    let open = MenuItem::with_id(app, "open", "Open Resilio Sync", true, None::<&str>)?;
    let prefs = MenuItem::with_id(app, "settings", "SyncPilot Settings…", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, "quit", "Quit SyncPilot", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open, &prefs, &sep, &quit])?;

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
            "settings" => open_settings_window(app),
            "quit" => {
                let _ = app.emit("app://quit-requested", ());
                app.exit(0);
            }
            _ => {}
        })
        .build(app)?;
    Ok(())
}
