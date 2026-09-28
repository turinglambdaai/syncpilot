//! Application-side settings (distinct from the generated rslsync.conf).
//! Stored as JSON under the app data dir; secrets are generated once on
//! first launch and never leave this machine.

use rand::Rng;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AppSettings {
    /// Explicit path to the rslsync binary; empty means auto-detect.
    pub rslsync_path: String,
    /// Port the embedded Web UI / API listens on, loopback only.
    pub webui_port: u16,
    pub webui_login: String,
    pub webui_password: String,
    pub api_key: String,
    pub device_name: String,
    /// Start the rslsync daemon together with the app.
    pub autostart_daemon: bool,
    /// Restart the daemon with backoff when it dies unexpectedly.
    pub restart_on_crash: bool,
    /// Keep the daemon running after the app exits.
    pub keep_daemon_on_exit: bool,
    /// Hide the window to the tray on close instead of quitting.
    pub close_to_tray: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            rslsync_path: String::new(),
            webui_port: 38889,
            webui_login: "syncpilot".into(),
            webui_password: random_token(20),
            api_key: random_token(32),
            device_name: device_name(),
            autostart_daemon: true,
            restart_on_crash: true,
            keep_daemon_on_exit: false,
            close_to_tray: false,
        }
    }
}

pub fn settings_path(dir: &Path) -> PathBuf {
    dir.join("syncpilot-settings.json")
}

impl AppSettings {
    /// Load settings, creating defaults (with fresh credentials) on first run.
    /// A corrupt file is moved aside rather than failing the app.
    pub fn load(dir: &Path) -> Self {
        let path = settings_path(dir);
        match fs::read_to_string(&path) {
            Ok(raw) => match serde_json::from_str::<AppSettings>(&raw) {
                Ok(s) => s,
                Err(_) => {
                    let _ = fs::rename(&path, path.with_extension("json.bak"));
                    Self::default().persist(dir);
                    Self::default()
                }
            },
            Err(_) => {
                Self::default().persist(dir);
                Self::default()
            }
        }
    }

    pub fn persist(&self, dir: &Path) -> &Self {
        let _ = fs::create_dir_all(dir);
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = fs::write(settings_path(dir), json);
        }
        self
    }
}

pub fn random_token(len: usize) -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut rng = rand::rng();
    (0..len)
        .map(|_| ALPHABET[rng.random_range(0..ALPHABET.len())] as char)
        .collect()
}

pub fn device_name() -> String {
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("COMPUTERNAME").ok())
        .unwrap_or_else(|| "syncpilot-device".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "syncpilot-test-{}-{}-{tag}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn defaults_have_fresh_credentials() {
        let a = AppSettings::default();
        let b = AppSettings::default();
        assert_eq!(a.webui_port, 38889);
        assert_eq!(a.webui_password.len(), 20);
        assert_eq!(a.api_key.len(), 32);
        assert_ne!(
            a.webui_password, b.webui_password,
            "passwords must be random"
        );
        assert_ne!(a.api_key, b.api_key, "api keys must be random");
    }

    #[test]
    fn load_creates_defaults_and_roundtrips() {
        let dir = temp_dir("roundtrip");
        let first = AppSettings::load(&dir);
        assert!(
            settings_path(&dir).exists(),
            "first load must persist defaults"
        );
        let mut second = first.clone();
        second.webui_port = 40001;
        second.device_name = "bench".into();
        second.persist(&dir);
        let third = AppSettings::load(&dir);
        assert_eq!(third.webui_port, 40001);
        assert_eq!(third.device_name, "bench");
        assert_eq!(
            third.api_key, first.api_key,
            "credentials must survive reload"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_file_falls_back_to_defaults() {
        let dir = temp_dir("corrupt");
        fs::write(settings_path(&dir), "{not json").unwrap();
        let s = AppSettings::load(&dir);
        assert_eq!(s.webui_port, 38889);
        assert!(dir.join("syncpilot-settings.json.bak").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn unknown_fields_survive_roundtrip() {
        let dir = temp_dir("extra");
        fs::write(
            settings_path(&dir),
            r#"{"webui_port": 39999, "future_field": true}"#,
        )
        .unwrap();
        let s = AppSettings::load(&dir);
        assert_eq!(s.webui_port, 39999);
        assert_eq!(s.webui_login, "syncpilot");
        let _ = fs::remove_dir_all(&dir);
    }
}
