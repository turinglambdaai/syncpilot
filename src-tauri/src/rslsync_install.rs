//! First-run installer for the official rslsync binary.
//!
//! SyncPilot does not bundle or redistribute Resilio's binary; on a fresh
//! machine without rslsync this downloads it straight from Resilio's CDN
//! into `~/.local/bin`, verifying the pinned sha256 checksum before install.
//! Same source and checksums as `scripts/install-rslsync.sh`.

use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::PathBuf;

const STABLE_URL_X64: &str =
    "https://download-cdn.resilio.com/stable/linux/x64/0/resilio-sync_x64.tar.gz";
const STABLE_URL_ARM64: &str =
    "https://download-cdn.resilio.com/stable/linux/arm64/0/resilio-sync_arm64.tar.gz";

/// Pinned checksums from the AUR rslsync PKGBUILD for Resilio stable
/// 3.1.2; re-pin when Resilio ships a new stable (same policy as
/// `scripts/install-rslsync.sh`).
pub const PINNED_SHA_X64: &str = "3cfedd41b3d21e2ae5fae58ca2114704d1ea4e4bab896796323c4a15c570f0f0";
pub const PINNED_SHA_ARM64: &str =
    "cdc30638d4a1909fb16685d25924216af70c2758160ffa74822d371f574fe136";

pub fn install_dir() -> PathBuf {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    home.join(".local").join("bin")
}

fn target_for_arch() -> Option<(&'static str, &'static str)> {
    match std::env::consts::ARCH {
        "x86_64" => Some((STABLE_URL_X64, PINNED_SHA_X64)),
        "aarch64" => Some((STABLE_URL_ARM64, PINNED_SHA_ARM64)),
        _ => None,
    }
}

/// Download, verify and install. Returns the installed binary path.
pub async fn install_official_binary() -> Result<PathBuf, String> {
    let (url, expected) = target_for_arch()
        .ok_or_else(|| format!("unsupported architecture: {}", std::env::consts::ARCH))?;

    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(300))
        .build()
        .map_err(|e| format!("http client: {e}"))?;

    // Transient CDN/network failures are common enough to retry a couple of
    // times before surfacing an error to the user.
    let mut bytes = None;
    let mut last_err = String::new();
    for attempt in 1..=3 {
        match download(&http, url).await {
            Ok(b) => {
                bytes = Some(b);
                break;
            }
            Err(e) => {
                last_err = e;
                if attempt < 3 {
                    tokio::time::sleep(std::time::Duration::from_secs(2 * attempt as u64)).await;
                }
            }
        }
    }
    let bytes = bytes.ok_or_else(|| {
        format!("{last_err} — check your network connection and retry, or install Resilio Sync manually")
    })?;

    verify_sha256(&bytes, expected)?;

    let binary = extract_rslsync(&bytes)?;
    let dest = install_dir();
    std::fs::create_dir_all(&dest).map_err(|e| format!("mkdir {}: {e}", dest.display()))?;
    let target = dest.join("rslsync");
    std::fs::write(&target, &binary).map_err(|e| format!("write {}: {e}", target.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("chmod {}: {e}", target.display()))?;
    }
    Ok(target)
}

async fn download(http: &reqwest::Client, url: &str) -> Result<Vec<u8>, String> {
    let resp = http
        .get(url)
        .send()
        .await
        .map_err(|e| format!("download failed: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!(
            "download failed: HTTP {} from {url}",
            resp.status()
        ));
    }
    resp.bytes()
        .await
        .map(|b| b.to_vec())
        .map_err(|e| format!("download body read failed: {e}"))
}

/// SHA-256 mismatch is a hard stop: the binary is executed, not inspected.
pub fn verify_sha256(bytes: &[u8], expected: &str) -> Result<(), String> {
    let actual = format!("{:x}", Sha256::digest(bytes));
    if actual != expected.to_lowercase() {
        return Err(format!(
            "checksum mismatch: expected {expected}, got {actual} — \
             the pinned Resilio stable may have moved; re-pin or install manually"
        ));
    }
    Ok(())
}

/// Pull the single `rslsync` executable out of the tar.gz payload.
pub fn extract_rslsync(gz: &[u8]) -> Result<Vec<u8>, String> {
    let gz = GzDecoder::new(gz);
    let mut archive = tar::Archive::new(gz);
    let mut entries = archive
        .entries()
        .map_err(|e| format!("archive read failed: {e}"))?;
    while let Some(entry) = entries
        .next()
        .transpose()
        .map_err(|e| format!("archive entry failed: {e}"))?
    {
        let path = entry
            .path()
            .map_err(|e| format!("entry path failed: {e}"))?
            .to_path_buf();
        let is_file = entry.header().entry_type().is_file();
        if is_file && path.file_name().map(|n| n == "rslsync").unwrap_or(false) {
            let mut out = Vec::new();
            entry
                .take(512 * 1024 * 1024)
                .read_to_end(&mut out)
                .map_err(|e| format!("entry read failed: {e}"))?;
            return Ok(out);
        }
    }
    Err("archive does not contain an `rslsync` binary".into())
}

use flate2::read::GzDecoder;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksum_verification() {
        let data = b"syncpilot test payload";
        let good = format!("{:x}", Sha256::digest(data));
        assert!(verify_sha256(data, &good).is_ok());
        assert!(verify_sha256(data, "deadbeef").is_err());
        // Uppercase hex in a pinned constant still matches.
        assert!(verify_sha256(data, &good.to_uppercase()).is_ok());
    }

    #[test]
    fn extracts_rslsync_from_tar_gz() {
        let mut builder = tar::Builder::new(Vec::new());
        let mut header = tar::Header::new_gnu();
        header.set_size(5);
        header.set_mode(0o755);
        header.set_cksum();
        builder
            .append_data(&mut header, "sub/dir/rslsync", b"HELLO" as &[u8])
            .unwrap();
        let tar_bytes = builder.into_inner().unwrap();
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        std::io::Write::write_all(&mut gz, &tar_bytes).unwrap();
        let gz_bytes = gz.finish().unwrap();

        let out = extract_rslsync(&gz_bytes).expect("extracts binary");
        assert_eq!(out, b"HELLO");
        assert!(extract_rslsync(b"not a gzip").is_err());
    }

    #[test]
    fn install_dir_is_under_home() {
        let dir = install_dir();
        assert!(dir.ends_with(".local/bin"), "got: {}", dir.display());
    }
}
