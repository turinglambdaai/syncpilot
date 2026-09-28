//! Tauri command layer: daemon lifecycle, the embedded official Web UI
//! handoff, first-run rslsync installation, and app settings.

use crate::manager::{DaemonStatus, Manager};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager as _};

type CmdResult<T> = Result<T, String>;

fn manager<'a>(app: &'a AppHandle) -> tauri::State<'a, Manager> {
    app.state::<Manager>()
}

#[tauri::command]
pub async fn daemon_status(app: AppHandle) -> CmdResult<DaemonStatus> {
    Ok(manager(&app).status())
}

#[tauri::command]
pub async fn daemon_start(app: AppHandle) -> CmdResult<DaemonStatus> {
    let m = manager(&app);
    m.ensure_running(&app).await?;
    Ok(m.status())
}

#[tauri::command]
pub async fn daemon_stop(app: AppHandle) -> CmdResult<DaemonStatus> {
    let m = manager(&app);
    m.stop(&app).await?;
    Ok(m.status())
}

#[derive(Debug, Clone, Serialize)]
pub struct GuiHandoff {
    /// URL of the auth-injecting proxy serving the official Web UI.
    pub url: String,
    /// Daemon version, e.g. "3.1.2 (1076)".
    pub version: Option<String>,
}

/// Make sure the daemon is up, then return the proxy URL the window should
/// load. `phase == starting` is surfaced so the boot page can keep waiting.
#[tauri::command]
pub async fn gui_url(app: AppHandle) -> CmdResult<GuiHandoff> {
    let m = manager(&app);
    m.ensure_running(&app).await?;
    let proxy = app
        .try_state::<crate::proxy::ProxyHandle>()
        .ok_or_else(|| "proxy not started".to_string())?;
    let version = m.client().version().await.ok();
    Ok(GuiHandoff {
        url: format!("{}/gui/", proxy.base_url),
        version,
    })
}

/// Download the official rslsync binary into ~/.local/bin (first run).
#[tauri::command]
pub async fn install_rslsync(app: AppHandle) -> CmdResult<String> {
    let path = crate::rslsync_install::install_official_binary().await?;
    let path = path.to_string_lossy().into_owned();
    // Bring the daemon up right away with the fresh binary.
    let m = manager(&app);
    m.ensure_running(&app).await?;
    Ok(path)
}

#[tauri::command]
pub fn get_app_settings(app: AppHandle) -> crate::settings::AppSettings {
    manager(&app).settings()
}

#[derive(Debug, Clone, Deserialize)]
pub struct SettingsUpdate {
    pub rslsync_path: Option<String>,
    pub webui_port: Option<u16>,
    pub device_name: Option<String>,
    pub autostart_daemon: Option<bool>,
    pub restart_on_crash: Option<bool>,
    pub keep_daemon_on_exit: Option<bool>,
    pub close_to_tray: Option<bool>,
}

#[tauri::command]
pub fn update_app_settings(
    app: AppHandle,
    update: SettingsUpdate,
) -> CmdResult<crate::settings::AppSettings> {
    let m = manager(&app);
    let mut s = m.settings();
    if let Some(v) = update.rslsync_path {
        s.rslsync_path = v.trim().to_string();
    }
    if let Some(v) = update.webui_port {
        if !(1024..=65535).contains(&v) {
            return Err("port must be in 1024..=65535".into());
        }
        s.webui_port = v;
    }
    if let Some(v) = update.device_name {
        s.device_name = v.trim().to_string();
    }
    if let Some(v) = update.autostart_daemon {
        s.autostart_daemon = v;
    }
    if let Some(v) = update.restart_on_crash {
        s.restart_on_crash = v;
    }
    if let Some(v) = update.keep_daemon_on_exit {
        s.keep_daemon_on_exit = v;
    }
    if let Some(v) = update.close_to_tray {
        s.close_to_tray = v;
    }
    m.update_settings(s);

    // Keep the auth-injecting proxy in sync with new credentials/port.
    let s = m.settings();
    if let Some(proxy) = app.try_state::<crate::proxy::ProxyHandle>() {
        proxy.update_config(crate::proxy::ProxyConfig {
            daemon_port: s.webui_port,
            login: s.webui_login.clone(),
            password: s.webui_password.clone(),
        });
    }
    Ok(m.settings())
}

#[tauri::command]
pub fn get_autostart() -> bool {
    crate::autostart::is_enabled()
}

#[tauri::command]
pub fn set_autostart(enable: bool) -> CmdResult<bool> {
    let exec = std::env::current_exe().map_err(|e| format!("cannot resolve executable: {e}"))?;
    crate::autostart::set_enabled(enable, &exec)
        .map_err(|e| format!("cannot update autostart: {e}"))?;
    Ok(enable)
}

#[tauri::command]
pub fn get_app_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[tauri::command]
pub fn open_settings(app: AppHandle) {
    crate::open_settings_window(&app);
}

#[tauri::command]
pub async fn pick_folder(app: AppHandle) -> CmdResult<Option<String>> {
    use tauri_plugin_dialog::DialogExt;
    let picked = app.dialog().file().blocking_pick_folder();
    Ok(picked
        .and_then(|f| f.into_path().ok())
        .map(|p| p.to_string_lossy().into_owned()))
}
