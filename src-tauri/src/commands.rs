//! Tauri command layer: thin wrappers over the manager and API client,
//! invoked from the frontend.

use crate::api::{Folder, GeneratedSecrets, KnownPeer, RuntimeStatus};
use crate::autostart;
use crate::manager::{DaemonStatus, Manager, Phase};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager as _};

type CmdResult<T> = Result<T, String>;

fn manager<'a>(app: &'a AppHandle) -> tauri::State<'a, Manager> {
    app.state::<Manager>()
}

fn running(app: &AppHandle) -> bool {
    manager(app).status().phase == Phase::Running
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

#[tauri::command]
pub async fn sync_status(app: AppHandle) -> CmdResult<Option<RuntimeStatus>> {
    if !running(&app) {
        return Ok(None);
    }
    Ok(manager(&app).client().status().await.ok())
}

#[tauri::command]
pub async fn list_folders(app: AppHandle) -> CmdResult<Vec<Folder>> {
    if !running(&app) {
        return Ok(Vec::new());
    }
    manager(&app).client().folders_detailed().await
}

#[tauri::command]
pub async fn list_known_peers(app: AppHandle) -> CmdResult<Vec<KnownPeer>> {
    if !running(&app) {
        return Ok(Vec::new());
    }
    manager(&app).client().known_peers().await
}

#[tauri::command]
pub async fn add_folder(app: AppHandle, path: String, secret: Option<String>) -> CmdResult<()> {
    manager(&app)
        .client()
        .add_folder(&path, secret.as_deref())
        .await
}

#[tauri::command]
pub async fn remove_folder(app: AppHandle, id: String) -> CmdResult<()> {
    manager(&app).client().remove_folder(&id).await
}

#[tauri::command]
pub async fn pause_folder(app: AppHandle, id: String, paused: bool) -> CmdResult<()> {
    manager(&app).client().pause_folder(&id, paused).await
}

#[tauri::command]
pub async fn pause_all(app: AppHandle, paused: bool) -> CmdResult<()> {
    manager(&app).client().pause_all(paused).await
}

#[tauri::command]
pub async fn generate_secret(app: AppHandle) -> CmdResult<GeneratedSecrets> {
    manager(&app).client().generate_secrets().await
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct SpeedLimits {
    /// KB/s; None = unlimited (rslsync reports -1).
    pub up_kbps: Option<u64>,
    pub down_kbps: Option<u64>,
}

#[tauri::command]
pub async fn get_speed_limits(app: AppHandle) -> CmdResult<SpeedLimits> {
    let settings = manager(&app).client().client_settings().await?;
    // Verified field names on 3.x: `ulrate` / `dlrate`; -1 = unlimited.
    let pick = |keys: &[&str]| -> Option<u64> {
        for k in keys {
            match settings.get(*k) {
                Some(serde_json::Value::Number(n)) => {
                    let v = n.as_i64().unwrap_or(-1);
                    if v > 0 {
                        return Some(v as u64);
                    }
                    return None;
                }
                _ => continue,
            }
        }
        None
    };
    Ok(SpeedLimits {
        up_kbps: pick(&["ulrate", "up", "upload"]),
        down_kbps: pick(&["dlrate", "down", "download"]),
    })
}

#[tauri::command]
pub async fn set_speed_limits(
    app: AppHandle,
    up_kbps: Option<u64>,
    down_kbps: Option<u64>,
) -> CmdResult<()> {
    // None = unlimited, which rslsync represents as -1 (0 is not accepted).
    let up = up_kbps.map(|v| v as i64).unwrap_or(-1);
    let down = down_kbps.map(|v| v as i64).unwrap_or(-1);
    manager(&app).client().set_speed_limits(up, down).await
}

#[derive(Debug, Clone, Serialize)]
pub struct LicenseState {
    /// rslsync 3.x gates folder operations on this.
    pub allowed_to_sync: bool,
    pub can_use_trial: Option<bool>,
}

#[tauri::command]
pub async fn license_state(app: AppHandle) -> CmdResult<LicenseState> {
    let lic = manager(&app).client().license_info().await?;
    Ok(LicenseState {
        allowed_to_sync: lic.allowed_to_sync,
        can_use_trial: lic.can_use_trial,
    })
}

/// Start the free trial period (rslsync 3.x activation path).
#[tauri::command]
pub async fn start_trial(app: AppHandle) -> CmdResult<()> {
    manager(&app).client().start_trial().await
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
    Ok(m.settings())
}

#[tauri::command]
pub fn get_autostart() -> bool {
    autostart::is_enabled()
}

#[tauri::command]
pub fn set_autostart(enable: bool) -> CmdResult<bool> {
    let exec = std::env::current_exe().map_err(|e| format!("cannot resolve executable: {e}"))?;
    autostart::set_enabled(enable, &exec).map_err(|e| format!("cannot update autostart: {e}"))?;
    Ok(enable)
}

#[tauri::command]
pub async fn pick_folder(app: AppHandle) -> CmdResult<Option<String>> {
    use tauri_plugin_dialog::DialogExt;
    let picked = app.dialog().file().blocking_pick_folder();
    Ok(picked
        .and_then(|f| f.into_path().ok())
        .map(|p| p.to_string_lossy().into_owned()))
}

#[tauri::command]
pub fn get_app_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
