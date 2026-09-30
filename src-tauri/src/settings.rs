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
    pub device_name: String,
    /// Start the rslsync daemon together with the app.
    pub autostart_daemon: bool,
    /// Restart the daemon with backoff when it dies unexpectedly.
    pub restart_on_crash: bool,
    /// Keep the daemon running after the app exits.
    pub keep_daemon_on_exit: bool,
    /// Hide the window to the tray on close instead of quitting.
    pub close_to_tray: bool,
    /// Schema version of the persisted file; drives one-time migrations.
    /// Field-level default, not the container one: a file without the
    /// stamp predates versioning and must enter `migrate`, whereas the
    /// container default would fill the current version and skip it.
    #[serde(default = "legacy_settings_version")]
    pub settings_version: u32,
}

/// Bump when `Default` changes in a way existing installs should pick up.
/// `load` migrates older files exactly once and stamps this value, so a
/// user's explicit edits at the current version are never rewritten.
const SETTINGS_VERSION: u32 = 2;

/// Version assumed for files that predate the version stamp (everything
/// up to and including 0.2.x).
fn legacy_settings_version() -> u32 {
    1
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            rslsync_path: String::new(),
            webui_port: 38889,
            webui_login: "syncpilot".into(),
            webui_password: random_token(20),
            device_name: device_name(),
            autostart_daemon: true,
            restart_on_crash: true,
            // Sync clients are expected to keep working with their window
            // closed: the official Windows/macOS clients hide to the tray
            // and the daemon syncs regardless of any UI. Quit stays
            // explicit, via the tray menu.
            keep_daemon_on_exit: true,
            close_to_tray: true,
            settings_version: SETTINGS_VERSION,
        }
    }
}

pub fn settings_path(dir: &Path) -> PathBuf {
    dir.join("syncpilot-settings.json")
}

impl AppSettings {
    /// Load settings, creating defaults (with fresh credentials) on first run.
    /// A corrupt file is moved aside rather than failing the app.
    ///
    /// The freshly generated instance is both persisted AND returned —
    /// returning a second `default()` would silently fork the credentials:
    /// the file keeps one random password while the app (and the conf it
    /// writes for the daemon) uses another, and the two can never talk.
    pub fn load(dir: &Path) -> Self {
        let path = settings_path(dir);
        match fs::read_to_string(&path) {
            Ok(raw) => match serde_json::from_str::<AppSettings>(&raw) {
                Ok(mut s) => {
                    if s.settings_version < SETTINGS_VERSION {
                        s.migrate();
                        s.persist(dir);
                    }
                    s
                }
                Err(_) => {
                    let _ = fs::rename(&path, path.with_extension("json.bak"));
                    let fresh = Self::default();
                    fresh.persist(dir);
                    fresh
                }
            },
            Err(_) => {
                let fresh = Self::default();
                fresh.persist(dir);
                fresh
            }
        }
    }

    /// Bring a settings file written by an older version up to date. Runs
    /// at most once per version bump: `load` stamps the current version
    /// right after, so choices the user makes afterwards always win.
    fn migrate(&mut self) {
        // v1 shipped both flags as false; adopt the tray-first behavior
        // wholesale rather than leaving upgraded installs looking unchanged.
        if self.settings_version < 2 {
            self.close_to_tray = true;
            self.keep_daemon_on_exit = true;
        }
        self.settings_version = SETTINGS_VERSION;
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
        assert_ne!(
            a.webui_password, b.webui_password,
            "passwords must be random"
        );
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
            third.webui_password, first.webui_password,
            "credentials must survive reload"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn first_load_returns_the_persisted_instance() {
        // Regression: first load used to persist one random credential set
        // and return a second one, forking the app/daemon credentials.
        let dir = temp_dir("first-load");
        let returned = AppSettings::load(&dir);
        let stored: AppSettings =
            serde_json::from_str(&fs::read_to_string(settings_path(&dir)).unwrap()).unwrap();
        assert_eq!(returned.webui_password, stored.webui_password);
        assert_eq!(returned.webui_login, stored.webui_login);
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

    #[test]
    fn v1_file_migrates_to_tray_defaults_once() {
        let dir = temp_dir("migrate");
        // A pre-0.3.0 file: explicit false values, no version stamp.
        fs::write(
            settings_path(&dir),
            r#"{"close_to_tray": false, "keep_daemon_on_exit": false}"#,
        )
        .unwrap();
        let s = AppSettings::load(&dir);
        assert!(s.close_to_tray, "v1 installs must pick up hide-to-tray");
        assert!(s.keep_daemon_on_exit, "v1 installs must keep the daemon");
        assert_eq!(s.settings_version, SETTINGS_VERSION);
        let stored = fs::read_to_string(settings_path(&dir)).unwrap();
        assert!(
            stored.contains("\"settings_version\": 2"),
            "migration must be stamped to disk, got {stored}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn current_version_never_rewrites_explicit_false() {
        let dir = temp_dir("explicit");
        fs::write(
            settings_path(&dir),
            r#"{"settings_version": 2, "close_to_tray": false, "keep_daemon_on_exit": false}"#,
        )
        .unwrap();
        let s = AppSettings::load(&dir);
        assert!(!s.close_to_tray, "explicit opt-out must survive load");
        assert!(!s.keep_daemon_on_exit);
        let _ = fs::remove_dir_all(&dir);
    }
}
