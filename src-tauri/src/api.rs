//! Client for the rslsync Web UI "action" API (`/gui/?token=…&action=…`).
//!
//! Verified against rslsync 3.1.2 on Linux — full transcript in
//! `docs/api-verified.md`. The headline facts that shape this module:
//!
//! - The Web UI is HTTP-basic-auth (`WWW-Authenticate: Basic realm="Resilio
//!   Sync"`); every request must carry the credentials.
//! - Each action request needs a CSRF token from `POST /gui/token.html`. The
//!   token sits in an HTML div and the official Web UI extracts it with
//!   `>([^<]+)<` — we do the same.
//! - A request with a stale/missing token returns HTTP 400 with the body
//!   `invalid request`; the client refreshes the token and retries once.
//! - Success responses are `{"status":200,"value":…}` — except a few actions
//!   (`getsyncfolders`, `adddir`) that reply with a bare object.
//! - Business errors are HTTP 500 + `{"error":"…","status":500}`, or a nested
//!   `{"error":N,"message":"…"}` inside `value`.
//! - The `/api/v2` REST routes found in the binary exist but only accept
//!   Resilio-ISSUED api keys (signed, versioned, revocation-checked); a
//!   locally generated key is rejected. The conf must not set one.
//! - rslsync 3.x gates folder operations on license/identity
//!   (`getlicenseinfo.allowed_to_sync`); folder adds are no-ops until the
//!   daemon is activated, so the client surfaces license state to the UI.

use serde::Serialize;
use serde_json::Value;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const EP_TOKEN: &str = "/gui/token.html";
const EP_ACTION: &str = "/gui/";

#[derive(Debug, Clone, Serialize, Default)]
#[serde(default)]
pub struct Peer {
    pub id: String,
    pub name: String,
    /// "online" / "offline" on most builds.
    pub status: Option<String>,
    /// "direct" / "relay" / "pex" / ...
    pub connection: Option<String>,
    /// "synced" / "syncing" / "offline" / ...
    pub syncstate: Option<String>,
    pub isreadable: Option<bool>,
    pub iswritable: Option<bool>,
    pub percent_downloaded: Option<f64>,
    pub download: Option<f64>,
    pub upload: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(default)]
pub struct Folder {
    pub id: String,
    pub secret: String,
    pub path: String,
    pub ispaused: bool,
    /// rslsync reports folder sizes as floats on some builds.
    pub size: Option<f64>,
    pub date_added: Option<u64>,
    /// 2 = read & write, 1 = read only (share level).
    pub synclevel: Option<u8>,
    pub peers: Vec<Peer>,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(default)]
pub struct KnownPeer {
    pub id: String,
    pub name: String,
    pub clientversion: Option<String>,
    pub os: Option<String>,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(default)]
pub struct RuntimeStatus {
    /// Bytes per second (last chart sample; 0 when the daemon reports none).
    pub speed_up: f64,
    pub speed_down: f64,
    pub paused: bool,
    pub uptime: Option<u64>,
    pub version: Option<String>,
}

/// rslsync 3.x activation state from `getlicenseinfo`. Folder operations are
/// no-ops until `allowed_to_sync` is true (activate via account sign-in or
/// the free trial).
#[derive(Debug, Clone, Serialize, Default)]
#[serde(default)]
pub struct LicenseState {
    pub allowed_to_sync: bool,
    pub valid: Option<bool>,
    pub can_use_trial: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct GeneratedSecrets {
    /// Read & write key.
    pub secret: String,
    pub read_only: Option<String>,
    pub encryption: Option<String>,
}

#[derive(Clone)]
pub struct ResilioClient {
    base: Arc<String>,
    login: Arc<String>,
    password: Arc<String>,
    http: reqwest::Client,
    /// CSRF token from token.html, reused until the daemon rejects it.
    token: Arc<std::sync::Mutex<Option<String>>>,
    /// `action=version` result, fetched once per client lifetime.
    version: Arc<std::sync::Mutex<Option<String>>>,
}

impl ResilioClient {
    /// `api_key` is accepted for call-site compatibility but intentionally
    /// unused: rslsync 3.x rejects locally generated keys (it expects
    /// Resilio-issued signed keys), so the conf ships without one.
    pub fn new(port: u16, _api_key: &str, login: &str, password: &str) -> Self {
        let http = reqwest::Client::builder()
            .cookie_store(true)
            .timeout(Duration::from_secs(8))
            .build()
            .expect("reqwest client builds");
        Self {
            base: Arc::new(format!("http://127.0.0.1:{port}")),
            login: Arc::new(login.to_string()),
            password: Arc::new(password.to_string()),
            http,
            token: Arc::new(std::sync::Mutex::new(None)),
            version: Arc::new(std::sync::Mutex::new(None)),
        }
    }

    /// True when something answers on the configured loopback port
    /// (401 still means a daemon is there, just unauthenticated).
    pub async fn ping(&self) -> bool {
        matches!(
            self.http
                .get(format!("{}{EP_ACTION}", self.base))
                .basic_auth(self.login.as_str(), Some(self.password.as_str()))
                .send()
                .await,
            Ok(r) if r.status().as_u16() == 200 || r.status().as_u16() == 401
        )
    }

    /// POST /gui/token.html and pull the CSRF token out of the HTML wrapper
    /// (`<div id='token' …>TOKEN</div>`).
    async fn fetch_token(&self) -> Result<String, String> {
        let resp = self
            .http
            .post(format!("{}{EP_TOKEN}", self.base))
            .basic_auth(self.login.as_str(), Some(self.password.as_str()))
            .query(&[("t", millis_now().to_string())])
            .send()
            .await
            .map_err(|e| format!("token request failed: {e}"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("token body read failed: {e}"))?;
        if status.as_u16() == 401 {
            return Err("basic auth rejected (check webui credentials)".into());
        }
        if !status.is_success() {
            return Err(format!("token request -> HTTP {status}"));
        }
        extract_token(&text)
            .ok_or_else(|| format!("token response has no token payload: {text:.100}"))
    }

    async fn token_or_refresh(&self, force: bool) -> Result<String, String> {
        if !force {
            if let Some(t) = self.token.lock().unwrap().clone() {
                return Ok(t);
            }
        }
        let t = self.fetch_token().await?;
        *self.token.lock().unwrap() = Some(t.clone());
        Ok(t)
    }

    fn invalidate_token(&self) {
        *self.token.lock().unwrap() = None;
    }

    /// Run one action and return its `value` payload (or the bare object for
    /// actions that reply without a `value` wrapper). Retries once with a
    /// fresh token when the daemon reports the current one invalid.
    async fn action(&self, action: &str, params: &[(&str, &str)]) -> Result<Value, String> {
        for retry in [false, true] {
            let token = self.token_or_refresh(retry).await?;
            let url = format!("{}{EP_ACTION}", self.base);
            let mut query: Vec<(&str, String)> = vec![
                ("token", token),
                ("action", action.to_string()),
                ("t", millis_now().to_string()),
            ];
            for (k, v) in params {
                query.push((k, (*v).to_string()));
            }
            let resp = self
                .http
                .get(&url)
                .basic_auth(self.login.as_str(), Some(self.password.as_str()))
                .query(&query)
                .send()
                .await
                .map_err(|e| format!("action {action} failed: {e}"))?;
            let status = resp.status().as_u16();
            let text = resp
                .text()
                .await
                .map_err(|e| format!("action {action} body read failed: {e}"))?;
            if status == 400 && text.contains("invalid request") {
                self.invalidate_token();
                continue;
            }
            if status == 401 {
                return Err("basic auth rejected (check webui credentials)".into());
            }
            if !(200..300).contains(&status) {
                // rslsync reports business errors as HTTP 500 + JSON envelope.
                if let Ok(v) = serde_json::from_str::<Value>(&text) {
                    if let Some(msg) = error_message(&v) {
                        return Err(format!("{action}: {msg}"));
                    }
                }
                return Err(format!("{action} -> HTTP {status}: {text:.200}"));
            }
            let v: Value = serde_json::from_str(&text)
                .map_err(|e| format!("action {action} non-JSON response: {e}"))?;
            if let Some(msg) = error_message(&v) {
                return Err(format!("{action}: {msg}"));
            }
            return Ok(v.get("value").cloned().unwrap_or(v));
        }
        Err(format!("{action}: daemon keeps rejecting the CSRF token"))
    }

    /// Client-level status: live transfer rates come from the speed charts
    /// (DOWNSPEED=1, UPSPEED=2 — mapping extracted from the official Web UI);
    /// `paused` has no action-API equivalent on 3.x and is always false.
    pub async fn status(&self) -> Result<RuntimeStatus, String> {
        let version = {
            let cached = self.version.lock().unwrap().clone();
            match cached {
                Some(v) => Some(v),
                None => match self.action("version", &[]).await {
                    Ok(v) => {
                        let s = v.as_str().unwrap_or_default().to_string();
                        *self.version.lock().unwrap() = Some(s.clone());
                        Some(s)
                    }
                    Err(_) => None,
                },
            }
        };
        Ok(RuntimeStatus {
            speed_down: self
                .action("getchartdata", &[("type", "1"), ("from", "0"), ("to", "0")])
                .await
                .map(|v| chart_last_sample(&v))
                .unwrap_or(0.0),
            speed_up: self
                .action("getchartdata", &[("type", "2"), ("from", "0"), ("to", "0")])
                .await
                .map(|v| chart_last_sample(&v))
                .unwrap_or(0.0),
            paused: false,
            uptime: None,
            version,
        })
    }

    pub async fn folders(&self) -> Result<Vec<Folder>, String> {
        self.action("getsyncfolders", &[("discovery", "1")])
            .await
            .map(|v| parse_folders(&v))
    }

    /// Folder list with peers attached: the folder payload may not embed
    /// peers, so fetch them per folder when missing.
    pub async fn folders_detailed(&self) -> Result<Vec<Folder>, String> {
        let mut folders = self.folders().await?;
        if folders.len() <= 20 {
            for f in &mut folders {
                if f.peers.is_empty() && !f.id.is_empty() {
                    f.peers = self.folder_peers(&f.id).await.unwrap_or_default();
                }
            }
        }
        Ok(folders)
    }

    pub async fn folder_peers(&self, fid: &str) -> Result<Vec<Peer>, String> {
        self.action("knownhosts", &[("id", fid)])
            .await
            .map(|v| parse_folder_peers(&v))
    }

    /// Peer transfer stats across all folders (`getpeersstat`).
    pub async fn known_peers(&self) -> Result<Vec<KnownPeer>, String> {
        self.action("getpeersstat", &[])
            .await
            .map(|v| parse_known_peers(&v))
    }

    /// Activation state (rslsync 3.x gates all folder operations on it).
    pub async fn license_info(&self) -> Result<LicenseState, String> {
        let v = self.action("getlicenseinfo", &[]).await?;
        Ok(LicenseState {
            allowed_to_sync: bool_field(&v, &["allowed_to_sync"]).unwrap_or(false),
            valid: bool_field(&v, &["valid"]),
            can_use_trial: bool_field(&v, &["can_use_trial"]),
        })
    }

    /// Start the free trial period (one of the two 3.x activation paths).
    pub async fn start_trial(&self) -> Result<(), String> {
        self.action("starttrialperiod", &[]).await.map(|_| ())
    }

    /// Generate a fresh share key set (`action=secret`; verified field names
    /// `secret` / `readonlysecret`).
    pub async fn generate_secrets(&self) -> Result<GeneratedSecrets, String> {
        let v = self.action("secret", &[]).await?;
        parse_secrets(&v).ok_or_else(|| "response contains no secret".to_string())
    }

    /// Add a folder. With a share key this joins an existing share
    /// (`addlink`); without one it creates a new synced folder at `dir`
    /// (`adddir` — the directory must NOT exist yet, rslsync creates it).
    /// On rslsync 3.x both fail until the daemon is activated; the license
    /// error is surfaced verbatim.
    pub async fn add_folder(&self, dir: &str, secret: Option<&str>) -> Result<(), String> {
        let key = secret.map(str::trim).filter(|s| !s.is_empty());
        match key {
            Some(k) => {
                let v = self.action("addlink", &[("link", k), ("dir", dir)]).await?;
                // addlink nests its error: {"status":200,"value":{"error":205,...}}
                if let Some(obj) = v.as_object() {
                    if let Some(e) = obj.get("error") {
                        let msg = obj
                            .get("message")
                            .and_then(Value::as_str)
                            .unwrap_or("unknown error");
                        return Err(format!("addlink: {msg} ({e})"));
                    }
                }
                Ok(())
            }
            None => {
                // Response on success: {"path": "..."} with no value wrapper.
                let _ = self.action("adddir", &[("dir", dir)]).await?;
                Ok(())
            }
        }
    }

    /// Remove a folder by id (files on disk are kept).
    pub async fn remove_folder(&self, id: &str) -> Result<(), String> {
        self.action("removefolder", &[("folderid", id)])
            .await
            .map(|_| ())
    }

    /// rslsync 3.x exposes no folder-pause action (verified against the
    /// official Web UI route table); the GUI hides the control instead.
    pub async fn pause_folder(&self, _id: &str, _paused: bool) -> Result<(), String> {
        Err("pause is not supported by rslsync 3.x".into())
    }

    /// rslsync 3.x exposes no global pause action either.
    pub async fn pause_all(&self, _paused: bool) -> Result<(), String> {
        Err("pause is not supported by rslsync 3.x".into())
    }

    pub async fn client_settings(&self) -> Result<Value, String> {
        self.action("settings", &[]).await
    }

    /// Global speed limits in KB/s via `setsettings`; -1 means unlimited
    /// (verified: set + read-back round-trips).
    pub async fn set_speed_limits(&self, up_kbps: i64, down_kbps: i64) -> Result<(), String> {
        let up = up_kbps.to_string();
        let down = down_kbps.to_string();
        self.action("setsettings", &[("ulrate", &up), ("dlrate", &down)])
            .await
            .map(|_| ())
    }

    pub async fn shutdown(&self) -> Result<(), String> {
        self.action("shutdown", &[]).await.map(|_| ())
    }
}

fn millis_now() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// The token.html body wraps the token in HTML tags; the official Web UI
/// matches `>([^<]+)<`. Walk tag pairs from the end: the `</html>` pair
/// yields an empty payload and is skipped, the innermost pair holds the
/// token.
fn extract_token(body: &str) -> Option<String> {
    body.rmatch_indices('<').find_map(|(end, _)| {
        let start = body[..end].rfind('>')?;
        let tok = &body[start + 1..end];
        (!tok.is_empty()).then(|| tok.to_string())
    })
}

/// Top-level envelope error `{"error":"msg","status":500}` or nested
/// `{"error":205,"message":"SE_SM_NO_IDENTITY"}` inside `value`.
fn error_message(v: &Value) -> Option<String> {
    let err = v.get("error")?;
    match err {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => {
            let msg = v
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown error");
            Some(format!("{msg} ({n})"))
        }
        _ => None,
    }
}

/// Newest-first chart samples; the first one is the latest rate.
fn chart_last_sample(v: &Value) -> f64 {
    v.as_array()
        .and_then(|a| a.first())
        .and_then(|s| s.get("value"))
        .and_then(Value::as_f64)
        .unwrap_or(0.0)
}

fn num_f64(v: Option<&Value>) -> f64 {
    match v {
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        _ => 0.0,
    }
}

fn str_field(v: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|k| v.get(*k).and_then(Value::as_str))
        .map(str::to_string)
}

fn bool_field(v: &Value, keys: &[&str]) -> Option<bool> {
    keys.iter().find_map(|k| v.get(*k).and_then(Value::as_bool))
}

fn num_field(v: &Value, keys: &[&str]) -> Option<f64> {
    keys.iter()
        .find_map(|k| v.get(*k))
        .map(|x| num_f64(Some(x)))
}

fn u64_field(v: &Value, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|k| v.get(*k).and_then(Value::as_u64))
}

pub fn parse_folders(v: &Value) -> Vec<Folder> {
    // Verified envelope: {"folders":[…],"status":200}; stay lenient about
    // wrapping for older builds.
    let arr = v
        .get("folders")
        .or_else(|| v.pointer("/value/folders"))
        .and_then(Value::as_array)
        .cloned()
        .or_else(|| v.as_array().cloned())
        .unwrap_or_default();
    arr.iter()
        .filter_map(|f| {
            let peers = f
                .get("peers")
                .and_then(Value::as_array)
                .map(|ps| ps.iter().map(parse_peer).collect())
                .unwrap_or_default();
            let folder = Folder {
                id: str_field(f, &["id", "folderid", "secret"]).unwrap_or_default(),
                secret: str_field(f, &["secret", "key"]).unwrap_or_default(),
                path: str_field(f, &["path", "dir"]).unwrap_or_default(),
                ispaused: bool_field(f, &["ispaused", "paused"]).unwrap_or(false),
                size: num_field(f, &["size"]),
                date_added: u64_field(f, &["date_added", "dateadded"]),
                synclevel: f.get("synclevel").and_then(Value::as_u64).map(|x| x as u8),
                peers,
            };
            if folder.id.is_empty() && folder.path.is_empty() {
                None
            } else {
                Some(folder)
            }
        })
        .collect()
}

pub fn parse_folder_peers(v: &Value) -> Vec<Peer> {
    let arr = v
        .as_array()
        .cloned()
        .or_else(|| v.get("peers").and_then(Value::as_array).cloned())
        .or_else(|| v.pointer("/value/peers").and_then(Value::as_array).cloned())
        .or_else(|| v.pointer("/value").and_then(Value::as_array).cloned())
        .unwrap_or_default();
    arr.iter().map(parse_peer).collect()
}

fn parse_peer(p: &Value) -> Peer {
    Peer {
        id: str_field(p, &["id", "peerid", "deviceid"]).unwrap_or_default(),
        name: str_field(p, &["name", "peername", "displayname"]).unwrap_or_default(),
        status: str_field(p, &["status", "state"]),
        connection: str_field(p, &["connection", "conntype", "linktype"]),
        syncstate: str_field(p, &["syncstate", "sync_state"]),
        isreadable: bool_field(p, &["isreadable"]),
        iswritable: bool_field(p, &["iswritable"]),
        percent_downloaded: num_field(p, &["percent_downloaded", "percentpermpleted", "progress"]),
        download: num_field(p, &["download", "recv_speed", "downspeed"]),
        upload: num_field(p, &["upload", "send_speed", "upspeed"]),
    }
}

pub fn parse_known_peers(v: &Value) -> Vec<KnownPeer> {
    let arr = v
        .as_array()
        .cloned()
        .or_else(|| v.get("peers").and_then(Value::as_array).cloned())
        .or_else(|| v.pointer("/value/peers").and_then(Value::as_array).cloned())
        .or_else(|| v.pointer("/value").and_then(Value::as_array).cloned())
        .unwrap_or_default();
    arr.iter()
        .map(|p| KnownPeer {
            id: str_field(p, &["id", "peerid", "deviceid"]).unwrap_or_default(),
            name: str_field(p, &["name", "peername", "displayname"]).unwrap_or_default(),
            clientversion: str_field(p, &["clientversion", "version"]),
            os: str_field(p, &["os", "platform"]),
        })
        .collect()
}

pub fn parse_secrets(v: &Value) -> Option<GeneratedSecrets> {
    let secret = str_field(v, &["secret"])?;
    Some(GeneratedSecrets {
        secret,
        read_only: str_field(v, &["readonlysecret", "rosecret", "read_only"]),
        encryption: str_field(v, &["encsecret", "encryption", "enc_secret"]),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    #[test]
    fn extracts_token_from_html_wrapper() {
        let body = "<html><div id='token' style='display:none;'>7QAlANw_Q9z6FT_AzWZNKya-vQU2mUiFcXMfSqA-Q2-bwOZW4cR2r05IumoAAAAA</div></html>";
        assert_eq!(
            extract_token(body).as_deref(),
            Some("7QAlANw_Q9z6FT_AzWZNKya-vQU2mUiFcXMfSqA-Q2-bwOZW4cR2r05IumoAAAAA")
        );
        // No tag pairs → no token payload.
        assert_eq!(extract_token("invalid request"), None);
        assert_eq!(extract_token(""), None);
    }

    #[test]
    fn error_envelopes_are_recognized() {
        let top = json!({"error": "can't find folder by folderid", "status": 500});
        assert_eq!(
            error_message(&top).as_deref(),
            Some("can't find folder by folderid")
        );
        let nested = json!({"error": 205, "message": "SE_SM_NO_IDENTITY"});
        assert_eq!(
            error_message(&nested).as_deref(),
            Some("SE_SM_NO_IDENTITY (205)")
        );
        assert_eq!(error_message(&json!({"status": 200})), None);
    }

    #[test]
    fn chart_sample_takes_newest() {
        let v = json!([{"time": 1790592995u64, "value": 42}, {"time": 1790592992u64, "value": 7}]);
        assert_eq!(chart_last_sample(&v), 42.0);
        assert_eq!(chart_last_sample(&json!([])), 0.0);
        assert_eq!(chart_last_sample(&json!({"nope": 1})), 0.0);
    }

    #[test]
    fn parses_folders_top_level_wrapped_and_bare_array() {
        let folder = json!({
            "id": "abc123",
            "secret": "SEC",
            "path": "/home/me/docs",
            "ispaused": true,
            "size": 1234.5,
            "date_added": 1700000000u64,
            "synclevel": 2,
            "peers": [{
                "id": "p1", "name": "laptop", "status": "online",
                "connection": "direct", "syncstate": "syncing",
                "percent_downloaded": 55.0, "download": 1024.0, "upload": 0.0
            }]
        });
        for v in [
            json!({ "folders": [folder], "status": 200 }),
            json!({ "value": { "folders": [folder] } }),
            json!([folder]),
        ] {
            let folders = parse_folders(&v);
            assert_eq!(folders.len(), 1, "shape must parse: {v}");
            let f = &folders[0];
            assert_eq!(f.id, "abc123");
            assert_eq!(f.path, "/home/me/docs");
            assert!(f.ispaused);
            assert_eq!(f.peers.len(), 1);
            assert_eq!(f.peers[0].syncstate.as_deref(), Some("syncing"));
        }
    }

    #[test]
    fn parses_folders_with_missing_fields() {
        let v = json!({ "folders": [{ "path": "/only/path" }] });
        let folders = parse_folders(&v);
        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].path, "/only/path");
        assert_eq!(folders[0].id, "");
        assert!(folders[0].peers.is_empty());
        let v2 = json!({ "folders": [42, "nope"] });
        assert!(parse_folders(&v2).is_empty());
    }

    #[test]
    fn parses_folder_peers_shapes() {
        let peer = json!({ "id": "p1", "name": "n1", "syncstate": "synced" });
        for v in [
            json!([peer]),
            json!({ "peers": [peer] }),
            json!({ "value": [peer] }),
        ] {
            assert_eq!(parse_folder_peers(&v).len(), 1);
        }
    }

    #[test]
    fn parses_known_peers_shapes() {
        let a = json!({ "value": [{ "id": "x", "name": "n1" }] });
        assert_eq!(parse_known_peers(&a).len(), 1);
        let b = json!([{ "id": "x", "name": "n1" }]);
        assert_eq!(parse_known_peers(&b).len(), 1);
    }

    #[test]
    fn parses_secrets_with_verified_field_names() {
        let v = json!({
            "canencrypt": false,
            "readonlysecret": "BFCXA3QKAPF3HPIOJRATWR7JM4GIQIIVS",
            "secret": "ATKB2I6C4GK62XJSZ3QBZ33BWQKFHLIVV",
            "secrettype": 1
        });
        let s = parse_secrets(&v).unwrap();
        assert_eq!(s.secret, "ATKB2I6C4GK62XJSZ3QBZ33BWQKFHLIVV");
        assert_eq!(
            s.read_only.as_deref(),
            Some("BFCXA3QKAPF3HPIOJRATWR7JM4GIQIIVS")
        );
        assert!(parse_secrets(&json!({ "nope": 1 })).is_none());
    }

    #[test]
    fn license_state_defaults_to_locked() {
        let v = json!({"allowed_to_sync": false, "can_use_trial": true, "valid": false});
        let st = LicenseState {
            allowed_to_sync: bool_field(&v, &["allowed_to_sync"]).unwrap_or(false),
            valid: bool_field(&v, &["valid"]),
            can_use_trial: bool_field(&v, &["can_use_trial"]),
        };
        assert!(!st.allowed_to_sync);
        assert!(st.can_use_trial.unwrap());
    }

    // ---- end-to-end against a tiny loopback HTTP mock ----

    /// Minimal loopback HTTP mock standing in for rslsync's Web UI server.
    /// Serves token.html and the /gui/?token=…&action=… surface with the
    /// verified envelope semantics (400 `invalid request` on a bad token).
    fn spawn_mock(routes: Vec<(&'static str, u16, String)>) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = match stream {
                    Ok(s) => s,
                    Err(_) => break,
                };
                let mut buf = [0u8; 16384];
                let n = stream.read(&mut buf).unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]);
                let (method, target) = {
                    let mut it = req.lines().next().unwrap_or("").split(' ');
                    (it.next().unwrap_or(""), it.next().unwrap_or(""))
                };
                let path = target.split('?').next().unwrap_or("");
                let query = target.split_once('?').map(|(_, q)| q).unwrap_or("");
                let mut params: Vec<(String, String)> = Vec::new();
                for kv in query.split('&').filter(|s| !s.is_empty()) {
                    let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
                    params.push((k.to_string(), v.to_string()));
                }
                let get = |name: &str| {
                    params
                        .iter()
                        .find(|(k, _)| k == name)
                        .map(|(_, v)| v.clone())
                };
                let (code, body) = if path == EP_TOKEN && method == "POST" {
                    (
                        200,
                        "<html><div id='token' style='display:none;'>TOK123</div></html>"
                            .to_string(),
                    )
                } else if path == EP_ACTION {
                    match (get("token").as_deref(), get("action")) {
                        (Some("TOK123"), _) => {
                            let action = get("action").unwrap_or_default();
                            routes
                                .iter()
                                .find(|(a, _, _)| *a == action)
                                .map(|(_, c, b)| (*c, b.clone()))
                                .unwrap_or((
                                    404,
                                    "{\"error\":\"unknown action\",\"status\":404}".into(),
                                ))
                        }
                        // Bare GET /gui/ is the Web UI page itself: the
                        // daemon answers 200 with valid basic auth.
                        (None, None) => (200, "{}".into()),
                        _ => (400, "invalid request".into()),
                    }
                } else {
                    (404, "not found".into())
                };
                let resp = format!(
                    "HTTP/1.1 {code} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(resp.as_bytes());
            }
        });
        port
    }

    #[tokio::test]
    async fn end_to_end_token_actions_and_error_surface() {
        let port = spawn_mock(vec![
            (
                "version",
                200,
                json!({"status":200,"value":"3.1.2 (1076)"}).to_string(),
            ),
            (
                "getchartdata",
                200,
                json!({"status":200,"value":[{"time":5u64,"value":0}]}).to_string(),
            ),
            (
                "getsyncfolders",
                200,
                json!({"folders":[{"id":"f1","path":"/tmp/x","secret":"S1"}],"status":200})
                    .to_string(),
            ),
            (
                "knownhosts",
                200,
                json!({"status":200,"value":[{"id":"p1","name":"laptop"}]}).to_string(),
            ),
            (
                "getpeersstat",
                200,
                json!({"status":200,"value":[]}).to_string(),
            ),
            (
                "getlicenseinfo",
                200,
                json!({"status":200,"value":{"allowed_to_sync":false,"can_use_trial":true}})
                    .to_string(),
            ),
            (
                "secret",
                200,
                json!({"status":200,"value":{"secret":"RW","readonlysecret":"RO"}}).to_string(),
            ),
            (
                "addlink",
                200,
                json!({"status":200,"value":{"error":205,"message":"SE_SM_NO_IDENTITY"}})
                    .to_string(),
            ),
            ("adddir", 200, json!({"path":"/tmp/x/"}).to_string()),
            ("removefolder", 200, json!({"status":200}).to_string()),
            ("setsettings", 200, json!({"status":200}).to_string()),
            (
                "settings",
                200,
                json!({"status":200,"value":{"dlrate":-1,"ulrate":2000}}).to_string(),
            ),
            ("shutdown", 200, json!({"status":200}).to_string()),
        ]);
        let c = ResilioClient::new(port, "unused", "u", "p");
        assert!(c.ping().await, "mock must answer on its port");

        let st = c.status().await.expect("status");
        assert_eq!(st.version.as_deref(), Some("3.1.2 (1076)"));
        assert_eq!(st.speed_down, 0.0);

        let detailed = c.folders_detailed().await.expect("folders");
        assert_eq!(detailed.len(), 1);
        assert_eq!(detailed[0].id, "f1");
        assert_eq!(detailed[0].peers.len(), 1, "peers sub-resource must merge");
        assert_eq!(detailed[0].peers[0].name, "laptop");

        let lic = c.license_info().await.expect("license");
        assert!(!lic.allowed_to_sync);
        assert!(lic.can_use_trial.unwrap());

        let sec = c.generate_secrets().await.expect("secrets");
        assert_eq!(sec.secret, "RW");
        assert_eq!(sec.read_only.as_deref(), Some("RO"));

        // addlink surfaces the nested 3.x license/identity error verbatim.
        let err = c.add_folder("/tmp/x", Some("RWKEY")).await.unwrap_err();
        assert!(err.contains("SE_SM_NO_IDENTITY"), "got: {err}");

        c.add_folder("/tmp/x", None).await.expect("adddir");
        c.remove_folder("f1").await.expect("remove");
        c.set_speed_limits(-1, 2000).await.expect("limits");
        let settings = c.client_settings().await.expect("settings read");
        assert_eq!(settings["ulrate"], 2000);
        assert_eq!(settings["dlrate"], -1);

        // Business errors (HTTP 500 + envelope) become Err with the message.
        assert!(c.pause_folder("f1", true).await.is_err());

        c.shutdown().await.expect("shutdown");
    }
}
