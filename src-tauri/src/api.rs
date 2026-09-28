//! Async client for the local Resilio Sync (rslsync) Web UI v2 API.
//!
//! Endpoint paths below are aligned with the route table extracted from the
//! rslsync 3.1.2 binary (`grep -aoE '/api/v2/...' rslsync`) and are being
//! cross-checked against a live daemon by `scripts/verify-api.sh`. Marked
//! `[UNVERIFIED]` where the HTTP method or body shape is still a best guess.
//!
//! All endpoint paths live in this module on purpose: rslsync has field drift
//! between builds, so responses are parsed leniently — anything absent or of
//! an unexpected shape degrades to `None`/defaults instead of an error. If a
//! future rslsync release renames an endpoint, this is the one file to fix.

use serde::Serialize;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;

const EP_TOKEN: &str = "/api/v2/token";
const EP_CLIENT: &str = "/api/v2/client";
const EP_CLIENT_SETTINGS: &str = "/api/v2/client/settings";
const EP_SHUTDOWN: &str = "/api/v2/client/shutdown";
const EP_FOLDERS: &str = "/api/v2/folders";
const EP_SECRET: &str = "/api/v2/secret";
const EP_USERS: &str = "/api/v2/users";

#[derive(Debug, Clone, Copy, PartialEq)]
enum AuthMode {
    /// POST /token form-encoded `user`/`password`.
    FormUserPass,
    /// POST /token JSON `{"username", "password"}`.
    JsonUsername,
    /// POST /token JSON `{"user", "password"}`.
    JsonUser,
    /// GET /token with HTTP basic auth.
    Basic,
}

const AUTH_CANDIDATES: [AuthMode; 4] = [
    AuthMode::FormUserPass,
    AuthMode::JsonUsername,
    AuthMode::JsonUser,
    AuthMode::Basic,
];

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
    /// Bytes per second.
    pub speed_up: f64,
    pub speed_down: f64,
    pub paused: bool,
    pub uptime: Option<u64>,
    pub version: Option<String>,
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
    api_key: Arc<String>,
    login: Arc<String>,
    password: Arc<String>,
    http: reqwest::Client,
    /// The auth candidate that worked, so later calls skip probing.
    auth_mode: Arc<std::sync::Mutex<Option<AuthMode>>>,
}

impl ResilioClient {
    pub fn new(port: u16, api_key: &str, login: &str, password: &str) -> Self {
        let http = reqwest::Client::builder()
            .cookie_store(true)
            .timeout(Duration::from_secs(8))
            .build()
            .expect("reqwest client builds");
        Self {
            base: Arc::new(format!("http://127.0.0.1:{port}")),
            api_key: Arc::new(api_key.to_string()),
            login: Arc::new(login.to_string()),
            password: Arc::new(password.to_string()),
            http,
            auth_mode: Arc::new(std::sync::Mutex::new(None)),
        }
    }

    fn auth_headers(&self) -> reqwest::header::HeaderMap {
        let mut h = reqwest::header::HeaderMap::new();
        if !self.api_key.is_empty() {
            if let Ok(v) = reqwest::header::HeaderValue::from_str(&self.api_key) {
                h.insert("X-API-Key", v);
            }
        }
        h
    }

    /// Authenticate so the session cookie lands in the cookie jar. Tries the
    /// known candidates once, then remembers the winner. The X-API-Key header
    /// stays attached to every request regardless.
    pub async fn login(&self) -> Result<(), String> {
        // Copy first: the temporary guard must not live across the await.
        let known = *self.auth_mode.lock().unwrap();
        if let Some(mode) = known {
            return self.login_with(mode).await;
        }
        let mut last = "no auth candidate succeeded".to_string();
        for mode in AUTH_CANDIDATES {
            match self.login_with(mode).await {
                Ok(()) => {
                    *self.auth_mode.lock().unwrap() = Some(mode);
                    return Ok(());
                }
                Err(e) => last = e,
            }
        }
        Err(last)
    }

    async fn login_with(&self, mode: AuthMode) -> Result<(), String> {
        let url = format!("{}{EP_TOKEN}", self.base);
        let send = match mode {
            AuthMode::FormUserPass => {
                self.http
                    .post(&url)
                    .headers(self.auth_headers())
                    .form(&[
                        ("user", self.login.as_str()),
                        ("password", self.password.as_str()),
                    ])
                    .send()
                    .await
            }
            AuthMode::JsonUsername => {
                self.http
                    .post(&url)
                    .headers(self.auth_headers())
                    .json(&json!({
                        "username": *self.login,
                        "password": *self.password
                    }))
                    .send()
                    .await
            }
            AuthMode::JsonUser => {
                self.http
                    .post(&url)
                    .headers(self.auth_headers())
                    .json(&json!({"user": *self.login, "password": *self.password}))
                    .send()
                    .await
            }
            AuthMode::Basic => {
                return match self
                    .http
                    .get(&url)
                    .headers(self.auth_headers())
                    .basic_auth(self.login.as_str(), Some(self.password.as_str()))
                    .send()
                    .await
                {
                    Ok(r) if r.status().is_success() => Ok(()),
                    Ok(r) => Err(format!(
                        "token auth (basic) rejected with HTTP {}",
                        r.status()
                    )),
                    Err(e) => Err(format!("token request failed: {e}")),
                };
            }
        };
        match send {
            Ok(r) if r.status().is_success() => Ok(()),
            Ok(r) => Err(format!(
                "token auth ({mode:?}) rejected with HTTP {}",
                r.status()
            )),
            Err(e) => Err(format!("token request failed: {e}")),
        }
    }

    /// True when something answers on the configured loopback port
    /// (401 still means a daemon is there, just unauthenticated).
    pub async fn ping(&self) -> bool {
        matches!(
            self.http
                .get(format!("{}{EP_CLIENT}", self.base))
                .headers(self.auth_headers())
                .send()
                .await,
            Ok(r) if r.status().is_success() || r.status().as_u16() == 401
        )
    }

    async fn json_req(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Value,
    ) -> Result<Value, String> {
        let url = format!("{}{path}", self.base);
        for relogin in [false, true] {
            if relogin {
                self.login().await?;
            }
            let resp = self
                .http
                .request(method.clone(), &url)
                .headers(self.auth_headers())
                .json(&body)
                .send()
                .await
                .map_err(|e| format!("{method} {path} failed: {e}"))?;
            if resp.status().as_u16() == 401 && !relogin {
                continue;
            }
            let status = resp.status();
            let text = resp
                .text()
                .await
                .map_err(|e| format!("{method} {path} body read failed: {e}"))?;
            if !status.is_success() {
                return Err(format!("{method} {path} -> HTTP {status}: {text}"));
            }
            return Ok(serde_json::from_str(&text).unwrap_or(Value::Null));
        }
        Err(format!("{method} {path} still unauthorized after login"))
    }

    async fn get_json(&self, path: &str) -> Result<Value, String> {
        self.json_req(reqwest::Method::GET, path, Value::Null).await
    }

    /// Client-level status: transfer speeds and global pause state.
    /// Field names not yet confirmed on a live daemon (candidates kept).
    pub async fn status(&self) -> Result<RuntimeStatus, String> {
        let v = self.get_json(EP_CLIENT).await?;
        Ok(parse_status(&v))
    }

    pub async fn folders(&self) -> Result<Vec<Folder>, String> {
        self.get_json(EP_FOLDERS).await.map(|v| parse_folders(&v))
    }

    /// Folder list with peers attached: 3.x may expose peers only as a
    /// sub-resource (`/folders/{fid}/peers`), so fetch them when missing.
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
        let v = self.get_json(&format!("{EP_FOLDERS}/{fid}/peers")).await?;
        Ok(parse_folder_peers(&v))
    }

    /// Devices known to this client (may map to the 3.x `/users` resource).
    pub async fn known_peers(&self) -> Result<Vec<KnownPeer>, String> {
        let v = self.get_json(EP_USERS).await?;
        Ok(parse_known_peers(&v))
    }

    /// Generate a fresh share key set. The binary confirms a `/secret`
    /// resource; the `rosecret` field name is present in its strings.
    pub async fn generate_secrets(&self) -> Result<GeneratedSecrets, String> {
        let v = match self.get_json(EP_SECRET).await {
            Ok(v) => v,
            Err(_) => {
                self.json_req(reqwest::Method::POST, EP_SECRET, json!({}))
                    .await?
            }
        };
        parse_secrets(&v).ok_or_else(|| "response contains no secret".to_string())
    }

    /// Add a folder by directory (and optional share key). Falls back to the
    /// 2.x-era `path` field name if `dir` is rejected. `[UNVERIFIED body]`
    pub async fn add_folder(&self, dir: &str, secret: Option<&str>) -> Result<(), String> {
        let mut body = json!({ "dir": dir });
        if let Some(s) = secret {
            if !s.trim().is_empty() {
                body["secret"] = json!(s.trim());
            }
        }
        let first_err = match self
            .json_req(reqwest::Method::POST, EP_FOLDERS, body.clone())
            .await
        {
            Ok(_) => return Ok(()),
            Err(e) => e,
        };
        if let Some(obj) = body.as_object_mut() {
            obj.remove("dir");
            obj.insert("path".into(), json!(dir));
        }
        match self.json_req(reqwest::Method::POST, EP_FOLDERS, body).await {
            Ok(_) => Ok(()),
            Err(_) => Err(first_err),
        }
    }

    /// [UNVERIFIED] 3.x route table has `/folders/{fid}` — DELETE is the
    /// natural remove; verify-api.sh confirms.
    pub async fn remove_folder(&self, id: &str) -> Result<(), String> {
        self.json_req(
            reqwest::Method::DELETE,
            &format!("{EP_FOLDERS}/{id}"),
            json!({}),
        )
        .await
        .map(|_| ())
    }

    /// [UNVERIFIED] pause via PATCH `/folders/{fid}` `{"paused": bool}`.
    pub async fn pause_folder(&self, id: &str, paused: bool) -> Result<(), String> {
        self.json_req(
            reqwest::Method::PATCH,
            &format!("{EP_FOLDERS}/{id}"),
            json!({ "paused": paused }),
        )
        .await
        .map(|_| ())
    }

    /// 3.x has no global pause route; pause every folder individually.
    pub async fn pause_all(&self, paused: bool) -> Result<(), String> {
        let folders = self.folders().await?;
        for f in &folders {
            self.pause_folder(&f.id, paused).await?;
        }
        Ok(())
    }

    /// [UNVERIFIED] POST `/client/shutdown` — route confirmed in binary.
    pub async fn shutdown(&self) -> Result<(), String> {
        self.json_req(reqwest::Method::POST, EP_SHUTDOWN, json!({}))
            .await
            .map(|_| ())
    }

    pub async fn client_settings(&self) -> Result<Value, String> {
        self.get_json(EP_CLIENT_SETTINGS).await
    }

    /// 0 means unlimited, mirroring rslsync semantics.
    /// [UNVERIFIED] exact `speed_limits` shape — verify-api.sh will tell.
    pub async fn set_speed_limits(&self, up_kbps: u64, down_kbps: u64) -> Result<(), String> {
        self.json_req(
            reqwest::Method::PATCH,
            EP_CLIENT_SETTINGS,
            json!({ "speed_limits": { "up": up_kbps, "down": down_kbps } }),
        )
        .await
        .map(|_| ())
    }
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

/// First key present as a JSON number wins.
fn num_field_multi(v: &Value, keys: &[&str]) -> f64 {
    for k in keys {
        if let Some(x) = v.get(*k) {
            if matches!(x, Value::Number(_)) {
                return num_f64(Some(x));
            }
        }
    }
    0.0
}

pub fn parse_status(v: &Value) -> RuntimeStatus {
    RuntimeStatus {
        speed_up: num_field_multi(v, &["speed_up", "up", "upload_speed"]),
        speed_down: num_field_multi(v, &["speed_down", "down", "download_speed"]),
        paused: bool_field(v, &["paused", "ispaused"]).unwrap_or(false),
        uptime: u64_field(v, &["uptime"]),
        version: str_field(v, &["version", "clientversion"]),
    }
}

pub fn parse_folders(v: &Value) -> Vec<Folder> {
    // Both top-level {"folders":[...]} and wrapped {"data":{"folders":[...]}}
    // shapes are handled; a bare array also works.
    let arr = v
        .get("folders")
        .or_else(|| v.pointer("/data/folders"))
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
                id: str_field(f, &["id"]).unwrap_or_default(),
                secret: str_field(f, &["secret"]).unwrap_or_default(),
                path: str_field(f, &["path", "dir"]).unwrap_or_default(),
                ispaused: bool_field(f, &["ispaused", "paused"]).unwrap_or(false),
                size: num_field(f, &["size"]),
                date_added: u64_field(f, &["date_added"]),
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
        .or_else(|| v.pointer("/data/peers").and_then(Value::as_array).cloned())
        .unwrap_or_default();
    arr.iter().map(parse_peer).collect()
}

fn parse_peer(p: &Value) -> Peer {
    Peer {
        id: str_field(p, &["id"]).unwrap_or_default(),
        name: str_field(p, &["name"]).unwrap_or_default(),
        status: str_field(p, &["status"]),
        connection: str_field(p, &["connection"]),
        syncstate: str_field(p, &["syncstate"]),
        isreadable: bool_field(p, &["isreadable"]),
        iswritable: bool_field(p, &["iswritable"]),
        percent_downloaded: num_field(p, &["percent_downloaded"]),
        download: num_field(p, &["download"]),
        upload: num_field(p, &["upload"]),
    }
}

pub fn parse_known_peers(v: &Value) -> Vec<KnownPeer> {
    let arr = v
        .get("peers")
        .or_else(|| v.get("users"))
        .or_else(|| v.pointer("/data/peers"))
        .or_else(|| v.pointer("/data/users"))
        .and_then(Value::as_array)
        .cloned()
        .or_else(|| v.as_array().cloned())
        .unwrap_or_default();
    arr.iter()
        .map(|p| KnownPeer {
            id: str_field(p, &["id"]).unwrap_or_default(),
            name: str_field(p, &["name"]).unwrap_or_default(),
            clientversion: str_field(p, &["clientversion", "version"]),
            os: str_field(p, &["os", "platform"]),
        })
        .collect()
}

pub fn parse_secrets(v: &Value) -> Option<GeneratedSecrets> {
    let secret = str_field(v, &["secret"])?;
    Some(GeneratedSecrets {
        secret,
        read_only: str_field(v, &["rosecret", "read_only", "ro_secret"]),
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
            json!({ "folders": [folder] }),
            json!({ "data": { "folders": [folder] } }),
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
    fn parses_status_first_number_key_wins() {
        let v = json!({ "speed_up": 1024, "speed_down": 2048.5, "paused": false, "uptime": 99, "version": "3.1.2" });
        let s = parse_status(&v);
        assert_eq!(s.speed_up, 1024.0);
        assert_eq!(s.speed_down, 2048.5);
        assert_eq!(s.version.as_deref(), Some("3.1.2"));
        // alternate field names
        let v2 = json!({ "up": 5, "down": 6 });
        let s2 = parse_status(&v2);
        assert_eq!(s2.speed_up, 5.0);
        assert_eq!(s2.speed_down, 6.0);
        let s3 = parse_status(&json!({}));
        assert_eq!(s3.speed_up, 0.0);
        assert!(!s3.paused);
    }

    #[test]
    fn parses_folder_peers_shapes() {
        let peer = json!({ "id": "p1", "name": "n1", "syncstate": "synced" });
        for v in [
            json!([peer]),
            json!({ "peers": [peer] }),
            json!({ "data": { "peers": [peer] } }),
        ] {
            assert_eq!(parse_folder_peers(&v).len(), 1);
        }
    }

    #[test]
    fn parses_known_peers_users_key() {
        let a = json!({ "users": [{ "id": "x", "name": "n1" }] });
        assert_eq!(parse_known_peers(&a).len(), 1);
        let b = json!({ "peers": [{ "id": "x", "name": "n1" }] });
        assert_eq!(parse_known_peers(&b).len(), 1);
    }

    #[test]
    fn parses_secrets_variants() {
        let v = json!({ "secret": "RWKEY", "rosecret": "ROKEY" });
        let s = parse_secrets(&v).unwrap();
        assert_eq!(s.secret, "RWKEY");
        assert_eq!(s.read_only.as_deref(), Some("ROKEY"));
        assert!(parse_secrets(&json!({ "nope": 1 })).is_none());
    }

    // ---- end-to-end against a tiny loopback HTTP mock ----

    /// Minimal loopback HTTP mock standing in for rslsync. Responds per path
    /// regardless of method; `Connection: close` so each request is one
    /// connection.
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
                let route = req
                    .lines()
                    .next()
                    .unwrap_or("")
                    .split(' ')
                    .nth(1)
                    .unwrap_or("")
                    .split('?')
                    .next()
                    .unwrap_or("")
                    .to_string();
                let (code, body) = routes
                    .iter()
                    .find(|(p, _, _)| *p == route)
                    .map(|(_, c, b)| (*c, b.clone()))
                    .unwrap_or((404, "{\"error\":\"not found\"}".to_string()));
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
    async fn end_to_end_token_status_folders_secret_shutdown() {
        let port = spawn_mock(vec![
            ("/api/v2/token", 200, "ok".into()),
            (
                "/api/v2/client",
                200,
                json!({ "speed_up": 10, "speed_down": 20, "paused": false }).to_string(),
            ),
            (
                "/api/v2/folders",
                200,
                json!({ "folders": [{ "id": "f1", "path": "/tmp/x", "secret": "S1" }] })
                    .to_string(),
            ),
            (
                "/api/v2/folders/f1/peers",
                200,
                json!([{ "id": "p1", "name": "laptop", "syncstate": "synced" }]).to_string(),
            ),
            ("/api/v2/folders/f1", 200, "{}".into()),
            (
                "/api/v2/secret",
                200,
                json!({ "secret": "RW", "rosecret": "RO" }).to_string(),
            ),
            (
                "/api/v2/client/settings",
                200,
                json!({ "speed_limits": { "up": 100, "down": 200 } }).to_string(),
            ),
            ("/api/v2/client/shutdown", 200, "{}".into()),
        ]);
        let c = ResilioClient::new(port, "testkey", "u", "p");
        assert!(c.ping().await, "mock must answer on its port");
        c.login().await.expect("first auth candidate succeeds");

        let st = c.status().await.expect("status");
        assert_eq!(st.speed_down, 20.0);

        let detailed = c.folders_detailed().await.expect("folders");
        assert_eq!(detailed.len(), 1);
        assert_eq!(detailed[0].id, "f1");
        assert_eq!(detailed[0].peers.len(), 1, "peers sub-resource must merge");
        assert_eq!(detailed[0].peers[0].name, "laptop");

        let sec = c.generate_secrets().await.expect("secrets");
        assert_eq!(sec.secret, "RW");
        assert_eq!(sec.read_only.as_deref(), Some("RO"));

        c.pause_folder("f1", true).await.expect("pause");
        c.remove_folder("f1").await.expect("remove");

        c.set_speed_limits(100, 200).await.expect("limits");

        c.shutdown().await.expect("shutdown");
    }
}
