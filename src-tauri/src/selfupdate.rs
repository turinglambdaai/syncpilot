//! In-app updates for the deb build. The updater plugin (commands.rs)
//! replaces AppImages in place but refuses deb/rpm — installing a package
//! needs root. This module closes that gap for deb installs: download the
//! new package from the release feed, verify it against the published
//! sha256 checksums, then run `pkexec dpkg -i` so the desktop's polkit
//! agent collects the administrator authorization. rpm keeps the
//! release-page fallback.

use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const RELEASE_BASE: &str = "https://github.com/turinglambdaai/syncpilot/releases/download";

/// deb package architecture for the running binary, e.g. "amd64"; the
/// names follow Debian's, not Rust's (`x86_64` → `amd64`).
pub fn deb_arch() -> Option<&'static str> {
    match std::env::consts::ARCH {
        "x86_64" => Some("amd64"),
        "aarch64" => Some("arm64"),
        _ => None,
    }
}

/// rustc target shorthand used by the release workflow's checksum files.
fn checksums_suffix() -> Option<&'static str> {
    match std::env::consts::ARCH {
        "x86_64" => Some("x86_64-unknown-linux-gnu"),
        "aarch64" => Some("aarch64-unknown-linux-gnu"),
        _ => None,
    }
}

pub fn deb_file_name(version: &str) -> Option<String> {
    deb_arch().map(|arch| format!("SyncPilot_{version}_{arch}.deb"))
}

/// True when this install can upgrade in place: not an AppImage, a deb
/// architecture we ship, and the two helpers the flow needs exist.
pub fn inplace_supported() -> bool {
    std::env::var_os("APPIMAGE").is_none()
        && deb_arch().is_some()
        && which("dpkg").is_some()
        && which("pkexec").is_some()
}

/// Extract the expected digest for `file_name` from a sha256sum listing
/// as produced by the release workflow (`<hash>  <relative/path>`).
pub fn expected_checksum(checksums: &str, file_name: &str) -> Option<String> {
    checksums.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let hash = parts.next()?;
        let path = parts.next()?;
        (Path::new(path).file_name()? == file_name).then(|| hash.to_string())
    })
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Download the release's deb for `version` into `dest_dir` after
/// verifying its sha256 against the published checksums. Returns the
/// verified file's path; nothing is written to disk before it checks out.
pub async fn download_verified_deb(
    http: &reqwest::Client,
    version: &str,
    dest_dir: &Path,
) -> Result<PathBuf, String> {
    let file_name = deb_file_name(version).ok_or_else(|| {
        "this CPU architecture has no deb build — update the package manually".to_string()
    })?;
    let base = format!("{RELEASE_BASE}/v{version}");
    let checksums_url = format!(
        "{base}/checksums-{}.txt",
        checksums_suffix().ok_or("unsupported architecture")?
    );

    let checksums = http
        .get(&checksums_url)
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .map_err(|e| format!("fetching the release checksums failed: {e}"))?
        .text()
        .await
        .map_err(|e| format!("reading the release checksums failed: {e}"))?;
    let expected = expected_checksum(&checksums, &file_name).ok_or_else(|| {
        format!("the release checksums have no entry for {file_name} — update the package manually")
    })?;

    let deb_url = format!("{base}/{file_name}");
    let bytes = http
        .get(&deb_url)
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .map_err(|e| format!("downloading {file_name} failed: {e}"))?
        .bytes()
        .await
        .map_err(|e| format!("reading {file_name} failed: {e}"))?;

    let actual = sha256_hex(&bytes);
    if actual != expected.to_lowercase() {
        return Err(format!(
            "checksum mismatch for {file_name}: expected {expected}, got {actual} — nothing was installed"
        ));
    }

    std::fs::create_dir_all(dest_dir)
        .and_then(|_| std::fs::write(dest_dir.join(&file_name), &bytes))
        .map_err(|e| format!("saving the downloaded package failed: {e}"))?;
    Ok(dest_dir.join(file_name))
}

/// The pkexec argv for installing `deb_path`. Exposed for tests.
fn pkexec_argv(dpkg_path: &str, deb_path: &Path) -> Vec<String> {
    vec![
        "pkexec".into(),
        dpkg_path.into(),
        "-i".into(),
        deb_path.display().to_string(),
    ]
}

/// Install a verified deb. Blocks on the polkit dialog; call from a
/// blocking thread. pkexec exits 126/127 when authorization fails or is
/// dismissed — distinguish that from a dpkg failure.
pub fn install_deb(deb_path: &Path) -> Result<(), String> {
    let dpkg = which("dpkg").ok_or("dpkg not found — is this a Debian-based system?")?;
    let argv = pkexec_argv(&dpkg, deb_path);
    let status = std::process::Command::new(&argv[0])
        .args(&argv[1..])
        .status()
        .map_err(|e| format!("failed to launch pkexec: {e}"))?;
    match status.code() {
        Some(0) => Ok(()),
        Some(126) | Some(127) => {
            Err("authorization was cancelled or failed — nothing was installed".into())
        }
        Some(code) => Err(format!(
            "dpkg -i failed (exit {code}) — the package is at {}",
            deb_path.display()
        )),
        None => Err("the install process was killed by a signal".into()),
    }
}

fn which(bin: &str) -> Option<String> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|dir| dir.join(bin))
            .find(|p| p.is_file())
            .map(|p| p.display().to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksum_line_is_matched_by_file_name_only() {
        let listing = concat!(
            "aaa111  deb/SyncPilot_0.3.2_amd64.deb\n",
            "bbb222  appimage/SyncPilot_0.3.2_amd64.AppImage\n",
        );
        assert_eq!(
            expected_checksum(listing, "SyncPilot_0.3.2_amd64.deb"),
            Some("aaa111".into())
        );
        assert_eq!(
            expected_checksum(listing, "SyncPilot_9.9.9_amd64.deb"),
            None
        );
    }

    #[test]
    fn sha256_matches_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn deb_file_name_matches_target_arch() {
        let Some(arch) = deb_arch() else { return };
        assert_eq!(
            deb_file_name("1.2.3"),
            Some(format!("SyncPilot_1.2.3_{arch}.deb"))
        );
    }

    #[test]
    fn pkexec_argv_is_absolute_and_installs() {
        let argv = pkexec_argv(
            "/usr/bin/dpkg",
            Path::new("/tmp/x/SyncPilot_1.0.0_amd64.deb"),
        );
        assert_eq!(
            argv,
            vec![
                "pkexec",
                "/usr/bin/dpkg",
                "-i",
                "/tmp/x/SyncPilot_1.0.0_amd64.deb"
            ]
        );
    }

    /// Full download + verify against a real release. Ignored by default
    /// (network): run with `cargo test -- --ignored` on a connection.
    #[test]
    #[ignore]
    fn downloads_and_verifies_a_real_release() {
        let http = reqwest::Client::new();
        let dest = std::env::temp_dir().join("syncpilot-selfupdate-test");
        let deb = tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(download_verified_deb(&http, "0.3.2", &dest))
            .expect("download + verify against the real v0.3.2 release");
        assert!(deb.is_file());
        let _ = std::fs::remove_dir_all(&dest);
    }
}
