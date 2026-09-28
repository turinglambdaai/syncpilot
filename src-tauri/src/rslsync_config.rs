//! Generation of the `rslsync.conf` handed to the managed daemon.
//! The file keeps the Web UI on loopback with app-generated credentials,
//! so the GUI can talk to the API without prompting the user.

use crate::settings::AppSettings;
use std::path::{Path, PathBuf};

pub fn conf_path(app_dir: &Path) -> PathBuf {
    app_dir.join("rslsync.conf")
}

pub fn storage_dir(app_dir: &Path) -> PathBuf {
    app_dir.join("storage")
}

pub fn build_json(settings: &AppSettings, storage_path: &Path) -> String {
    let conf = serde_json::json!({
        "device_name": settings.device_name,
        "storage_path": storage_path.to_string_lossy(),
        "webui": {
            "listen": format!("127.0.0.1:{}", settings.webui_port),
            "login": settings.webui_login,
            "password": settings.webui_password,
            "api_key": settings.api_key
        },
        "shared_folders": []
    });
    serde_json::to_string_pretty(&conf).unwrap()
}

/// Write the config with restrictive permissions (secrets inside).
pub fn write_conf(app_dir: &Path, settings: &AppSettings) -> std::io::Result<PathBuf> {
    let storage = storage_dir(app_dir);
    std::fs::create_dir_all(&storage)?;
    let path = conf_path(app_dir);
    std::fs::write(&path, build_json(settings, &storage))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::AppSettings;

    #[test]
    fn conf_json_is_wellformed_and_loopback() {
        let s = AppSettings::default();
        let json = build_json(&s, Path::new("/tmp/storage"));
        let v: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        assert_eq!(v["webui"]["listen"], format!("127.0.0.1:{}", s.webui_port));
        assert_eq!(v["webui"]["api_key"], s.api_key.as_str());
        assert_eq!(v["device_name"], s.device_name.as_str());
        assert_eq!(v["storage_path"], "/tmp/storage");
    }

    #[test]
    fn write_conf_creates_files() {
        let dir = std::env::temp_dir().join(format!(
            "syncpilot-conf-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let s = AppSettings::default();
        let path = write_conf(&dir, &s).expect("write conf");
        assert!(path.exists());
        assert!(storage_dir(&dir).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
