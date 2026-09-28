//! XDG autostart entry management (~/.config/autostart/syncpilot.desktop).

use std::io;
use std::path::{Path, PathBuf};

const FILE_NAME: &str = "syncpilot.desktop";

pub fn autostart_dir() -> PathBuf {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/tmp"));
            home.join(".config")
        });
    config.join("autostart")
}

pub fn is_enabled() -> bool {
    is_enabled_in(&autostart_dir())
}

pub fn set_enabled(enable: bool, exec: &Path) -> io::Result<()> {
    set_enabled_in(&autostart_dir(), enable, exec)
}

pub fn is_enabled_in(dir: &Path) -> bool {
    dir.join(FILE_NAME).exists()
}

pub fn set_enabled_in(dir: &Path, enable: bool, exec: &Path) -> io::Result<()> {
    let file = dir.join(FILE_NAME);
    if !enable {
        if file.exists() {
            std::fs::remove_file(&file)?;
        }
        return Ok(());
    }
    std::fs::create_dir_all(dir)?;
    let content = format!(
        "[Desktop Entry]\nType=Application\nName=SyncPilot\nComment=Resilio Sync desktop GUI\nExec=\"{}\"\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
        exec.display()
    );
    std::fs::write(&file, content)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "syncpilot-autostart-{}-{}-{tag}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn enable_disable_roundtrip() {
        let dir = temp_dir("rt");
        let exec = Path::new("/usr/bin/SyncPilot");
        assert!(!is_enabled_in(&dir));
        set_enabled_in(&dir, true, exec).unwrap();
        assert!(is_enabled_in(&dir));
        let content = std::fs::read_to_string(dir.join(FILE_NAME)).unwrap();
        assert!(content.contains("Exec=\"/usr/bin/SyncPilot\""));
        assert!(content.contains("[Desktop Entry]"));
        set_enabled_in(&dir, false, exec).unwrap();
        assert!(!is_enabled_in(&dir));
        // disabling again is a no-op
        set_enabled_in(&dir, false, exec).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
